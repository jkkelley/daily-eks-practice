output "bucket_name" {
  value = aws_s3_bucket.practice.bucket
}

output "bucket_arn" {
  value = aws_s3_bucket.practice.arn
}

output "s3_access_role_arn" {
  description = "Annotate the practice service account with this for IRSA."
  value       = aws_iam_role.s3_access.arn
}
