# CONTEXT_STATE.md

> Source of truth for AI session state. Feed this as the opening prompt of any new session.
> Do not edit manually unless re-validating against live infrastructure.

## Meta

| Field        | Value                                                                              |
| ------------ | ---------------------------------------------------------------------------------- |
| last_updated | 2026-08-20 17:02 UTC                                                               |
| updated_by   | context-compaction skill, Phase 2 close-out                                        |
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
| kind               | $0 cluster sandbox | `/usr/local/bin/kind`, podman provider. Harness `scripts/kind-sandbox.sh` ships: `make -f Makefile.test kind-up/kind-status/kind-down`     |
| Podman             | container sandbox  | 4.9.3. Runs node, helm, and the Vite preview. `npm install` never runs on the host                                                         |
| ministack          | $0 Terraform proof | `make -f Makefile.test ministack`. Mocks AWS, **does not run pods** - cannot validate cluster behaviour                                    |
| Prometheus/Grafana | observability      | kube-prometheus-stack, scenario 07                                                                                                         |
| RDS                | database           | tiny instance, scenario 11                                                                                                                 |
| gh CLI             | GitHub auth        | scopes: `gist, read:org, repo, workflow`. **`write:packages` not yet granted** (needed at Phase 5 only)                                    |
| Node / Python      | app / glue         | Host node v20.20.2 is **never used**; the drill workspace runs in `docker.io/node:22-alpine`. python3 3.12.3, stdlib only, no pip deps     |
| drill workspace    | the grader / GUI   | npm workspaces at `drill/`. `make -f Makefile.test drill-install drill-test drill-typecheck drill-build drill-clean`, all inside Podman    |
| prettier           | markdown/HTML fmt  | **Not a repo dependency.** It runs from the user's global agent hook on every Write/Edit outside `work-orders/`. See `.prettierignore`     |

## Active Tasks

| Priority | Task                                                                                                | Status  | Next Action                                                                                                                                                                          |
| -------- | --------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1        | Execute `WO-20260819-98da - Phase 3: Terraform - the in-cluster git server Argo CD reads`           | ready   | **The natural next and the epic's one real risk.** Task 3.2 Step 7 proves on kind, at $0, that Argo CD will clone in-cluster dumb-HTTP git. Five-rung fallback ladder is pre-written |
| 2        | Execute `WO-20260819-ca7c - Phase 5: the mothership GUI, its container image, and the first visual` | ready   | Also startable now that Phase 2 is done, and it is the **first visual**. Under-linked though - see the graph mismatch below, it cannot finish without Phase 4                        |
| 3        | Port scenarios 01-02 and 04-12 to the drill format                                                  | pending | After the scenario 03 vertical slice is proven end to end. One at a time                                                                                                             |

**The epic is cut.** `WO-20260819-f5c9 - Scenario drill sessions: make scenario N=03 converges an in-cluster graded drill` and its eight children, one child per plan phase, in `work-orders/`.
Phase 0 (`WO-20260819-844f`) is **done and archived**, shipped in PR #11.
Phase 1 (`WO-20260819-11df`) is **done and archived**, shipped in PR #14, merge commit `0a5ab10`.
Phase 2 (`WO-20260819-a56c`) is **done and archived**, shipped in PR #16, merge commit `c84a156`.
Run `bash .claude/skills/work-order/scripts/work-order.sh next` for what is startable and `... tree` for the shape; `work-orders/INDEX.md` is the generated router.
The epic depends on all eight children so it never appears as startable work itself.

The `work-order` skill is now **vendored into this repo** at `.claude/skills/work-order/`, a copy rather than a symlink, same as `container-sandbox`.
Its source of truth is `~/dotfiles/claude/skills/work-order` at dotfiles commit `4c6b696`, and the copy will drift from it - there is no version field to detect that automatically.

Nothing is in progress. Phases 0, 1 and 2 are the only implementation code on `main`; everything else is planning artifacts and tickets.

**What Phase 1 shipped**, because everything downstream reads it:

