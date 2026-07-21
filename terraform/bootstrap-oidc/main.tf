# One-time bootstrap: creates the GitHub Actions OIDC provider + an IAM role the
# workflows assume (no static AWS keys ever stored in GitHub). Apply this ONCE with
# admin credentials (set AWS_PROFILE to your admin profile), then set the repo variable
# AWS_ROLE_ARN to the role_arn output.

provider "aws" {
  region = var.aws_region
}

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

locals {
  subs = length(var.subject_claims) > 0 ? var.subject_claims : ["repo:${var.github_owner}/${var.github_repo}:*"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subs
    }
  }
}

resource "aws_iam_role" "gha" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = { Purpose = "daily-eks-practice-ci" }
}

resource "aws_iam_role_policy_attachment" "gha" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.gha.name
  policy_arn = each.value
}
