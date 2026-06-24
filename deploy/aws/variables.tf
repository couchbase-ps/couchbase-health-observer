variable "name_prefix" {
  description = "Prefix for the target group, alarm, and SNS topic names."
  type        = string
  default     = "cb-health"
}

variable "vpc_id" {
  description = "VPC the monitoring target group lives in (same VPC as the EKS cluster running the observer fleet)."
  type        = string
}

variable "app_port" {
  description = "Port the observer health endpoint listens on."
  type        = number
  default     = 8080
}

variable "health_path" {
  description = "Observer health endpoint. Returns 200 when UP, 503 when DOWN."
  type        = string
  default     = "/health/couchbase"
}

variable "quorum_threshold" {
  description = "Unhealthy ratio (0-1) at or above which the cluster is considered DOWN by quorum (strict majority = 0.5; default 0.6 needs a clear majority)."
  type        = number
  default     = 0.6
}

variable "sustained_periods" {
  description = "Consecutive 1-minute periods the quorum must hold before alarming (anti-flap / FailoverDelay equivalent; set above the cluster auto-failover timeout)."
  type        = number
  default     = 2
}
