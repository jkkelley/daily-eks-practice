# No defaults - values come from scripts/config.toml [bootstrap_oidc] via
# `python3 scripts/bootstrap.py bootstrap-oidc ...`.

variable "aws_region" { type = string }
variable "github_owner" { type = string }
variable "github_repo" { type = string }
variable "role_name" { type = string }

variable "subject_claims" {
  description = "Allowed OIDC sub claims. Empty list = repo:<owner>/<repo>:* (any branch/env)."
  type        = list(string)
}

variable "managed_policy_arns" {
  description = "Policies attached to the CI role. Scope down from AdministratorAccess for real use."
  type        = list(string)
}
