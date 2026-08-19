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
App logs (b) : kubectl logs -f -l app=mock-app-b -n app-b
cb-conn now  : kubectl get configmap cb-conn -o jsonpath='{.data.connstring}'
cb-conn (b)  : kubectl get configmap cb-conn -n app-b -o jsonpath='{.data.connstring}'

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

echo "== preload official Couchbase images into kind =="
# Each kind node otherwise pulls these from Docker Hub independently; with 6
# server pods + 2 operators that is many anonymous pulls of the same big
# images, which Docker Hub rate-limits and stalls (pod stuck ContainerCreating
# past the progress deadline). Pull once on the host, load into every node.
# NB: load via a single-platform `docker save` archive, NOT `kind load
# docker-image`. Docker's containerd image store keeps the full multi-platform
# manifest list, so `kind load docker-image` fails with
# "ctr: content digest <sha> not found" (it exports a manifest referencing
# platforms whose content is absent locally). `docker save --platform` exports
# only this node's arch, which `kind load image-archive` imports cleanly.
case "$(uname -m)" in
  aarch64|arm64) LOAD_PLATFORM=linux/arm64 ;;
  *)             LOAD_PLATFORM=linux/amd64 ;;
esac
for img in couchbase/operator:2.9.2 couchbase/admission-controller:2.9.2 couchbase/server:8.0.1; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull --platform "$LOAD_PLATFORM" "$img"
  archive="$(mktemp)"
  docker save --platform "$LOAD_PLATFORM" "$img" -o "$archive"
  kind load image-archive "$archive" --name "$KIND_CLUSTER"
  rm -f "$archive"
done

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
kubectl apply -k "$ROOT/deploy/kind/mock-app-b"
kubectl apply -k "$ROOT/deploy/kind/observer"
kubectl rollout status deployment/mock-app --timeout=2m
kubectl rollout status deployment/mock-app-b --namespace app-b --timeout=2m
kubectl rollout status deployment/observer --timeout=2m

BASELINE="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
[[ "$BASELINE" == "couchbase://region-a-srv.region-a.svc" ]] || {
  echo "FAIL: unexpected baseline connstring: $BASELINE"
  exit 1
}
echo "baseline OK: cb-conn=$BASELINE"

BASELINE_B="$(kubectl get configmap cb-conn --namespace app-b -o jsonpath='{.data.connstring}')"
[[ "$BASELINE_B" == "couchbase://region-a-srv.region-a.svc" ]] || {
  echo "FAIL: unexpected app-b baseline connstring: $BASELINE_B"
  exit 1
}
echo "baseline OK (app-b): cb-conn=$BASELINE_B"

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
  CUR_B="$(kubectl get configmap cb-conn --namespace app-b -o jsonpath='{.data.connstring}')"
  [[ "$CUR_B" == "couchbase://region-a-srv.region-a.svc" ]] || {
    echo "FAIL: observer switched app-b on an absorbed single-node loss (cb-conn=$CUR_B)"
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

echo "== assert the switch fanned out to app-b =="
NEW_B=""
for _ in $(seq 1 30); do
  NEW_B="$(kubectl get configmap cb-conn --namespace app-b -o jsonpath='{.data.connstring}')"
  [[ "$NEW_B" == "couchbase://region-b-srv.region-b.svc" ]] && break
  sleep 2
done
[[ "$NEW_B" == "couchbase://region-b-srv.region-b.svc" ]] || {
  echo "FAIL: app-b configmap not switched (cb-conn=$NEW_B)"
  kubectl logs deployment/observer --tail=100 || true
  exit 1
}

kubectl rollout status deployment/mock-app-b --namespace app-b --timeout=2m
kubectl get deployment mock-app-b --namespace app-b \
  -o jsonpath='{.spec.template.metadata.annotations.observer/switched-to}' \
  | grep -q 'couchbase://region-b-srv.region-b.svc'
APP_B_LOGS="$(kubectl logs -l app=mock-app-b --namespace app-b --tail=20)"
grep -q 'connstring=couchbase://region-b-srv.region-b.svc' <<<"$APP_B_LOGS" || {
  echo "FAIL: mock-app-b log does not show the switched connstring"
  echo "$APP_B_LOGS"
  exit 1
}
echo "PASS: switch fanned out to app-b and rolled mock-app-b"

echo "== verify controlled redeploy picked up region-b =="
kubectl rollout status deployment/mock-app --timeout=2m
kubectl get deployment mock-app \
  -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}' | grep -q .
APP_LOGS="$(kubectl logs -l app=mock-app --tail=20)"
grep -q 'connstring=couchbase://region-b-srv.region-b.svc' <<<"$APP_LOGS"

echo "PASS: active observer switched cb-conn and rolled mock-app"

