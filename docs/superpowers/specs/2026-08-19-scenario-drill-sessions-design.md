# Scenario drill sessions - design

Date: 2026-08-19
Status: proposed, awaiting review
Slice: scenario 03 only (`03-rolling-update-rollback`)

## Problem

Today `make scenario N=03` prints a Markdown card to the terminal and nothing else.
The drill is entirely honour-system: nothing captures what you did, nothing tells you whether an individual task was right, and the only feedback is `make check N=03` at the very end, which grades the final cluster state rather than the reasoning that got you there.

Three concrete gaps follow from that.

Answers are never captured, so there is no record of how you solved a card and nothing to review later.
Nothing guards against starting a second scenario while the first is half-finished, even though scenarios mutate the same `practice-app` and therefore interfere.
Cleanup is all-or-nothing: the only way to undo a drill is `make down`, which destroys the whole cluster.

## Goal

Turn a scenario into a **drill session**: a declarative, idempotent resource with an apply and a destroy, backed by a web GUI that grades your answers task by task and acts as the gate for completing the card.

## Scope

This spec covers **scenario 03 only**, built end to end.

Scenario 03 is chosen deliberately because it exercises every hard part of the design: a rollout to watch, a `values.yaml` edit to make, and a GitOps trap in task 5 that only lands if Argo CD is genuinely fighting you.
If the design survives 03 it will survive most of the rest.

The other eleven scenarios are **explicitly out of scope** and get ported one at a time afterwards.
Each card is different and may need format changes, so the answers-file schema must be extended per scenario rather than frozen now.

That makes incremental migration a hard requirement, not an aspiration.
See "Mixed-mode answer key" below.

## Non-goals

Multiple concurrent drill sessions.
Multi-user or shared sessions.
Replacing `scenario_testing/check.sh`, which stays hand-written bash.
Porting scenarios 01, 02, and 04 through 12.

## Architecture

Six components, three of which are new processes.

```
your terminal                    your laptop                      the cluster
-------------                    -----------                      -----------
real kubectl work  ------------------------------------------->  practice-app
                                                                       ^
                                                                       | syncs
make scenario N=03  --->  drill CLI (python)                           |
                            |  .drill-state.json (local, gitignored)   |
                            |  scenario_testing/answers/03.toml        |
                            |                                     Argo CD
                            |                                          ^
                            +---> applies ------------------------+    | polls
                                                                  v    |
                                                          namespace practice-drill
                                                            drill SA (cluster-admin)
                                                            pod drill-03
                                                              - GUI server  :8080
                                                              - git repo (the chart)
                                                              - nginx dumb-HTTP :80
                                                            svc drill-git
```

The division of labour is deliberate.

**You do the real work in your own terminal**, against the real cluster, with real `kubectl`.
That is the learning and it stays untouched.

**The GUI is the submission surface**, not the work surface.
It takes answers, renders the simulated repo, tracks progress, and gates completion.

**The drill CLI is local** because it needs the repo, git, helm, and the repo-local kubeconfig, none of which an in-cluster pod can reach.

### Why the pod hosts a real git repo

The original idea was for the GUI to simulate `helm/practice-app/values.yaml` and apply changes directly to the cluster.
That works for mechanism but silently destroys the lesson in task 5, which asks when `kubectl rollout undo` bites you in a GitOps shop.
The honest answer is "when Argo re-syncs from git and stomps your imperative fix", and you cannot feel that if nothing is ever committed to git.

So the pod hosts a **real** git repo instead of a simulated one.
Argo CD can point at any git URL, including a Service inside the cluster, so this costs very little and keeps every GitOps lesson intact.
It also means no scenario cards need rewriting.

## Components

### 1. Answers file - `scenario_testing/answers/03.toml`

TOML, because the repo is stdlib-only Python and `tomllib` is already in use by `scripts/bootstrap.py`.
Adding PyYAML for this would be the only third-party dependency in the project.

This file is the **single source of truth** for scenario 03's tasks, graders, accepted answers, hints, and prose answers.
It drives the GUI, the grader, and the generated answer key.

