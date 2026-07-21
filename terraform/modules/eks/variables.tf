# No defaults - all values are threaded from the stack (ultimately scripts/config.toml).

variable "name_prefix" { type = string }
variable "cluster_name" { type = string }
variable "cluster_version" { type = string }

variable "subnet_ids" {
  description = "Subnets for the control plane cross-account ENIs (usually all subnets)."
  type        = list(string)
}
variable "node_subnet_ids" {
  description = "Subnets the managed node group launches into."
  type        = list(string)
}

variable "endpoint_public_access" { type = bool }
variable "endpoint_private_access" { type = bool }
variable "public_access_cidrs" { type = list(string) }
variable "enabled_cluster_log_types" { type = list(string) }
variable "authentication_mode" { type = string }
variable "bootstrap_cluster_creator_admin_permissions" { type = bool }

variable "access_entries" {
  type = map(object({
    principal_arn = string
    policy_arn    = string
    access_scope  = optional(string, "cluster")
    namespaces    = optional(list(string), [])
  }))
}

variable "node_instance_types" { type = list(string) }
variable "capacity_type" { type = string }
variable "ami_type" { type = string }
variable "node_version" {
  description = "Node group k8s version. Empty string = created at cluster version, then lags (kubelet-skew lesson)."
  type        = string
}
variable "node_desired_size" { type = number }
variable "node_min_size" { type = number }
variable "node_max_size" { type = number }
variable "node_max_unavailable" { type = number }
variable "node_disk_size" { type = number }

variable "tags" { type = map(string) }