# Verbose logging: the switch must emit the structured events (design 20260811).
SWITCH_LOGS="$(kubectl logs deployment/observer --tail=500)"
for ev in "SWITCHED " "Patching ConfigMap " "Rolling deployment "; do
  if ! grep -q "$ev" <<<"$SWITCH_LOGS"; then
    echo "FAIL: observer log missing event: $ev"
    echo "$SWITCH_LOGS" | tail -40
    exit 1
  fi
done
echo "PASS: switch emitted switched + configmap_patch + deployment_roll"

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
until kubectl get pod -l app=observer -o name 2>/dev/null | grep -q .; do sleep 1; done # RS may not have created the pod yet -> avoid "no matching resources found"
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
ROLL_B_BEFORE="$(kubectl get deployment mock-app-b --namespace app-b -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"

echo "stopping observer (simulate a crash after the switch already happened)"
kubectl scale deployment/observer --replicas=0
kubectl wait --for=delete pod -l app=observer --timeout=60s

echo "cold-starting observer; region-a still DOWN, cb-conn already on secondary"
kubectl scale deployment/observer --replicas=1
# Same as scenario C: cold-start into a DOWN primary is not Ready until the first
# evaluation; wait for Running, not Ready.
until kubectl get pod -l app=observer -o name 2>/dev/null | grep -q .; do sleep 1; done # RS may not have created the pod yet -> avoid "no matching resources found"
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
ROLL_B_AFTER="$(kubectl get deployment mock-app-b --namespace app-b -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"
[[ "$ROLL_B_AFTER" == "$ROLL_B_BEFORE" ]] || { echo "FAIL: mock-app-b rolled again on adopt (want no roll)"; exit 1; }
# Retry the log check: the adopt line is emitted once at startup, but a lone
# `kubectl logs` right after a pod restart can transiently miss it, so poll like
# every other assertion here rather than one-shot.
ADOPT_LOGGED=0
for _ in $(seq 1 15); do
  if kubectl logs deployment/observer 2>/dev/null | grep -q "Adopting already-switched"; then
    ADOPT_LOGGED=1; break
  fi
  sleep 2
done
[[ "$ADOPT_LOGGED" == "1" ]] || {
  echo "FAIL: observer did not log the adopt path"
  kubectl logs deployment/observer --tail=100 || true
  exit 1
}
echo "PASS: cold-start adopt, no re-switch, no app roll"

# Scenario E: a webhook-only observer (--actuators=webhook) must POST the switch
# request and must NOT touch any cb-conn or roll any app. region-a is still DOWN
# from the earlier scenarios, and both ConfigMaps are on region-b, so rewind BOTH
# to primary to recreate a pending switch that only the webhook may act on.
echo "== scenario E: webhook-only observer, expect POST and NO configmap patch =="
kubectl apply -k "$ROOT/deploy/kind/webhook-receiver"
kubectl rollout status deployment/webhook-receiver --timeout=2m

kubectl patch configmap cb-conn --type=merge -p '{"data":{"connstring":"couchbase://region-a-srv.region-a.svc"}}'
kubectl patch configmap cb-conn --namespace app-b --type=merge -p '{"data":{"connstring":"couchbase://region-a-srv.region-a.svc"}}'
ROLL_BEFORE_E="$(kubectl get deployment mock-app -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"
ROLL_B_BEFORE_E="$(kubectl get deployment mock-app-b --namespace app-b -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"

echo "restarting the observer in webhook-only mode"
kubectl scale deployment/observer --replicas=0
kubectl wait --for=delete pod -l app=observer --timeout=60s
# The observer Deployment runs --interval=2s, so the liveness window (3x interval)
# is 6s. The guard now warns on the COMBINED probe + webhook budget: 2*probe-timeout
# + (retries+1)*webhook-timeout + backoff. The webhook defaults (3s timeout, 2
# retries) allow a worst case of 12s total against that 6s window, which would
# starve the observer's liveness heartbeat and let kubelet restart the pod
# mid-scenario. 1s timeout + 1 retry keeps the webhook's own worst case at about
# 3s (two 1s attempts plus 1s backoff), but combined with the 2*2s=4s probe
# budget that is 7s against the 6s window, so this scenario emits a
# webhook_window_tight WARN. That WARN is expected and harmless here: the
# secondary probe returns fast and the receiver answers immediately, so the
# real tick stays well under the window. Do not "simplify" this back to the
# plan's defaults.
# Args index 0 is the actuator selector (see deploy/kind/observer/deployment.yaml),
# so replacing it swaps the whole actuator set in one op.
kubectl patch deployment observer --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/args/0","value":"--actuators=webhook"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--webhook-url=http://webhook-receiver:8080/hook"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--webhook-header=X-Source: observer"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--webhook-timeout=1s"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--webhook-retries=1"}
]'
kubectl scale deployment/observer --replicas=1
until kubectl get pod -l app=observer -o name 2>/dev/null | grep -q .; do sleep 1; done
kubectl wait --for=jsonpath='{.status.phase}'=Running pod -l app=observer --timeout=2m

