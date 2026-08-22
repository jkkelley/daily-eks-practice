# HYDRATION.md

The prompt that starts the next session, and the 10 before it.

**Read the top entry only.** It is the current one and it is complete on its own.
Everything below it has been superseded and is kept for history, not for reading.

**Newest on top.** Adding an entry removes the oldest in the same commit, so this
file holds exactly 10 once it has filled up. Entries are never renumbered and
never edited in place - a correction is a new entry.

Written by `hydration.sh add`. Do not hand-edit.
<!-- hydration-entry: WO-20260819-0562 -->
## WO-20260819-0562 - Phase 7: live verification on real EKS (approval gated)
_Generated 2026-08-21 by hydration.sh. Newest entry._

### Ticket

`WO-20260819-0562` - `Phase 7: live verification on real EKS (approval gated)`. Position 8 of 8, the last child of the epic `WO-20260819-f5c9` - `Scenario drill sessions: make scenario N=03 converges an in-cluster graded drill`.
Predecessor `WO-20260819-7840` - `Phase 6: session lifecycle, the sync watcher, and the Makefile handover`, merged in PR #29.

**This phase costs money and is gated on the user saying yes, with the number in front of them.** Do not run `make up`. Present the cost, say what will be verified, and wait.

### What just landed

Phase 6 made the drill a thing you can leave and come back to, and gave `EXIT` somewhere to go.

**The save files.** `scripts/progress.py` and `drill-progress/` - append-only, one directory per session, every write atomic, no colons in any path component because Windows 11 is a supported target. `.gitignore` names it in the same commit that created the module and **before** anything could create the directory.

**One bundle implementation, not three.** `scripts/clustergit.py` was factored out of `git-seed.py` because three callers now move bundles through the git pod. The measured corruption bug - 443833 bytes sent, 98662 landed, `kubectl` exiting 0 - has one guard again with the evidence written on it. Every transfer counts its bytes; every bundle is `git bundle verify`-ed before it is renamed into place.

**The watcher.** `scripts/drill-watch.py` follows `drill-state` with `kubectl --watch`, writes `state.json`, re-bundles, and is where the two terminal phases actually land - a pod can write an intent but cannot reach a process on your laptop.

**The handover.** `scripts/scenario.py` converges rather than creates; `scripts/handover.py` stands the Makefile down while the GUI drives, with `FORCE=1` as the escape hatch and a refusal that names the **consequence** per target rather than the rule.

**The pause menu.** `EXIT` opens it: RESUME, RESTART, NEXT, PREVIOUS, SELECT, QUIT, SHUT IT DOWN. All twelve scenarios listed, the eleven unported ones disabled and saying why. The transition screen is the `/api/deps` dependency chain rendered large rather than a spinner, so a slow switch says which link is slow.

**Two ConfigMaps, one writer each.** `drill-state` server-owned, read by the laptop; `drill-request` laptop-owned, read by the server. The server writes `drill-state` and **mutates nothing else in the cluster** - `QUIT` records a phase and the laptop acts on it.

**`CLAUDE.md` hard rule 1 was amended**, with the user's explicit approval, to carry one narrow exception: the GUI's `SHUT IT DOWN`. Read the rule before touching anything that produces `phase: "destroy-requested"`.

### What is NOT done

**Nothing has been applied to real AWS. No cluster exists and nothing is billing.** Everything above was proven on kind and in Podman. `aws eks list-clusters` returns an empty list; `terraform output` has no state to read.

**The image has never been pushed.** `make drill-image` has not been run, the GHCR package does not exist, and it has therefore never been made public. **The first run must set the package to Public or the pod is `ImagePullBackOff`.** `tests/drill-gui-kind.sh` sidesteps this by loading the image into kind directly, so a green kind run proves nothing about the pull.

**`WO-20260819-1fea` - `Phase 4: Terraform - the shared ALB, the source-IP security group, and non-orphaning teardown` still carries an unmet `AC-H3`.** It asks for one ALB across three Ingresses. Only the drill GUI's Ingress exists - Argo CD's and Grafana's arrive with scenario 07 - and that Ingress's `yaml_body` is unknown at plan time because it interpolates a security group id that does not exist until apply. **This phase is the first time it is observable at all.** Count the load balancers.

