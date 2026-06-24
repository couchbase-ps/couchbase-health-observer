#!/usr/bin/env bash
# AWS stack test: apply the distributed-quorum aggregation Terraform against LocalStack
# and assert the resource shapes (target group health path, quorum alarm comparator,
# SNS topic). This proves the Terraform applies and the resources exist with the right
# shape. It does NOT prove that a monitoring-only target group emits UnHealthyHostCount
# the way real ALB does -- that fidelity check is the AWS-sandbox runbook in
# deploy/aws/README.md.
#
# Requires: Docker, LocalStack running with a license tier that includes elbv2 (plus
# cloudwatch and sns). The freemium tier excludes elbv2, so the target group apply
# fails with HTTP 501 "elbv2 service is not included within your LocalStack license".
# Setup:
#   pip install terraform-local awscli-local
#   localstack auth set-token <token>   # or export LOCALSTACK_AUTH_TOKEN=...
#   localstack start -d
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODULE="$HERE/../../deploy/aws"
TFVARS="$MODULE/localstack/local.tfvars"

for c in tflocal awslocal; do
  command -v "$c" >/dev/null || {
    echo "FAIL: '$c' not found. Install: pip install terraform-local awscli-local"
    exit 1
  }
done

cd "$MODULE"

# elbv2 validates the VPC/subnets exist, and the internal ALB needs >= 2 subnets in
# different AZs. Stand up an ephemeral VPC + 2 subnets for the test and tear everything
# down on exit (so the test is repeatable).
VPC=$(awslocal ec2 create-vpc --cidr-block 10.0.0.0/16 --query 'Vpc.VpcId' --output text)
SUBNET_A=$(awslocal ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
SUBNET_B=$(awslocal ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)
echo "ephemeral vpc: $VPC subnets: $SUBNET_A,$SUBNET_B"
SUBNET_IDS="[\"$SUBNET_A\",\"$SUBNET_B\"]"
cleanup() {
  tflocal destroy -auto-approve -input=false -var-file="$TFVARS" -var "vpc_id=$VPC" -var "subnet_ids=$SUBNET_IDS" >/dev/null 2>&1 || true
  awslocal ec2 delete-subnet --subnet-id "$SUBNET_A" >/dev/null 2>&1 || true
  awslocal ec2 delete-subnet --subnet-id "$SUBNET_B" >/dev/null 2>&1 || true
  awslocal ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

tflocal init -input=false >/dev/null
tflocal apply -auto-approve -input=false -var-file="$TFVARS" -var "vpc_id=$VPC" -var "subnet_ids=$SUBNET_IDS"

TG_ARN=$(tflocal output -raw monitoring_target_group_arn)
SNS_ARN=$(tflocal output -raw switch_sns_topic_arn)
ALARM=$(tflocal output -raw quorum_alarm_name)
ALB_ARN=$(tflocal output -raw monitoring_alb_arn)

echo "target group: $TG_ARN"
awslocal elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].HealthCheckPath' --output text | grep -q '/health/couchbase'

echo "alb: $ALB_ARN"
awslocal elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].Scheme' --output text | grep -q 'internal'
# a listener must forward to the monitoring TG (otherwise the TG is never health-checked)
awslocal elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text | grep -q "$TG_ARN"

echo "alarm: $ALARM"
awslocal cloudwatch describe-alarms --alarm-names "$ALARM" \
  --query 'MetricAlarms[0].ComparisonOperator' --output text | grep -q 'GreaterThanOrEqualToThreshold'
# the alarm metric must carry BOTH the TargetGroup and LoadBalancer dimensions
awslocal cloudwatch describe-alarms --alarm-names "$ALARM" \
  --query 'MetricAlarms[0].Metrics[].MetricStat.Metric.Dimensions[].Name' --output text | grep -q 'LoadBalancer'

echo "sns: $SNS_ARN"
awslocal sns list-topics --query 'Topics[].TopicArn' --output text | grep -q "$SNS_ARN"

echo "PASS: terraform applies; TG health path, internal ALB+listener -> TG, quorum alarm (TG+LB dims), and SNS topic present"
