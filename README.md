# Daily EKS Practice

A small, cheap, spin-up/spin-down EKS playground for **daily hands-on practice**.

You stand it up with Terraform (locally or through GitHub Actions + OIDC), get a real running stack - a frontend/backend app on Helm, a tiny RDS Postgres, Argo CD, Prometheus/Grafana, the AWS Load Balancer Controller - then work through ticket-style scenarios: scaling, rollouts, load balancing, DNS, storage, observability, GitOps, break/fix.
When you're done for the day, `make down` and the bill stops.

> **Fly blind first.** Each scenario card states the task; grade yourself with `make check N=NN`; the full answers are sealed in [`PRACTICE_ANSWERS.html`](PRACTICE_ANSWERS.html) (`make serve-answers`).

---

## 💸 Read this before you build (costs money)

The EKS **control plane costs ~$0.10/hour (~$73/month) the entire time it exists**, pods or not.
With the defaults here (2× t3.medium SPOT, single NAT, db.t4g.micro, 20GB storage) a session runs roughly **$0.15-0.25/hour** - a 2-hour practice session is well under a dollar.
After `make down` you are back to ~$0 (a few cents of S3 state).

The ways this gets expensive:

1. **Forgetting to destroy it.** Run `make down` when you finish. Every time.
2. **Leaving a scenario's extras on.** Load balancers (~$16/mo each), CloudWatch log ingestion ($0.50/GB - audit logs are chatty), Container Insights, EBS volumes from PVCs. Each scenario card carries its own cost note and cleanup step.
3. **Orphaned load balancers.** Delete Ingress/LoadBalancer resources BEFORE `make down`, so the controller can delete the AWS side. The cards remind you.
4. **Extended support.** Keep `cluster_version` on standard support or the control plane jumps to $0.60/hour.

Everything is tagged (`Project`, `Environment`, `ManagedBy`, `Purpose=daily-eks-practice`) so you can always find - and kill - anything that survived a teardown.
Nothing here applies to AWS on its own; **you** run every apply.

---

## What's in here

```
terraform/
  modules/{vpc,eks,addons,rds,storage,platform,stack}/  # implementation (stack composes)
  envs/dev/                                             # thin consumer (no values, no defaults)
  bootstrap-oidc/                                       # one-time GitHub Actions OIDC role
helm/practice-app/            # the fe/be app chart (nginx + PostgREST + seed job)
argocd/                       # GitOps glue (Application generated from YOUR git remote)
scenarios/                    # the daily drill cards (start at the README there)
scenario_testing/             # `make check N=NN` outcome checks for the drills
tests/                        # $0 local validation: fmt/validate/ministack/helm-in-podman
scripts/config.example.toml   # ← single source of truth (copy to config.toml)
scripts/bootstrap.py          # reads config, generates tfvars, runs terraform
.github/workflows/            # plan on PR + gated apply/destroy (OIDC, no keys)
Makefile                      # lifecycle;  Makefile.test = validation
PRACTICE_ANSWERS.html         # 🔒 sealed answer key (make serve-answers)
```

Every Terraform variable has **no default** - values come from one git-ignored file, `scripts/config.toml`.
Nothing personal (profiles, account ids, zones) is ever committed; a fresh clone runs on the documented example config.

---

## Configuration (single source of truth)

```bash
cp scripts/config.example.toml scripts/config.toml   # then edit for your account
```

- `[backend]` - the S3 bucket you created for Terraform state.
- `[common]` - everything: region, profile, cluster sizing, feature toggles (`enable_rds`, `enable_argocd`, `enable_monitoring`, `enable_alb_controller`, `enable_external_dns`, ...).
- `[dev]` - the single practice env (only its `environment` name).
- `[bootstrap_oidc]` - the one-time CI role.

`scripts/bootstrap.py` (Python 3.11+, works the same on Linux/WSL/Windows) merges the config, writes `config.auto.tfvars.json`, and runs Terraform - `make`, the tests, and CI all go through it.

---

## Prerequisites

- **Terraform** ≥ 1.6, **AWS CLI v2**, **kubectl**, **make**, **Python 3.11+**.
- **Podman** for the $0 local tests (helm runs inside a container - no local helm needed).
- An **AWS profile** that can create VPC/EKS/IAM/RDS (auth via `AWS_PROFILE`; never hardcoded).
- An **S3 bucket for Terraform state** (put it in `[backend]`).

---

## Quick start

```bash
cp scripts/config.example.toml scripts/config.toml   # edit for your account
make up            # ~15 min (control plane + nodes + rds + platform)
make kubeconfig    # writes .kubeconfig-daily-eks-practice (repo-local; ~/.kube/config is never touched)
eval "$(make kubeconfig-env)"   # point YOUR shell's kubectl at it (PowerShell: $env:KUBECONFIG = ...)
make argo-repo     # let Argo CD read this private repo (token from your gh login)
make app-deploy    # register the app with Argo CD (creates nothing yet)
make argo-sync     # Sync it - creates the pods (or do it in the UI: make argo-ui, click Sync)
make scenario N=01 # print today's drill (checks its prereqs first)
make check N=01    # grade yourself
make down          # WHEN DONE - stops the charges
```