**The scenario-switch round trip is unproven.** Only 03 is ported, so `drill 03 -> switch to 06 -> drill 06 -> switch back` has no fixture. The switch mechanics are proven against a real bundle round trip; the round trip itself belongs to whichever epic ports the second scenario. It is recorded in `BACKLOG.md`, in the ticket's notes, in `CONTEXT_STATE.md` and in the plan's self-review.

**The destroy branch of the watcher has never actually run `make down`.** It was exercised only through its `DRILL_ALLOW_DESTROY=0` disarm path, because running it for real destroys an environment. Phase 7 step 6 is where it gets driven, by the user.

**The proxy is still unexercised.** Subpath serving needs Grafana's `root_url` and `serve_from_sub_path` plus Argo's `server.rootpath`, verified against the charts scenario 07 installs.

### Stale or false in the docs

**`scripts/config.toml` is still six keys behind and any real `make plan` fails on all six.** It is dated 2026-08-19 and predates Phase 4. Add to `[common]`: `enable_cluster_git`, `drill_ingress_group_name`, `drill_allowed_cidrs`, `enable_drill_gui`, `drill_gui_image`, `drill_gui_tag`. All six are documented in `scripts/config.example.toml`. **This is the first ticket that cannot proceed without it.** The user was asked twice and declined to have it edited for them - `drill_allowed_cidrs` is the only control in front of an unauthenticated cluster-admin terminal and is theirs to set. **Do not edit that file without asking.**

The plan's Phase 7 step 3 says Argo reads `http://git-server.git.svc.cluster.local/repo.git`. It is **`git://`**, not `http://` - see the rung-3 decision at the top of `cluster-git.tf`. The port is 9418.

Nothing else in the plan is at interface level any more. Phase 6's tasks were expanded before its code was written and the expansion is in the plan.

### Your scope

Phase 7, steps 1 through 7, in `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`.

Approximate cost for one 30-hour cycle: EKS control plane ~$3.00, ALB ~$1.00, NAT gateway ~$1.35, nodes on SPOT ~$0.60, RDS ~$0.50, EBS ~$0.05. **Call it $6.50.**

What kind and ministack cannot prove, and this phase must: IRSA; the AWS Load Balancer Controller actually provisioning **one** ALB across the group; the source-IP security group actually restricting it; EBS behind the PVCs; and the teardown ordering that keeps them from orphaning. Plus `make drill-allow`, whose AWS calls have never run - Task 4.1 could only reach the guard. Run it twice: the second must report `already correct, nothing to do`, or the comparison logic churns the rule on every invocation.

Then **actually drill scenario 03 end to end in the browser**, all six tasks, real answers, real verdicts, and watch Argo put the bad version back after a `rollout undo`. Then tear down, bring it back, and confirm the session restores.

### Before you start

1. **Get the cost approved, with the number.** `$6.50` for a 30-hour cycle. This is `CLAUDE.md` hard rule 1 and it is not a formality.
2. **`scripts/config.toml` must gain its six keys, by the user, before anything runs.** Ask; do not edit. Every `$0` check still works via `DAILY_EKS_CONFIG=scripts/config.example.toml`.
3. **Decide the image tag and make the GHCR package public** on the first `make drill-image`. A private package is an `ImagePullBackOff` that looks like a cluster problem.

### Read in this order

1. `CLAUDE.md` - hard rules, and read rule 1's exception in full before touching the destroy path.
2. `COMPASS.md` - the drill loop. Phase 7 is the first time the whole picture is real.
3. `CONTEXT_STATE.md` - Blockers first, then Lessons Learned.
4. `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, Phase 7 - the authority.
5. The ticket file, `work-orders/WO-20260819-f5c9/WO-20260819-0562-phase-7-live-verification-on-real-eks-approval-g.md`.
6. `WO-20260819-7840`'s `## Notes` in `work-orders/archive/2026/` - every Phase 6 defect and decision.

### Reuse, it is proven

- `scripts/clustergit.py` - `settings()`, `pod_name()`, `push_bundle()`, `pull_bundle()`. Sharp edge: `tee` is exec'd directly with no shell, and that is a regression guard for a measured corruption bug. Do not reintroduce a shell.
- `scripts/progress.py` - `write_atomic` puts its temp file beside the target, because `os.replace` is only atomic within a filesystem.
- `scripts/pre-destroy.py` - counts load balancers by the `elbv2.k8s.aws/cluster` **tag**, never by name. It runs first in `make down`.
- `scripts/drill-allow.py` + `make drill-allow` - the mid-drill lockout recovery path, never yet run against a real security group.
- `tests/drill-resume-kind.sh` - extracts manifests from the ministack plan and sorts them into dependency order. Copy that approach; do not restate manifests.
- `drill/server/src/integrations/k8s.ts` - the only file importing the Kubernetes client. `K8sReader` reads, `K8sStateWriter` writes, and they are separate types on purpose.

