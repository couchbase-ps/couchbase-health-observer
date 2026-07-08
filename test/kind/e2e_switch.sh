#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KIND_CLUSTER="${KIND_CLUSTER:-couchbase-health-observer}"
OBSERVER_IMAGE="${OBSERVER_IMAGE:-couchbase-health-observer:dev}"
KEEP_KIND="${KEEP_KIND:-0}"
CB_CHART="$ROOT/deploy/kind/couchbase-cluster"

# Mode: full automated test (default), or a manual demo driver.
#   e2e_switch.sh         full e2e (build, install, scenario A + B asserts, teardown)
#   e2e_switch.sh up      build + install + wait baseline + pause region-a, then STOP (no asserts, no teardown)
#   e2e_switch.sh down    delete the kind cluster
MODE="${1:-test}"

for command in docker kind kubectl helm; do
  command -v "$command" >/dev/null || {
    echo "FAIL: required command not found: $command"
    exit 1
  }
done

if [[ "$MODE" == "down" ]]; then
  echo "== deleting kind cluster: $KIND_CLUSTER =="
  kind delete cluster --name "$KIND_CLUSTER" || true
  echo "done"; exit 0
fi

cheatsheet() {
  cat <<'EOF'

================== KIND DEMO READY ==================
Couchbase UI (region-a): kubectl -n region-a port-forward svc/region-a-ui 8091:8091
   then open http://localhost:8091           (Administrator / password)
Couchbase UI (region-b): kubectl -n region-b port-forward svc/region-b-ui 8092:8091
   then open http://localhost:8092
Observer API : kubectl port-forward deployment/observer 8080:8080
   then curl -s http://localhost:8080/health/couchbase | jq
Observer logs: kubectl logs -f deployment/observer
App logs     : kubectl logs -f -l app=mock-app      (shows connstring=...region-a/b...)
cb-conn now  : kubectl get configmap cb-conn -o jsonpath='{.data.connstring}'

region-a operator is PAUSED, so killed pods are NOT rescheduled (real outage).
  Absorbed loss (NO switch): kill ONE node, e.g.
     kubectl delete pod region-a-0000 -n region-a --force --grace-period=0
  Full outage (SWITCH): kill the whole region
     kubectl delete pod -n region-a -l couchbase_cluster=region-a --force --grace-period=0
   -> observer flips cb-conn to region-b and rolls mock-app within ~30-60s.
Teardown     : test/kind/e2e_switch.sh down
====================================================
EOF
}

