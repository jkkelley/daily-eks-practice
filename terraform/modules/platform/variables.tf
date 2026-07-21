variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "aws_region" {
  description = "AWS region (for controllers that need it)."
  type        = string
}

variable "vpc_id" {
  description = "VPC id (the ALB controller needs it)."
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

variable "enable_alb_controller" {
  description = "Install the AWS Load Balancer Controller (needed for ALB Ingress / NLB scenarios)."
  type        = bool
}

variable "alb_controller_chart_version" {
  description = "aws-load-balancer-controller chart version; \"\" = latest."
  type        = string
}

variable "enable_external_dns" {
  description = "Install external-dns. Requires a Route53 hosted zone you own (dns_zone_name)."
  type        = bool
}

variable "external_dns_chart_version" {
  description = "external-dns chart version; \"\" = latest."
  type        = string
}

variable "dns_zone_name" {
  description = "Route53 hosted zone name for external-dns (e.g. practice.example.com). Ignored unless enable_external_dns."
  type        = string
}

variable "enable_argocd" {
  description = "Install Argo CD in its own argocd namespace (in-cluster GitOps)."
  type        = bool
}

variable "argocd_chart_version" {
  description = "argo-cd chart version; \"\" = latest."
  type        = string
}

variable "enable_monitoring" {
  description = "Install kube-prometheus-stack (Prometheus + Grafana) in the monitoring namespace."
  type        = bool
}

variable "kube_prometheus_stack_chart_version" {
  description = "kube-prometheus-stack chart version; \"\" = latest."
  type        = string
}

variable "app_namespace" {
  description = "Namespace for the practice app (created here so the DB secret can land in it)."
  type        = string
}

variable "enable_db_secret" {
  description = "Create the practice-db Secret in the app namespace (on when RDS is on)."
  type        = bool
}

variable "db_host" {
  description = "RDS hostname for the app secret."
  type        = string
}

variable "db_port" {
  description = "RDS port for the app secret."
  type        = number
}

variable "db_name" {
  description = "Database name for the app secret."
  type        = string
}

variable "db_username" {
  description = "Database user for the app secret."
  type        = string
}

variable "db_password" {
  description = "Database password for the app secret."
  type        = string
  sensitive   = true
}

variable "create_s3_service_account" {
  description = "Create the IRSA-annotated S3 practice service account (on when the bucket is on)."
  type        = bool
}

variable "s3_access_role_arn" {
  description = "IRSA role arn for the S3 practice service account (\"\" when disabled)."
  type        = string
}

variable "s3_service_account" {
  description = "Name of the S3 practice service account."
  type        = string
}

variable "tags" {
  description = "Tags for every AWS resource."
  type        = map(string)
}
