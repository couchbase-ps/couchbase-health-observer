# The quorum alarm publishes here on the DOWN transition. The switch Lambda
# (plan 3, deferred) subscribes to this topic.
resource "aws_sns_topic" "switch" {
  name = "${var.name_prefix}-switch"
}
