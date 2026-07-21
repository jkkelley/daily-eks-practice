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
