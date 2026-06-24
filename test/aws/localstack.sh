#!/usr/bin/env bash
# LocalStack tests for the distributed-quorum AWS pieces. Two phases, selected with PHASE:
#
#   PHASE=infra   Aggregation Terraform shapes: target group, internal ALB -> listener ->
#                 TG, quorum alarm (TG+LB dimensions), SNS topic.
#                 Needs an elbv2-capable LocalStack tier (elbv2 + cloudwatch). The free
#                 tier excludes elbv2, so the apply fails with HTTP 501 "elbv2 service is
#                 not included within your LocalStack license".
#
#   PHASE=lambda  SNS -> switch Lambda trigger flow, exercising the real binary.
#                 Runs on the LocalStack FREE / community tier: it uses only lambda + sns
#                 (+ logs), none of which need a Pro/elbv2 license.
#
#   PHASE=all     (default) Run both. Needs the elbv2 tier because of the infra phase.
#
# Each phase creates and tears down its own resources (in a subshell with its own EXIT
# trap), so they are independent.
#
# Setup: pip install terraform-local awscli-local ; localstack start -d
#   - PHASE=lambda: the free tier is enough.
#   - PHASE=infra / all: set an elbv2-capable token first (localstack auth set-token ...).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODULE="$HERE/../../deploy/aws"
ROOT="$HERE/../.."
TFVARS="$MODULE/localstack/local.tfvars"
PHASE="${PHASE:-all}"

