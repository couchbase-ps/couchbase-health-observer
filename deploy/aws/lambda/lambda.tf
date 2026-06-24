variable "name" {
  type    = string
  default = "cb-health-switch"
}

variable "switch_sns_topic_arn" {
  description = "SNS topic the quorum alarm publishes to (output switch_sns_topic_arn of the aggregation module)."
  type        = string
}

variable "secondary_conn" {
  description = "Connection string to switch the apps to on a sustained quorum-DOWN."
  type        = string
}

variable "deployments" {
  description = "Comma-separated Deployments to roll on switch."
  type        = string
  default     = ""
}

variable "namespace" {
  type    = string
  default = "default"
}

variable "configmap" {
  type    = string
  default = "cb-conn"
}

variable "config_key" {
  type    = string
  default = "connstring"
}

variable "dry_run" {
  description = "When true the Lambda logs the intended switch but makes no changes."
  type        = bool
  default     = false
}

variable "eks_cluster_name" {
  description = "If set, the Lambda authenticates to this EKS cluster via its IAM role (mapped by an access entry) instead of KUBECONFIG/in-cluster."
  type        = string
  default     = ""
}

variable "bootstrap_path" {
  description = "Path to the built linux/arm64 'bootstrap' binary (see build.sh)."
  type        = string
  default     = "bootstrap"
}

# The Lambda needs VPC placement to reach a private EKS API endpoint. Leave empty to run
# the Lambda outside a VPC (e.g. a public EKS endpoint or LocalStack).
variable "subnet_ids" {
  type    = list(string)
  default = []
}

variable "security_group_ids" {
  type    = list(string)
  default = []
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = var.bootstrap_path
  output_path = "${path.module}/bootstrap.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${var.name}-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC ENI permissions, only needed when the Lambda runs inside a VPC.
resource "aws_iam_role_policy_attachment" "vpc" {
  count      = length(var.subnet_ids) > 0 ? 1 : 0
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# eks:DescribeCluster so the Lambda can resolve the cluster endpoint/CA before building
# an STS-token client (RBAC itself comes from the EKS access entry, created by the caller).
resource "aws_iam_role_policy" "eks_describe" {
  count = var.eks_cluster_name != "" ? 1 : 0
  name  = "eks-describe"
  role  = aws_iam_role.lambda.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "eks:DescribeCluster", Resource = "*" }]
  })
}

resource "aws_lambda_function" "switch" {
  function_name    = var.name
  role             = aws_iam_role.lambda.arn
  runtime          = "provided.al2023"
  handler          = "bootstrap"
  architectures    = ["arm64"]
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      SECONDARY_CONN = var.secondary_conn
      DEPLOYMENTS    = var.deployments
      NAMESPACE        = var.namespace
      CONFIGMAP        = var.configmap
      CONFIG_KEY       = var.config_key
      DRY_RUN          = var.dry_run ? "true" : "false"
      EKS_CLUSTER_NAME = var.eks_cluster_name
    }
  }

  dynamic "vpc_config" {
    for_each = length(var.subnet_ids) > 0 ? [1] : []
    content {
      subnet_ids         = var.subnet_ids
      security_group_ids = var.security_group_ids
    }
  }
}

resource "aws_sns_topic_subscription" "to_lambda" {
  topic_arn = var.switch_sns_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.switch.arn
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.switch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.switch_sns_topic_arn
}

output "lambda_function_name" {
  value = aws_lambda_function.switch.function_name
}

output "lambda_role_arn" {
  description = "Grant this role Kubernetes RBAC via an EKS access entry (see README)."
  value       = aws_iam_role.lambda.arn
}
