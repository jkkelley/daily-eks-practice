# 12 - Terraform through GitHub Actions (OIDC)

**Time:** ~60 min first time. **Needs:** repo on GitHub; local admin AWS profile for the one-time bootstrap.

Ticket: "Laptop terraform is over. All plans on PRs, applies only from CI with an approval, and absolutely no long-lived AWS keys in GitHub."

## Tasks

1. One-time OIDC bootstrap (creates the IAM role GitHub Actions will assume - no keys anywhere):
   - fill `[bootstrap_oidc]` in `scripts/config.toml` (your GitHub owner + this repo),
   - `python3 scripts/bootstrap.py bootstrap-oidc init` then `... apply` with your admin profile,
   - set the repo variable: `gh variable set AWS_ROLE_ARN --body "$(python3 scripts/bootstrap.py bootstrap-oidc output -raw role_arn)"`.
2. Give CI your config (it's git-ignored, remember): `gh secret set CONFIG_TOML < scripts/config.toml`.
3. Protect the money button: in repo Settings → Environments, create `dev` and add yourself as a required reviewer.
4. Open a PR that changes something harmless (e.g. a tag in `extra_tags`). Watch `terraform-plan` run fmt/validate/helm lint, then post the real plan as a PR comment. Read the whole plan.
5. Merge, then run `terraform-apply` via workflow_dispatch (action: apply). Approve it in the environment gate. Verify the tag landed in AWS.
6. Study the trust: open the IAM role and read its trust policy. Exactly which repo/branches can assume it? What would you tighten with `subject_claims` for a real org?
7. End-of-day discipline, CI edition: run `terraform-apply` with action **destroy** and approve it. Confirm ~$0.

## Success criteria (`make check N=12`)

- Repo variable `AWS_ROLE_ARN` and secret `CONFIG_TOML` exist (`gh` CLI can tell you).
- At least one green `terraform-plan` and one green `terraform-apply` run.
- You can explain the OIDC handshake (workflow token → STS → role) in three sentences.
