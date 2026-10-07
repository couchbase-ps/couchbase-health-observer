variable "region" {
  type    = string
  default = "eu-west-1"
}
variable "name" {
  type    = string
  default = "cng-demo"
  validation {
    condition     = can(regex("^cng-demo(-[a-z0-9-]+)?$", var.name))
    error_message = "Demo name must start with cng-demo."
  }
}
variable "cluster_version" {
  type    = string
  default = "1.35"
}
variable "instance_type" {
  type    = string
  default = "m7g.large"
}
variable "node_groups" {
  type    = map(number)
  default = { primary = 2, secondary = 1, apps = 2 }
  validation {
    condition     = toset(keys(var.node_groups)) == toset(["primary", "secondary", "apps"])
    error_message = "Exactly primary, secondary and apps pools are required."
  }
}
variable "admin_cidrs" {
  description = "Public EKS API source CIDRs. Lifecycle script supplies caller IPv4 /32."
  type        = list(string)
  default     = ["127.0.0.1/32"]
}
