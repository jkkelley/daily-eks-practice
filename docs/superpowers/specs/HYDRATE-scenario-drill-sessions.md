# Hydration prompt - scenario drill sessions

Paste the block below into a fresh session (or after a compaction) to pick this work back up.

Current target: **stage 3 of the pipeline, cutting the work-order epic.**

---

Cut the work-order epic for the scenario drill sessions feature in `daily-eks-practice`.

## What to do

Invoke the `work-order` skill and cut **one epic with eight children**, one child per plan phase, plus the dependency graph below.

Do not hand-write ticket markdown. The script writes the ticket, never the model.
Do not start implementing. This session's deliverable is the epic and nothing else.
`lavish-axi` is available for approval; if it refuses, use `--no-lavish --reason "..."` rather than skipping approval.

## Read these two files before cutting anything

1. `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md` - the implementation plan. 8 phases, 22 tasks. **This is what you are turning into tickets.** Read its `## Global Constraints`, `## The self-contained git rule`, and `## Phase map` sections in full; they bind every ticket.
2. `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md` - the spec the plan argues from. Read it for the why behind any phase whose ticket needs context.

The plan and the spec agree. Every contradiction between them has been resolved and the spec amended. **Do not re-litigate anything in either file.**

## The pipeline this belongs to

Three stages, each producing a committed artifact that is the next stage's input, so a compaction never loses the thread:

1. **Spec** (`superpowers:brainstorming`) -> `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`. **Done.**
2. **Implementation plan** (`superpowers:writing-plans`) -> `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`. **Done.**
3. **Tickets** (`work-order` skill) -> the epic. **This session.**

Stage 3 is what adds branch creation, PR submission and branch cleanup. That is why it exists and why it comes last.

## The eight children and their dependency graph

| Child | Plan phase | Deliverable                                                                                                           | Cost         | Depends on    |
| ----- | ---------- | --------------------------------------------------------------------------------------------------------------------- | ------------ | ------------- |
| 1     | Phase 0    | Kind sandbox harness + the `## Kind Sandbox` section of `.claude/skills/container-sandbox/SKILL.md`                   | $0           | nothing       |
| 2     | Phase 1    | Answers TOML as single source of truth; `PRACTICE_ANSWERS.html` generated for 03, byte-identical for the other eleven | $0           | nothing       |
| 3     | Phase 2    | The grader: alias expansion, semantic command parsing, hints                                                          | $0           | child 2       |
| 4     | Phase 3    | Terraform: in-cluster git, seeding, Argo repointed                                                                    | $0           | child 1       |
| 5     | Phase 4    | Terraform: shared ALB IngressGroup, source-IP SG, non-orphaning teardown                                              | $0           | child 4       |
| 6     | Phase 5    | The mothership GUI. **First visual at Task 5.3**                                                                      | $0           | children 1, 3 |
| 7     | Phase 6    | Session lifecycle, sync watcher, Makefile handover                                                                    | $0           | children 4, 6 |
| 8     | Phase 7    | Live verification on real EKS                                                                                         | ~$6.50 / 30h | children 5, 7 |

Children 1 and 2 are the only ones with no dependency, so they are where work starts.

## Five things the tickets must carry

**1. Child 8 is approval-gated and must say so in its acceptance criteria.** Phase 7 is the only phase that touches real AWS. Its Step 1 is literally "ask for approval, with the number, and wait". Approximate cost for one 30-hour cycle is $6.50 (EKS control plane ~$3.00, ALB ~$1.00, NAT ~$1.35, SPOT nodes ~$0.60, RDS ~$0.50, EBS ~$0.05), of which the drill platform's own share is about $1.05. Children 1 to 7 are $0 and need no approval.

**2. Child 6 has a hard stop mid-ticket.** Task 5.3 is the first time the user sees anything, served from a Vite dev server in Podman on a probed port. The ticket must stop there and show them before the remaining panels are built.

**3. Two things in the plan are deliberately specified at interface level, not full TDD steps: Tasks 5.4-5.5 and Tasks 6.1-6.5.** They depend on what the user says at the Task 5.3 review. Children 6 and 7 must record that those tasks get expanded after that review and before their work begins - do not cut them as if they were fully specified.

**4. Child 4 carries the one live technical risk.** Whether Argo CD will clone from an in-cluster git server over plain HTTP is unproven. It is validated on kind as Task 3.2 Step 7, the acceptance test of the ticket, at $0. Task 3.2 carries a ranked **five-rung** fallback ladder: dumb HTTP nginx, smart HTTP via `git-http-backend`, `git daemon`, Gitea, and finally helm-on-submit with no Argo. Rung 5 is the floor and the only rung that stops teaching GitOps. The ticket must say: report to the user before Task 3.3 if the ladder is entered below rung 2, because rungs 3 to 5 change `cluster_git_url`.

