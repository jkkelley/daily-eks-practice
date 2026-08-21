output "cluster_name" {
  value = module.stack.cluster_name
}

output "cluster_version" {
  value = module.stack.cluster_version
}

output "cluster_endpoint" {
  value = module.stack.cluster_endpoint
}

output "vpc_id" {
  value = module.stack.vpc_id
}

output "managed_addons" {
  value = module.stack.managed_addons
}

output "rds_endpoint" {
  value = module.stack.rds_endpoint
}

output "rds_password" {
  value     = module.stack.rds_password
  sensitive = true
}

output "practice_bucket" {
  value = module.stack.practice_bucket
}

output "s3_access_role_arn" {
  value = module.stack.s3_access_role_arn
}

output "grafana_admin_password" {
  value     = module.stack.grafana_admin_password
  sensitive = true
}

output "app_namespace" {
  value = module.stack.app_namespace
}

output "update_kubeconfig_command" {
  description = "Run this (or `make kubeconfig`) to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --name ${module.stack.cluster_name} --region ${var.aws_region} --profile ${var.aws_profile}"
}

output "cluster_git_url" {
  description = "In-cluster repo URL Argo CD reads from (\"\" when cluster git is disabled)."
  value       = module.stack.cluster_git_url
}

output "cluster_git_namespace" {
  description = "Namespace the cluster git server runs in."
  value       = module.stack.cluster_git_namespace
}

output "cluster_git_deployment" {
  description = "Deployment name of the cluster git server, for `kubectl exec` seeding."
  value       = module.stack.cluster_git_deployment
}

output "cluster_git_container" {
  description = "Container in the git-server pod that has the git binary, for `kubectl exec` seeding."
  value       = module.stack.cluster_git_container
}

output "cluster_git_repo_path" {
  description = "Absolute path of the bare repo inside that container."
  value       = module.stack.cluster_git_repo_path
}

output "drill_alb_security_group_id" {
  description = "Security group id to annotate on every ops Ingress (\"\" when the ALB controller is off)."
  value       = module.stack.drill_alb_security_group_id
}

output "drill_ingress_group_name" {
  description = "Shared IngressGroup name; every ops Ingress must use it or it gets its own ALB."
  value       = module.stack.drill_ingress_group_name
}
