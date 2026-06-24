#!/usr/bin/env bash
# Full distributed-quorum pipeline on a REAL AWS account, including the switch Lambda:
#   apply the aggregation infra (TG + internal ALB + quorum alarm + SNS),
#   apply the switch Lambda (Terraform subscribes it to the SNS topic),
#   drive a quorum-DOWN with an unreachable stand-in target (no compute), then assert:
#     1. the quorum alarm latches ALARM,
#     2. SNS delivers (captured on a temp SQS queue),
#     3. the Lambda is invoked by SNS (CloudWatch Invocations metric > 0).
# Then tear everything down.
#
# No EKS: the Lambda runs in DRY_RUN and, with no Kubernetes credentials on AWS, errors at
# the switch attempt. That is expected here -- this test proves the AWS wiring up to the
# Lambda being invoked. The Lambda's actual ConfigMap switch + rollout is validated on
# kind (test/kind/switch_lambda_e2e.sh) and its SNS->parse path on LocalStack
# (PHASE=lambda ./test/aws/localstack.sh).
#
# No account-specific values are committed. Provide at runtime:
#   AWS auth/region : your environment (AWS_PROFILE / AWS_REGION / SSO)
#   VPC_ID          : required
#   SUBNET_IDS      : required, comma-separated, >= 2 subnets in different AZs (for the ALB)
#   NAME_PREFIX     : optional, default cb-health-full
#   APP_PORT        : optional, default 8080
#   KEEP            : optional, "1" leaves everything up (default 0)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
INFRA_SRC="$ROOT/deploy/aws"
LAMBDA_SRC="$ROOT/deploy/aws/lambda"
NAME_PREFIX="${NAME_PREFIX:-cb-health-full}"
APP_PORT="${APP_PORT:-8080}"
KEEP="${KEEP:-0}"
SECONDARY="couchbase://region-b-srv.region-b.svc"

: "${VPC_ID:?set VPC_ID=vpc-xxxx}"
: "${SUBNET_IDS:?set SUBNET_IDS=subnet-a,subnet-b (>=2 AZs)}"
for c in terraform aws python3 go; do
  command -v "$c" >/dev/null || { echo "FAIL: '$c' not found"; exit 1; }
done
aws sts get-caller-identity >/dev/null 2>&1 || { echo "FAIL: AWS not authenticated"; exit 1; }

TF_SUBNETS=$(python3 -c "import json,sys; print(json.dumps([s for s in sys.argv[1].split(',') if s]))" "$SUBNET_IDS")

