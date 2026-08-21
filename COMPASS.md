# COMPASS.md - daily-eks-practice

The map. Pointers only, capped at 100 lines. It routes; it never explains.
Read it first. Update rules are in `CLAUDE.md` under "The north star".

## The north star - the drill loop

**Everything in this repo answers to this picture.** A change that does not serve this loop is out of scope; one that contradicts it is wrong.

```
  USER'S BROWSER
        |  (one ALB, one origin, source-IP restricted)
        v
+-------------------------------------------------------+
|  drill-gui pod   ns: practice-drill                    |   <- THE interface.
|                                                        |      Not their laptop.
|   +----------+----------+----------+--------------+    |
|   | terminal |   IDE    | answers  | Argo/Grafana |    |
|   | (xterm)  | (Monaco) |  + hints |  (proxied)   |    |
|   +----+-----+----+-----+----------+--------------+    |
|        |          |                                    |
|        |     edits values.yaml  -->  workspace PVC     |
|        |                              (a CLONE of      |
|        |  git commit && git push      cluster git,     |
|        +----------+---------------->  so origin IS     |
+-------------------|-----------------  cluster git)-----+
                    |
                    v
        +-----------------------+
        | git-server   ns: git  |  <-- the "real" git
        | git daemon :9418      |      the user sees
        +-----------+-----------+
                    | Argo polls every 10s
                    v
        +-----------------------+
        | Argo CD   ns: argocd  |  automated sync;
        |                       |  selfHeal per-scenario
        +-----------+-----------+
                    | syncs
                    v
        +-----------------------+
        | practice-app          | --> user watches it
        | new image tag rolls   |     roll in the same
        +-----------------------+     browser
```

**The user never leaves the browser. Their laptop terminal is not in this loop at all.**
Real git, real push, real Argo sync - only _whose_ repo the remote is is simulated. A drill push must never reach the user's GitHub account.

## Where things are

| Path                                             | What it is                                      | Open it when                                     |
| ------------------------------------------------ | ----------------------------------------------- | ------------------------------------------------ |
| `CLAUDE.md`                                      | agent rules, hard rules, the north star SOP     | before any change                                |
| `HYDRATION.md`                                   | the prompt that starts a session, newest first  | **first**, every session; top entry only         |
| `CONTEXT_STATE.md`                               | the background that prompt assumes              | after it; on a conflict the prompt wins          |
| `BACKLOG.md` / `ISSUES.md`                       | parked ideas / known problems                   | logging either; never hand-edit                  |
| `work-orders/`                                   | tickets; `INDEX.md` is the router               | picking up work                                  |
| `work-orders/archive/`                           | closed tickets                                  | tracing why something was built                  |
| `docs/superpowers/specs/`                        | the design argument                             | a decision looks arbitrary                       |
| `docs/superpowers/plans/`                        | the implementation plan, task by task           | executing a phase; it is the authority           |
| `terraform/envs/dev`                             | the only env; backend + one stack call          | changing what gets provisioned                   |
| `terraform/modules/stack`                        | composition; the only place modules wire        | adding a module or threading a variable          |
| `terraform/modules/platform/cluster-git.tf`      | the git server; rung verdict in its header      | touching the git protocol                        |
| `terraform/modules/platform/drill-ingress.tf`    | the source-IP SG - the only control on the GUI  | anything about who can reach the drill           |
| `terraform/modules/platform/drill-gui.tf`        | the drill pod, its PVC, cluster-admin, Ingress  | changing what runs in the cluster                |
| `scripts/pre-destroy.py`                         | teardown that does not orphan a billing ALB     | changing `make down`                             |
| `terraform/modules/{vpc,eks,addons,rds,storage}` | raw resources, kept transparent                 | learning how a piece works                       |
| `scripts/config.example.toml`                    | every config value, documented                  | adding a Terraform variable                      |
| `scripts/bootstrap.py`                           | config -> tfvars -> terraform                   | anything Terraform runs through                  |
| `scripts/git-seed.py`                            | bootstrap the cluster repo from local           | the env has no code in it                        |
| `scripts/gen-argocd-app.py`                      | generates the Argo Application                  | changing what Argo reads or its sync policy      |
| `drill/`                                         | the GUI + server + grader (TypeScript)          | anything the user sees or that grades them       |
| `drill/shared/src/index.ts`                      | the websocket protocol, defined once            | adding a message between web and server          |
| `drill/Containerfile` + `.containerignore`       | the image; the allow-list keeping secrets out   | changing what ships or widening the context      |
| `drill/server/src/committed.ts`                  | what cluster git has - the GitOps half of grading | the saved-vs-committed lesson                  |
| `drill/server/src/grader/`                       | the grader; pure functions                      | changing how a submission is judged              |
| `scenarios/`                                     | the curriculum cards                            | adding or editing a drill                        |
| `scenarios/answers/*.toml`                       | single source of truth for answers              | changing an answer, a hint, or a scenario switch |
| `PRACTICE_ANSWERS.html`                          | generated; `make answers-gen` only              | never by hand                                    |
| `scenario_testing/check.sh`                      | live-cluster outcome checks                     | adding a scenario                                |
| `tests/`                                         | $0 local validation                             | adding a guard                                   |
| `tests/cluster-git-argo.sh`                      | proves Argo clones cluster git on kind          | changing the git server                          |
| `tests/drill-gui-kind.sh`                        | proves the drill pod serves the console on kind | changing the image or the deployment             |
| `Makefile`                                       | lifecycle (up, down, git-seed, scenario)        | driving the env                                  |
| `Makefile.test`                                  | static checks, ministack, kind, drill           | validating a change                              |
| `.claude/skills/`                                | vendored: work-order, container-sandbox, hydration-prompt | ticketing, sandboxed testing, handoff  |