### The verification ladder

Cheapest first. Every rung has caught something real.

1. `make -f Makefile.test test` - 291 static assertions.
2. `make -f Makefile.test drill-test drill-typecheck` - 186 tests in Podman.
3. `make -f Makefile.test drill-build` - caught Monaco silently returning to a CDN fetch.
4. `DAILY_EKS_CONFIG=scripts/config.example.toml make -f Makefile.test ministack` - full plan against mock AWS.
5. `make -f Makefile.test drill-gui-test` - 22 assertions on kind. `make -f Makefile.test drill-resume-test` - 20 more, including a real cluster destroyed and rebuilt.
6. **Look at it.** Four Phase 6 defects reached a green suite and a clean typecheck and were found only by looking at the running UI. For anything with a surface this is a different instrument, not a formality.
7. **Only then, real AWS** - and only with approval.

### Traps, already paid for

- `kubectl apply -f` with many documents applies in **file order**, does not stop at the first error, and reports it only in the exit code. A terraform plan lists resources alphabetically, so a Deployment can precede its Namespace - and because the namespace then exists, a second run passes. Never discard an apply's exit code.
- A bare PID is not a liveness check; PIDs get recycled. Record the start time too.
- `kubectl get --watch -o json` emits **concatenated** JSON objects, not an array and not one per line.
- A ConfigMap is capped at 1 MiB and the API server rejects the whole object over it.
- A test harness that invents a name fails everywhere except where the name is checked - the git container is `git`, not `git-daemon`.
- `git -C <dir>` walks **up** to find a repo. Compare `rev-parse --show-toplevel` to the directory you meant.
- An acceptance check can go green against a resource that does not exist. Assert existence first, then assert about it.
- `kubectl` reports the context does not exist: this project's kubeconfig is repo-local and never `~/.kube/config`.
- A CSS utility class can be scoped to a parent you are not under. `.grow` is `.panel > header .grow` and `.statusbar .grow`.

### Workflow

```sh
WO=.claude/skills/work-order/scripts/work-order.sh
HP=.claude/skills/hydration-prompt/scripts/hydration.sh

bash $WO start    --id WO-20260819-0562
bash $WO note     --id WO-20260819-0562 --text "what happened"
bash $WO evidence --id WO-20260819-0562 --index 1 --observed "what was seen"

# close-out, all on the work branch, then ONE pull request
#   1. CONTEXT_STATE.md
#   2. evidence every AC, retro note, then done
#   3. HYDRATION.md
bash $HP check    --project . --body-file /tmp/entry.md
bash $HP add      --project . --id WO-... --title "..." --body-file /tmp/entry.md
gh-axi pr create  --title "..." --body "..."
bash $WO submit   --id WO-20260819-0562 --pr <N>
bash $WO done     --id WO-20260819-0562
# after the merge
bash $WO close    --id WO-20260819-0562
```

The flow's diagram puts `done` before the pull request, but `work-order.sh done` requires status `in-review`, which only `submit --pr <N>` sets and which needs a PR number. The reconciliation used since Phase 5 is: open the one PR first, then `submit`, then `done`, all on the same branch. Raise it rather than rediscovering it.

### Conventions

Every reference to a work order carries its ID **and** its full title, joined by a dash, on every mention. A bare ID is a defect.

No em dashes; use a plain dash. Never add an agent co-author line to a commit. Never hand-edit `HYDRATION.md`, `CHANGELOG.md`, `PRACTICE_ANSWERS.html`, `scenarios/answers/catalogue.json`, `work-orders/INDEX.md`, a ticket file, or `.claude/settings.local.json`.

**Never run `terraform apply`, `make up`, `make down` or anything touching real AWS without explicit approval** - and in this phase that approval is the first step, not an afterthought. The one standing exception is the drill GUI's `SHUT IT DOWN`, written into hard rule 1.

Config-driven, no defaults: every Terraform variable has no `default =`, and values live in `scripts/config.toml`. No account ids, profile names, real domains or repo-owner strings anywhere in git.