- `scenarios/answers/03.toml` is the single source of truth for scenario 03. Only 03 is ported; the other eleven answer blocks are still hand-written and pass through byte-for-byte.
- `scripts/answers.py` - `load()`, `load_path()`, `available()`, `AnswersError`, and the validator. Its module docstring carries the validated shape.
- `scripts/gen-answers.py` - `split()` / `render()` / `generate()`, plus `--check` and `--stdout`. `make answers-gen` regenerates; `answers-check` is now a prerequisite of `make -f Makefile.test test`.
- `tests/fixtures/answers-invalid/` - ten invalid TOML files, one per rule, plus a README carrying the full validated shape as tables. **This is a contract, not scaffolding.** The two validators are now pinned to each other by it: both reject all ten with byte-identical messages.

**What Phase 2 shipped**, because Phase 5 consumes it directly:

- `drill/` is an npm workspace tree, `@drill/shared` and `@drill/server`, installed and tested **only** in Podman. `drill/README.md` is its documentation.
- `drill/shared/src/index.ts` is the websocket protocol. `Verdict`, `SessionState`, `Attempt`, `DependencyStatus` and the `ClientMessage` / `ServerMessage` unions are defined **once, here**, and Phase 5 consumes them unchanged.
- `drill/server/src/grader/` is the grader: `aliases.ts` (shell alias expansion), `parse.ts` (`parseCommand`, `normaliseResource`, `commandVerbs`), `answers.ts` (the TypeScript half of the TOML schema), `index.ts` (the three graders plus hint dispatch). All pure functions - no cluster, no AWS, no network, no PTY.
- `GradeContext` is the grader's only door for facts a submission cannot carry: `committed` (the file as cluster git has it, for the `uncommitted` hint) and `accepted` (this session's earlier passes, for the `only-imperative` nudge). Every field optional; absent means "not known", never "false". **Phase 5 supplies these** from the workspace and from `SessionState.attempts`.
- 58 tests, all in Podman. `scenario-03.test.ts` grades the real `03.toml` end to end and asserts every authored hint key has a trigger that fires it, so a curriculum hint cannot be added and left dead.

## Decisions Made