Sketch of the shape:

```toml
[scenario]
n     = "03"
title = "Rolling update + rollback"

[[task]]
n      = 1
grader = "command"
prompt = "Find the frontend Deployment's current image tag and its rollout history."

  [[task.accept]]
  verb      = "rollout history"
  resource  = "deployment"
  name      = "practice-app-frontend"
  namespace = "practice-app"

  [[task.hint]]
  when = "resource == 'pod'"
  say  = "Rollout history lives on the Deployment, not on an individual Pod."

  answer = """
  kubectl -n practice-app rollout history deploy/practice-app-frontend
  """
```

Three grader kinds, matching the decision already made:

`command` matches a submitted command semantically.
`concept` matches a free-text or multiple-choice answer.
`effect` shells out to `check.sh` with a per-task selector and grades live cluster state.

### 2. Answer key generator - mixed-mode

`PRACTICE_ANSWERS.html` becomes **generated**, so it cannot drift from the answers file.

The generator must handle a mixed state, because only scenario 03 is ported in this slice.
It renders 03's `<details>` block from `answers/03.toml` and passes the other eleven hand-written blocks through untouched.
Practically that means keeping the current HTML as a template with a marked region per scenario, and substituting only the regions that have a corresponding answers file.

`scripts/serve-answers.sh` regenerates before serving.
Its existing awk-based per-scenario scoping keeps working unchanged, because the output shape is identical.

### 3. Drill session lifecycle

`make scenario N=03` becomes an **apply**, not a create.

| Command                    | State           | Behaviour                                                                                       |
| -------------------------- | --------------- | ----------------------------------------------------------------------------------------------- |
| `make scenario N=03`       | nothing active  | create namespace, SA, RBAC, pod, Service, Argo Application; write state; print card and GUI URL |
| `make scenario N=03`       | 03 already up   | converge and no-op; reattach, reprint the card and which tasks have passed                      |
| `make scenario N=03`       | 03 up, pod died | heal by recreating the pod; progress is preserved                                               |
| `make scenario N=05`       | 03 still active | refuse; point at `make scenario-clean N=03`                                                     |
| `make scenario-clean N=03` | any             | destroy pod, Service, Argo Application, namespace; revert the values flip; release the lock     |
| `make down`                | 03 active       | warn that a drill is open before destroying                                                     |

The one-at-a-time guard **refuses rather than parks**.
This is a constraint, not a preference: scenarios mutate the same `practice-app`, so 02's HPA, 03's image roll, and 04's Ingress interfere with each other and make grading unattributable.
Parking would require snapshotting and restoring per-scenario cluster state, which is more machinery than the feature justifies.

### 4. Session state - `.drill-state.json`

Local to the repo and gitignored.

State lives on the laptop, not in the cluster, because the cluster is torn down nightly for cost.
In-cluster progress would evaporate with it.
Keeping it local means progress survives `make down` and reattaches on the next `make up`.

It records the active scenario, when it started, which tasks have passed, and the submitted answers.
That last part also delivers the "per-scenario answer capture" item already sitting in `BACKLOG.md`.

### 5. Drill pod

Namespace `practice-drill`, one pod, three concerns in it.

A **GUI server** on :8080, served over `kubectl port-forward` rather than an ingress, so the drill provisions nothing billable.

A **git repo** holding the chart, seeded from `helm/practice-app` at session-apply time so it cannot drift from the real chart.

**nginx** serving that repo's `.git` directory over dumb HTTP after `git update-server-info`, fronted by the `drill-git` Service.
nginx is already a public image this project uses, so nothing needs building or pushing.

The pod runs under a dedicated `drill` ServiceAccount bound to `cluster-admin`.
Read-only would not be enough: scenario 10 is break/fix and must mutate, and the pod needs to apply chart changes.
This is a personal single-user playground, so the blast radius is acceptable, but it is a deliberate choice and is recorded as such.

### 6. Argo CD integration

The drill Application is **scenario-scoped and separate** from the real one that `scripts/gen-argocd-app.py` generates from the user's git remote.
It must not collide with or overwrite that Application.

