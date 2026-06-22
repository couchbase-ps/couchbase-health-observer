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
    if [[ "$output" != *"failed calling webhook"* || "$output" != *"connect: connection refused"* ]]; then
      return 1
    fi
    if [[ "$attempt" == "3" ]]; then
      echo "FAIL: admission webhook still refused connections after 3 Helm attempts"
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
  kubectl wait --for=condition=Available --timeout=10m \
    --namespace "$region" "couchbasecluster/$region"
  kubectl wait --for=condition=Ready --timeout=5m \
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

echo "== hold region-a down past FailoverDelay =="
kubectl patch couchbasecluster region-a --namespace region-a \
  --type=merge -p '{"spec":{"paused":true}}'
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