| Date       | Decision                                                                                                 | Reason                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ---------- | -------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-08-19 | Three-stage pipeline: spec -> plan -> work-order tickets. Never skip a stage, never hand-write a ticket  | Each stage's output is the next stage's input, so a compaction or a fresh agent resumes from a file rather than from conversation history. work-order adds branch, PR and cleanup                                                                                                                                                                                                                                         |
| 2026-08-19 | **Self-contained git.** The drill never contacts github.com; Argo reads only in-cluster git              | The spec's init-container-clones-GitHub cannot work - `scripts/argo-repo.py` supplies the token _after_ apply, so a private repo fails the first apply. Seeding from a local `git bundle` removes the PAT, removes the egress dependency, and reuses one primitive in both directions                                                                                                                                     |
| 2026-08-19 | Self-contained is **not** simulated                                                                      | The in-cluster server runs genuine git; Argo does a genuine clone and sync. Only the remote's location changes. A faked GitOps step would teach a mock of the skill                                                                                                                                                                                                                                                       |
| 2026-08-19 | The standalone Argo spike was **cut**                                                                    | It built the same manifest Task 3.2 builds, proved it, deleted it, then Task 3.2 rebuilt it. A negative result never killed the design - it only meant swapping the container                                                                                                                                                                                                                                             |
| 2026-08-19 | Argo-clones-cluster-git is validated as Task 3.2 Step 7 on kind, with a ranked five-rung fallback ladder | `ministack` never runs a pod, so without a kind step the discovery would land in Phase 7 on real EKS. Rung 5 (helm-on-submit, no Argo) is the floor and the only rung that stops teaching GitOps                                                                                                                                                                                                                          |
| 2026-08-19 | `drill_allowed_cidrs = ["auto"]`, resolved to the current public /32 at plan time                        | Residential addresses are DHCP. A pinned literal goes stale on a lease change and locks the user out with no error - the browser just hangs                                                                                                                                                                                                                                                                               |
| 2026-08-19 | Application auth **deferred**; source IP is the only control                                             | Verified the target is a directly-assigned residential IPv4, not carrier-grade NAT, so the /32 identifies one machine. Triggers to revisit are recorded in plan Task 4.1                                                                                                                                                                                                                                                  |
| 2026-08-19 | GUI image is a **public** GHCR package under the user's own account                                      | The repo is public and `PRACTICE_ANSWERS.html` is already committed to it, so the image holds nothing new. Public removes an `imagePullSecret` and one more credential in the cluster                                                                                                                                                                                                                                     |
| 2026-08-19 | **Never create a personal access token.** Extend the grant `gh` already holds                            | A PAT is a second credential with its own expiry that must be stored, and every candidate here is bad: `config.toml` is serialised into Terraform state, a shell export lands in history, a dotfile is one `git add -A` from being committed                                                                                                                                                                              |
| 2026-08-19 | Grader is TypeScript in the cluster; Python stays laptop-side CLI glue                                   | Grading runs per submission inside the Node process. Python would mean shipping a runtime in the image. `bootstrap.py` stays Python so `make up` needs only `python3`                                                                                                                                                                                                                                                     |
| 2026-08-20 | The epic depends on all eight of its children                                                            | Without those edges the epic itself appears in `work-order.sh next` once approved, reading as startable work. Its only real job is to close after its children do                                                                                                                                                                                                                                                         |
| 2026-08-20 | `kind create/delete cluster` is always called with `--kubeconfig`                                        | Without it kind merges the new context into the user's `~/.kube/config`, which this repo must never write. Verified as a live regression guard in `tests/kind-sandbox.sh`, which samples that file's mtime and fails if it moves                                                                                                                                                                                          |
| 2026-08-20 | The `work-order` skill is vendored into the repo, copied not symlinked                                   | Both the epic and this file's hydration prompt reference `.claude/skills/work-order/scripts/work-order.sh`, and that path resolved to nothing for any clone. A symlink would point outside the repo and break the same way                                                                                                                                                                                                |
| 2026-08-20 | `PRACTICE_ANSWERS.html` is in `.prettierignore`; the generator owns its formatting                       | The generated block is not prettier-stable - prettier re-wraps every `<h3>` and `<p>` in it while leaving the eleven hand-written blocks alone. Without the ignore, one formatter pass makes `gen-answers.py --check`, and so `make -f Makefile.test test`, fail until somebody regenerates                                                                                                                               |
| 2026-08-20 | **`CONTEXT_STATE.md` is updated on the work branch and ships inside that phase's PR**                    | The flow is CONTEXT_STATE -> PR -> cleanup -> hydration prompt. A separate PR whose only content is the state file is ceremony: it doubles the review surface for a phase and leaves `main` briefly describing a world that no longer exists. `work-order.sh close` still opens its own PR afterwards, and that is fine - it is generated bookkeeping (merge SHA, archive move, INDEX regeneration), not authored content |
| 2026-08-20 | The drill workspace runs on `node:22-alpine`, not the plan's `node:20-alpine`                            | The tests are TypeScript executed with no build step, `node --test --experimental-strip-types`. Type stripping landed in Node 22.6 and test-runner globs in Node 21, so on Node 20 not one test in Phase 2 executes. `tsc` still emits `dist/` for the Phase 5 image                                                                                                                                                      |
| 2026-08-20 | `drill/node_modules` is a **named Podman volume**, not a directory in the bind mount                     | AC-H5 requires no `node_modules` on the host. A plain bind mount satisfies "npm ran in a container" but still writes the whole tree to disk - verified, six package directories appeared. With the volume the host holds an empty mountpoint. `make -f Makefile.test drill-clean` drops it                                                                                                                                |
| 2026-08-20 | An accept rule's `verb` is **tool-qualified** for non-kubectl commands                                   | `AcceptRule` has no `tool` key, so `git-revert` and `curl-loop` are the only way an answers file can say which tool it means. `commandVerbs()` returns every label a command answers to, kubectl being the unqualified default. Without this, `03.toml`'s own tasks 4 and 5 were ungradeable                                                                                                                              |
| 2026-08-20 | A hint may fire on a **passing** verdict                                                                 | `only-imperative` is the case: `kubectl rollout undo` is the correct rollback, and the lesson is that Argo CD is about to put the bad version back. Marking it wrong would teach the opposite of the truth, so `passed` stays `true` and the nudge rides in `hint`. Documented on `Verdict.hint` because Phase 5 renders it                                                                                               |
| 2026-08-20 | Scenario 03's answer block renders as plain escaped text; the inline `<code>` spans were not preserved   | TOML prose is plain text and must be HTML-escaped. Keeping `<code>` would mean inventing a markup convention in the TOML that the TypeScript grader then has to strip. Deferred as a design decision, not an oversight - revisit if a ported card actually needs it                                                                                                                                                       |

