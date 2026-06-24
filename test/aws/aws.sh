#!/usr/bin/env bash
# Deploy the aggregation module to a REAL AWS account and run the same fidelity check as
# the LocalStack test, but against real ALB/CloudWatch/SNS (which LocalStack cannot fully
# emulate): apply the module, register an unreachable stand-in target (no compute) to
# drive a quorum-DOWN, confirm UnHealthyHostCount -> alarm ALARM -> SNS delivered, then
# tear everything down.
#
# No account-specific values are committed. Provide them at runtime:
#   AWS auth/region : your environment (AWS_PROFILE / AWS_REGION / SSO)
#   VPC_ID          : required, the VPC to deploy into
#   SUBNET_IDS      : required, comma-separated, >= 2 subnets in different AZs
#   NAME_PREFIX     : optional, default cb-health-fidelity
#   APP_PORT        : optional, default 8080
#   KEEP            : optional, "1" leaves resources up for inspection (default 0)
#
# Example:
#   AWS_PROFILE=my-sandbox AWS_REGION=eu-west-1 \
#   VPC_ID=vpc-xxxx SUBNET_IDS=subnet-a,subnet-b ./test/aws/aws.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODULE="$HERE/../../deploy/aws"
NAME_PREFIX="${NAME_PREFIX:-cb-health-fidelity}"
APP_PORT="${APP_PORT:-8080}"
KEEP="${KEEP:-0}"

: "${VPC_ID:?set VPC_ID=vpc-xxxx}"
: "${SUBNET_IDS:?set SUBNET_IDS=subnet-a,subnet-b (>=2 AZs)}"

for c in terraform aws python3; do
  command -v "$c" >/dev/null || { echo "FAIL: '$c' not found"; exit 1; }
done
aws sts get-caller-identity >/dev/null 2>&1 || { echo "FAIL: AWS not authenticated (set AWS_PROFILE / AWS_REGION / SSO)"; exit 1; }

# terraform wants subnet_ids as a JSON list
TF_SUBNETS=$(python3 -c "import json,sys; print(json.dumps([s for s in sys.argv[1].split(',') if s]))" "$SUBNET_IDS")

# run terraform in a throwaway dir so no real-AWS state lands in the repo
WORK="$(mktemp -d)"
cp "$MODULE"/*.tf "$WORK"/

SUB_ARN=""; QURL=""
cleanup() {
  if [[ "$KEEP" == "1" ]]; then
    echo "KEEP=1 -> leaving resources up. Destroy later with:"
    echo "  (cd $WORK && terraform destroy -auto-approve -var vpc_id=$VPC_ID -var 'subnet_ids=$TF_SUBNETS' -var name_prefix=$NAME_PREFIX)"
    return
  fi
  [[ -n "$SUB_ARN" ]] && aws sns unsubscribe --subscription-arn "$SUB_ARN" >/dev/null 2>&1 || true
  [[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
  (cd "$WORK" && terraform destroy -auto-approve -input=false \
     -var "vpc_id=$VPC_ID" -var "subnet_ids=$TF_SUBNETS" -var "name_prefix=$NAME_PREFIX" >/dev/null 2>&1) || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== apply module (real AWS; the internal ALB takes a few minutes) =="
cd "$WORK"
terraform init -input=false >/dev/null
terraform apply -auto-approve -input=false \
  -var "vpc_id=$VPC_ID" -var "subnet_ids=$TF_SUBNETS" -var "name_prefix=$NAME_PREFIX" -var "app_port=$APP_PORT" >/dev/null
TG=$(terraform output -raw monitoring_target_group_arn)
SNS=$(terraform output -raw switch_sns_topic_arn)
ALARM=$(terraform output -raw quorum_alarm_name)
echo "  target group: $TG"
echo "  sns topic:    $SNS"

echo "== subscribe a temp SQS queue to the SNS topic =="
QURL=$(aws sqs create-queue --queue-name "${NAME_PREFIX}-alarmq" --query QueueUrl --output text)
QARN=$(aws sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
POLICY=$(python3 -c '
import json,sys
qarn,sns=sys.argv[1],sys.argv[2]
print(json.dumps({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sns.amazonaws.com"},"Action":"sqs:SendMessage","Resource":qarn,"Condition":{"ArnEquals":{"aws:SourceArn":sns}}}]}))' "$QARN" "$SNS")
aws sqs set-queue-attributes --queue-url "$QURL" --attributes "$(python3 -c 'import json,sys;print(json.dumps({"Policy":sys.argv[1]}))' "$POLICY")" >/dev/null
SUB_ARN=$(aws sns subscribe --topic-arn "$SNS" --protocol sqs --notification-endpoint "$QARN" --query SubscriptionArn --output text)

echo "== register an unreachable stand-in target (simulates a quorum-DOWN, no compute) =="
SUBNET1="${SUBNET_IDS%%,*}"
CIDR=$(aws ec2 describe-subnets --subnet-ids "$SUBNET1" --query 'Subnets[0].CidrBlock' --output text)
DOWN_IP=$(python3 -c "import ipaddress,sys; h=list(ipaddress.ip_network(sys.argv[1]).hosts()); print(h[min(200,len(h)-1)])" "$CIDR")
echo "  stand-in DOWN target: $DOWN_IP:$APP_PORT (nothing listening -> health check fails)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=$DOWN_IP,Port=$APP_PORT" >/dev/null

echo "== wait for the quorum alarm to latch (health checks + sustained window) =="
STATE=""
for i in $(seq 1 24); do
  STATE=$(aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text)
  echo "  t=$((i*20))s alarm=$STATE"
  [[ "$STATE" == "ALARM" ]] && break
  sleep 20
done
[[ "$STATE" == "ALARM" ]] || { echo "FAIL: alarm did not reach ALARM"; exit 1; }

echo "== confirm the SNS notification was delivered to SQS =="
GOT=""
for i in $(seq 1 6); do
  BODY=$(aws sqs receive-message --queue-url "$QURL" --max-number-of-messages 1 --wait-time-seconds 10 --query 'Messages[0].Body' --output text 2>/dev/null)
  if [[ -n "$BODY" && "$BODY" != "None" ]]; then
    python3 -c "import sys,json; m=json.loads(json.load(sys.stdin)['Message']); print('  SNS->SQS:', m['AlarmName'], m['NewStateValue'])" <<<"$BODY"
    GOT=1; break
  fi
done
[[ -n "$GOT" ]] || { echo "FAIL: no SNS message arrived on SQS"; exit 1; }

echo "PASS: real-AWS fidelity -- target unhealthy -> UnHealthyHostCount -> quorum alarm ALARM -> SNS delivered"
