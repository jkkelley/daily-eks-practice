# CLAUDE.md - daily-eks-practice

Agent rules for this repo.
This is a **learning/practice** project: a small, cheap, spin-up/spin-down EKS playground with a Helm fe/be app, tiny RDS, Argo CD, and Prometheus/Grafana, driven through ticket-style scenario cards.

## The north star

**`COMPASS.md` holds the north star: the drill loop.** Read it before any change. Everything in this repo answers to that picture - a change that does not serve the loop is out of scope, and one that contradicts it is wrong.

It is not duplicated here on purpose. One copy, in `COMPASS.md`. A second copy drifts, and a drifted north star is worse than none because it is trusted.

### When COMPASS.md gets updated

Only when the thing it depicts actually changes. Specifically:

- a component enters or leaves the loop, or moves namespace
- what the user interacts with changes
- what is **real** versus **simulated** changes
- a path in a pointer row moves, is renamed, or is deleted

Routine work does not touch it. Adding a scenario, fixing a bug, threading a variable - none of those are north star changes.

### How it gets updated

1. **In the same PR as the change that caused it.** Never as a follow-up, never as its own PR. A north star that lags the code by even one merge has already lied to somebody.
2. **By whoever made the change.** It is part of the deliverable, like a test.
3. **A change to the loop itself needs the user's explicit approval before it is written.** Pointer rows and moved paths do not - fix those silently and immediately.
4. **Staleness is a defect**, the same severity as a failing test. A row pointing at a path that no longer exists gets fixed in the change that moved the file.

### What COMPASS.md is not

It routes; it never explains. Hard cap 100 lines. The moment it explains something it has duplicated the file it points at, and the duplicate goes stale. If it does not fit in the cap, it belongs in the file being pointed at - not in a longer COMPASS.

If a change contradicts the north star, stop and raise it. Do not quietly edit the picture to match the code.

## What this repo is

