# Scenario drill sessions - design

Date: 2026-08-19
Status: all open questions (Q1-Q7) resolved. Ready for an implementation plan.
Slice: scenario 03 only (`03-rolling-update-rollback`).

## Problem

Today `make scenario N=03` prints a Markdown card to the terminal and nothing else.
The drill is honour-system: nothing captures what you did, nothing grades an individual task, and the only feedback is `make check N=03` at the end, which grades final cluster state rather than the reasoning that produced it.

Three gaps follow.
Answers are never captured, so there is no record of how you solved a card.
Nothing guards against starting a second scenario while the first is half-finished, even though scenarios mutate the same app.
Cleanup is all-or-nothing: the only way to undo a drill is `make down`, which destroys the whole cluster.

## Goal

Turn a scenario into a **drill session**: a declarative, idempotent thing with an apply and a destroy, driven from an in-cluster GUI that is the whole working environment, grades task by task, and can restore you to where you left off after the cluster is torn down.

## Scope

Scenario 03 only, built end to end.
It is chosen because it exercises every hard part: a rollout to watch, a chart edit to make, and a GitOps trap in task 5 that only lands if Argo is genuinely fighting you.

The other eleven are explicitly out of scope and get ported one at a time.
Each card differs and may need schema changes, so the answers format must be extensible rather than frozen now.
Incremental migration is a hard requirement.

## Vocabulary

Four different things in this design are "the repo", so these terms are used precisely throughout.

| Term            | What it is                                        | Lives                       | Holds                                            |
| --------------- | ------------------------------------------------- | --------------------------- | ------------------------------------------------ |
| **local repo**  | your clone on your laptop                         | laptop                      | the project, plus `drill-progress/` (gitignored) |
| **workspace**   | the checked-out working tree you edit in the GUI  | EBS volume in the drill pod | the chart you are drilling on                    |
| **cluster git** | the git server the workspace is published through | namespace `git`             | what Argo CD actually reads                      |
| **GitHub**      | the shared remote                                 | github.com                  | `origin` for both                                |

Three distinct actions, deliberately kept separate because the gap between them is what people get wrong about GitOps:

**Autosave writes to the workspace.** Debounced, VS Code style. Argo sees nothing. You cannot lose work.
**Commit publishes to cluster git.** Now Argo sees it and syncs. This is the moment things happen.
**Push sends to GitHub.** Separate and deliberate, needed only for scenarios 09 and 12.

## Architecture

```
your browser ──▶ drill GUI (in-cluster)
                     │
your laptop          │  terminal · editor · answers · help
  make up ───────────┼──────────────────────────────────┐
  make down          │                                  │
  drill-progress/    ▼                                  ▼
                ns practice-drill                  ns git
                  drill-gui pod                      cluster git pod
                  PVC (workspace, PTY logs)          (seeded at make up)
                  ConfigMap (live state)                  │
                  SA drill -> cluster-admin               │ one Application
                                                          ▼
                                                     Argo CD ──▶ ns practice-app
```

You do the real work **in the GUI's terminal**, which is a real PTY in a real pod with `kubectl`, `git` and `helm` on PATH.
Because the terminal lives in the GUI, the grader **observes** what you actually run.
There is no submission form and no way to accidentally misreport what you did.

### Startup dependency chain

Each link genuinely needs the previous one:

```
EKS cluster  ──▶  cluster git  ──▶  Argo CD  ──▶  practice-app
                        (GUI starts independently and waits)
```

The GUI comes up whenever it comes up and reports what it is still waiting on rather than hanging or failing.
`cluster git: ready. Argo CD: starting. practice-app: waiting on Argo.`
That status view doubles as a live picture of the dependency chain, which is itself worth learning.

### Makefile handover

The Makefile is **demoted, never archived**.
If the GUI is the only way to drive the cluster and the GUI breaks, there is no way in.
Keeping the Makefile working, just locked while the GUI holds the wheel, preserves the recovery path.

