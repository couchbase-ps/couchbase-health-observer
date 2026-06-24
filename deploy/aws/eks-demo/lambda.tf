# Switch Lambda (reused module): SNS-triggered, authenticates to EKS via its IAM role and
# patches the ConfigMap + rolls the app on a sustained quorum-DOWN. Build the binary first
# (deploy/aws/lambda/build.sh) so the archive exists at plan time.
module "lambda" {
  source = "../lambda"

  name                 = "${var.name}-switch"
  switch_sns_topic_arn = module.agg.switch_sns_topic_arn
  secondary_conn       = "couchbase://region-b-srv.region-b.svc"
  deployments          = "mock-app"
  namespace            = "default"
  configmap            = "cb-conn"
  config_key           = "connstring"
  dry_run              = false

  eks_cluster_name   = module.eks.cluster_name
  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [aws_security_group.lambda.id]

  bootstrap_path = abspath("${path.module}/../lambda/bootstrap")
}

# Map the Lambda's IAM role to Kubernetes RBAC (edit on the default namespace) so it can
# patch the cb-conn ConfigMap and roll the mock-app Deployment.
resource "aws_eks_access_entry" "lambda" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.lambda.lambda_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "lambda" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.lambda.lambda_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }
  depends_on = [aws_eks_access_entry.lambda]
}
