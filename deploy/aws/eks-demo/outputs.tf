output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the demo cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "monitoring_target_group_arn" {
  value = module.agg.monitoring_target_group_arn
}

output "quorum_alarm_name" {
  value = module.agg.quorum_alarm_name
}

output "switch_sns_topic_arn" {
  value = module.agg.switch_sns_topic_arn
}

output "lambda_function_name" {
  value = module.lambda.lambda_function_name
}
