variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "name" {
  description = "Name prefix for the demo resources."
  type        = string
  default     = "cb-health-eks"
}

variable "cluster_version" {
  type    = string
  default = "1.31"
}

variable "node_instance_type" {
  type    = string
  default = "t3.large"
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "observer_image" {
  description = "Observer image (ghcr; the package must be public or use an imagePullSecret)."
  type        = string
  default     = "ghcr.io/couchbase-ps/couchbase-health-observer:edge"
}

variable "observer_replicas" {
  type    = number
  default = 3
}

variable "cb_server_image" {
  description = "Couchbase Server image; also provides cbc-pillowfight for the traffic generator."
  type        = string
  default     = "couchbase/server:8.0.1"
}

# Couchbase admin credentials for the demo clusters (demo-only).
variable "cb_username" {
  type    = string
  default = "Administrator"
}

variable "cb_password" {
  type      = string
  default   = "password"
  sensitive = true
}
