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

output "monitoring_alb_arn" {
  description = "Internal ALB that drives the target-group health checks."
  value       = aws_lb.monitoring.arn
}

output "monitoring_alb_security_group_id" {
  description = "ALB security group; the observer fleet pods must allow inbound on app_port from this SG."
  value       = aws_security_group.monitoring.id
}
