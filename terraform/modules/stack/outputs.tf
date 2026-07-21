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
