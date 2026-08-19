# Scenario drill sessions - design

Date: 2026-08-19
Status: in progress. Q1, Q2, Q2a and Q3 resolved; Q4 through Q7 open.
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
It is seeded by an init container that clones from GitHub, using the same token mechanism `scripts/argo-repo.py` already uses to give Argo read access to a private repo.
Init containers run to completion before any main container starts, so the clone cannot race the git server.

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

### Build-time items not to forget

`drill-progress/` must be added to `.gitignore` before it is ever created, or practice history lands in a commit.
The drill GUI must not use port 8080, which `make argo-ui` already occupies.
Two new config values are needed in `config.toml` and `config.example.toml`: the ingress group name and the allowed CIDR.

## Open questions

**Q4 - integrations scope.** Argo CD only, or Argo plus Prometheus/Grafana, given scenario 07 is entirely observability.

**Q5 - pod lifetime.** One long-lived `drill-gui` that loads whichever scenario is active, versus one pod per scenario.

**Q6 - stack.** Frontend is TypeScript regardless: xterm.js is effectively the only serious browser terminal, and Monaco and CodeMirror 6 are both JS.
Backend candidates are Node/TS (shared websocket message types with the frontend, `node-pty`, official k8s client), Go (`client-go`, static binary, tiny image, protocol maintained twice), or Python (weakest; the only argument was matching `scripts/`, which is inertia).
Separable sub-choices: React+Vite versus Svelte, and Monaco (~5MB, literally VS Code) versus CodeMirror 6 (~10x smaller).

**Q7 - guarding unsafe targets.** Largely absorbed by the Makefile handover model above, but the exact refusal behaviour and the GUI port still need pinning.

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
A spike to confirm Argo CD will clone from cluster git over the chosen protocol, before committing to the design.
Live verification by actually drilling scenario 03, which is the point of the vertical slice.

## Repo rules this must respect

No Terraform defaults; every value goes in `scripts/config.toml` and `config.example.toml`.
No PII or account-specific values committed.
Anything that bills must have a cleanup path, which is what session teardown and PVC deletion are for.
Card, answers and `check.sh` must agree, which generation now enforces mechanically rather than by discipline.