The app with no LB yet: `kubectl -n practice-app port-forward svc/practice-app-frontend 8081:80` → http://localhost:8081.
UIs: `make argo-ui` (Argo CD), `make grafana-ui` (Grafana).

**Kubeconfig isolation:** this playground writes only to `.kubeconfig-daily-eks-practice` at the repo root (git-ignored) and every make target uses it automatically.
Your `~/.kube/config` and its contexts are never created, modified, or selected.
For hands-on kubectl during drills, export it into your shell first: `eval "$(make kubeconfig-env)"` (Linux/WSL) or `$env:KUBECONFIG = "<repo>\.kubeconfig-daily-eks-practice"` (PowerShell).

---

## The daily practice loop

1. `make up` while you get coffee (~15 min).
2. Pick a card from [`scenarios/`](scenarios/README.md) - they're written like real tickets.
3. Do the work. Get stuck → struggle a bit → `make check N=NN` → only then `make serve-answers`.
4. Clean up anything the card's cost note flags (LBs, PVCs, log groups).
5. `make down`. Always.

---

## Your practice record: `drill-progress/`

Once a scenario is ported to the drill format, `make scenario N=NN` opens a **session** and your progress is saved to `drill-progress/` on this machine.

```
drill-progress/
  curriculum.json          running totals across every scenario you've drilled
  baseline.bundle          cluster git as `make git-seed` left it
  current.json             which scenario is open right now, if any
  03/
    index.json             one results row per session, oldest first
    sessions/2026-08-19T14-03-11Z/
      state.json           where the drill got to
      workspace.bundle     your working tree, as a git bundle
```

**It is git-ignored, and that is deliberate.** This is your practice record - your attempts, your wrong answers, the shape of how long each card took you. It is personal, and nobody forking this project wants to inherit somebody else's attempt log. It survives because it is on your laptop, not because it is committed.

**It is a state snapshot, not a diary.** It records where the drill got to, not a replay of everything you typed. That is why resuming works at all: `make scenario N=03` converges the environment back to the state in the save file, so it either restores completely or it tells you it could not. There is no half-restored session to debug.

**`workspace.bundle` is a real `git bundle`.** If you ever want your work out of here without the drill, `git clone drill-progress/03/sessions/<id>/workspace.bundle somewhere/` is all it takes.

Nothing in here is ever overwritten or deleted. `make scenario-clean N=03` ends a session and stops the watcher; it does not touch the save files.

---

## Two ways to deploy

### A) Locally with Terraform

The Quick start above - `make up/plan/apply/down`, authenticating with your AWS profile via `AWS_PROFILE`.

### B) GitHub Actions (OIDC, no static keys)

Scenario 12 walks this end to end. Short version:

1. Bootstrap the CI role once (locally, with an admin profile):
   ```bash
   AWS_PROFILE=<admin> python3 scripts/bootstrap.py bootstrap-oidc init -input=false
   AWS_PROFILE=<admin> python3 scripts/bootstrap.py bootstrap-oidc apply
   gh variable set AWS_ROLE_ARN --body "$(python3 scripts/bootstrap.py bootstrap-oidc output -raw role_arn)"
   gh secret set CONFIG_TOML < scripts/config.toml
   ```
2. **Plan on PRs** - `terraform-plan.yml` runs fmt/validate/helm-lint with no AWS, then a real OIDC plan posted as a PR comment.
3. **Apply is manual and gated** - run `terraform-apply.yml` via workflow_dispatch (apply or destroy); tie the `dev` GitHub Environment to required reviewers so the money button needs an approval.

---

## Testing (no cloud spend)

```bash
make -f Makefile.test test        # terraform fmt + validate + helm lint (helm runs in Podman)
make -f Makefile.test ministack   # full terraform plan vs a local mock AWS (Podman)
```

How local testing works - and its fidelity limits - is documented in [`tests/README.md`](tests/README.md).
Scenario grading (`make check`) is separate and documented in [`scenario_testing/README.md`](scenario_testing/README.md).

---

## Scrub a Git identity before publishing

`scripts/scrub-git-identity.sh` permanently replaces an author, committer, and tagger email through `git-filter-repo`.
It always works in a fresh mirror clone outside this checkout, verifies that branch and tag trees remain unchanged, and does not touch the remote unless `--push` is explicit.

```bash
scripts/scrub-git-identity.sh \
  --old-email '<private-email>' \
  --new-name '<public-name>' \
  --new-email '<github-noreply-email>' \
  --output /tmp/daily-eks-practice-sanitized.git
```

Inspect the sanitized mirror before rerunning with `--push`.
The push path requires typing `force-push`, checks that the remote has not changed since cloning, and reclones the remote afterward for verification.
Every rewritten commit ID changes, signatures become invalid, and hosting-provider pull-request refs or caches can retain old objects.

---

## Hand-off

This repo is built to be handed to another engineer whole: clone, copy the example config, fill in your own account values, go.
No AWS accounts, profiles, or personal values are committed anywhere - if you find one, that's a bug (log it in `ISSUES.md`).