echo "== wait for the webhook delivery =="
DELIVERED=0
for _ in $(seq 1 60); do
  if kubectl logs deployment/webhook-receiver 2>/dev/null | grep -q '"event":"switch_required"'; then
    DELIVERED=1; break
  fi
  sleep 2
done
[[ "$DELIVERED" == "1" ]] || {
  echo "FAIL: webhook receiver never saw the switch request"
  kubectl logs deployment/webhook-receiver --tail=100 || true
  kubectl logs deployment/observer --tail=200 || true
  exit 1
}

echo "== assert the payload targets region-b and carries the custom header =="
# The receiver is a small unbuffered Python HTTP server (see
# deploy/kind/webhook-receiver/deployment.yaml): it prints "HDR <name>: <value>"
# for every request header and "BODY <json>" for the decoded body before it
# answers 204, so both lines are already complete by the time they hit stdout.
# Do NOT expect a second POST to fix a miss here: once a delivery succeeds the
# state machine latches and the observer stops posting (it re-POSTs only while
# delivery FAILS). The polling here just absorbs the lag between the receiver
# writing to stdout and `kubectl logs` returning it.
PAYLOAD_OK=0
for _ in $(seq 1 30); do
  RECEIVED="$(kubectl logs deployment/webhook-receiver 2>/dev/null || true)"
  BODY_LINE="$(grep '^BODY ' <<<"$RECEIVED" | tail -1)"
  # This observer runs --actuators=webhook, but the pre-existing
  # --configmap=cb-conn,app-b/cb-conn and --deployments=mock-app,app-b/mock-app-b
  # args are still on the Deployment (see the patch above), so this is exactly the
  # case that regresses if the payload construction ever stops gating on the k8s
  # actuator: configmaps/deployments must be absent even though non-empty values
  # were passed on the command line. Check the BODY line, not the whole log, so a
  # header echoing either word could not false-pass.
  if grep -q 'HDR X-Source: observer' <<<"$RECEIVED" && grep -q 'couchbase://region-b-srv.region-b.svc' <<<"$RECEIVED" \
      && ! grep -q '"configmaps"' <<<"$BODY_LINE" && ! grep -q '"deployments"' <<<"$BODY_LINE"; then
    PAYLOAD_OK=1; break
  fi
  sleep 2
done
[[ "$PAYLOAD_OK" == "1" ]] || {
  echo "FAIL: never saw a complete request (header + region-b payload) from the receiver, or the webhook-only payload leaked the Kubernetes configmaps/deployments fields"
  kubectl logs deployment/webhook-receiver --tail=200 || true
  kubectl logs deployment/observer --tail=200 || true
  exit 1
}

echo "== assert the observer logged the call and left Kubernetes alone =="
WEBHOOK_LOGGED=0
for _ in $(seq 1 15); do
  if kubectl logs deployment/observer 2>/dev/null | grep -q "Webhook called"; then
    WEBHOOK_LOGGED=1; break
  fi
  sleep 2
done
[[ "$WEBHOOK_LOGGED" == "1" ]] || {
  echo "FAIL: observer did not log webhook_called"
  kubectl logs deployment/observer --tail=200 || true
  exit 1
}
CONN_E="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
[[ "$CONN_E" == "couchbase://region-a-srv.region-a.svc" ]] || {
  echo "FAIL: webhook-only observer patched cb-conn (cb-conn=$CONN_E)"
  exit 1
}
CONN_E_B="$(kubectl get configmap cb-conn --namespace app-b -o jsonpath='{.data.connstring}')"
[[ "$CONN_E_B" == "couchbase://region-a-srv.region-a.svc" ]] || {
  echo "FAIL: webhook-only observer patched the app-b cb-conn (cb-conn=$CONN_E_B)"
  exit 1
}
ROLL_AFTER_E="$(kubectl get deployment mock-app -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"
[[ "$ROLL_AFTER_E" == "$ROLL_BEFORE_E" ]] || { echo "FAIL: webhook-only observer rolled mock-app"; exit 1; }
ROLL_B_AFTER_E="$(kubectl get deployment mock-app-b --namespace app-b -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}')"
[[ "$ROLL_B_AFTER_E" == "$ROLL_B_BEFORE_E" ]] || { echo "FAIL: webhook-only observer rolled mock-app-b"; exit 1; }
echo "PASS: webhook-only observer POSTed the switch and left Kubernetes untouched"
