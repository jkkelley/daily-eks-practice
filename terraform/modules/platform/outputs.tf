output "argocd_namespace" {
  value = var.enable_argocd ? "argocd" : null
}

output "monitoring_namespace" {
  value = var.enable_monitoring ? "monitoring" : null
}

output "grafana_admin_password" {
  description = "Grafana admin password (user: admin)."
  value       = var.enable_monitoring ? random_password.grafana_admin[0].result : null
  sensitive   = true
}

output "app_namespace" {
  value = var.app_namespace
}

output "cluster_git_url" {
  description = "In-cluster repo URL Argo CD reads from (\"\" when cluster git is disabled)."
  value       = local.cluster_git_url
}

output "cluster_git_namespace" {
  description = "Namespace the cluster git server runs in."
  value       = var.enable_cluster_git ? local.git_ns : ""
}

output "cluster_git_deployment" {
  description = "Deployment name of the cluster git server, for `kubectl exec` seeding."
  value       = var.enable_cluster_git ? local.git_svc : ""
}

output "cluster_git_container" {
  description = "Container in the git-server pod that has the git binary, for `kubectl exec` seeding."
  value       = var.enable_cluster_git ? "git" : ""
}

output "cluster_git_repo_path" {
  description = "Absolute path of the bare repo inside that container."
  value       = var.enable_cluster_git ? "${local.git_root}/${local.git_repo}" : ""
}

output "drill_alb_security_group_id" {
  description = "Security group id to annotate on every ops Ingress (\"\" when the ALB controller is off)."
  value       = var.enable_alb_controller ? aws_security_group.drill_alb[0].id : ""
}

output "drill_ingress_group_name" {
  description = "Shared IngressGroup name; every ops Ingress must use it or it gets its own ALB."
  value       = var.drill_ingress_group_name
}