Report failing tests as failing, and say plainly when an acceptance criterion is not met rather than dressing it up.

<!-- hydration-entry: WO-20260819-7840 -->
## WO-20260819-7840 - Phase 6: session lifecycle, the sync watcher, and the Makefile handover
_Generated 2026-08-21 by hydration.sh. Newest entry._

### Ticket

`WO-20260819-7840` - `Phase 6: session lifecycle, the sync watcher, and the Makefile handover`. Position 7 of 8 under the epic `WO-20260819-f5c9` - `Scenario drill sessions: make scenario N=03 converges an in-cluster graded drill`.
Predecessor `WO-20260819-ca7c` - `Phase 5: the mothership GUI, its container image, and the first visual`, merged in PR #27.

### What just landed

Phase 5 gave the drill a surface. One long-lived pod, namespace `practice-drill`, serving everything the user touches.

**The server**, `drill/server/src/`. Fastify 5 on 8090. Routes: `/healthz`, `/api/session`, `/api/scenario`, `/api/tasks`, `/api/tree`, `/api/file`, `/api/git/status`, `/api/deps`, `/api/argo`, `POST /api/submit`. One websocket at `/ws` carrying the terminal both ways plus the editor's autosave, with a dependency push every ten seconds. `pty.ts` runs the shell under `tmux new-session -A` so closing the tab does not kill the work, and tees output to a log outside the git tree. `workspace.ts` is the path jail. `git.ts` reports status and deliberately offers no stage, unstage or commit, because those commands ARE scenario 03's model answer.

**`committed.ts` fills the `readCommitted` seam** that had been empty since Task 5.1. It fetches the remote and reads the file as cluster git has it, which is what Argo will sync. Three answers, not two: content, `""` when git demonstrably does not have the file, and `undefined` when it could not be determined. `undefined` means commit state is not graded at all.

**The integrations**, `drill/server/src/integrations/`. `k8s.ts` is the only file in the repo importing `@kubernetes/client-node` and holds no logic; everything above it takes a `K8sReader` and is tested against a fake. `argo.ts` maps the `Application` CRD. `deps.ts` derives the three-link startup chain and keeps `waiting` distinct from `absent`. `proxy.ts` mounts `@fastify/http-proxy` at `/argo` and `/grafana`, built and deliberately unexercised.

**The web app**, `drill/web/src/`. Activity rail, explorer, source control, Monaco with tabs and five themes, xterm terminal, and a right-hand panel with `tasks`, `card` and `argo`. Monaco is a lazy chunk; `tests/test_web_bundle_shape.py` pins that.

**The image and the deployment.** `drill/Containerfile` is a two-stage Alpine build; `/.containerignore` denies everything and allows `drill/` and `scenarios/answers/` back. `terraform/modules/platform/drill-gui.tf` creates the namespace, a `cluster-admin` ServiceAccount, a 15 GB PVC, the Deployment, a Service on 8090, and an Ingress joining the shared group. An init container **clones** cluster git into the PVC and is idempotent across restarts.

**The environment has an identity.** The account is `pilot`, the host is `drill`, and the workspace is `~/practice-app` - a directory inside the home, so every dotfile a shell writes lands outside the git tree. `callsign <name>` renames the account by rewriting the passwd entry for its own uid, so `whoami`, `id`, `ps` and `ls -l` all agree.

**Publishing.** `make drill-image` locally, `.github/workflows/drill-image.yml` on push to `main` with the automatic `GITHUB_TOKEN`.

**Process.** `CLAUDE.md` adopted the roll-forward close-out flow and the `hydration-prompt` skill is vendored at `.claude/skills/hydration-prompt/`. This file is the first product of it.

### What is NOT done

**Nothing has been applied to real AWS. No cluster exists and nothing is billing.** Everything above was proven on kind and in Podman. `terraform output` has no state to read; `aws eks list-clusters` returns an empty list.

**The image has never been pushed.** `make drill-image` has not been run, the GHCR package does not exist, and it has therefore never been made public. First run must set the package to Public or the pod is `ImagePullBackOff`.

**`WO-20260819-1fea` - `Phase 4: Terraform - the shared ALB, the source-IP security group, and non-orphaning teardown` carries an unmet `AC-H3`**, and Phase 5 did not clear it. It asks for a plan showing one ALB across three Ingresses. Two blockers: only one Ingress exists, the drill GUI's, because Argo CD's and Grafana's arrive with scenario 07; and that Ingress's `yaml_body` is unknown at plan time because it interpolates `aws_security_group.drill_alb[0].id`, which does not exist until apply. It is not evidenceable from a plan at all. It becomes observable at the first real apply with two or more group members.

