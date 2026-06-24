output "monitoring_target_group_arn" {
  description = "ARN of the monitoring-only target group; bind the observer fleet's pods here."
  value       = aws_lb_target_group.monitoring.arn
}

output "switch_sns_topic_arn" {
  description = "SNS topic the quorum alarm publishes to; the switch Lambda (plan 3) subscribes here."
  value       = aws_sns_topic.switch.arn
}

output "quorum_alarm_name" {
  description = "Name of the CloudWatch quorum alarm."
  value       = aws_cloudwatch_metric_alarm.quorum.alarm_name
}
