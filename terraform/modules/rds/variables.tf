variable "name_prefix" {
  description = "Prefix for all resource names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the DB lives in."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach Postgres (the EKS cluster SG)."
  type        = list(string)
}

variable "engine_version" {
  description = "Postgres engine version (major or major.minor)."
  type        = string
}

variable "instance_class" {
  description = "DB instance class. Keep tiny - you pay for what you provision."
  type        = string
}

variable "allocated_storage" {
  description = "Storage in GB. Keep small."
  type        = number
}

variable "db_name" {
  description = "Initial database name."
  type        = string
}

variable "username" {
  description = "Master username."
  type        = string
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
}