Some targets can never move in-cluster, because you cannot create a cluster from a pod that does not exist yet, nor destroy the floor you are standing on.

| Stays on the laptop permanently | Moves into the GUI                                 |
| ------------------------------- | -------------------------------------------------- |
| `up` / `plan` / `apply`         | `app-deploy`, `argo-sync`, `argo-repo`             |
| `down`                          | `app-status`, `argo-password`                      |
| `kubeconfig`, `config`          | `argo-ui`, `grafana-ui` (Service calls in-cluster) |
| `make -f Makefile.test`         | `scenario`, `check`, `serve-answers`               |

The handover has four states:

1. `make up` runs. Makefile is fully in charge.
2. GUI comes up. Handover: it now owns the app, Argo, and scenarios.
3. Cluster-side targets refuse with a pointer to the GUI. Bootstrap and teardown targets keep working.
4. `make down` runs. Cluster is gone, Makefile is fully in charge again.

This replaces guarding each dangerous target individually.
There is one steering wheel at a time by construction, rather than by remembering to add a guard.

The GUI shows the equivalent command for every action it takes, so the Makefile's knowledge carries forward instead of being buried.

## Resolved decisions

### Q1 - Argo CD reads exactly one source, forever

**Decision: a single in-cluster git repo is the only thing Argo ever reads.**

Rejected: swapping two Applications in and out per drill, retiring the GitHub Application, and giving drills a separate namespace.
All three manage a conflict that does not need to exist.

Cluster git is created at `make up` as permanent platform infrastructure, in its own `git` namespace, via the Terraform `platform` module with a config toggle.

**Seeding: amended 2026-08-19.**
This paragraph originally said the repo is seeded by an init container that clones from GitHub using the token mechanism `scripts/argo-repo.py` already uses.
That is superseded by a standing rule: **the drill never contacts github.com, and everything Argo CD reads comes from the local repo by way of the cluster.**

Two reasons the original could not stand.
It cannot work: `scripts/argo-repo.py` is a script the user runs _after_ apply, so Terraform has no token to give an init container, and a private repo would fail the first apply.
It is also more mechanism than the problem needs: the files are already on the laptop, so reaching out to a remote to fetch a copy of them is a round trip with a credential attached for no gain.

What replaces it: the init container runs `git init --bare` only, and `make git-seed` streams `git bundle create - --all` from the local repo into the pod over `kubectl exec`.
That one primitive is used inward to seed and outward to save drill progress, so there is no second mechanism.
It removes the PAT from the cluster, removes the dependency on GitHub being reachable from a private subnet, and seeds exactly what is on disk rather than whatever was last pushed.

**Self-contained is not simulated.** The in-cluster server runs genuine git; Argo does a genuine clone and a genuine sync.
Only the location of the remote changes, from `github.com` to `git-server.git.svc.cluster.local`.
If the GitOps step were faked, the scenario would be teaching a simulation of the skill instead of the skill.

The ordering guarantee the init container provided is preserved by the readiness probe described below, which is strictly stronger: an init container only orders the _clone_ against the server starting, while the probe orders Argo's first read against the repo actually being complete.

See "The self-contained git rule" in `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md` for what the rule forbids and, equally, what it does not.

There is therefore **one Argo Application, permanently**, pointing at cluster git.
Nothing to swap, no second Application, no conflict to guard.

GitHub is not demoted, it becomes the upstream.
The workspace is a normal clone with GitHub as `origin`, so scenarios 09 and 12 keep a real push and pull loop against a real remote.

A readiness probe on the git pod matters more than it appears.
The danger is not that Argo errors when the repo is not ready; it is that Argo **succeeds too early** against a half-served repo and syncs a broken state, which looks like it worked.
The probe must only pass once refs are genuinely complete, so the Service has no endpoints until then and Argo retries cleanly.

### Q2 - progress is a save file, not a diary

Two different things were conflated and have opposite requirements.

