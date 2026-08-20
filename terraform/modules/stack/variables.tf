# NO defaults on purpose - every value comes from scripts/config.toml via bootstrap.py.

# ---- identity / naming ----
variable "project" {
  description = "Name prefix for all resources."
  type        = string
}

variable "environment" {
  description = "Environment name (dev)."
  type        = string
}

variable "aws_region" {
  description = "AWS region (controllers like the ALB controller need it)."
  type        = string
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version."
  type        = string
}

# ---- networking ----
variable "vpc_cidr" {
  type = string
}

variable "az_count" {
  type = number
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "node_subnet_tier" {
  description = "\"private\" (needs NAT) or \"public\"."
  type        = string
}

variable "enable_nat_gateway" {
  type = bool
}

variable "single_nat_gateway" {
  type = bool
}

variable "enable_vpc_endpoints" {
  type = bool
}

# ---- control plane ----
variable "endpoint_public_access" {
  type = bool
}

variable "endpoint_private_access" {
  type = bool
}

variable "public_access_cidrs" {
  type = list(string)
}

variable "enabled_cluster_log_types" {
  type = list(string)
}

variable "authentication_mode" {
  type = string
}

variable "bootstrap_cluster_creator_admin_permissions" {
  type = bool
}

variable "access_entries" {
  description = "Extra IAM principals to grant cluster access."
  type = map(object({
    principal_arn = string
    policy_arn    = string
    access_scope  = optional(string, "cluster")
    namespaces    = optional(list(string), [])
  }))
}

# ---- node group ----
variable "node_instance_types" {
  type = list(string)
}

variable "capacity_type" {
  type = string
}

variable "ami_type" {
  type = string
}

variable "node_version" {
  type = string
}

variable "node_desired_size" {
  type = number
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "node_max_unavailable" {
  type = number
}

variable "node_disk_size" {
  type = number
}

# ---- managed add-ons + helm add-ons ----
variable "managed_addons" {
  type = list(string)
}

variable "addon_versions" {
  type = map(string)
}

variable "addon_resolve_conflicts" {
  type = string
}

variable "enable_metrics_server" {
  type = bool
}

variable "metrics_server_chart_version" {
  type = string
}

variable "enable_cluster_autoscaler" {
  type = bool
}

variable "cluster_autoscaler_chart_version" {
  type = string
}

variable "cluster_autoscaler_image_tag" {
  type = string
}

variable "enable_cert_manager" {
  type = bool
}

variable "cert_manager_chart_version" {
  type = string
}

# ---- practice database (RDS) ----
variable "enable_rds" {
  type = bool
}

variable "rds_engine_version" {
  type = string
}

variable "rds_instance_class" {
  type = string
}

variable "rds_allocated_storage" {
  type = number
}

variable "rds_db_name" {
  type = string
}

variable "rds_username" {
  type = string
}

# ---- practice S3 bucket ----
variable "enable_practice_bucket" {
  type = bool
}

# ---- platform toggles ----
variable "enable_alb_controller" {
  type = bool
}

variable "alb_controller_chart_version" {
  type = string
}

variable "enable_external_dns" {
  type = bool
}

variable "external_dns_chart_version" {
  type = string
}

variable "dns_zone_name" {
  type = string
}

variable "enable_argocd" {
  type = bool
}

variable "argocd_chart_version" {
  type = string
}

variable "enable_monitoring" {
  type = bool
}

variable "kube_prometheus_stack_chart_version" {
  type = string
}

variable "enable_cluster_git" {
  description = "Install the in-cluster git server (namespace \"git\") that Argo CD reads from."
  type        = bool
}

# ---- practice app plumbing ----
variable "app_namespace" {
  type = string
}

variable "s3_service_account" {
  type = string
}

# ---- drill platform ----
variable "drill_ingress_group_name" {
  description = "Shared ALB IngressGroup name for every ops UI, so they share one load balancer."
  type        = string
}

variable "drill_allowed_cidrs" {
  description = "Source CIDRs allowed to reach the drill ALB. The GUI is an unauthenticated cluster-admin terminal; keep this to your own IP."
  type        = list(string)
}

# ---- tags ----
variable "extra_tags" {
  type = map(string)
}