WORK="$(mktemp -d)"
mkdir -p "$WORK/infra" "$WORK/lambda"
cp "$INFRA_SRC"/*.tf "$WORK/infra/"
cp "$LAMBDA_SRC"/*.tf "$WORK/lambda/"

echo "== build the switch lambda binary =="
( cd "$ROOT" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -tags lambda.norpc -o "$WORK/lambda/bootstrap" ./cmd/switch-lambda )

SUB_ARN=""; QURL=""
cleanup() {
  if [[ "$KEEP" == "1" ]]; then echo "KEEP=1 -> leaving resources up ($WORK)"; return; fi
  ( cd "$WORK/lambda" && terraform destroy -auto-approve -input=false \
      -var "switch_sns_topic_arn=${SNS:-arn:aws:sns:us-east-1:0:none}" -var "secondary_conn=$SECONDARY" \
      -var "name=$NAME_PREFIX-switch" >/dev/null 2>&1 ) || true
  [[ -n "$SUB_ARN" ]] && aws sns unsubscribe --subscription-arn "$SUB_ARN" >/dev/null 2>&1 || true
  [[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
  ( cd "$WORK/infra" && terraform destroy -auto-approve -input=false \
      -var "vpc_id=$VPC_ID" -var "subnet_ids=$TF_SUBNETS" -var "name_prefix=$NAME_PREFIX" >/dev/null 2>&1 ) || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== apply aggregation infra (real AWS; the internal ALB takes a few minutes) =="
( cd "$WORK/infra" && terraform init -input=false >/dev/null && \
  terraform apply -auto-approve -input=false \
    -var "vpc_id=$VPC_ID" -var "subnet_ids=$TF_SUBNETS" -var "name_prefix=$NAME_PREFIX" -var "app_port=$APP_PORT" >/dev/null )
SNS=$(cd "$WORK/infra" && terraform output -raw switch_sns_topic_arn)
TG=$(cd "$WORK/infra" && terraform output -raw monitoring_target_group_arn)
ALARM=$(cd "$WORK/infra" && terraform output -raw quorum_alarm_name)
echo "  sns: $SNS"

echo "== apply switch lambda (subscribes to SNS; DRY_RUN, no VPC) =="
( cd "$WORK/lambda" && terraform init -input=false >/dev/null && \
  terraform apply -auto-approve -input=false \
    -var "switch_sns_topic_arn=$SNS" -var "secondary_conn=$SECONDARY" \
    -var "deployments=mock-app" -var "dry_run=true" -var "name=$NAME_PREFIX-switch" >/dev/null )
FN=$(cd "$WORK/lambda" && terraform output -raw lambda_function_name)
echo "  lambda: $FN"

echo "== subscribe a temp SQS queue to SNS (to assert delivery) =="
QURL=$(aws sqs create-queue --queue-name "${NAME_PREFIX}-alarmq" --query QueueUrl --output text)
QARN=$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
POLICY=$(python3 -c 'import json,sys;q,s=sys.argv[1],sys.argv[2];print(json.dumps({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sns.amazonaws.com"},"Action":"sqs:SendMessage","Resource":q,"Condition":{"ArnEquals":{"aws:SourceArn":s}}}]}))' "$QARN" "$SNS")
aws sqs set-queue-attributes --queue-url "$QURL" --attributes "$(python3 -c 'import json,sys;print(json.dumps({"Policy":sys.argv[1]}))' "$POLICY")" >/dev/null
SUB_ARN=$(aws sns subscribe --topic-arn "$SNS" --protocol sqs --notification-endpoint "$QARN" --query SubscriptionArn --output text)

echo "== register an unreachable stand-in target (quorum-DOWN, no compute) =="
SUBNET1="${SUBNET_IDS%%,*}"
CIDR=$(aws ec2 describe-subnets --subnet-ids "$SUBNET1" --query 'Subnets[0].CidrBlock' --output text)
DOWN_IP=$(python3 -c "import ipaddress,sys; h=list(ipaddress.ip_network(sys.argv[1]).hosts()); print(h[min(200,len(h)-1)])" "$CIDR")
echo "  stand-in DOWN target: $DOWN_IP:$APP_PORT"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=$DOWN_IP,Port=$APP_PORT" >/dev/null

echo "== wait for the quorum alarm to latch =="
STATE=""
for i in $(seq 1 24); do
  STATE=$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)
  echo "  t=$((i*20))s alarm=$STATE"
  [[ "$STATE" == "ALARM" ]] && break
  sleep 20
done
[[ "$STATE" == "ALARM" ]] || { echo "FAIL: alarm did not reach ALARM"; exit 1; }

echo "== assert SNS delivered (SQS) =="
GOT=""
for i in $(seq 1 6); do
  BODY=$(aws sqs receive-message --queue-url "$QURL" --max-number-of-messages 1 --wait-time-seconds 10 --query 'Messages[0].Body' --output text 2>/dev/null)
  if [[ -n "$BODY" && "$BODY" != "None" ]]; then
    python3 -c "import sys,json; m=json.loads(json.load(sys.stdin)['Message']); print('  SNS->SQS:', m['AlarmName'], m['NewStateValue'])" <<<"$BODY"
    GOT=1; break
  fi
done
[[ -n "$GOT" ]] || { echo "FAIL: SNS message not delivered"; exit 1; }

echo "== assert SNS invoked the Lambda (CloudWatch Invocations > 0) =="
INVOKED=""
for i in $(seq 1 9); do
  START=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.UTC)-datetime.timedelta(minutes=15)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  END=$(python3 -c "import datetime;print(datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'))")
  SUM=$(aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations \
    --dimensions Name=FunctionName,Value="$FN" --start-time "$START" --end-time "$END" \
    --period 300 --statistics Sum --query 'sort_by(Datapoints,&Timestamp)[-1].Sum' --output text 2>/dev/null || true)
  echo "  t=$((i*20))s lambda invocations=$SUM"
  if [[ -n "$SUM" && "$SUM" != "None" ]] && python3 -c "import sys;sys.exit(0 if float(sys.argv[1])>0 else 1)" "$SUM" 2>/dev/null; then INVOKED=1; break; fi
  sleep 20
done
[[ -n "$INVOKED" ]] || { echo "FAIL: Lambda was not invoked by SNS"; exit 1; }

echo "PASS: full AWS pipeline -- quorum-DOWN -> alarm ALARM -> SNS delivered -> switch Lambda invoked"
