terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    helm = {
      # Pinned < 3.0 so the nested `set {}` block syntax below stays valid.
      source  = "hashicorp/helm"
      version = ">= 2.12, < 3.0"
    }
  }
}
