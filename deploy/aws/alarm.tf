# Fires when the unhealthy ratio across the monitoring target group is at or above
# the quorum threshold for `sustained_periods` consecutive minutes. The sustained
# window is the anti-flap / FailoverDelay equivalent; set it above the cluster
# auto-failover timeout so Couchbase gets its window to absorb the failure first.
resource "aws_cloudwatch_metric_alarm" "quorum" {
  alarm_name          = "${var.name_prefix}-quorum-down"
  alarm_description   = "Quorum of observer instances report Couchbase DOWN (unhealthy ratio >= threshold, sustained)."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.quorum_threshold
  evaluation_periods  = var.sustained_periods
  datapoints_to_alarm = var.sustained_periods

  # Missing data => the monitoring plane is broken (no hosts reporting), which is more
  # likely than "Couchbase is down". Do NOT switch on "cannot tell".
  treat_missing_data = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "unhealthy / (unhealthy + healthy)"
    label       = "UnhealthyRatio"
    return_data = true
  }

  metric_query {
    id = "unhealthy"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "UnHealthyHostCount"
      period      = 60
      stat        = "Maximum"
      dimensions = {
        TargetGroup = aws_lb_target_group.monitoring.arn_suffix
      }
    }
  }

  metric_query {
    id = "healthy"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HealthyHostCount"
      period      = 60
      stat        = "Maximum"
      dimensions = {
        TargetGroup = aws_lb_target_group.monitoring.arn_suffix
      }
    }
  }

  alarm_actions = [aws_sns_topic.switch.arn]
  ok_actions    = [] # no auto-failback: recovery does nothing
}