|                 | curriculum progress              | live session state  |
| --------------- | -------------------------------- | ------------------- |
| lifetime        | forever, across clusters         | one drill           |
| write frequency | once per scenario                | every submission    |
| must survive    | cluster teardown, laptop rebuild | pod restart         |
| losing it means | your whole record is gone        | you lose your place |

**Curriculum progress lives in `drill-progress/` in the local repo, gitignored.**
It is personal, so nobody forking the project inherits it, and it survives because it is on your laptop rather than because it is committed.
The README must explain what the directory is and why it is ignored.

**Live session state lives in a ConfigMap** in the drill namespace.
It survives pod restarts, which is the failure that matters, and dies with the cluster, which is correct because the drill dies with the cluster anyway.

**Resume works by converging to a declared state, not by replaying actions.**
Git is already the save file: scenario 03's state change _is_ "the chart says 1.28-alpine with this history".
`git bundle` puts an entire repo with its refs and objects into one file that can be cloned back out.

```
drill-progress/
  03/
    state.json          # scenario, task pointer, timestamps, attempt log
    workspace.bundle    # the whole chart repo + history, one file
  curriculum.json       # 01 done, 02 done, 03 in progress
```

Restoring means cloning the bundle into the workspace, writing the ConfigMap with the task pointer, and letting Argo converge the cluster to match.
Replaying recorded actions was rejected: one non-deterministic step and the resume is silently wrong, whereas converging to a declared state cannot drift.

Rejected alternatives: a `DrillProgress` CRD (still dies with the cluster, so it needs the same export step anyway, and adds a CRD to version), etcd snapshots (unavailable, EKS manages the control plane), Velero (wants S3, restores cluster objects rather than learning state), pushing drill branches to GitHub (puts practice history in the remote), and a database (needs a service; this should be a file you can copy, diff and delete).

Passing a task requires reaching a _verified_ end state, so "tasks 1, 2, 3 passed" is not a note about the past.
It is a declaration of a state the cluster provably reached, which is what makes rebuilding deterministic rather than hopeful.
The pass criteria are the state declaration.

### Q2a - the sync watcher

**Decision: a watcher, started as part of the session apply.**

The trigger is the Kubernetes watch API (`kubectl get cm drill-state -n practice-drill --watch`), not polling.
The API server pushes changes, so there is no interval to tune and no lag on a task pass.
It is also the primitive every controller is built on, which keeps the tool that teaches Kubernetes built out of Kubernetes.

Getting the repo out avoids a persistent port-forward.
The workspace lives on the PVC inside the pod, so the laptop cannot bundle a directory it cannot see, and holding a port-forward open for a whole drill means reconnect logic.
Instead the bundle is created in the pod and streamed out in one shot:

```bash
kubectl exec -n git deploy/git-server -- \
  git -C /srv/repo bundle create - --all  >  drill-progress/03/workspace.bundle
```

`git bundle create -` writes to stdout and `kubectl exec` streams it back.
The repo is a Helm chart, so a full bundle each time is a few hundred KB and not worth making incremental.

All writes are atomic: write a temp file, then rename.
A crash mid-sync leaves the previous good save rather than a half-written one, because losing one task is annoying and a corrupt save file is losing everything.

The watcher's lifecycle falls out of the declarative apply rather than being special-cased.
`make scenario N=03` starts it and writes a PID file; re-running is a no-op if the PID is live; a dead watcher is restarted by converge exactly like a dead pod; it syncs immediately on start to catch up on anything missed while it was down; and `scenario-clean` and `down` stop it.

