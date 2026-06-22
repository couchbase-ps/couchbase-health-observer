#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIND_CLUSTER="${KIND_CLUSTER:-couchbase-health-observer}"
OBSERVER_IMAGE="${OBSERVER_IMAGE:-couchbase-health-observer:dev}"
KEEP_KIND="${KEEP_KIND:-0}"
CB_CHART="$ROOT/deploy/kind/couchbase-cluster"

for command in docker kind kubectl helm; do
  command -v "$command" >/dev/null || {
    echo "FAIL: required command not found: $command"
    exit 1
  }
done

cleanup() {
  if [[ "$KEEP_KIND" != "1" ]]; then
    kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

helm_region() {
  local region="$1"

  if [[ "$region" == "region-b" ]]; then
    helm upgrade --install "$region" "$CB_CHART" \
      --namespace "$region" \
      --create-namespace \
      --values "$CB_CHART/region-b-values.yaml" \
      --wait \
      --timeout 10m
  else
    helm upgrade --install "$region" "$CB_CHART" \
      --namespace "$region" \
      --create-namespace \
      --wait \
      --timeout 10m
  fi
}

install_region() {
  local region="$1"
  local attempt
  local output

  for attempt in 1 2 3; do
    if output="$(helm_region "$region" 2>&1)"; then
      printf '%s\n' "$output"
      return
    fi

    printf '%s\n' "$output"
    # The official chart races on a cold node: the admission webhook is registered
    # before its pod can serve traffic, so the first create fails to *call* the
    # webhook (connection refused / context deadline exceeded / no endpoints). Retry
    # only those; a genuine validation rejection ("admission webhook ... denied the
    # request") has a different message and must fail fast.
    if [[ "$output" != *"failed calling webhook"* ]]; then
      return 1
    fi
    if [[ "$attempt" == "3" ]]; then
      echo "FAIL: admission webhook still not serving after 3 Helm attempts"
      return 1
    fi

    echo "admission webhook not accepting traffic yet; waiting before retry $((attempt + 1))/3"
    kubectl rollout status \
      "deployment/$region-couchbase-admission-controller" \
      --namespace "$region" \
      --timeout=5m
    sleep 2
  done
}

echo "== reset kind cluster: $KIND_CLUSTER =="
kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$KIND_CLUSTER" --config "$ROOT/deploy/kind/cluster.yaml"

echo "== build and load observer image =="
docker build -t "$OBSERVER_IMAGE" "$ROOT"
kind load docker-image "$OBSERVER_IMAGE" --name "$KIND_CLUSTER"

echo "== build the pinned official Couchbase chart dependency =="
helm dependency build "$CB_CHART"

echo "== install each region as one official CAO + CouchbaseCluster Helm release =="
install_region region-a
install_region region-b

for region in region-a region-b; do
  echo "waiting for $region..."
  # region-a brings up 5 nodes that the operator adds and rebalances; on kind that
  # can take well past 10m, so allow generous headroom.
  kubectl wait --for=condition=Available --timeout=20m \
    --namespace "$region" "couchbasecluster/$region"
  kubectl wait --for=condition=Ready --timeout=20m \
    --namespace "$region" "pod" -l "couchbase_cluster=$region"
done

echo "== deploy mock app and active observer =="
kubectl apply -k "$ROOT/deploy/kind/mock-app"
kubectl apply -k "$ROOT/deploy/kind/observer"
kubectl rollout status deployment/mock-app --timeout=2m
kubectl rollout status deployment/observer --timeout=2m

BASELINE="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
[[ "$BASELINE" == "couchbase://region-a-srv.region-a.svc" ]] || {
  echo "FAIL: unexpected baseline connstring: $BASELINE"
  exit 1
}
echo "baseline OK: cb-conn=$BASELINE"

# Pause the operator so deleted pods are NOT rescheduled; the surviving Couchbase
# nodes are what react (auto-failover, then full outage), exactly as in production.
echo "== pause region-a operator reconciliation =="
kubectl patch couchbasecluster region-a --namespace region-a \
  --type=merge -p '{"spec":{"paused":true}}'

# Scenario A: lose ONE region-a node. With 5 nodes + replica 1 and a 5s
# auto-failover timeout, Couchbase absorbs it well inside the 30s FailoverDelay,
# so the observer must NOT switch. Mirrors the docker e2e transient-DOWN path.
echo "== scenario A: single-node loss absorbed by auto-failover, expect NO switch =="
VICTIM="$(kubectl get pods --namespace region-a -l couchbase_cluster=region-a \
  -o jsonpath='{.items[0].metadata.name}')"
echo "killing one node: $VICTIM"
kubectl delete pod "$VICTIM" --namespace region-a --force --grace-period=0

echo "asserting cb-conn stays region-a for ~45s (> FailoverDelay)..."
for _ in $(seq 1 22); do
  CUR="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
  [[ "$CUR" == "couchbase://region-a-srv.region-a.svc" ]] || {
    echo "FAIL: observer switched on an absorbed single-node loss (cb-conn=$CUR)"
    kubectl logs deployment/observer --tail=100 || true
    exit 1
  }
  sleep 2
done
echo "scenario A OK: no switch, auto-failover absorbed the node"

# Scenario B: take the rest of region-a down. KV is now unreachable and stays
# DOWN past FailoverDelay, so the observer switches to region-b and rolls the app.
echo "== scenario B: full region-a outage, expect switch to region-b =="
kubectl delete pod --namespace region-a -l couchbase_cluster=region-a \
  --force --grace-period=0

echo "== wait for ConfigMap switch =="
NEW=""
for _ in $(seq 1 60); do
  NEW="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
  [[ "$NEW" == "couchbase://region-b-srv.region-b.svc" ]] && break
  sleep 2
done
[[ "$NEW" == "couchbase://region-b-srv.region-b.svc" ]] || {
  echo "FAIL: configmap not switched"
  kubectl logs deployment/observer --tail=100 || true
  exit 1
}

echo "== verify controlled redeploy picked up region-b =="
kubectl rollout status deployment/mock-app --timeout=2m
kubectl get deployment mock-app \
  -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}' | grep -q .
APP_LOGS="$(kubectl logs -l app=mock-app --tail=20)"
grep -q 'connstring=couchbase://region-b-srv.region-b.svc' <<<"$APP_LOGS"

echo "PASS: active observer switched cb-conn and rolled mock-app"
