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
