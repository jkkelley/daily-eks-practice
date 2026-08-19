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
- The plan records **two deliberate deviations from the spec** at the top: cluster git is seeded by streaming a `git bundle` in from the laptop rather than by an init container cloning GitHub with a PAT, and the grader is TypeScript rather than Python. Read that section before treating any spec sentence as final.
- **Phases 6.1-6.5 and Tasks 5.4-5.5 are specified at interface level, not full TDD steps**, on purpose: they depend on what the user says when they first see the UI at Task 5.3. Expand them after that review, before those tickets are cut.

**One-paragraph summary of what we are building:**
`make scenario N=03` stops printing a Markdown card and instead converges a drill session.
A single long-lived in-cluster GUI pod (the "mothership") serves a terminal, a Monaco editor, an answers panel and a help panel, and is the only surface the user works from.
A permanent in-cluster git server is the sole source Argo CD ever reads, with GitHub as its upstream, so the GitOps lessons stay real.
Progress is a `git bundle` save file in the user's local repo that can rebuild a scenario from where they left off.
Scope is **scenario 03 only**; the other eleven get ported one at a time afterwards.

**Before cutting tickets, know these:**

- **Phase 0 gates everything.** The Argo-clones-cluster-git spike is still unproven. It runs on kind for $0 and its verdict changes the shape of Phases 3, 5 and 6. Nothing downstream starts until it is answered.
- **Everything is faked locally first.** kind for cluster behaviour, ministack for Terraform, Podman for node and helm. Phase 7 is the only phase that touches AWS, and it is gated on explicit user approval with the cost stated (about $6.50 for a 30-hour cycle).
- **The first visual is Phase 5 Task 5.3**, a Vite dev server in Podman on a probed port. No cluster, no AWS. Stop there and show the user before building the remaining panels.
- `CLAUDE.md` hard rules still apply: no Terraform defaults, everything config-driven through `scripts/config.toml`, no PII committed, test through the container sandbox, never touch real AWS without explicit approval.

**Working preferences for this user:**

- When more than one question or decision is open, list them all first, then work through them one at a time in order. Do not bundle questions or jump ahead.
- Plain dashes, never em dashes.
- Say plainly when a previous recommendation was wrong and why, rather than quietly changing position.
