output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  description = "Base64 cluster CA - feeds the kubernetes/helm providers."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-managed cluster security group."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "oidc_provider_url" {
  description = "OIDC issuer URL without the https:// prefix (for IRSA trust policies)."
  value       = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "node_group_name" {
  value = aws_eks_node_group.this.node_group_name
}

output "node_group_asg_names" {
  description = "Auto Scaling Group name(s) behind the managed node group (for cluster-autoscaler discovery tags)."
  value       = aws_eks_node_group.this.resources[0].autoscaling_groups[*].name
}