It points at `http://drill-git.practice-drill.svc.cluster.local/chart.git`, anonymously, since no credentials are needed in-cluster.

`make scenario-clean` must delete it, or it dangles and keeps trying to sync a repo that no longer exists.

### 7. Grader

Commands are graded **semantically, not by regex**.

The submitted string is alias-expanded, then parsed into `(verb, resource, namespace, name, flags)`, then matched against the task's accepted shapes.
This means `k rollout history deploy/practice-app-frontend -n practice-app` and `kubectl rollout history deployment practice-app-frontend --namespace practice-app` both pass without maintaining a regex zoo.

The alias table covers the user's actual shell aliases: `k`, `kg`, `kgp`, `kgn`, `kgs`, `kd`, `kl`, `kaf`, `kp`.
It lives in the answers-file layer as shared config, not hardcoded in the grader.

A wrong answer must **point you in the right direction** rather than just failing.
Hints are keyed to the misconception, matched on the parsed command: describing a Pod when the task wants the Deployment produces a hint that says so.
A generic fallback covers anything unmatched.

## Data flow - walking scenario 03

1. `make scenario N=03` writes state, applies the namespace, SA, RBAC, pod, Service, and Argo Application, then prints the card and the GUI URL.
2. You open the GUI and work task 1 in your own terminal with real `kubectl`.
3. You paste the command into the GUI. The grader alias-expands and parses it, matches an accepted shape, and marks task 1 passed.
4. Task 2 renders the chart's `values.yaml` in the GUI. You change the tag to `1.28-alpine`. The GUI commits that to the pod's real git repo.
5. Argo CD polls, sees the commit, syncs, and the rollout starts. You watch it in your terminal.
6. Task 4's curl loop needs an in-cluster vantage point, so the GUI hands you a `kubectl run --rm` one-liner.
7. Task 5 you run `kubectl rollout undo`. Argo re-syncs from git and stomps it. The trap lands for real.
8. `make check N=03` still grades the end state, unchanged.
9. `make scenario-clean N=03` tears the session down and releases the lock.

## Error handling

Pod died but state says active: converge heals it and preserves progress.
Cluster unreachable: reuse the existing `scripts/scenario-prereqs.py` preflight, which already prints actionable fix hints.
Argo Application already exists from a previous unclean session: converge adopts it rather than erroring.
`make down` with an open session: warn, do not silently orphan the state file.
Answers file missing for a scenario: fall back to today's behaviour of printing the card, so unported scenarios keep working.

## Testing

Static and $0 first, per the repo's existing discipline.

Grader unit tests over the alias-expansion and semantic-parse layer, which is pure Python and needs no cluster.
Answer-key generator tests asserting that mixed-mode output for the unported eleven is byte-identical to today's file.
`make -f Makefile.test test` must keep passing.
Live-cluster verification happens by actually drilling scenario 03, which is the point of the vertical slice.

## Risks and spikes

**Spike needed before committing:** confirm Argo CD will clone a dumb-HTTP git repo.
Argo shells out to git, which supports the protocol, but this should be proven rather than assumed, because the whole GitOps half of the design rests on it.
If it fails, the fallback is a small HTTP git backend in the pod, which is more moving parts but not a redesign.

`cluster-admin` on the drill SA is a deliberate widening of blast radius, accepted for a single-user playground.

The answers-file schema will need to change as scenarios are ported.
That is expected and is why only 03 is in scope.

Regenerating `PRACTICE_ANSWERS.html` risks losing hand-tuned HTML.
Mitigated by the mixed-mode byte-identical test above.

## Repo rules this must respect

No Terraform defaults; anything configurable goes in `scripts/config.toml` and `config.example.toml` (`CLAUDE.md` rule 2).
No PII or account-specific values committed (rule 3).
Anything the drill creates that bills must have a cleanup path, which is what `scenario-clean` is for (rule 5).
Card, answers, and `check.sh` must agree, which generation now enforces mechanically rather than by discipline.
