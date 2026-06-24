#!/usr/bin/env bash
# AWS stack test: apply the distributed-quorum aggregation Terraform against LocalStack
# and assert the resource shapes (target group health path, quorum alarm comparator,
# SNS topic). This proves the Terraform applies and the resources exist with the right
# shape. It does NOT prove that a monitoring-only target group emits UnHealthyHostCount
# the way real ALB does -- that fidelity check is the AWS-sandbox runbook in
# deploy/aws/README.md.
#
# Requires: Docker, LocalStack *Pro* (ELBv2 and CloudWatch are Pro features) running,
# plus the tflocal and awslocal wrappers:
#   pip install terraform-local awscli-local
#   LOCALSTACK_AUTH_TOKEN=... localstack start -d
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
tflocal init -input=false >/dev/null
tflocal apply -auto-approve -input=false -var-file="$TFVARS"

TG_ARN=$(tflocal output -raw monitoring_target_group_arn)
SNS_ARN=$(tflocal output -raw switch_sns_topic_arn)
ALARM=$(tflocal output -raw quorum_alarm_name)

echo "target group: $TG_ARN"
awslocal elbv2 describe-target-groups --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[0].HealthCheckPath' --output text | grep -q '/health/couchbase'

echo "alarm: $ALARM"
awslocal cloudwatch describe-alarms --alarm-names "$ALARM" \
  --query 'MetricAlarms[0].ComparisonOperator' --output text | grep -q 'GreaterThanOrEqualToThreshold'

echo "sns: $SNS_ARN"
awslocal sns list-topics --query 'Topics[].TopicArn' --output text | grep -q "$SNS_ARN"

echo "PASS: terraform applies; target group health path, quorum alarm, and SNS topic present"
