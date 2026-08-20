# CLAUDE.md - daily-eks-practice

Agent rules for this repo.
This is a **learning/practice** project: a small, cheap, spin-up/spin-down EKS playground with a Helm fe/be app, tiny RDS, Argo CD, and Prometheus/Grafana, driven through ticket-style scenario cards.

## What this repo is

A modular Terraform EKS project plus daily drill scenarios and a sealed answer key.
The scenarios in `scenarios/` are the curriculum; `PRACTICE_ANSWERS.html` holds the answers - keep the two in sync if you add or change a scenario, and add a matching outcome check to `scenario_testing/check.sh`.
Do not "pre-solve" scenarios in the committed defaults (e.g. don't enable the HPA or Ingress in values.yaml - flipping them on is the exercise).

## Session State

See `CONTEXT_STATE.md` for current infrastructure state, active tasks, decisions and lessons learned.
Read it before starting any task.
Check its `last_updated` field first; if it is more than 7 days old, verify the infrastructure rows against reality before trusting them, and refresh it with the `context-compaction` skill.

## The close-out flow

**`CONTEXT_STATE.md` -> PR -> cleanup -> hydration prompt.** In that order, every time.

1. Update `CONTEXT_STATE.md` **on the work branch, as part of the work**, before the PR is opened. It is part of the deliverable, not paperwork that follows it.
2. Open the PR. It carries the code and the state file together, so one review sees the change and the record of the change.
3. After the merge, run `bash .claude/skills/work-order/scripts/work-order.sh close --id WO-...`. It opens its own PR for the merge SHA, the archive move and the `INDEX.md` regeneration. That one is generated bookkeeping and is expected.
4. Leave the hydration prompt at the bottom of `CONTEXT_STATE.md` naming the next work order by **both its id and its full title**, so the next session starts from a file rather than from memory.

**Never open a PR whose only content is `CONTEXT_STATE.md`.**
It doubles the review surface for one piece of work and leaves `main` briefly describing a world that no longer exists.

## Hard rules

1. **Never run `terraform apply`, `make up/apply/down`, or otherwise touch real AWS without explicit user approval.** The user drives all applies and destroys. Plans and validation are fine.
2. **Config-driven - no defaults, no hardcoding.** Every Terraform variable has NO default; all values live in `scripts/config.toml` (`[common]` + `[dev]`). To add a value: put it in `scripts/config.example.toml` (documented) AND declare the default-less variable threaded through env -> `modules/stack` -> the module. Never write a `default =`. Run Terraform through `scripts/bootstrap.py` / `make`, never bare.
3. **No PII / personal values in git.** No AWS account ids, profile names, real domains, or repo-owner strings outside `scripts/config.toml` (git-ignored) and generated files. The Argo CD Application is generated from the user's git remote (`scripts/gen-argocd-app.py`), never committed.
4. **Test through the sandbox.** Terraform changes: `make -f Makefile.test test` and a ministack plan (`make -f Makefile.test ministack`) via the vendored `container-sandbox` skill (`.claude/skills/container-sandbox/SKILL.md`). Helm chart changes: `make -f Makefile.test helm-lint helm-template` - helm runs INSIDE Podman, do not assume a local helm binary. No real AWS.
5. **Cost discipline.** The control plane bills ~$0.10/hr while up. Whenever you help the user bring the cluster up, remind them `make down` stops the charges. Anything a scenario creates that bills (LBs, PVCs, log groups) must have a cleanup step on its card.
6. **Never touch `.claude/settings.local.json`.** The user maintains it by hand.

## Layout

- `terraform/modules/{vpc,eks,addons,rds,storage,platform}` - implementation (raw resources, transparent for learning).
- `terraform/modules/stack` - composition; the only place modules are wired together.
- `terraform/envs/dev` - thin consumer (backend + providers + one `module "stack"` block; no defaults). Single env on purpose.
- `terraform/bootstrap-oidc` - one-time GitHub Actions OIDC role (config table `[bootstrap_oidc]`).
- `helm/practice-app` - the fe/be app (public images only: nginx + PostgREST + postgres seed job; nothing to build or push).
- `argocd/` - GitOps glue; `argocd/generated/` is git-ignored output.
- `scenarios/` - drill cards; `scenario_testing/` - live-cluster outcome checks (`make check N=NN`); `tests/` - $0 local validation docs.
- `Makefile` (lifecycle) and `Makefile.test` (static + ministack + helm-in-podman). Cross-OS (Linux + Windows 11).

## Conventions

- Providers: AWS `>= 6.0, < 7.0`, helm `>= 2.12, < 3.0`, kubectl (gavinbunney), random. Values blocks via `yamlencode`.
- Kube/AWS auth uses `aws eks get-token` via the `AWS_PROFILE` env var; same config works locally and in CI (OIDC). No profile in `backend.tf` or providers.
- Kubeconfig is repo-local: `.kubeconfig-daily-eks-practice` (git-ignored), written by `make kubeconfig` and exported as `KUBECONFIG` by the Makefile for every target. Never read or write the user's `~/.kube/config`.
- State: partial S3 backend; bucket/region from `[backend]`, key injected per env by `bootstrap.py`. `use_lockfile = true`, no DynamoDB.
- Follow the global markdown rule: one full sentence per line in long Markdown.
- Track problems in `ISSUES.md` (DATE/TIME | description table); park ideas in `BACKLOG.md`.

## Definition of done for changes here

- `make -f Makefile.test test` passes (fmt + validate + helm lint).
- If Terraform changed: a ministack plan was attempted and the result reported.
- If a scenario changed: card, `scenario_testing/check.sh`, and `PRACTICE_ANSWERS.html` all agree.
- No real-AWS side effects unless the user explicitly asked.
