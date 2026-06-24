#!/usr/bin/env bash
# Validates the SNS -> Lambda trigger wiring on LocalStack: deploy the real switch-lambda
# binary, subscribe it to an SNS topic, publish a synthetic alarm, and confirm the Lambda
# was invoked and parsed the event. Uses an OK event so the run is a clean no-op (no
# Kubernetes needed); the real switch against a cluster is covered by the kind e2e
# (test/kind/switch_lambda_e2e.sh).
#
# Requires: Docker + LocalStack running (lambda + sns + logs; community tier is enough),
# awslocal, and the Go toolchain. Lambda + SNS do NOT need a LocalStack Pro license.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FN=cb-health-switch-localstack
TMP="$(mktemp -d)"

command -v awslocal >/dev/null || { echo "FAIL: awslocal not found (pip install awscli-local)"; exit 1; }

cleanup() {
  awslocal lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
  [[ -n "${TOPIC:-}" ]] && awslocal sns delete-topic --topic-arn "$TOPIC" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "== build the lambda binary + package (with a dummy kubeconfig so startup does not fatal) =="
( cd "$ROOT" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o "$TMP/bootstrap" ./cmd/switch-lambda )
cat > "$TMP/kubeconfig" <<'KCFG'
apiVersion: v1
kind: Config
clusters: [{cluster: {server: https://127.0.0.1:6443}, name: dummy}]
contexts: [{context: {cluster: dummy, user: dummy}, name: dummy}]
current-context: dummy
users: [{name: dummy, user: {token: dummy}}]
KCFG
( cd "$TMP" && zip -q lambda.zip bootstrap kubeconfig )

echo "== create the lambda function on localstack =="
awslocal lambda create-function --function-name "$FN" \
  --runtime provided.al2023 --handler bootstrap --architectures arm64 \
  --role arn:aws:iam::000000000000:role/irrelevant \
  --zip-file "fileb://$TMP/lambda.zip" \
  --environment "Variables={SECONDARY_CONN=couchbase://region-b,DEPLOYMENTS=mock-app,NAMESPACE=default,CONFIGMAP=cb-conn,CONFIG_KEY=connstring,DRY_RUN=true,KUBECONFIG=/var/task/kubeconfig}" >/dev/null
awslocal lambda wait function-active-v2 --function-name "$FN"
LARN=$(awslocal lambda get-function --function-name "$FN" --query 'Configuration.FunctionArn' --output text)

echo "== subscribe the lambda to an SNS topic =="
TOPIC=$(awslocal sns create-topic --name cb-health-switch --query TopicArn --output text)
awslocal sns subscribe --topic-arn "$TOPIC" --protocol lambda --notification-endpoint "$LARN" >/dev/null
awslocal lambda add-permission --function-name "$FN" --statement-id sns \
  --action lambda:InvokeFunction --principal sns.amazonaws.com --source-arn "$TOPIC" >/dev/null 2>&1 || true

echo "== publish a synthetic OK alarm (clean no-op; proves trigger + parse) =="
awslocal sns publish --topic-arn "$TOPIC" \
  --message '{"AlarmName":"cb-health-quorum-down","NewStateValue":"OK"}' >/dev/null

echo "== confirm the lambda was invoked and parsed the event =="
FOUND=""
for i in $(seq 1 15); do
  LOGS=$(awslocal logs filter-log-events --log-group-name "/aws/lambda/$FN" \
    --query 'events[].message' --output text 2>/dev/null || true)
  if grep -q 'not actionable' <<<"$LOGS"; then FOUND=1; break; fi
  sleep 2
done
[[ -n "$FOUND" ]] || { echo "FAIL: lambda was not invoked / did not parse the alarm"; \
  awslocal logs filter-log-events --log-group-name "/aws/lambda/$FN" --query 'events[].message' --output text 2>/dev/null || true; exit 1; }

echo "PASS: SNS published -> lambda invoked -> alarm parsed (OK -> no-op, no auto-failback)"
