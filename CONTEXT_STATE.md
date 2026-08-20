# CONTEXT_STATE.md

> Source of truth for AI session state. Feed this as the opening prompt of any new session.
> Do not edit manually unless re-validating against live infrastructure.

## Meta

| Field        | Value                                                                              |
| ------------ | ---------------------------------------------------------------------------------- |
| last_updated | 2026-08-20 01:40 UTC                                                               |
| updated_by   | context-compaction skill                                                           |
| project      | daily-eks-practice                                                                 |
| repo         | see `git remote -v` - the owner string is PII per `CLAUDE.md` and is not committed |

## Infrastructure

**Nothing is provisioned. The cluster is destroyed and nothing is billing.** Verified 2026-08-19: the EKS API endpoint in `.kubeconfig-daily-eks-practice` no longer resolves. Every row below is what Terraform _would_ create, not what exists.

| Resource         | Value                                                                                                                                                                                              |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| control_plane_ip | n/a - EKS managed, no static IP. Endpoint is generated per cluster and lands in the git-ignored repo-local kubeconfig                                                                              |
| worker_ips       | none. Managed node group, `t3.medium`, `AL2023_x86_64_STANDARD`, desired 2 / min 1 / max 3, private subnets                                                                                        |
| dns_server       | none. `enable_external_dns = false`, `dns_zone_name = ""` - this is why ALB OIDC auth is deferred (no ACM cert)                                                                                    |
| ingress          | **planned, not built.** One shared internet-facing ALB via `alb.ingress.kubernetes.io/group.name`, fronting the drill GUI, Argo CD and Grafana. Source-IP restricted SG is the only access control |
| storage          | gp3 EBS via the EBS CSI driver. Drill workspace PVC 15 GB. **Orphans if the cluster is destroyed first** - see Task 4.2                                                                            |
| registry         | GHCR under the user's own account, **public** package, referenced through the `drill_gui_image` config value                                                                                       |
| dns_zone         | none configured                                                                                                                                                                                    |
| state backend    | S3, partial backend config, `use_lockfile = true`, no DynamoDB. Key injected per env by `scripts/bootstrap.py`                                                                                     |
| config           | `scripts/config.toml` (git-ignored, hand-maintained). **Never edit without asking.** Template: `scripts/config.example.toml`                                                                       |

## Toolchain

| Tool               | Role               | Notes                                                                                                                                      |
| ------------------ | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Terraform          | IaC                | AWS `>= 6.0, < 7.0`, helm `>= 2.12, < 3.0`, kubectl (gavinbunney), random. **Every variable has NO `default =`**                           |
| Argo CD            | GitOps             | Post-feature it reads **only** in-cluster git at `http://git-server.git.svc.cluster.local/repo.git`                                        |
| Helm               | packaging          | `helm/practice-app` (nginx + PostgREST + postgres seed). **Not installed on the host** - runs in Podman via `docker.io/alpine/helm:latest` |
| kind               | $0 cluster sandbox | `/usr/local/bin/kind`. Harness `scripts/kind-sandbox.sh` is Phase 0, not yet written                                                       |
| Podman             | container sandbox  | 4.9.3. Runs node, helm, and the Vite preview. `npm install` never runs on the host                                                         |
| ministack          | $0 Terraform proof | `make -f Makefile.test ministack`. Mocks AWS, **does not run pods** - cannot validate cluster behaviour                                    |
| Prometheus/Grafana | observability      | kube-prometheus-stack, scenario 07                                                                                                         |
| RDS                | database           | tiny instance, scenario 11                                                                                                                 |
| gh CLI             | GitHub auth        | scopes: `gist, read:org, repo, workflow`. **`write:packages` not yet granted** (needed at Phase 5 only)                                    |
| Node / Python      | app / glue         | node v20.20.2, python3 3.12.3 (stdlib only, no pip deps)                                                                                   |

## Active Tasks

