# tests/

How local, $0 validation works in this repo.
Nothing here touches real AWS; it exists so both a human and an agent can prove a change is sane before anything is applied.

## The layers

```bash
make -f Makefile.test test        # the default gate: fmt-check + validate + helm-lint
make -f Makefile.test ministack   # deepest: full terraform plan vs a mock AWS
```

1. **`fmt-check`** - `terraform fmt -recursive -check`. Style only.
2. **`validate`** - `terraform init -backend=false` + `validate` for `envs/dev` and `bootstrap-oidc`. Catches type errors, missing variables, bad references. Needs internet for provider downloads, no credentials.
3. **`helm-lint` / `helm-template`** - lints and fully renders `helm/practice-app`. Helm runs **inside Podman** (`docker.io/alpine/helm`), so no local helm install is needed or assumed.
4. **`ministack`** - `scripts/ministack-test.sh` starts a local mock-AWS container (Podman), points Terraform at it with fake credentials and a local state backend (via a git-ignored `*_override.tf`), and runs a full plan. This is the vendored [`container-sandbox`](../.claude/skills/container-sandbox/SKILL.md) skill's flow; it catches wiring/dependency/attribute bugs across the whole graph for $0.

## Fidelity caveat

ministack emulates the AWS API surface - it validates that the **Terraform graph is correct**.
It does not run real EKS, RDS, or helm releases into a live cluster; some resources may hit emulator gaps (the script says so when that happens - read the error and judge whether it's a real bug or a gap).
Real-cluster verification is what the drills themselves are for, and `scenario_testing/` grades those outcomes.

## Who uses what

- **You (or any engineer)**: run the commands above before opening a PR; CI runs the same static layers on every PR.
- **The agent (Claude)**: must pass `make -f Makefile.test test` and attempt a ministack plan for any Terraform change - that's the repo's definition of done (see `CLAUDE.md`).
- **Scenario grading** is a different thing: `make check N=NN` against the live cluster, documented in [`scenario_testing/README.md`](../scenario_testing/README.md).
