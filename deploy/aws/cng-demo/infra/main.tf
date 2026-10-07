data "aws_availability_zones" "available" {
  state = "available"
}
locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name            = var.name
  cidr            = "10.42.0.0/16"
  azs             = local.azs
  private_subnets = ["10.42.1.0/24", "10.42.2.0/24"]
  public_subnets  = ["10.42.101.0/24", "10.42.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
}
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.9.0"

  name               = var.name
  kubernetes_version = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  endpoint_public_access                   = true
  endpoint_private_access                  = true
  endpoint_public_access_cidrs             = var.admin_cidrs
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  addons = {
    vpc-cni    = { before_compute = true }
    kube-proxy = {}
    coredns    = {}
  }
  eks_managed_node_groups = {
    for pool, count in var.node_groups : pool => {
      instance_types = [var.instance_type]
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      min_size       = 0
      max_size       = count
      desired_size   = count
      block_device_mappings = {
        root = { device_name = "/dev/xvda", ebs = { volume_size = 30, volume_type = "gp3", encrypted = true, delete_on_termination = true } }
      }
      labels = { "demo.couchbase.com/pool" = pool }
      taints = pool == "apps" ? {} : {
        isolated = { key = "demo-pool", value = pool, effect = "NO_SCHEDULE" }
      }
      iam_role_additional_policies = { ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" }
    }
  }
}
data "aws_iam_policy_document" "ebs_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ebs" {
  name               = "${var.name}-ebs"
  assume_role_policy = data.aws_iam_policy_document.ebs_trust.json
}
resource "aws_iam_role_policy_attachment" "ebs" {
  role       = aws_iam_role.ebs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
resource "aws_eks_addon" "ebs" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs.arn
  depends_on               = [aws_iam_role_policy_attachment.ebs]
}
resource "aws_ecr_repository" "observer" {
  name                 = "${var.name}/observer"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  encryption_configuration { encryption_type = "AES256" }
}
resource "aws_ecr_repository" "harness" {
  name                 = "${var.name}/harness"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  encryption_configuration { encryption_type = "AES256" }
}