**The proxy is unexercised.** Subpath serving needs Grafana's `root_url` and `serve_from_sub_path` plus Argo's `server.rootpath`, verified against the charts scenario 07 installs.

**Only scenario 03 is ported.** The other eleven answer blocks still pass through byte-for-byte.

### Stale or false in the docs

`scripts/config.toml` is **six keys behind** and any real `make plan` fails on all six. It is dated 2026-08-19, predates Phase 4, and contains zero drill keys. Add to `[common]`: `enable_cluster_git`, `drill_ingress_group_name`, `drill_allowed_cidrs`, `enable_drill_gui`, `drill_gui_image`, `drill_gui_tag`. All six are documented in `scripts/config.example.toml`. The user was asked and declined to have the file edited for them - `drill_allowed_cidrs` is the only control in front of an unauthenticated cluster-admin terminal and is theirs to set. **Do not edit that file without asking.**

The plan's Task 5.1 says to switch `NODE_IMAGE` to `node:20-bookworm-slim` if `node-pty` fails to build. That is wrong and the fallback fails identically - the missing thing was never the libc, it is python3. `drill/Containerfile.build` documents it.

The plan's Task 5.5 says the PVC is `gp3`. It is not: no `storageClassName` is set, matching `cluster-git.tf`, because the default class is right on both EKS and kind and naming gp3 would break the kind sandbox where this is tested.

Phase 6 tasks 6.1 through 6.5 are still specified at **interface level only**. Expand them into step-by-step tasks before working them, the way 5.4 and 5.5 were expanded in `f61a947`.

### Your scope

Phase 6, Tasks 6.1 to 6.5. Five pieces:

1. `drill-progress/` on the laptop, git-ignored, append-only sessions as `git bundle` save files. A **state snapshot, not a replay** - explicitly not a diary of what the user did.
2. The `drill-state` ConfigMap and the sync watcher that keeps it current. `SessionState` in `drill/shared/src/index.ts` is already the shape it mirrors.
3. `make scenario N=03` converging a session rather than printing a card.
4. The Makefile handover, including **refusing** a second scenario while one is live. Refused by design, not queued.
5. Exit and tear down from the GUI. The status bar already has an `EXIT` affordance with nothing behind it.

Server code goes in `drill/server/src/`; the Deployment already sets `DRILL_SCENARIO=03` as a placeholder that the ConfigMap should take ownership of.

### Before you start

Two things must be settled first.

1. **Expand plan Tasks 6.1-6.5 into step-by-step tasks before writing code**, and do it in the same PR. They were left at interface level deliberately because they depend on what the GUI turned out to be, and the GUI now exists.
2. **`scripts/config.toml` needs its six keys before anything reaches AWS.** Ask the user; do not edit it. `$0` work is unaffected - `DAILY_EKS_CONFIG=scripts/config.example.toml` points ministack and the kind harness at the checked-in example.

Everything else this ticket depends on exists and is proven.

### Read in this order

1. `CLAUDE.md` - hard rules, the close-out flow, the north star SOP.
2. `COMPASS.md` - the drill loop. Phase 6 is the lifecycle around that loop.
3. `CONTEXT_STATE.md` - Lessons Learned and Blockers especially.
4. `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, Phase 6 - the authority, and the thing you must expand first.
5. The ticket file, `work-orders/WO-20260819-f5c9/WO-20260819-7840-phase-6-session-lifecycle-the-sync-watcher-and-t.md`.
6. `WO-20260819-ca7c`'s `## Notes` in `work-orders/archive/2026/` - every Phase 5 defect and decision.

### Reuse, it is proven

- `drill/shared/src/index.ts` - `SessionState` and the websocket protocol. Adding a message without handling it is a compile error. The ConfigMap mirrors `SessionState`; do not invent a second shape.
- `drill/server/src/integrations/k8s.ts` - `K8sReader`. Extend this rather than importing the Kubernetes client anywhere else. Sharp edge: `undefined` means not found, a throw means something is wrong, and the two must never merge.
- `drill/server/src/committed.ts` - the git-backed reader. Sharp edge: three answers, not two.
- `scripts/git-seed.py` - `DRILL_PATHS = ["helm"]` and the `CLUSTER_GIT_*` env overrides for sandbox use.
- `tests/drill-gui-kind.sh` - extracts manifests from the ministack plan rather than duplicating them. Copy that approach for anything new on kind.
- `scripts/bootstrap.py` - `DAILY_EKS_CONFIG` for sandbox runs.