infra_phase() {
  for c in tflocal awslocal; do
    command -v "$c" >/dev/null || { echo "FAIL: '$c' not found. Install: pip install terraform-local awscli-local"; exit 1; }
  done
  cd "$MODULE"

  # elbv2 validates the VPC/subnets exist, and the internal ALB needs >= 2 subnets in
  # different AZs. Stand up an ephemeral VPC + 2 subnets and tear everything down on exit.
  local VPC SUBNET_A SUBNET_B SUBNET_IDS
  VPC=$(awslocal ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
  SUBNET_A=$(awslocal ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
  SUBNET_B=$(awslocal ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
  echo "[infra] ephemeral vpc: $VPC subnets: $SUBNET_A,$SUBNET_B"
  SUBNET_IDS="[\"$SUBNET_A\",\"$SUBNET_B\"]"
  trap '
    tflocal destroy -auto-approve -input=false -var-file="'"$TFVARS"'" -var "vpc_id='"$VPC"'" -var "subnet_ids='"$SUBNET_IDS"'" >/dev/null 2>&1 || true
    awslocal ec2 delete-subnet --subnet-id "'"$SUBNET_A"'" >/dev/null 2>&1 || true
    awslocal ec2 delete-subnet --subnet-id "'"$SUBNET_B"'" >/dev/null 2>&1 || true
    awslocal ec2 delete-vpc --vpc-id "'"$VPC"'" >/dev/null 2>&1 || true
  ' EXIT

  tflocal init -input=false >/dev/null
  tflocal apply -auto-approve -input=false -var-file="$TFVARS" -var "vpc_id=$VPC" -var "subnet_ids=$SUBNET_IDS"

  local TG_ARN SNS_ARN ALARM ALB_ARN
  TG_ARN=$(tflocal output -raw monitoring_target_group_arn)
  SNS_ARN=$(tflocal output -raw switch_sns_topic_arn)
  ALARM=$(tflocal output -raw quorum_alarm_name)
  ALB_ARN=$(tflocal output -raw monitoring_alb_arn)

  echo "[infra] target group: $TG_ARN"
  awslocal elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
    --query 'TargetGroups[0].HealthCheckPath' --output text | grep -q '/health/couchbase'

  echo "[infra] alb: $ALB_ARN"
  awslocal elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].Scheme' --output text | grep -q 'internal'
  # a listener must forward to the monitoring TG (otherwise the TG is never health-checked)
  awslocal elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text | grep -q "$TG_ARN"

  echo "[infra] alarm: $ALARM"
  awslocal cloudwatch describe-alarms --alarm-names "$ALARM" \
    --query 'MetricAlarms[0].ComparisonOperator' --output text | grep -q 'GreaterThanOrEqualToThreshold'
  # the alarm metric must carry BOTH the TargetGroup and LoadBalancer dimensions
  awslocal cloudwatch describe-alarms --alarm-names "$ALARM" \
    --query 'MetricAlarms[0].Metrics[].MetricStat.Metric.Dimensions[].Name' --output text | grep -q 'LoadBalancer'

  echo "[infra] sns: $SNS_ARN"
  awslocal sns list-topics --query 'Topics[].TopicArn' --output text | grep -q "$SNS_ARN"

  echo "[infra] PASS: terraform applies; TG health path, internal ALB+listener -> TG, quorum alarm (TG+LB dims), and SNS topic present"
}

lambda_phase() {
  command -v awslocal >/dev/null || { echo "FAIL: awslocal not found (pip install awscli-local)"; exit 1; }
  local FN TMP TOPIC LARN
  FN=cb-health-switch-localstack
  TMP="$(mktemp -d)"
  trap '
    awslocal lambda delete-function --function-name "'"$FN"'" >/dev/null 2>&1 || true
    [ -n "${TOPIC:-}" ] && awslocal sns delete-topic --topic-arn "$TOPIC" >/dev/null 2>&1 || true
    rm -rf "'"$TMP"'"
  ' EXIT

  echo "[lambda] build the binary + package (dummy kubeconfig so startup does not fatal)"
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

  echo "[lambda] create the function on localstack"
  awslocal lambda create-function --function-name "$FN" \
    --runtime provided.al2023 --handler bootstrap --architectures arm64 \
    --role arn:aws:iam::000000000000:role/irrelevant \
    --zip-file "fileb://$TMP/lambda.zip" \
    --environment "Variables={SECONDARY_CONN=couchbase://region-b,DEPLOYMENTS=mock-app,NAMESPACE=default,CONFIGMAP=cb-conn,CONFIG_KEY=connstring,DRY_RUN=true,KUBECONFIG=/var/task/kubeconfig}" >/dev/null
  awslocal lambda wait function-active-v2 --function-name "$FN"
  LARN=$(awslocal lambda get-function --function-name "$FN" --query 'Configuration.FunctionArn' --output text)

  echo "[lambda] subscribe to an SNS topic"
  TOPIC=$(awslocal sns create-topic --name cb-health-switch --query TopicArn --output text)
  awslocal sns subscribe --topic-arn "$TOPIC" --protocol lambda --notification-endpoint "$LARN" >/dev/null
  awslocal lambda add-permission --function-name "$FN" --statement-id sns \
    --action lambda:InvokeFunction --principal sns.amazonaws.com --source-arn "$TOPIC" >/dev/null 2>&1 || true

  echo "[lambda] publish a synthetic OK alarm (clean no-op; proves trigger + parse)"
  awslocal sns publish --topic-arn "$TOPIC" \
    --message '{"AlarmName":"cb-health-quorum-down","NewStateValue":"OK"}' >/dev/null

  echo "[lambda] confirm the lambda was invoked and parsed the event"
  local i LOGS FOUND=""
  for i in $(seq 1 15); do
    LOGS=$(awslocal logs filter-log-events --log-group-name "/aws/lambda/$FN" --query 'events[].message' --output text 2>/dev/null || true)
    if grep -q 'not actionable' <<<"$LOGS"; then FOUND=1; break; fi
    sleep 2
  done
  [ -n "$FOUND" ] || { echo "[lambda] FAIL: lambda was not invoked / did not parse the alarm"; exit 1; }
  echo "[lambda] PASS: SNS published -> lambda invoked -> alarm parsed (OK -> no-op, no auto-failback)"
}

case "$PHASE" in
  infra)  ( infra_phase ) ;;
  lambda) ( lambda_phase ) ;;
  all)    ( infra_phase ) && ( lambda_phase ) ;;
  *) echo "FAIL: PHASE must be infra | lambda | all"; exit 1 ;;
esac
echo "PASS (PHASE=$PHASE)"
