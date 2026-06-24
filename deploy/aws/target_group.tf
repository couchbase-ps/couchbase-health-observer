# Monitoring-only: the registered observer pods are health-checked and emit
# HealthyHostCount / UnHealthyHostCount, but this target group is attached to NO
# listener, so it never serves user traffic. An "unhealthy" target means that
# observer instance sees Couchbase DOWN (its /health/couchbase returns 503).
resource "aws_lb_target_group" "monitoring" {
  name        = "${var.name_prefix}-mon"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # EKS pod IPs via the AWS Load Balancer Controller

  health_check {
    enabled             = true
    path                = var.health_path
    matcher             = "200" # 503 (Couchbase DOWN) => unhealthy target
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Purpose = "couchbase-health-monitoring-only"
  }
}