| Priority | Task                                                                             | Status  | Next Action                                                                                                              |
| -------- | -------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------ |
| 1        | Execute `WO-20260819-844f - Phase 0: kind sandbox harness and its documentation` | ready   | `work-order.sh start --id WO-20260819-844f`, which creates and stamps the branch. Then follow plan Task 0.1 step by step |
| 2        | Execute `WO-20260819-11df - Phase 1: answers TOML as the single source of truth` | ready   | The other startable ticket. Independent of Phase 0, so it can go first or in parallel                                    |
| 3        | Port scenarios 01-02 and 04-12 to the drill format                               | pending | After the scenario 03 vertical slice is proven end to end. One at a time                                                 |

**The epic is cut.** `WO-20260819-f5c9 - Scenario drill sessions: make scenario N=03 converges an in-cluster graded drill` and its eight children are all `ready`, one child per plan phase, in `work-orders/`.
Run `bash .claude/skills/work-order/scripts/work-order.sh next` for what is startable and `... tree` for the shape; `work-orders/INDEX.md` is the generated router.
The epic depends on all eight children so it never appears as startable work itself.

Nothing is in progress. No implementation code exists yet - everything on `main` is planning artifacts and tickets.

## Decisions Made

| Date       | Decision                                                                                                 | Reason                                                                                                                                                                                                                                                                                |
| ---------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-08-19 | Three-stage pipeline: spec -> plan -> work-order tickets. Never skip a stage, never hand-write a ticket  | Each stage's output is the next stage's input, so a compaction or a fresh agent resumes from a file rather than from conversation history. work-order adds branch, PR and cleanup                                                                                                     |
| 2026-08-19 | **Self-contained git.** The drill never contacts github.com; Argo reads only in-cluster git              | The spec's init-container-clones-GitHub cannot work - `scripts/argo-repo.py` supplies the token _after_ apply, so a private repo fails the first apply. Seeding from a local `git bundle` removes the PAT, removes the egress dependency, and reuses one primitive in both directions |
| 2026-08-19 | Self-contained is **not** simulated                                                                      | The in-cluster server runs genuine git; Argo does a genuine clone and sync. Only the remote's location changes. A faked GitOps step would teach a mock of the skill                                                                                                                   |
| 2026-08-19 | The standalone Argo spike was **cut**                                                                    | It built the same manifest Task 3.2 builds, proved it, deleted it, then Task 3.2 rebuilt it. A negative result never killed the design - it only meant swapping the container                                                                                                         |
| 2026-08-19 | Argo-clones-cluster-git is validated as Task 3.2 Step 7 on kind, with a ranked five-rung fallback ladder | `ministack` never runs a pod, so without a kind step the discovery would land in Phase 7 on real EKS. Rung 5 (helm-on-submit, no Argo) is the floor and the only rung that stops teaching GitOps                                                                                      |
| 2026-08-19 | `drill_allowed_cidrs = ["auto"]`, resolved to the current public /32 at plan time                        | Residential addresses are DHCP. A pinned literal goes stale on a lease change and locks the user out with no error - the browser just hangs                                                                                                                                           |
| 2026-08-19 | Application auth **deferred**; source IP is the only control                                             | Verified the target is a directly-assigned residential IPv4, not carrier-grade NAT, so the /32 identifies one machine. Triggers to revisit are recorded in plan Task 4.1                                                                                                              |
| 2026-08-19 | GUI image is a **public** GHCR package under the user's own account                                      | The repo is public and `PRACTICE_ANSWERS.html` is already committed to it, so the image holds nothing new. Public removes an `imagePullSecret` and one more credential in the cluster                                                                                                 |
| 2026-08-19 | **Never create a personal access token.** Extend the grant `gh` already holds                            | A PAT is a second credential with its own expiry that must be stored, and every candidate here is bad: `config.toml` is serialised into Terraform state, a shell export lands in history, a dotfile is one `git add -A` from being committed                                          |
| 2026-08-19 | Grader is TypeScript in the cluster; Python stays laptop-side CLI glue                                   | Grading runs per submission inside the Node process. Python would mean shipping a runtime in the image. `bootstrap.py` stays Python so `make up` needs only `python3`                                                                                                                 |
| 2026-08-20 | The epic depends on all eight of its children                                                            | Without those edges the epic itself appears in `work-order.sh next` once approved, reading as startable work. Its only real job is to close after its children do                                                                                                                     |

