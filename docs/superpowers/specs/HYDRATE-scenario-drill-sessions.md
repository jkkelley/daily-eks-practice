# Hydration prompt - scenario drill sessions

Paste the block below into a fresh session (or after a compaction) to pick this work back up.

---

We are building the scenario drill sessions feature in `daily-eks-practice`.

**Read `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md` first - it is the authority, not this prompt.**
It contains every decision, the alternatives that were rejected, and why.
Do not re-litigate anything already recorded there.

**State:**

- Branch `feat/scenario-drill-sessions`, six commits, nothing pushed, cluster is down (`make down` already ran).
- Design phase is **complete**. All seven open questions (Q1-Q7, plus Q2a) are resolved and recorded in the spec.
- The implementation plan does **not** exist yet. Next step is the `superpowers:writing-plans` skill, output to `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`.
- Task list holds one closed task per question with the full resolution in each description.
- A Lavish architecture diagram exists at `.lavish/drill-platform-architecture.html`; it predates Q4-Q7 and is stale relative to the spec.

**One-paragraph summary of what we are building:**
`make scenario N=03` stops printing a Markdown card and instead converges a drill session.
A single long-lived in-cluster GUI pod (the "mothership") serves a terminal, a Monaco editor, an answers panel and a help panel, and is the only surface the user works from.
A permanent in-cluster git server is the sole source Argo CD ever reads, with GitHub as its upstream, so the GitOps lessons stay real.
Progress is a `git bundle` save file in the user's local repo that can rebuild a scenario from where they left off.
Scope is **scenario 03 only**; the other eleven get ported one at a time afterwards.

**Before writing the plan, know these:**

- There is an **unproven spike**: confirming Argo CD will clone from the in-cluster git server over the chosen protocol. The entire GitOps half of the design rests on it, so it belongs at the front of the plan.
- Scope is large even sliced to one scenario: Terraform (cluster git + ALB), a TypeScript app (Fastify + node-pty + React + xterm.js + Monaco), a CLI with a watcher, the answers TOML plus its generator, and the grader. Sequence it so something is drillable early rather than everything landing at once.
- `CLAUDE.md` hard rules still apply: no Terraform defaults, everything config-driven through `scripts/config.toml`, no PII committed, test through the container sandbox, never touch real AWS without explicit approval.

**Working preferences for this user:**

- When more than one question or decision is open, list them all first, then work through them one at a time in order. Do not bundle questions or jump ahead.
- Plain dashes, never em dashes.
- Say plainly when a previous recommendation was wrong and why, rather than quietly changing position.