**Caveat.** The bundle captures everything that lives in git and nothing that does not.
Scenario 03 is entirely chart-driven, so the bundle is complete for the slice.
A scenario that creates state imperatively (scenario 02's HPA via `kubectl autoscale`, say) lives only in the cluster and would need a declared `resume` block per task in the answers TOML.
That is the per-scenario variation this design already expects, and it does not affect the 03 slice.

**Nothing in `drill-progress/` reads like a report card.**
The log records attempts, not judgments: what you typed, what the grader said, what the canonical answer was.
"Passed" is only a bookmark for where to resume.

**Deliberately not persisted, with reasons:**

Terminal scrollback across a _pod restart_ is persisted by teeing PTY output to the volume and replaying the tail on reconnect.
Terminal _sessions_ across browser disconnects are held by tmux, so reattaching lands you exactly where you were.
Uncommitted file edits are autosaved to the workspace, but making uncommitted work survive a teardown would teach the wrong lesson: what makes work durable is committing it.

**Storage cost.** EBS bills per GB of _provisioned_ storage per hour for as long as the volume exists, regardless of attachment or use, with gp3 including 3,000 IOPS and 125 MB/s at no extra charge.
At roughly $0.08/GB-month in us-east-2, 15 GB is about $1.20 a month, or about 1.6 cents for 10 hours.
Size is therefore irrelevant here; the real risk is **orphaning**.
If `make down` destroys the cluster while a PVC still exists, the EBS volume can outlive Terraform and bill indefinitely with nothing pointing at what created it.
Teardown must delete the PVC before the cluster goes.

### Q3 - an internet-facing ALB, with three conditions

**Decision: an ALB, chosen for growth rather than for today.**

Port-forward was rejected because it caps what the platform can become.
An ALB gives every future thing a place to be exposed, which matters more than the roughly $1 per 30-hour cycle it costs.

**Cost.** At us-east-2 list prices: $0.0225/hr base, plus $0.008/LCU-hr, plus roughly $0.005/hr per public IPv4 across two AZs.
For a 30-hour cycle that is about $1.00, of which the base rate is $0.675.
LCU billing charges the highest of four dimensions rather than their sum (25 new connections/sec, 3,000 active connections/min, 1 GB/hr processed, 1,000 rule evaluations/sec per LCU), and a practice app never approaches one LCU on any axis.
For context, the NAT gateway costs more than the ALB will, and the EKS control plane is roughly half the total bill.

**Condition 1: one ALB, shared.**
By default every Ingress provisions its own ALB, so Argo UI, Grafana and the drill GUI would be three of them.
`alb.ingress.kubernetes.io/group.name` makes Ingresses share a single ALB with host and path routing.
This is what keeps "it'll grow" affordable: cost stays flat as things are added.

**Condition 2: a pre-destroy hook, or it orphans.**
The AWS Load Balancer Controller creates the ALB, so it is not a Terraform resource and Terraform cannot sequence its deletion.
`make down` must delete the Ingresses, poll until the ALB is genuinely gone, and only then run `terraform destroy`.
Getting this backwards leaves a load balancer billing about $16/month that nothing in the account points at, plus security groups that make VPC deletion hang.
Same failure shape as the orphaned PVC above.

**Condition 3: source-IP restricted security group.**
Without this the drill GUI is an unauthenticated web terminal running as `cluster-admin`, reachable by anyone who finds the hostname, over plain HTTP.
The allowed CIDR lives in `scripts/config.toml`, which is already gitignored, alongside the existing `public_access_cidrs` value it mirrors.

ALB OIDC auth was rejected for now, not on merit but on prerequisites: it needs an HTTPS listener, which needs an ACM certificate, which needs a Route53 domain that is not currently configured (`enable_external_dns = false`, `dns_zone_name = ""`).
It is the documented growth path the moment more than one person uses this, and would make a good scenario in itself.

Accepted friction: a changed IP (ISP renewal, coffee shop, tether, VPN) locks you out until the config is updated and re-applied.

**Scenario 04 reframes rather than dies.**
The platform ALB is the ops plane; scenario 04 is about exposing a workload.
The card becomes "join the existing ALB with a new Ingress, then stand up an NLB separately to feel the difference", which is closer to what you would actually do at work than provisioning a load balancer from scratch.

### Q4 - integrations are contextual, and mostly not iframes

**Decision: Argo CD, Grafana and Prometheus surface when the active scenario calls for them and they are actually running.**

Delivered at three levels, and the top one is preferred.

**Native widgets from their APIs.**
Argo CD has a REST API and the Prometheus query API is plain HTTP and JSON.
Sync status, health and metric charts get built as components of this app, so they look like this app, load instantly, and need no auth dance or framing workaround.
For scenario 03 this is the whole requirement: one call to `/api/v1/applications/practice-app` shows Argo stomping a `rollout undo` in a panel we designed.

**Grafana `d-solo` panel embeds** when a scenario wants one specific chart rather than the whole product.

**Full-app access through a reverse proxy** for scenarios where the lesson is the app itself, such as 07.

The reverse proxy is the "central wrapper" and it lives in the Fastify backend.
Path-based routing on **one** host (`/`, `/argo/*`, `/grafana/*`) makes everything same-origin, which is the structural fix.
Subdomain-per-app cannot be wrapped: different origins mean `X-Frame-Options: sameorigin` blocks framing and cookies do not cross.

The proxy does three things the browser cannot.
It injects backend-held API tokens, so the browser never sees a login screen and "logged in once" works today without OIDC or a domain.
It rewrites `X-Frame-Options` and CSP `frame-ancestors` on the way through.
It gives one entry point through the ALB that is already paid for.

An iframe of Grafana inside this app looks like an iframe of Grafana; native widgets look like this app, which matters given the quality bar.

Gotcha to verify at build time: serving those apps under a subpath needs Grafana's `root_url` and `serve_from_sub_path`, and Argo CD's server rootpath parameter.
Both are settable through Helm values already under our control, and both are fiddly enough to verify against current chart versions rather than trusting memory.
The proxy is designed now and built when scenario 07 is ported, so no subpath surgery happens for a scenario that does not need it.

### Q5 - one long-lived pod, and sessions are append-only

**Decision: a single long-lived `drill-gui` pod.**

It is the mothership and the only surface the user interacts from.
`make scenario N=NN` switches what it is doing rather than building a new pod; scenarios are state inside it.

**Sessions are append-only.**
Redoing a scenario creates a _new_ session tracked in a results table with running totals.
Nothing is overwritten and nothing is deleted.
This changes the Q2 schema from one save file per scenario to a history:

```
drill-progress/
  curriculum.json                    # running totals across all scenarios
  03/
    sessions/
      2026-08-19T14-03-11/
        state.json
        workspace.bundle
      2026-08-21T09-12-40/
    index.json                       # results table + current-session pointer
```

Timestamps carry no colons and the current-session pointer is JSON rather than a symlink, because Windows 11 is a supported target.

### Q6 - TypeScript both ends

| Layer      | Choice                        | Why                                                                                                                                                   |
| ---------- | ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language   | TypeScript, both ends         | The websocket carries a real protocol: terminal bytes, resize, grader verdicts, file saves, sync status. Shared types make a mismatch a compile error |
| Backend    | Node + Fastify                | TypeScript-native, first-class websocket plugin, fast, not bloated like Nest                                                                          |
| PTY        | `node-pty`                    | What VS Code itself uses                                                                                                                              |
| Kubernetes | `@kubernetes/client-node`     | Official, and supports the watch the sync watcher depends on                                                                                          |
| Proxy      | `@fastify/http-proxy`         | The integration wrapper above                                                                                                                         |
| Frontend   | React + Vite                  | Multi-panel IDE-like app with heavy state; mature resizable-panel libraries, and xterm and Monaco integrations are all React-first                    |
| Terminal   | `xterm.js` + fit/webgl addons | Effectively the only serious option                                                                                                                   |
| Editor     | Monaco                        | Monaco _is_ VS Code's editor, so "fake VS Code" is literal rather than an imitation. ~5MB is irrelevant when shipping an image                        |

Hand-rolling RFC6455 was rejected.
It was only ever justified by the stdlib-only constraint, which died when we chose to build an image.

Both terminal surfaces, the one integrated into the code page and the dedicated terminal page, run `tmux attach` against the same session.
Multiplexing, shared views and reattach-after-disconnect come free rather than being built.

### Q7 - refusal behaviour and the GUI port

Most of this question was absorbed by the Makefile handover above, which replaced per-target guards with one steering wheel at a time.
Two things remained.

**Locked targets refuse and explain, with a `FORCE=1` escape hatch.**
A refusal names the consequence rather than just declining: "this would re-apply the Argo Application and fight the drill", not only "the GUI owns this now".
That costs one line per target and fits a project whose whole job is teaching why things break.

`FORCE=1 make app-deploy` overrides the lock.
This exists for the same reason the Makefile was demoted rather than archived: if the GUI wedges and the handover flag goes stale, the only alternative is destroying a cluster you are mid-drill on.
Removing the escape hatch would remove the recovery path.

**The GUI listens on 8090.**
`make argo-ui` already uses 8080 and `make grafana-ui` uses 3000.
Going through the ALB mostly removes the collision, but the container port still needs a number that does not trip anyone up during local development, and 8090 leaves 8081 and 8082 free for proxied apps if they ever need separate addressing in dev.

## Build-time items not to forget

`drill-progress/` must be added to `.gitignore` before it is ever created, or practice history lands in a commit.
Three new config values are needed in `config.toml` and `config.example.toml`: the ingress group name, the allowed CIDR for the ALB security group, and a toggle for cluster git.
The drill GUI listens on 8090, clear of `make argo-ui` (8080) and `make grafana-ui` (3000).

## Other requirements captured

Exiting and tearing everything down must be possible **from the GUI**, at pass, fail, or whenever the user wants.
An off-menu terminal equivalent is tracked as an easter egg in `BACKLOG.md`.

The answers file per scenario is TOML, because the repo is stdlib-only Python and `tomllib` is already used by `scripts/bootstrap.py`.
It is the single source of truth for tasks, graders, accepted answers, hints and prose answers, and it generates `PRACTICE_ANSWERS.html` so the key cannot drift.
Generation must handle a mixed state, rendering 03 from TOML while passing the other eleven hand-written blocks through untouched, verified by a byte-identical test.

Commands are graded semantically rather than by regex: alias-expanded, then parsed into verb, resource, namespace, name and flags.
The alias table covers `k`, `kg`, `kgp`, `kgn`, `kgs`, `kd`, `kl`, `kaf`, `kp`.
Wrong answers produce hints keyed to the misconception rather than a bare failure.

The `drill` ServiceAccount gets `cluster-admin`; read-only cannot do scenario 10 break/fix.

Starting scenario 05 while 03 is open refuses, because scenarios mutate the same app and concurrent drills make cluster state unattributable.

## Testing

Grader unit tests over alias expansion and semantic parsing, which are pure functions needing no cluster.
Answer-key generator tests asserting mixed-mode output for the unported eleven is byte-identical to today's file.
`make -f Makefile.test test` must keep passing.
Confirmation that Argo CD will clone from cluster git over the chosen protocol.
**Amended 2026-08-19:** this originally called for a standalone spike run before committing to the design.
It is instead an acceptance test on kind against the manifests that ship, because a negative result never invalidated the design, it only ever changed which container serves the repo, and a throwaway spike would have built the same manifest twice.
The plan carries a ranked fallback ladder so a failure is a menu pick rather than a redesign.
Live verification by actually drilling scenario 03, which is the point of the vertical slice.

## Repo rules this must respect

No Terraform defaults; every value goes in `scripts/config.toml` and `config.example.toml`.
No PII or account-specific values committed.
Anything that bills must have a cleanup path, which is what session teardown and PVC deletion are for.
Card, answers and `check.sh` must agree, which generation now enforces mechanically rather than by discipline.
