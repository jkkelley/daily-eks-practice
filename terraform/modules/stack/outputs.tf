output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_data" {
  value = module.eks.cluster_ca_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "node_group_name" {
  value = module.eks.node_group_name
}

output "managed_addons" {
  value = module.addons.managed_addons
}

output "rds_endpoint" {
  value = var.enable_rds ? module.rds[0].endpoint : null
}

output "rds_password" {
  value     = var.enable_rds ? module.rds[0].password : null
  sensitive = true
}

output "practice_bucket" {
  value = var.enable_practice_bucket ? module.storage[0].bucket_name : null
}

output "s3_access_role_arn" {
  value = var.enable_practice_bucket ? module.storage[0].s3_access_role_arn : null
}

output "grafana_admin_password" {
  value     = module.platform.grafana_admin_password
  sensitive = true
}

output "app_namespace" {
  value = module.platform.app_namespace
}

output "cluster_git_url" {
  description = "In-cluster repo URL Argo CD reads from (\"\" when cluster git is disabled)."
  value       = module.platform.cluster_git_url
}

output "cluster_git_namespace" {
  description = "Namespace the cluster git server runs in."
  value       = module.platform.cluster_git_namespace
}

output "cluster_git_deployment" {
  description = "Deployment name of the cluster git server, for `kubectl exec` seeding."
  value       = module.platform.cluster_git_deployment
}

output "cluster_git_container" {
  description = "Container in the git-server pod that has the git binary, for `kubectl exec` seeding."
  value       = module.platform.cluster_git_container
}

output "cluster_git_repo_path" {
  description = "Absolute path of the bare repo inside that container."
  value       = module.platform.cluster_git_repo_path
}
