variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN of the cluster (for IRSA)."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL without the https:// prefix."
  type        = string
}

variable "app_namespace" {
  description = "Namespace whose service account gets S3 access."
  type        = string
}

variable "s3_service_account" {
  description = "Service account name allowed to use the practice bucket (IRSA)."
  type        = string
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
}
