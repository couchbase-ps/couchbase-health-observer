# vpc_id is intentionally omitted: it is environment-specific. The LocalStack test
# (test/aws/localstack.sh) creates an ephemeral VPC and passes it via -var vpc_id=...
name_prefix       = "cb-health"
app_port          = 8080
quorum_threshold  = 0.6
sustained_periods = 2
