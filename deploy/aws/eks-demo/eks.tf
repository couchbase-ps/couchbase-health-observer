data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true
  enable_irsa                    = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Grant the caller (whoever runs terraform) cluster-admin so kubectl works post-apply.
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_desired_size
      max_size       = var.node_desired_size + 1
      desired_size   = var.node_desired_size
    }
  }
}

# A security group the Lambda uses to reach the EKS API (443). Placed in the VPC so the
# Lambda can call the cluster endpoint; the cluster's SG allows the VPC CIDR by default.
resource "aws_security_group" "lambda" {
  name        = "${var.name}-lambda"
  description = "switch lambda egress to the EKS API"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