## Lessons Learned

- 2026-08-19: Checking for carrier-grade NAT by testing whether the **externally visible** address falls in `100.64.0.0/10` does not work; that range lives on the router's WAN interface, and an external service returns the carrier's normal-looking public IP either way. Use the reverse-DNS host label instead - if it encodes the address itself, the address is directly assigned.
- 2026-08-19: Probing tool availability with `for c in ...; do $c version --short; done` produced mangled output and was misread as "kind is not installed", nearly forcing a $0 test onto real AWS. Use `command -v` to check for a binary; never infer absence from a failed version flag.
- 2026-08-19: An init container cloning GitHub cannot seed cluster git, because the token mechanism (`scripts/argo-repo.py`) runs _after_ apply. Do not retry credential-at-init-time designs in this repo.
- 2026-08-19: Widening a container build context without a deny-by-default `.containerignore` would have baked `scripts/config.toml` into a **public** image. Use `*` plus explicit `!` allows, never an exclude list - an exclude list leaks the next secret file somebody adds.
- 2026-08-19: `gh pr merge` returned repeated HTTP 502s and then `GraphQL: Merge already in progress` - a stale server-side merge lock from the failed request. It clears on its own; retry rather than forcing, and never assume a merge landed without checking `gh pr view --json state`.
- 2026-08-19: `gh auth refresh` is interactive and blocks on a browser one-time code. An agent cannot run it. Print the command for the user.

## Blockers

| Blocker | Last Known State                                                                                 | Owner |
| ------- | ------------------------------------------------------------------------------------------------ | ----- |
| none    | Nothing is blocked. `main` is clean, no open PRs, no branches other than `main`, cluster is down | -     |

Not blockers, but scheduled friction to expect:

| Item                                                            | When it bites            | Resolution                                                                                                                          |
| --------------------------------------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| `write:packages` scope not granted                              | Phase 5, Task 5.5        | User runs `gh auth refresh -h github.com -s write:packages`. Interactive - print it, do not attempt to run it                       |
| Argo may refuse to clone dumb-HTTP in-cluster git               | Phase 3, Task 3.2 Step 7 | Ranked five-rung fallback ladder is written into Task 3.2. Report to the user before Task 3.3 if the ladder is entered below rung 2 |
| Tasks 5.4-5.5 and 6.1-6.5 are specified at interface level only | Phase 5 and 6            | Deliberate. Expand them after the user reviews the UI at Task 5.3, before those tickets are worked                                  |
| Phase 7 costs money                                             | Phase 7                  | ~$6.50 per 30-hour cycle. **Requires explicit user approval before any step runs.** Phases 0-6 are $0                               |

## Hydration Prompt

Copy-paste this at the start of a new session:

```
Read CONTEXT_STATE.md in this project root before doing anything else.
Use the Infrastructure and Toolchain tables as ground truth.

Current focus: execute the first ticket of the scenario drill sessions epic,
WO-20260819-844f - Phase 0: kind sandbox harness and its documentation.
Read that ticket, then plan Task 0.1 in
docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md, which is the
authority for every step. Start with
`bash .claude/skills/work-order/scripts/work-order.sh start --id WO-20260819-844f`
so the branch is created and stamped on the ticket. TDD: test first, watch it
fail, then implement. Never hand-edit a ticket file - the script owns that format.

Do not suggest IP addresses, tool versions, or architecture patterns
that contradict CONTEXT_STATE.md without flagging the conflict first.
```
