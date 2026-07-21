# No defaults - all values are threaded from the stack (ultimately scripts/config.toml).

variable "name_prefix" { type = string }
variable "cluster_name" { type = string }
variable "cluster_version" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider_url" { type = string }

variable "node_group_asg_names" {
  description = "ASG names behind the managed node group (cluster-autoscaler discovery tags)."
  type        = list(string)
}

# ---- EKS-managed add-ons ----
variable "managed_addons" { type = list(string) }
variable "addon_versions" {
  description = "Explicit add-on versions by name. Empty map = EKS default (which then lags on upgrade)."
  type        = map(string)
}
variable "addon_resolve_conflicts" { type = string }

# ---- Helm live subset (chart_version empty string = latest) ----
variable "enable_metrics_server" { type = bool }
variable "metrics_server_chart_version" { type = string }
variable "enable_cluster_autoscaler" { type = bool }
variable "cluster_autoscaler_chart_version" { type = string }
variable "cluster_autoscaler_image_tag" { type = string }
variable "enable_cert_manager" { type = bool }
variable "cert_manager_chart_version" { type = string }

variable "tags" { type = map(string) }
