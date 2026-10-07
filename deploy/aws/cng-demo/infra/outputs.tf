output "cluster_name" { value = module.eks.cluster_name }
output "cluster_arn" { value = module.eks.cluster_arn }
output "vpc_id" { value = module.vpc.vpc_id }
output "region" { value = var.region }
output "node_groups" { value = module.eks.eks_managed_node_groups }
output "observer_repository" { value = aws_ecr_repository.observer.repository_url }
output "harness_repository" { value = aws_ecr_repository.harness.repository_url }
