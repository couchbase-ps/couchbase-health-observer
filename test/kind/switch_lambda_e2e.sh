#!/usr/bin/env bash
# Validates the switch Lambda's core logic against a real Kubernetes cluster: create a
# ConfigMap + Deployment, run the Lambda binary in one-shot mode with a synthetic ALARM
# event, and assert the ConfigMap flips to the secondary and the Deployment is rolled.
# This exercises the real binary (cmd/switch-lambda) and the reused actuator on kind,
# without needing AWS. Creates and deletes its own kind cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KIND_CLUSTER="${KIND_CLUSTER:-cb-switch-lambda-e2e}"
SECONDARY="couchbase://region-b-srv.region-b.svc"

for c in kind kubectl go; do
  command -v "$c" >/dev/null || { echo "FAIL: required command not found: $c"; exit 1; }
done

kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$KIND_CLUSTER" >/dev/null
trap 'kind delete cluster --name "$KIND_CLUSTER" >/dev/null 2>&1 || true' EXIT

KUBECONFIG_FILE="$(mktemp)"
kind get kubeconfig --name "$KIND_CLUSTER" > "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"

echo "== seed configmap (region-a) + a dependent deployment =="
kubectl create configmap cb-conn --from-literal=connstring=couchbase://region-a-srv.region-a.svc
kubectl create deployment mock-app --image=busybox:1.36 -- sh -c 'while true; do sleep 5; done'
kubectl rollout status deployment/mock-app --timeout=2m

BASELINE="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
echo "baseline connstring: $BASELINE"

echo "== run the switch lambda binary one-shot with a synthetic ALARM event =="
EVENT='{"Records":[{"Sns":{"Message":"{\"AlarmName\":\"cb-health-quorum-down\",\"NewStateValue\":\"ALARM\"}"}}]}'
NAMESPACE=default CONFIGMAP=cb-conn CONFIG_KEY=connstring DEPLOYMENTS=mock-app \
  SECONDARY_CONN="$SECONDARY" KUBECONFIG="$KUBECONFIG_FILE" ONESHOT_EVENT="$EVENT" \
  go run "$ROOT/cmd/switch-lambda"

echo "== assert the switch happened =="
NEW="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
echo "connstring after switch: $NEW"
[[ "$NEW" == "$SECONDARY" ]] || { echo "FAIL: configmap not switched to secondary"; exit 1; }
kubectl get deployment mock-app -o jsonpath='{.spec.template.metadata.annotations.observer/restartedAt}' | grep -q . \
  || { echo "FAIL: deployment was not rolled"; exit 1; }

echo "== assert an OK event does NOT switch back (no auto-failback) =="
OK_EVENT='{"Records":[{"Sns":{"Message":"{\"AlarmName\":\"cb-health-quorum-down\",\"NewStateValue\":\"OK\"}"}}]}'
NAMESPACE=default CONFIGMAP=cb-conn CONFIG_KEY=connstring DEPLOYMENTS=mock-app \
  SECONDARY_CONN="$SECONDARY" KUBECONFIG="$KUBECONFIG_FILE" ONESHOT_EVENT="$OK_EVENT" \
  go run "$ROOT/cmd/switch-lambda"
AFTER_OK="$(kubectl get configmap cb-conn -o jsonpath='{.data.connstring}')"
[[ "$AFTER_OK" == "$SECONDARY" ]] || { echo "FAIL: OK event must not change the connstring"; exit 1; }

echo "PASS: switch lambda flipped cb-conn to secondary and rolled mock-app; OK event was a no-op"
