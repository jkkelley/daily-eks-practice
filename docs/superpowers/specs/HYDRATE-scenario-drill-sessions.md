# Hydration prompt - scenario drill sessions

Paste the block below into a fresh session (or after a compaction) to pick this work back up.

---

We are building the scenario drill sessions feature in `daily-eks-practice`.

**Read `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md` first - it is the authority, not this prompt.**
It contains every decision, the alternatives that were rejected, and why.
Do not re-litigate anything already recorded there.

**The delivery pipeline this work follows.** Three stages, each producing a committed artifact that is the next stage's input, so a compaction or a fresh session picks up from a file rather than from conversation history:

1. **Spec** (`superpowers:brainstorming`) -> `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`. **Done.**
2. **Implementation plan** (`superpowers:writing-plans`) -> `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`. **Done.**
3. **Tickets** (`work-order` skill) -> an epic with one child per plan phase, plus the dependency graph. **Not started - this is the next step.**

Stage 3 is what adds branch creation, PR submission and branch cleanup, so do not hand-write tickets and do not skip to implementation without them. The script writes the ticket, never the model.

**State:**

- Branch `main`, everything merged and pushed. Cluster is down; nothing is billing.
- Design phase is **complete**. All seven open questions (Q1-Q7, plus Q2a) are resolved and recorded in the spec.
- Implementation plan is **complete** and on main: `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, 8 phases, 21 tasks.
- The architecture diagram lives at `docs/architecture/drill-platform.html` and matches the spec. It was moved out of `.lavish/`, which is git-ignored at `.gitignore:27` and could never reach the remote.
- The plan opens with **the self-contained git rule**: the drill never contacts github.com, and cluster git is seeded by streaming a `git bundle` in from the laptop. The spec has been amended to match, so the two now agree. Read that section before designing anything that touches git.
- The plan also has a **"Where each language runs, and why"** section. That is not a deviation - the spec never said which language grades. TypeScript runs in the cluster (the whole GUI, including the grader); Python is laptop-side CLI glue the Makefile calls and is never in the container image. Read it before wondering why a TypeScript app has Python next to it.
- **Phases 6.1-6.5 and Tasks 5.4-5.5 are specified at interface level, not full TDD steps**, on purpose: they depend on what the user says when they first see the UI at Task 5.3. Expand them after that review, before those tickets are cut.

**Four open questions.** Work through them in order, one at a time. Do not assume an answer or bundle them.

**Q1 - Run the Phase 0 spike first, or cut work-order tickets first? ANSWERED: neither. The spike was cut.**
The user's call: do not spike, record the risk with pre-decided fallbacks, and surface it at the roadblock.
The correction I gave, which they accepted: dropping the spike does not move the discovery to Phase 3, it moves it to Phase 7 on real EKS, because `ministack` proves Terraform _plans_ and never runs a pod, so only a real cluster can tell you whether Argo clones.
The resolution: **Task 0.2 was deleted**, and the validation moved into **Task 3.2 Step 7** as that task's acceptance test rather than a prerequisite. Same kind cluster, same commands, $0, but validating the manifests that ship instead of a throwaway.
Task 3.2 now carries a **six-rung fallback ladder** under "The cluster git protocol risk": dumb HTTP nginx, smart HTTP via `git-http-backend`, `git daemon`, Gitea, Argo-reads-GitHub, and finally helm-on-submit with no Argo.
Rung 6 is the floor and is the only rung that stops teaching GitOps. Work down in order; report to the user before Task 3.3 if you land below rung 2, because rungs 3 to 6 change `cluster_git_url`.
Phase 0 is now a single task, the kind harness.

**Q2 - Amend the spec to match the seeding deviation? ANSWERED: yes, and the rule got wider.**
The user's framing: "we don't want to contact a real git, the whole purpose of this is to simulate it based off the files already available, why make another mechanism we don't need?"
This is now a **standing rule, not a one-off deviation**: the drill never contacts github.com, and everything Argo CD reads comes from the local repo by way of the cluster.
The spec was amended in place at its cluster-git section, marked "Seeding: amended 2026-08-19".
The plan's "One deviation from the spec" section became "The self-contained git rule".

One correction I gave and the user accepted: **self-contained is not simulated.**
The in-cluster server runs genuine git and Argo does a genuine clone and sync; only the location of the remote changes.
Do not let "simulate" drift into "mock" - if the GitOps step were faked, scenario 03 would teach a simulation of the skill instead of the skill.

What the rule forbids: Argo reading any repoURL outside the cluster, a GitHub credential in the cluster on the drill path, and `gen-argocd-app.py` reading the user's git remote on the drill path.
What it does **not** forbid: container images from `docker.io`/`ghcr.io`, and the kind test pulling Argo's install manifest from `raw.githubusercontent.com`. The rule governs what Argo reads, not cluster egress.
`scripts/argo-repo.py` is **kept, not deleted** - `scenarios/09-gitops-argocd.md` teaches manual PAT registration as its lesson and ships today. The drill just never calls it.

**Q3 - The user's public IP, for `drill_allowed_cidrs`.**
Needed at Phase 4. It lives in `scripts/config.toml`, which is git-ignored and hand-maintained.
**Do not edit that file without asking.** Print the line and their IP (`curl -s https://checkip.amazonaws.com`) and let them paste it.

**Q4 - Where the drill GUI container image gets published.**
Needed at Phase 5.5. GHCR under their account is the assumption but has not been confirmed.

**One-paragraph summary of what we are building:**
`make scenario N=03` stops printing a Markdown card and instead converges a drill session.
A single long-lived in-cluster GUI pod (the "mothership") serves a terminal, a Monaco editor, an answers panel and a help panel, and is the only surface the user works from.
A permanent in-cluster git server is the sole source Argo CD ever reads, with GitHub as its upstream, so the GitOps lessons stay real.
Progress is a `git bundle` save file in the user's local repo that can rebuild a scenario from where they left off.
Scope is **scenario 03 only**; the other eleven get ported one at a time afterwards.

**Before cutting tickets, know these:**

- **Nothing gates everything any more.** The one live risk is Argo-clones-cluster-git, and it lives inside Task 3.2 as that task's acceptance test with a ranked fallback ladder. Phases 1 and 2 do not depend on it at all.
- **Everything is faked locally first.** kind for cluster behaviour, ministack for Terraform, Podman for node and helm. Phase 7 is the only phase that touches AWS, and it is gated on explicit user approval with the cost stated (about $6.50 for a 30-hour cycle).
- **The first visual is Phase 5 Task 5.3**, a Vite dev server in Podman on a probed port. No cluster, no AWS. Stop there and show the user before building the remaining panels.
- `CLAUDE.md` hard rules still apply: no Terraform defaults, everything config-driven through `scripts/config.toml`, no PII committed, test through the container sandbox, never touch real AWS without explicit approval.

**Working preferences for this user:**

- When more than one question or decision is open, list them all first, then work through them one at a time in order. Do not bundle questions or jump ahead.
- Plain dashes, never em dashes.
- Say plainly when a previous recommendation was wrong and why, rather than quietly changing position.