### The verification ladder

Cheapest first. Every rung has caught something real.

1. `make -f Makefile.test test` - static suite. Caught the answer key reaching the workspace, and a `.containerignore` that would have shipped `config.toml`.
2. `make -f Makefile.test drill-test drill-typecheck` - 150 tests in Podman. Caught the three-state `readCommitted` contract under mutation.
3. `make -f Makefile.test drill-build` - caught Monaco silently returning to a CDN fetch.
4. `DAILY_EKS_CONFIG=scripts/config.example.toml make -f Makefile.test ministack` - full plan against mock AWS.
5. `bash tests/drill-gui-kind.sh` - 21 assertions on a real cluster. Caught an assertion that passed against a pod that did not exist.
6. **Look at it.** `make -f Makefile.test drill-dev`. Every one of the thirteen Phase 5 defects was found this way and none by a test. A green suite on top of an unusable product is this project's characteristic failure.

### Traps, already paid for

- Terminal renders blank while tmux is healthy: the first resize was sent before the socket opened and dropped.
- Green tmux status bar returns after a config change: `${VAR:-default}` is a tmux parse error and a parse error discards the whole file.
- An acceptance check goes green against a resource that does not exist: grepping for an absent field on an absent object returns nothing, and nothing reads as "absent by design". Assert existence first.
- `git -C <dir>` reports the parent repo: it walks up. Compare `rev-parse --show-toplevel` to the directory.
- Terminal never connects, no error: a `node-pty` built against musl in a glibc runtime. Both image stages must stay Alpine.
- `dist/` carries `*.test.js`: `tsc -b` emits whatever the tsconfig includes. `tsconfig.build.json` excludes them; `tsconfig.json` still typechecks them.
- Editor shows an empty file: Monaco applies its initial value once, at model creation.
- Argo syncs a half-served repo and succeeds: the readiness probe requires the `.seeded` marker. Succeeding against an incomplete repo is worse than failing.
- `kubectl` reports the context does not exist: this project's kubeconfig is repo-local and never `~/.kube/config`.

### Workflow

```sh
WO=.claude/skills/work-order/scripts/work-order.sh
HP=.claude/skills/hydration-prompt/scripts/hydration.sh

bash $WO start    --id WO-20260819-7840
bash $WO note     --id WO-20260819-7840 --text "what happened"
bash $WO evidence --id WO-20260819-7840 --index 1 --observed "what was seen"

# close-out, all on the work branch, then ONE pull request
#   1. CONTEXT_STATE.md
#   2. evidence every AC, retro note, then done
#   3. HYDRATION.md
bash $HP check    --project . --body-file /tmp/entry.md
bash $HP add      --project . --id WO-... --title "..." --body-file /tmp/entry.md
gh-axi pr create  --title "..." --body "..."
bash $WO submit   --id WO-20260819-7840 --pr <N>
bash $WO done     --id WO-20260819-7840
# after the merge
bash $WO close    --id WO-20260819-7840
```

Note a real conflict found at Phase 5 close-out: the flow's diagram puts `done` before the pull request, but `work-order.sh done` requires status `in-review`, which only `submit --pr <N>` sets and which needs a PR number. The reconciliation used was to open the one PR first, then `submit`, then `done` on the same branch. Raise it rather than rediscovering it.

### Conventions

Every reference to a work order carries its ID **and** its full title, joined by a dash, on every mention. A bare ID is a defect.

No em dashes; use a plain dash. Never add an agent co-author line to a commit. Never hand-edit `HYDRATION.md`, `CHANGELOG.md`, `PRACTICE_ANSWERS.html`, `work-orders/INDEX.md`, a ticket file, or `.claude/settings.local.json`.

Never run `terraform apply`, `make up`, `make down` or anything touching real AWS without explicit approval. Plans and validation are fine.

Config-driven, no defaults: every Terraform variable has no `default =`, and values live in `scripts/config.toml`. No account ids, profile names, real domains or repo-owner strings anywhere in git.

Report failing tests as failing, and say plainly when an acceptance criterion is not met rather than dressing it up.

