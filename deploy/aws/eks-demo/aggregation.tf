# Distributed-quorum aggregation layer (reused module): monitoring target group + internal
# ALB + quorum alarm + SNS, in the demo VPC.
module "agg" {
  source = "../"

  name_prefix = var.name
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = module.vpc.private_subnets
  app_port    = 8080
}

# Allow the monitoring ALB to health-check the observer pods on 8080. EKS pods get VPC IPs
# (VPC CNI), so the ALB reaches them on the node security group.
resource "aws_security_group_rule" "alb_to_observer" {
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  security_group_id        = module.eks.node_security_group_id
  source_security_group_id = module.agg.monitoring_alb_security_group_id
  description              = "monitoring ALB health checks to observer pods"
}