## Lessons Learned

- 2026-08-19: Checking for carrier-grade NAT by testing whether the **externally visible** address falls in `100.64.0.0/10` does not work; that range lives on the router's WAN interface, and an external service returns the carrier's normal-looking public IP either way. Use the reverse-DNS host label instead - if it encodes the address itself, the address is directly assigned.
- 2026-08-19: Probing tool availability with `for c in ...; do $c version --short; done` produced mangled output and was misread as "kind is not installed", nearly forcing a $0 test onto real AWS. Use `command -v` to check for a binary; never infer absence from a failed version flag.
- 2026-08-19: An init container cloning GitHub cannot seed cluster git, because the token mechanism (`scripts/argo-repo.py`) runs _after_ apply. Do not retry credential-at-init-time designs in this repo.
- 2026-08-19: Widening a container build context without a deny-by-default `.containerignore` would have baked `scripts/config.toml` into a **public** image. Use `*` plus explicit `!` allows, never an exclude list - an exclude list leaks the next secret file somebody adds.
- 2026-08-19: `gh pr merge` returned repeated HTTP 502s and then `GraphQL: Merge already in progress` - a stale server-side merge lock from the failed request. It clears on its own; retry rather than forcing, and never assume a merge landed without checking `gh pr view --json state`.
- 2026-08-19: `gh auth refresh` is interactive and blocks on a browser one-time code. An agent cannot run it. Print the command for the user.
- 2026-08-20: An empty `KUBECONFIG` is not "no kubeconfig" - `kubectl` falls back to `~/.kube/config`. A test that does `KUBECONFIG="$KC" kubectl ...` where `$KC` came from a command that failed will silently read the user's real config and hang on whatever dead endpoint it holds. Guard on a non-empty value and pass `--request-timeout`.
- 2026-08-20: A plan written by an earlier session is not pre-verified. Both defects in plan Task 0.1 were invisible on reading and only appeared on execution: the 120s hang, and `~/.kube/config`'s mtime moving. Run the mandatory failing test rather than reasoning about what it would print.
- 2026-08-20: Plan Task 1.2's own Step 1 test contradicted its own Step 6. It asserted `changed == ["03"]`, but once Step 6 writes the generated file, regenerating 03 is a no-op and `changed` is `[]`. A test that asserts "the generator changed something" goes red exactly when the repo is in its correct, up-to-date state. Assert the invariant that must always hold - here, that no unrelated block changed - never the transient one.
- 2026-08-20: Plan Task 1.2's Step 6 verification curled `localhost:8000`, but `scripts/serve-answers.sh` picks a **random** port in 8000-8998 unless `PORT` is set, and serves at `/PRACTICE_ANSWERS.html`, not `/`. As written it would have hit a directory listing and quietly reported the wrong number. Pin `PORT` and request the real file path.
- 2026-08-20: The user's global agent hook runs `npx prettier --write` on every Write/Edit outside `work-orders/`. Any generated file this repo commits must therefore either be prettier-stable or be listed in `.prettierignore`, or a later agent touching it turns the static suite permanently red. Write generated files from a script via Bash, never with the Write tool.
- 2026-08-20: `npm test` proves nothing about types. Node strips TypeScript rather than checking it, so plan Task 2.3's `parse.ts` passed every test while failing `tsc` with three `TS2412`s. Run `drill-typecheck` as well as `drill-test`, or a type error ships green.
- 2026-08-20: Unit tests written alongside a feature cannot catch a curriculum that names something the code will never produce. `03.toml` accepted `verb = "curl-loop"` and `verb = "git-revert"`, which the parser never emits, so two of six tasks were unpassable and their hints unreachable - and every unit test passed. The test that found it grades the answers file's own model answers with the real loader, parser and grader. Do that for every ported scenario.
- 2026-08-20: A grader hint that needs context the submission cannot carry is not a "later" problem, it is dead curriculum. `uncommitted` and `only-imperative` were both authored in `03.toml` and neither could ever fire. The fix is an explicit optional context argument where absent means "not known" rather than "false", so no caller is punished for what it could not look up.
- 2026-08-20: `tsc --noEmit` in a workspace that references another via `types: ./dist/...` fails on a fresh clone, because `dist/` is git-ignored and nothing has built it. Build the referenced workspace first in the `typecheck` script; verify by deleting every `dist/` and `tsbuildinfo` before running it.

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
| The ticket graph and the plan's interfaces disagree, twice      | Phase 4 and Phase 5      | Found 2026-08-20 by reading both. Neither is fixed; decide when the ticket is picked up, do not discover it mid-work                |

