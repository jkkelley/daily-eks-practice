terraform {
  backend "s3" {
    # Partial config: bucket, key, and region are injected at init time by
    # scripts/bootstrap.py from scripts/config.toml [backend]. Backend blocks can't
    # use variables, so nothing user-specific is hardcoded here. Run through
    # `make` / bootstrap.py (bare `terraform init` would prompt for the backend).
    encrypt      = true
    use_lockfile = true # S3-native locking (Terraform >= 1.10); no DynamoDB table.
  }
}
