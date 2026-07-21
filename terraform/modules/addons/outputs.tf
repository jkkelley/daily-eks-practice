output "ebs_csi_role_arn" {
  value = aws_iam_role.ebs_csi.arn
}

output "cluster_autoscaler_role_arn" {
  value = var.enable_cluster_autoscaler ? aws_iam_role.ca[0].arn : null
}

output "managed_addons" {
  description = "Installed managed add-ons and their resolved versions."
  value       = { for k, a in aws_eks_addon.this : k => a.addon_version }
}