The two graph mismatches, stated plainly so nobody rediscovers them the hard way:

- **Phase 5 is under-linked.** `WO-20260819-ca7c` declares `depends_on: [844f, a56c]`, but plan Task 5.5 consumes `drill_alb_security_group_id` and `drill_ingress_group_name` from Task 4.1 and `cluster_git_url` from Task 3.2.
  This is probably deliberate, because Tasks 5.1-5.3 need nothing from Phase 4 and the ticket stops at 5.3 for the user's review anyway.
  The consequence is that Phase 5 can **start** without Phase 4 and cannot **finish** without it, and `work-order.sh next` will not warn about that.
- **Phase 4's declared dependency is not justified by the interfaces.** `WO-20260819-1fea` declares `depends_on: [98da]`, yet Tasks 4.1 and 4.2 consume nothing from Phase 3 - only `vpc_id`, `enable_alb_controller`, and their own two new config values.
  The edge is most likely about sequencing the Terraform threading through `modules/stack` rather than a real data handoff.
  If that is all it is, Phase 4 could run in parallel with Phase 3 rather than behind it.
## Hydration Prompt

Copy-paste this at the start of a new session:

```
Read CONTEXT_STATE.md in this project root before doing anything else.
Use the Infrastructure and Toolchain tables as ground truth.

Work WO-20260819-98da - Phase 3: Terraform - the in-cluster git server Argo CD
reads. It is `ready`, it is startable now, and it is the epic's one real risk.
Read the ticket first:
work-orders/WO-20260819-f5c9/WO-20260819-98da-phase-3-terraform-the-in-cluster-git-server-argo.md

Then read Tasks 3.1 through 3.3 of
docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md:
  Task 3.1 config values and variable threading  - plan lines 2669-2938
  Task 3.2 the cluster git server                - plan lines 2939-3285
  Task 3.3 seed cluster git, repoint the Argo Application - plan lines 3286-3601
The plan is the authority for every step; the ticket is the contract. Read the
plan's ## Global Constraints section too - it binds this ticket in full and is
deliberately not restated in it. Read "The self-contained git rule" (plan lines
32-66) as well: it is the standing rule this whole phase implements, it
supersedes the spec's Q1 seeding sentence, and it is what deletes rung 5 from
Task 3.2's fallback ladder rather than merely deprioritising it.

Start with:
bash .claude/skills/work-order/scripts/work-order.sh start --id WO-20260819-98da
That creates the branch and stamps it onto the ticket. Do not create the branch
by hand. The work-order skill is vendored into this repo, so that path resolves.

**The close-out flow, which changed after Phase 2 and is not optional:**
CONTEXT_STATE.md -> PR -> cleanup -> hydration prompt. Update CONTEXT_STATE.md
on the work branch as part of the work, so it ships inside THIS phase's PR.
Never open a separate PR whose only content is the state file. After the merge,
`work-order.sh close --id ...` opens its own PR for the merge SHA, the archive
move and the INDEX regeneration - that one is generated bookkeeping and is
expected. Leave the next hydration prompt naming the next work order by BOTH
its id and its full title.

This ticket is three tasks and it is strict TDD throughout, same as Phases 0-2:
write the failing test, RUN it, say out loud what it failed with, then
implement. A test that was never seen failing proves nothing. Every phase so
far has shipped fixes to defects in its own plan text - two in Phase 0, three
in Phase 1, five in Phase 2 - and every one of them was invisible on reading.

What this phase is, in one line: a permanent in-cluster git server in namespace
`git` becomes the only repo Argo CD ever reads, seeded by streaming a
`git bundle` in from the local repo over `kubectl exec`. The drill never
contacts github.com.

Ground rules that bite on this ticket specifically:
- **Terraform variables have NO defaults, ever.** Thread each new value through
scripts/config.example.toml -> terraform/envs/dev/variables.tf -> envs/dev/main.tf
-> modules/stack/variables.tf -> modules/stack/main.tf -> the target module.
Run Terraform only through scripts/bootstrap.py / make, never bare. That is
AC-H5 and it is checkable by grep.
- **Never run terraform apply, make up/apply/down, or otherwise touch real AWS
without explicit user approval.** Plans and validation are fine. This phase is
$0: ministack for the plan, kind for the cluster behaviour.
- Task 3.2 Step 7 is the acceptance test that de-risks the whole GitOps half:
on kind, does Argo CD clone from in-cluster dumb-HTTP git? A five-rung fallback
ladder is already written into the task. **If you land below rung 2, report to
the user before Task 3.3 repoints the Argo Application**, because rungs 3-5
change cluster_git_url. That is AC-H3.
- The readiness gate is the `.seeded` marker: no endpoints until the bundle
lands, so Argo retries cleanly instead of syncing a half-served repo. That is
AC-H2 and it is observable with `kubectl get endpoints -n git`.
- scripts/argo-repo.py is KEPT, not deleted. It exists for
scenarios/09-gitops-argocd.md, which teaches manual PAT-and-UI repo
registration against real GitHub. The drill simply never calls it.
- Do not port scenarios other than 03. Do not pre-solve scenarios in committed
defaults - helm/practice-app/values.yaml must stay at 1.27-alpine, and there is
now a test in drill/ that fails if it moves.
- PRACTICE_ANSWERS.html is generated and is in .prettierignore. Never hand-edit
it and never write it with the Write tool; run `make answers-gen`.
- No PII in git. No AWS account ids, profile names, real domains, CIDRs or
repo-owner strings outside scripts/config.toml and generated files.
- Plain dashes, never em dashes. One full sentence per line in long Markdown.
- Never hand-edit a ticket file. work-order.sh owns that format, and the
markdown formatter hook will corrupt the JSON frontmatter if you do. Progress
goes in with `work-order.sh note --id ... --text "..."`.

When the work is done: evidence each acceptance criterion with
`work-order.sh evidence --id WO-20260819-98da --index N --observed "..."`.
`done` refuses while any is unobserved, and that refusal is the gate working -
observe the thing, never tick it. There are FIVE criteria on this ticket.

Definition of done, from CLAUDE.md: `make -f Makefile.test test` passes, a
ministack plan was attempted and its result reported, and
`make -f Makefile.test drill-install drill-test` still passes since Phase 2
wired the drill workspace into the repo.

Do not suggest IP addresses, tool versions, or architecture patterns that
contradict CONTEXT_STATE.md without flagging the conflict first.
```