A modular Terraform EKS project plus daily drill scenarios and a sealed answer key.
The scenarios in `scenarios/` are the curriculum; `PRACTICE_ANSWERS.html` holds the answers - keep the two in sync if you add or change a scenario, and add a matching outcome check to `scenario_testing/check.sh`.
Do not "pre-solve" scenarios in the committed defaults (e.g. don't enable the HPA or Ingress in values.yaml - flipping them on is the exercise).

## Session State

Two files, written in the same commit by the same close-out, describing the same moment.

`HYDRATION.md` is the prompt that starts a session: what to do, what not to assume, what must be settled first.
Read the **top entry only** - everything below it has been superseded and is kept for history.
Never hand-edit it; the `hydration-prompt` skill owns its ordering and its ten-entry window.

`CONTEXT_STATE.md` is the background that prompt assumes: infrastructure state, active tasks, decisions, lessons learned.
Read it after the prompt, for context.
Check its `last_updated` field first; if it is more than 7 days old, verify the infrastructure rows against reality before trusting them, and refresh it with the `context-compaction` skill.

**When the two disagree, the hydration prompt wins** - and say so, because two files written in the same commit that contradict each other is a defect worth reporting rather than silently resolving.
State describes; the prompt directs.
A stale snapshot is survivable information; an instruction overridden by stale information is how a session confidently does the wrong thing.

## The close-out flow

**Everything the ticket owns happens on the work branch, and the ticket reaches `done` there.** Then one pull request, then the merge, then the handback.

We always roll forward. Nothing about a ticket is left as paperwork that follows the PR, because paperwork that follows a merge is paperwork that gets skipped.

```text
close-out
│
├─ ON THE WORK BRANCH ─── everything the ticket owns, nothing deferred
│  │
│  ├─ 1. CONTEXT_STATE.md        new checkpoint at the TOP, newest first
│  │
│  ├─ 2. THE TICKET REACHES done ← every part of it, in this order
│  │     ├─ evidence every AC      work-order.sh evidence --observed
│  │     ├─ interview-ready retro  work-order.sh note
│  │     └─ mark it done           work-order.sh done
│  │
│  └─ 3. HYDRATION.md            hydration.sh check, then add
│
├─ ONE PULL REQUEST
│  └─ 4. push once               code + ticket + state + prompt, one review
│
└─ AFTER THE MERGE
   ├─ 5. archive                 work-order.sh close, straight to main
   ├─ 6. cleanup                 ff main, delete the branch both sides
   └─ 7. hand back               the prompt AND its launch command, then hold
```

**There is exactly one pull request per ticket.** A second PR carrying only state files doubles the review surface for one piece of work and leaves `main` briefly describing a world that no longer exists.

1. Update `CONTEXT_STATE.md` **on the work branch, as part of the work**. New checkpoint at the **top**, newest first. It is part of the deliverable, not paperwork that follows it.
2. **The ticket is marked `done` on the same branch, and everything it needs to get there is done first.** Evidence every acceptance criterion with `--observed`, including what the command or console actually printed; if a criterion is not met, say so plainly rather than dressing it up. Leave the interview-ready retro as a note. Then `work-order.sh done`. This is the rule the rest of the flow depends on: a branch carrying finished code and an unfinished ticket merges into a `main` where the work exists and the record of it does not.
3. Generate the successor's hydration prompt **on the same branch** with the `hydration-prompt` skill. Never hand-edit `HYDRATION.md`; the script owns its ordering and its window.
4. Push once and open **one** PR. It carries the code, the finished ticket, the state file and the hydration prompt together, so one review sees the change and the whole record of the change.
5. After the merge, run `bash .claude/skills/work-order/scripts/work-order.sh close --id WO-...`. It backfills the merge SHA, archives the ticket and regenerates `INDEX.md` **straight to `main`** - no second PR. It falls back to a PR only if that push is rejected.
6. Post-merge cleanup: fast-forward `main`, delete the feature branch locally and on the remote.
7. Hand back **both** the hydration prompt and the command that starts the next session, then hold. Do not start it.

**Never open a PR whose only content is `CONTEXT_STATE.md` or `HYDRATION.md`.**

**Check whether your PR has already merged before every commit once it is open.** A squash merge rewrites the SHA and closes the branch, so a commit pushed seconds later is stranded on a branch nothing points at. Recovery is fast-forward `main`, branch fresh, cherry-pick, delete both sides - but noticing late is avoidable, and it is the usual reason a step gets skipped and the one-PR rule gets broken.

## Hard rules

1. **Never run `terraform apply`, `make up/apply/down`, or otherwise touch real AWS without explicit user approval.** The user drives all applies and destroys. Plans and validation are fine.

   **There are exactly two sanctioned exceptions, both granted explicitly by the user, both narrow on purpose, and both written here rather than left implicit** - because an unwritten exception does not narrow a rule, it voids it: the next reader finds code that destroys AWS resources, finds a rule saying that never happens, and concludes the rule is decorative. Every clause under each is load-bearing and none of them may be dropped without asking again.

   **Exception 1, granted 2026-08-21: the drill GUI's `SHUT IT DOWN` entry.**

   - The learner types the literal string `DESTROY` in the browser, and **the server re-checks it**. A confirmation enforced only in the client is a suggestion.
   - **The pod destroys nothing.** It writes `phase: "destroy-requested"` into a ConfigMap. The destroy is carried out by `scripts/drill-watch.py`, a process the user started themselves, on their own laptop, in their own checkout, against the Terraform state that lives there.
   - The watcher prints a ten-second countdown naming what is about to go, and `ctrl-c` aborts it, so the last gate is in the terminal the user is sitting at. `DRILL_ALLOW_DESTROY=0` disarms the branch entirely.
   - It runs `make down`, so `scripts/pre-destroy.py` runs first and exits 1 rather than destroying into a mess. The safe teardown path is not bypassed - it is the thing being invoked.

   **Exception 2, granted 2026-08-22: idle teardown.** The playground stands itself down after a configurable quiet period, because the control plane bills for as long as it is up and the only thing that stops it is somebody remembering. Every comparable platform - Cloud9, SageMaker Studio, Codespaces, Gitpod - ships one for the same reason.

   Configured entirely on the laptop, on `scripts/drill-watch.py`: `DRILL_IDLE_TIMEOUT` (`90s`, `5m`, `1h`, or bare seconds), `DRILL_IDLE_ACTION` (`warn` or `destroy`), `DRILL_IDLE_GRACE`.

   - **Off unless `DRILL_IDLE_TIMEOUT` is set. There is no default and there must never be one.** A malformed value is fatal, never rounded to something sensible - a destroy timer the user and the machine disagree about is the worst failure available here.
   - **`warn` is the default action.** Arming it is a second deliberate act by the user, not a consequence of turning the clock on.
   - **The pod destroys nothing**, exactly as in Exception 1. It stamps `lastActivityAt` and renders the countdown; `scripts/drill-watch.py` decides and acts.
   - **The deadline is computed only from human input** - a keystroke, a save, a submission. Never from the app's own dependency push, health probe or Argo poll. If chatter counted, an abandoned tab would hold the cluster open forever and the feature would silently never fire.
   - **State that cannot be read is never grounds to destroy.** An unreachable API and an idle learner are different answers, and only one of them may act.
   - The countdown is abortable with `ctrl-c` on a longer grace than Exception 1's ten seconds, because here the user is walking back to the keyboard rather than sitting at it. `DRILL_ALLOW_DESTROY=0` disarms it, and it runs `make down`, so `pre-destroy.py` runs first.

   **The gate Exception 1 has and this one cannot: the typed `DESTROY`.** Its whole premise is that nobody is at the keyboard, so there is no one to type anything. What stands in for it is being off by default, warn-by-default, and a countdown the learner can see in the GUI that any keystroke resets. That substitution is the reason this needed approving separately rather than being read as covered by Exception 1.

   Neither exception generalises. An agent may still never run a destroy on its own initiative, and nothing else in this repo may acquire a "the user pre-approved it" path without the user approving that path specifically.

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
