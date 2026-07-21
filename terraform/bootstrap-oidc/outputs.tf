output "role_arn" {
  description = "Set this as the repo variable AWS_ROLE_ARN so the workflows can assume it."
  value       = aws_iam_role.gha.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "next_step" {
  value = "gh variable set AWS_ROLE_ARN --repo ${var.github_owner}/${var.github_repo} --body ${aws_iam_role.gha.arn}"
}
