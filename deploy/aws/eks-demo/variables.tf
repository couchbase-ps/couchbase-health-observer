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
  type    = string
  default = "tayebchlyah/couchbase-health-observer:latest"
}

variable "observer_replicas" {
  type    = number
  default = 3
}

variable "traffic_image" {
  description = "Image for the demo Couchbase traffic app."
  type        = string
  default     = "tayebchlyah/couchbase-traffic-demo:latest"
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