**5. Every ticket inherits the plan's `## Global Constraints`.** Do not restate them all in each ticket; point at the section. The ones most likely to be violated by an implementer who skips it:

- **No Terraform defaults.** Every variable declared with no `default =`; values live in git-ignored `scripts/config.toml`, documented in `scripts/config.example.toml`, threaded env -> stack -> module. Run Terraform only through `scripts/bootstrap.py` / `make`.
- **No real AWS without explicit approval.** Children 1-7 are kind + Podman + ministack only.
- **No PII in git.** No AWS account ids, profile names, domains, CIDRs or repo-owner strings outside `scripts/config.toml` and generated files.
- **Never create a personal access token.** Extend the grant `gh` already holds: `gh auth refresh -h github.com -s <scope>`. It is interactive and blocks on a browser, so print the command for the user rather than trying to run it.
- **Never touch `scripts/config.toml` or `.claude/settings.local.json`** without asking. Both are hand-maintained.
- **Plain dashes, never em dashes.** One full sentence per line in long Markdown.

## The four design questions, all answered

Recorded so they are not reopened. Full reasoning is in the plan.

**Q1 - spike or tickets first? Neither; the spike was cut.** A standalone spike would have built the same manifest Task 3.2 builds, proved it, deleted it, and let Task 3.2 rebuild it. The validation moved into Task 3.2 Step 7 as an acceptance test instead, with the fallback ladder written in advance. Phase 0 is now a single task.

**Q2 - self-contained git.** The drill never contacts github.com; everything Argo CD reads comes from the local repo by way of the cluster, seeded by streaming `git bundle create - --all` in over `kubectl exec`. This is a standing rule and the spec was amended to match. **Self-contained is not simulated** - the in-cluster server runs genuine git and Argo does a genuine clone and sync; only the location of the remote changes. The rule governs what Argo reads, not cluster egress: images from `docker.io`/`ghcr.io` are fine. `scripts/argo-repo.py` is kept, not deleted, because `scenarios/09-gitops-argocd.md` teaches manual PAT registration and ships today.

**Q3 - the drill ALB allow list.** `drill_allowed_cidrs = ["auto"]`, resolved to the current public /32 at plan time by `bootstrap.py`. Never ask the user for a literal address and never print one. `make drill-allow` is the mid-drill recovery path. Application auth is **deferred with its trigger recorded in Task 4.1**: source IP is the only control on an unauthenticated cluster-admin terminal, and it is defensible only because the target was verified as a directly-assigned residential IPv4 rather than carrier-grade NAT. Add the shared-secret check before drilling from a cafe, a tether, a corporate network, a VPN, or as soon as a second person uses the platform.

**Q4 - the GUI image.** A **public** GHCR package under the user's own account, referenced through the `drill_gui_image` config value, never hardcoded. Public because the repo is public and the answer key is already committed to it, which removes an `imagePullSecret`. The build context is the **repo root**, not `drill/`, because the grader reads `scenarios/answers/*.toml` - which makes `.containerignore` security-critical and deny-by-default (`*`, then `!drill/`, `!scenarios/answers/`). Single-arch amd64; do not reach for buildx.

## What we are building, in a paragraph

`make scenario N=03` stops printing a Markdown card and instead converges a drill session.
A single long-lived in-cluster GUI pod (the "mothership") serves a terminal, a Monaco editor, an answers panel and a help panel, and is the only surface the user works from.
Because the terminal lives in the GUI, the grader observes what the user actually runs; there is no submission form.
A permanent in-cluster git server is the sole source Argo CD ever reads, so the GitOps lessons stay real.
Progress is a `git bundle` save file in the local repo that can rebuild a scenario from where they left off.
Scope is **scenario 03 only**; the other eleven get ported one at a time afterwards.

## State

- Branch `main`, clean, everything merged and pushed. Cluster is down; nothing is billing.
- No implementation code exists yet. Everything so far is planning artifacts.
- The architecture diagram is at `docs/architecture/drill-platform.html` and matches the spec.
- Local tooling confirmed: `kind`, `minikube`, `kubectl`, `podman` 4.9.3, `node` v20.20.2, `npm`, `python3` 3.12.3, `jq`, `tmux`. **`helm` is NOT on the host** and runs in Podman via `docker.io/alpine/helm:latest`.

## Working preferences for this user

- When more than one question or decision is open, list them all first, then work through them one at a time in order. Do not bundle questions or jump ahead.
- Plain dashes, never em dashes.
- Say plainly when a previous recommendation was wrong and why, rather than quietly changing position.
- Name every work-order with its ID and full title on every mention. A bare ID, or "the next ticket", is a defect.