cleanup() {
  if [[ "$KEEP_KIND" != "1" ]]; then
    kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

helm_region() {
  local region="$1"
  # Common values.yaml (chart default) layered with the region's own overrides.
  helm upgrade --install "$region" "$CB_CHART" \
    --namespace "$region" \
    --create-namespace \
    --values "$CB_CHART/$region-values.yaml" \
    --wait \
    --timeout 10m
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
# The chart depends on the couchbase-operator repo; `helm dependency build`
# needs it registered locally (present on a dev box, absent on a clean CI runner).
helm repo add couchbase-partners https://couchbase-partners.github.io/helm-charts/ >/dev/null 2>&1 || true
helm repo update couchbase-partners >/dev/null 2>&1 || true
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

# Manual demo: everything is up, baseline on region-a, operator paused so a kill is a
# real outage. Keep the cluster and hand control to the presenter.
if [[ "$MODE" == "up" ]]; then
  KEEP_KIND=1
  cheatsheet
  exit 0
fi

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

echo "== assert liveness stays 200 while Couchbase is DOWN (must NOT restart the observer) =="
kubectl port-forward deployment/observer 18080:8080 >/tmp/pf-observer.log 2>&1 &
PF_PID=$!
sleep 3
LIVE="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/healthz)"
READY="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/readyz)"
kill "$PF_PID" 2>/dev/null || true
echo "  /healthz=$LIVE /readyz=$READY (during DB outage)"
[[ "$LIVE" == "200" ]] || { echo "FAIL: liveness not 200 during DB outage (would restart mid-outage)"; exit 1; }
[[ "$READY" == "200" ]] || { echo "FAIL: readiness not 200 (K8s API still reachable during DB outage)"; exit 1; }
RESTARTS="$(kubectl get pod -l app=observer -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')"
[[ "$RESTARTS" == "0" ]] || { echo "FAIL: observer restarted during DB outage (restartCount=$RESTARTS)"; exit 1; }
echo "observer survived the DB outage without restart (restartCount=0)"

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

# Scenario C: the observer restarts (cold start) into a region-a that is ALREADY
# DOWN while cb-conn still points at primary -- as if the previous instance died
# before it could react to the outage. region-a is already gone from scenario B
# (operator paused, pods force-deleted, never rescheduled), so there is no need to
# re-kill it; just rewind cb-conn back to primary to recreate the "not yet
# switched" starting state, then restart the observer and confirm it still
# switches (armed->AlreadySwitched cold-start reconciliation must not block a
# genuine pending switch).
echo "== scenario C: cold-start restart into already-DOWN primary, configmap==primary, expect switch =="
kubectl patch configmap cb-conn --type=merge -p '{"data":{"connstring":"couchbase://region-a-srv.region-a.svc"}}'

echo "stopping observer (simulate a crash before it could react to the outage)"
kubectl scale deployment/observer --replicas=0
kubectl wait --for=delete pod -l app=observer --timeout=60s

BEFORE_HASH="$(kubectl get deployment mock-app -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"

echo "cold-starting observer into the still-DOWN region-a"
kubectl scale deployment/observer --replicas=1
# Cold-start into a DOWN primary: the observer is intentionally NOT Ready until its
# first health evaluation completes (/readyz gates on firstEval), and readiness does
# NOT gate the switch loop. Wait for the pod to be Running, then assert on the switch.
kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l app=observer --timeout=2m

echo "== wait for ConfigMap switch =="
NEW=""
for _ in $(seq 1 120); do
  NEW="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
  [[ "$NEW" == "couchbase://region-b-srv.region-b.svc" ]] && break
  sleep 2
done
[[ "$NEW" == "couchbase://region-b-srv.region-b.svc" ]] || {
  echo "FAIL: cb-conn did not switch after cold-start restart (cb-conn=$NEW)"
  kubectl get pods -l app=observer -o wide || true
  kubectl describe pod -l app=observer || true
  kubectl logs deployment/observer --tail=200 || true
  exit 1
}

echo "== verify controlled redeploy picked up region-b =="
kubectl rollout status deployment/mock-app --timeout=2m
AFTER_HASH="$(kubectl get deployment mock-app -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"
[[ "$AFTER_HASH" != "$BEFORE_HASH" ]] || { echo "FAIL: mock-app not rolled after cold-start switch"; exit 1; }
echo "PASS: cold-start restart switched + rolled apps"

# Scenario D: the observer restarts (cold start) again, this time with cb-conn
# already on region-b (left by scenario C) and region-a still DOWN. It must adopt
# the already-switched state -- no re-switch, no app roll -- since the switch
# already happened; only the ConfigMap's current value at boot tells it that.
echo "== scenario D: cold-start with configmap already==secondary, expect adopt (no roll) =="
CONN_BEFORE="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
[[ "$CONN_BEFORE" == "couchbase://region-b-srv.region-b.svc" ]] || {
  echo "SETUP FAIL: expected cb-conn on secondary before scenario D, got $CONN_BEFORE"
  exit 1
}
ROLL_BEFORE="$(kubectl get deployment mock-app -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"

echo "stopping observer (simulate a crash after the switch already happened)"
kubectl scale deployment/observer --replicas=0
kubectl wait --for=delete pod -l app=observer --timeout=60s

echo "cold-starting observer; region-a still DOWN, cb-conn already on secondary"
kubectl scale deployment/observer --replicas=1
# Same as scenario C: cold-start into a DOWN primary is not Ready until the first
# evaluation; wait for Running, not Ready.
kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l app=observer --timeout=2m

echo "asserting cb-conn stays region-b for ~45s (> FailoverDelay)..."
for _ in $(seq 1 22); do
  CONN_AFTER="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
  [[ "$CONN_AFTER" == "couchbase://region-b-srv.region-b.svc" ]] || {
    echo "FAIL: cb-conn changed on adopt (cb-conn=$CONN_AFTER)"
    kubectl logs deployment/observer --tail=100 || true
    exit 1
  }
  sleep 2
done
ROLL_AFTER="$(kubectl get deployment mock-app -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"
[[ "$ROLL_AFTER" == "$ROLL_BEFORE" ]] || { echo "FAIL: mock-app rolled again on adopt (want no roll)"; exit 1; }
kubectl logs deployment/observer | grep -q "adopting switched state" || {
  echo "FAIL: observer did not log the adopt path"
  exit 1
}
echo "PASS: cold-start adopt, no re-switch, no app roll"
