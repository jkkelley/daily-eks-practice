# Practice S3 bucket + an IRSA role so a pod can reach it without static keys.
# The bucket name gets the account id suffix for global uniqueness - no PII beyond
# what any ARN already carries, and nothing is hardcoded.

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "practice" {
  bucket        = "${var.name_prefix}-practice-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # practice rig: `make down` must never be blocked by leftover objects
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "practice" {
  bucket                  = aws_s3_bucket.practice.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "practice" {
  bucket = aws_s3_bucket.practice.id
  versioning_configuration {
    status = "Disabled" # keep storage costs at zero-ish; enabling it is a scenario
  }
}

# IRSA role: trusted only by the specific service account in the app namespace.
data "aws_iam_policy_document" "s3_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.app_namespace}:${var.s3_service_account}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "s3_access" {
  name               = "${var.name_prefix}-s3-practice"
  assume_role_policy = data.aws_iam_policy_document.s3_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.practice.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.practice.arn}/*"]
  }
}

resource "aws_iam_role_policy" "s3_access" {
  name   = "practice-bucket-rw"
  role   = aws_iam_role.s3_access.id
  policy = data.aws_iam_policy_document.s3_access.json
}
