data "aws_vpc" "this" {
  id = var.vpc_id
}

# AWS only runs health checks and emits Healthy/UnHealthyHostCount for a target group
# that is attached to a load balancer. A standalone target group (no listener) reports
# its targets as "unused" and emits nothing. This internal ALB exists ONLY to drive the
# health checks: it is internal and its DNS is never published, so it carries no real
# user traffic. The listener forwards to the monitoring target group.
resource "aws_security_group" "monitoring" {
  name        = "${var.name_prefix}-mon-alb"
  description = "Internal monitoring ALB for the Couchbase health quorum"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "monitoring" {
  name               = "${var.name_prefix}-mon-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.monitoring.id]
}

resource "aws_lb_listener" "monitoring" {
  load_balancer_arn = aws_lb.monitoring.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.monitoring.arn
  }
}
