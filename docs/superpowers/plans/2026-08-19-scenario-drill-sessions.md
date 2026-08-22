# Scenario Drill Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `make scenario N=03` from a card-printer into a converged drill session driven from an in-cluster GUI that grades task by task and can restore you to where you left off.

**Architecture:** A permanent in-cluster git server in namespace `git` is the only source Argo CD ever reads, seeded by streaming a `git bundle` in from the local repo. A single long-lived `drill-gui` pod in namespace `practice-drill` serves a terminal, a Monaco editor, an answers panel and a help panel over one ALB. Session state lives in a ConfigMap; curriculum progress lives in gitignored `drill-progress/` on the laptop as append-only sessions of `git bundle` save files. Answers live in per-scenario TOML that is the single source of truth for both grading (TypeScript, server-side) and `PRACTICE_ANSWERS.html` (Python, render-only).

**Tech Stack:** Terraform (aws/helm/kubectl-gavinbunney/random), Python 3.11+ stdlib only (`tomllib`), TypeScript on Node 20 (Fastify, `node-pty`, `ws`, `@kubernetes/client-node`, `@fastify/http-proxy`, `smol-toml`, `yaml`), React + Vite, `xterm.js`, Monaco, tmux, Podman, kind.

**Spec:** `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`

---

## Global Constraints

Copied verbatim from the spec and `CLAUDE.md`. Every task's requirements implicitly include this section.

- **No Terraform defaults.** Every variable is declared with NO `default =`. Values live in `scripts/config.toml` (git-ignored) and are documented in `scripts/config.example.toml`. Thread each new value through `scripts/config.example.toml` -> `terraform/envs/dev/variables.tf` -> `terraform/envs/dev/main.tf` -> `terraform/modules/stack/variables.tf` -> `terraform/modules/stack/main.tf` -> the target module. Run Terraform only through `scripts/bootstrap.py` / `make`, never bare.
- **No real AWS without explicit user approval.** Phases 0-6 are $0 and run entirely on kind + Podman + ministack. Phase 7 is the only phase that touches AWS, and it is gated on the user saying yes.
- **Fake it locally first.** Terraform changes go through ministack (`make -f Makefile.test ministack`) per the vendored `.claude/skills/container-sandbox/SKILL.md`. Cluster behaviour goes through kind. Node and helm run inside Podman; there is no local `helm` binary and `npm install` never runs on the host.
- **No PII in git.** No AWS account ids, profile names, real domains, CIDRs, or repo-owner strings outside `scripts/config.toml` and generated files. `argocd/generated/` and `drill-progress/` are git-ignored.
- **Never create a personal access token.** When a GitHub scope is missing, extend the grant `gh` already holds: `gh auth refresh -h github.com -s <scope>`. Settled 2026-08-19 and it applies to every scope this project ever needs, not just `write:packages`. A PAT is a second credential with its own expiry that has to be stored somewhere, and every candidate is bad: `scripts/config.toml` is serialised into Terraform state, a shell export lands in history, a dotfile is one `git add -A` from being committed. `gh auth refresh` is interactive and blocks on a browser, so an agent cannot run it - print the command for the user. A classic PAT is an escape hatch for when org SSO refuses the refresh, never a first choice.
- **Cost discipline.** Anything that bills gets a cleanup step: the drill PVC must be deleted before `terraform destroy`, and Ingresses must be deleted and the ALB confirmed gone before `terraform destroy`.
- **Plain dashes, never em dashes**, in every file this plan creates or edits.
- **One full sentence per line** in long Markdown files.
- **Card, answers TOML, and `scenario_testing/check.sh` must agree.** After Phase 1 this is enforced mechanically by generation rather than by discipline.
- **Never touch `.claude/settings.local.json`.**
- Ports already taken: `make argo-ui` uses 8080, `make grafana-ui` uses 3000. The drill GUI uses **8090**.
- Local tooling confirmed present: `kind` (/usr/local/bin/kind), `minikube`, `kubectl`, `podman` 4.9.3, `node` v20.20.2, `npm`, `python3` 3.12.3, `jq`, `tmux`. **`helm` is NOT installed on the host** and must run in Podman via `docker.io/alpine/helm:latest`.

## The self-contained git rule

**The drill never contacts github.com. Everything Argo CD reads comes from the local repo, via the cluster.**

This is a standing rule, not a preference, and it supersedes the spec's Q1 seeding sentence.
The spec must be amended to match.

**"Self-contained" is not "simulated."** The in-cluster server runs genuine git and Argo CD does a genuine clone and a genuine sync.
Nothing here is a mock.
What changes is the location of the remote, from `github.com` to `git-server.git.svc.cluster.local`, and nothing else.
The distinction is the whole learning value: if the GitOps step were faked, scenario 03 would be teaching a simulation of a skill instead of the skill.

**How it works.** The init container runs `git init --bare` only.
A `make git-seed` target streams `git bundle create - --all` from the local repo into the pod over `kubectl exec`.
That one primitive, `git bundle`, is used inward to seed and outward to save progress, so there is no second mechanism to build or maintain.

**Why the spec's version cannot work anyway.** Q1 says the init container clones from GitHub using the token mechanism `scripts/argo-repo.py` already uses.
That mechanism is a script the user runs _after_ apply, so Terraform cannot supply the token at init-container time, and a private repo would make the first apply fail.
Seeding from the laptop removes the PAT from the cluster entirely, removes the dependency on GitHub being reachable from a private subnet, and seeds exactly what is on disk rather than whatever was last pushed.
The readiness gate the spec actually cared about is preserved and strengthened: the probe requires a `.seeded` marker, so until the bundle lands the Service has no endpoints and Argo retries cleanly instead of syncing a half-served repo.

**What the rule forbids:**

- Argo CD reading any repoURL outside the cluster. This deletes rung 5 from Task 3.2's fallback ladder rather than merely deprioritising it, so a failure at rung 4 cannot slide back into the thing the rule rejects.
- A GitHub credential in the cluster. The drill path never calls `make argo-repo`.
- `scripts/gen-argocd-app.py` reading the user's git remote on the drill path. It generates from `cluster_git_url`.

**What the rule does not forbid**, stated so nobody over-applies it: container images still come from `docker.io` and `ghcr.io`, and the kind acceptance test pulls Argo's install manifest from `raw.githubusercontent.com`.
Those are network but they are not git and they are not the sync path.
The rule governs what Argo reads, not whether the cluster has egress.

**`scripts/argo-repo.py` is kept, not deleted.** It exists for `scenarios/09-gitops-argocd.md`, which teaches manual PAT-and-UI repo registration against real GitHub, and that lesson ships today.
The drill simply never calls it.
Whether 09's lesson survives contact with cluster git is a decision for when 09 is ported, not now.

## Where each language runs, and why

The spec settled that the app is TypeScript on both ends (Q6) and that answers are TOML (because the repo is stdlib-only Python and `tomllib` is already used by `scripts/bootstrap.py`).
It did not say which language does the grading, so this plan decides it. Recording the split here because "the repo is Python and the app is TypeScript" is the kind of thing that reads as a contradiction until the line between them is drawn explicitly.

| Runs where                      | Language   | What                                                                                                                             |
| ------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------- |
| In the cluster, in the pod      | TypeScript | `drill/web` (React, xterm.js, Monaco) and `drill/server` (Fastify, PTY, **the grader**, the proxy)                               |
| On the laptop, called by `make` | Python     | `bootstrap.py`, `git-seed.py`, `pre-destroy.py`, `progress.py`, `drill-watch.py`, `scenario.py`, `handover.py`, `gen-answers.py` |

**Python is never in the container image and never serves a byte to the browser.**
It is the same laptop-side CLI glue every script in `scripts/` already is.
It stays Python because `make up` currently needs only `python3`, and `bootstrap.py` is what generates the tfvars; moving that to TypeScript would make Node a prerequisite for bringing up a cluster, which is a real regression for a repo whose pitch is "clone it and `make up`".

**The grader is TypeScript because of where it runs, not because Python was rejected.**
Grading happens per submission inside the GUI's Node process. A Python grader would mean shipping a Python runtime in the app image and shelling out to it on every submission, for nothing.

**The TOML file is the boundary between them.**
Python reads it to render `PRACTICE_ANSWERS.html` and never grades.
TypeScript reads it to grade and never renders.
Two consumers, one source of truth, no runtime coupling.

**Known wart: the TOML is validated twice**, in `scripts/answers.py::_validate()` and `drill/server/src/grader/answers.ts::validate()`.
If the two drift, a file can pass generation and fail grading, which is the worst of both.
Task 1.1 Steps 6-7 build a shared fixture set of deliberately-invalid TOML, and Task 2.4 Step 6 runs the same files through the TypeScript validator, so drift becomes a test failure rather than a support ticket.

## Phase map

Each phase is an independently reviewable deliverable and is intended to become one work-order ticket under a single epic.

| Phase | Deliverable                                       | Cost                   | Needs approval |
| ----- | ------------------------------------------------- | ---------------------- | -------------- |
| 0     | Local sandbox harness                             | $0 (kind)              | no             |
| 1     | Answers TOML as the single source of truth        | $0                     | no             |
| 2     | The grader                                        | $0 (Podman)            | no             |
| 3     | Terraform: cluster git                            | $0 (ministack)         | no             |
| 4     | Terraform: ALB, shared IngressGroup, source-IP SG | $0 (ministack)         | no             |
| 5     | The mothership GUI - **first visual**             | $0 (Podman + kind)     | no             |
| 6     | Session lifecycle, watcher, Makefile handover     | $0 (kind)              | no             |
| 7     | Live verification on real EKS                     | ~$6.50 for a 30h cycle | **YES**        |

**The one live risk is in Task 3.2**, not in Phase 0. Whether Argo CD will clone from an in-cluster git server over plain HTTP is unproven, and it is the assumption the whole GitOps half rests on. It is validated as Task 3.2's acceptance test on kind, at $0, against the manifests that actually ship. Task 3.2 carries a ranked fallback ladder so a failure there is a menu pick rather than a redesign. See "The cluster git protocol risk" inside Task 3.2.

**First visual is Phase 5, Task 5.3**, served from a Vite dev server in Podman on a probed port in 30000+, per the container-sandbox skill's single-container preview pattern. No cluster and no AWS needed to look at it.

---

## Phase 0: Local sandbox harness

This phase used to contain a second task, a standalone spike that stood a git server up on kind, pointed Argo at it, recorded a verdict and then deleted itself. It was cut deliberately.

The reasoning: the spike built the same manifest Task 3.2 builds, proved it, threw it away, and then Task 3.2 rebuilt it in Terraform. Writing it twice bought nothing, because a negative result never killed the design - it only ever meant "swap the container." A gate is the wrong instrument for a risk whose worst case is a substitution.

What the spike was genuinely protecting against is preserved and strengthened, not dropped. It moved into Task 3.2 as an acceptance test rather than a prerequisite, so the validation runs on kind at $0 against the manifests that actually ship, and the fallback options are written down in advance instead of being researched at the moment of failure. See "The cluster git protocol risk" in Task 3.2.

### Task 0.1: Kind sandbox harness and its documentation

`.claude/skills/container-sandbox/SKILL.md` line 12 points at a "Kind Sandbox" section that does not exist in the file. This task writes it and provides the harness it describes, so every later phase has one documented way to get a throwaway cluster.

**Files:**

- Create: `scripts/kind-sandbox.sh`
- Modify: `.claude/skills/container-sandbox/SKILL.md` (add a `## Kind Sandbox` section after `## Terraform / Ministack Sandbox`, which currently ends at the `### Step 6 - Teardown` block)
- Modify: `Makefile.test` (add `kind-up`, `kind-down`, `kind-status` targets)
- Test: `tests/kind-sandbox.sh`

**Interfaces:**

- Consumes: nothing.
- Produces:
  - `scripts/kind-sandbox.sh up` - creates cluster `daily-eks-drill-sandbox`, writes kubeconfig to `.kubeconfig-kind-sandbox` (git-ignored), idempotent (re-running when the cluster exists is a no-op that still rewrites the kubeconfig).
  - `scripts/kind-sandbox.sh down` - deletes the cluster and the kubeconfig file.
  - `scripts/kind-sandbox.sh status` - exits 0 when the cluster exists and every node is `Ready`, non-zero otherwise.
  - `scripts/kind-sandbox.sh kubeconfig` - prints the absolute path to the kubeconfig.
  - Env var `KIND_SANDBOX_NAME` overrides the cluster name; defaults to `daily-eks-drill-sandbox`.

- [ ] **Step 1: Add the git-ignore entry first**

The kubeconfig must never be committable, and it must be ignored before it can ever be created.

Add to `.gitignore` immediately after the existing `.kubeconfig-daily-eks-practice` line:

```
# ---- kind sandbox kubeconfig (make -f Makefile.test kind-up) ----
.kubeconfig-kind-sandbox
```

- [ ] **Step 2: Write the failing test**

Create `tests/kind-sandbox.sh`:

```bash
#!/usr/bin/env bash
# E2E test for the kind sandbox harness. Creates a throwaway cluster, asserts
# idempotency and status behaviour, then tears it down. No AWS, no cost.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT/scripts/kind-sandbox.sh"
export KIND_SANDBOX_NAME="drill-harness-test"

PASS=0; FAIL=0
ok()  { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }

cleanup() { bash "$HARNESS" down >/dev/null 2>&1 || true; }
trap cleanup EXIT

command -v kind >/dev/null 2>&1 || { echo "SKIP: kind not installed"; exit 0; }

echo "== status on a cluster that does not exist =="
bash "$HARNESS" status >/dev/null 2>&1 && bad "status exited 0 with no cluster" || ok "status is non-zero with no cluster"

echo "== up =="
bash "$HARNESS" up >/dev/null 2>&1 && ok "up succeeded" || bad "up failed"
bash "$HARNESS" status >/dev/null 2>&1 && ok "status is 0 after up" || bad "status non-zero after up"

echo "== kubeconfig points somewhere real =="
KC="$(bash "$HARNESS" kubeconfig)"
[ -f "$KC" ] && ok "kubeconfig exists at $KC" || bad "no kubeconfig at '$KC'"
KUBECONFIG="$KC" kubectl get nodes >/dev/null 2>&1 && ok "kubectl works against it" || bad "kubectl failed"

echo "== up is idempotent =="
bash "$HARNESS" up >/dev/null 2>&1 && ok "second up succeeded" || bad "second up failed"

echo "== down =="
bash "$HARNESS" down >/dev/null 2>&1 && ok "down succeeded" || bad "down failed"
bash "$HARNESS" status >/dev/null 2>&1 && bad "status exited 0 after down" || ok "status non-zero after down"
[ -f "$KC" ] && bad "kubeconfig survived down" || ok "kubeconfig removed by down"

echo ""
echo "kind-sandbox: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash tests/kind-sandbox.sh`
Expected: FAIL - every step errors because `scripts/kind-sandbox.sh` does not exist.

- [ ] **Step 4: Write the harness**

Create `scripts/kind-sandbox.sh`:

```bash
#!/usr/bin/env bash
# Throwaway kind cluster for $0 local testing of anything that needs a real
# Kubernetes API. Never touches AWS and never touches ~/.kube/config - the
# kubeconfig is repo-local and git-ignored, same rule as the EKS one.
#
#   bash scripts/kind-sandbox.sh up          # create (idempotent)
#   bash scripts/kind-sandbox.sh status      # 0 when every node is Ready
#   bash scripts/kind-sandbox.sh kubeconfig  # print the kubeconfig path
#   bash scripts/kind-sandbox.sh down        # delete cluster + kubeconfig
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${KIND_SANDBOX_NAME:-daily-eks-drill-sandbox}"
KUBECONFIG_FILE="$ROOT/.kubeconfig-kind-sandbox"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1"; exit 2; }; }

exists() { kind get clusters 2>/dev/null | grep -qx "$NAME"; }

cmd_up() {
  need kind; need kubectl
  if exists; then
    echo "kind-sandbox: cluster '$NAME' already exists - refreshing kubeconfig"
  else
    echo "kind-sandbox: creating cluster '$NAME' (this takes about a minute)"
    kind create cluster --name "$NAME" --wait 120s || return 1
  fi
  kind get kubeconfig --name "$NAME" > "$KUBECONFIG_FILE" || return 1
  echo "kind-sandbox: wrote $KUBECONFIG_FILE"
  echo "  use it with:  export KUBECONFIG=$KUBECONFIG_FILE"
}

cmd_down() {
  need kind
  exists && kind delete cluster --name "$NAME"
  rm -f "$KUBECONFIG_FILE"
  echo "kind-sandbox: cluster '$NAME' and its kubeconfig are gone"
}

cmd_status() {
  need kubectl
  exists || { echo "kind-sandbox: no cluster '$NAME'"; return 1; }
  local total ready
  total=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  ready=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
  [ "$total" -gt 0 ] && [ "$total" -eq "$ready" ] || { echo "kind-sandbox: $ready/$total nodes Ready"; return 1; }
  echo "kind-sandbox: cluster '$NAME' up, $ready/$total nodes Ready"
}

cmd_kubeconfig() { echo "$KUBECONFIG_FILE"; }

case "${1:-}" in
  up)         cmd_up ;;
  down)       cmd_down ;;
  status)     cmd_status ;;
  kubeconfig) cmd_kubeconfig ;;
  *) echo "usage: kind-sandbox.sh <up|down|status|kubeconfig>"; exit 2 ;;
esac
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash tests/kind-sandbox.sh`
Expected: PASS on all 9 assertions, ending `kind-sandbox: 9 passed, 0 failed`.

- [ ] **Step 6: Add the Makefile.test targets**

In `Makefile.test`, add `kind-up kind-down kind-status` to the `.PHONY` line, and add these targets after the `ministack-down` target:

```makefile
kind-up: ## Create the throwaway kind sandbox cluster ($0, no AWS)
	bash scripts/kind-sandbox.sh up

kind-status: ## Is the kind sandbox up and Ready?
	bash scripts/kind-sandbox.sh status

kind-down: ## Delete the kind sandbox cluster and its kubeconfig
	bash scripts/kind-sandbox.sh down
```

Also add `kind-sandbox` to the `test` target's dependency list is **not** wanted - creating a cluster is too slow for the default static check. Leave `test` alone.

- [ ] **Step 7: Document it in the container-sandbox skill**

Append a `## Kind Sandbox` section to `.claude/skills/container-sandbox/SKILL.md`, placed immediately after the `### Step 6 - Teardown` block that ends the Ministack section. Write it in the skill's existing voice, covering what to test here and why:

````markdown
## Kind Sandbox

**RULE:** Use Kind any time behaviour depends on a real Kubernetes API - controllers,
operators, admission, RBAC, probes, watch streams, or anything a manifest does once it
is actually admitted. Ministack proves Terraform _plans_; Kind proves Kubernetes
_behaves_. They answer different questions and neither substitutes for the other.

### What belongs here

| Question                                                                   | Sandbox                                             |
| -------------------------------------------------------------------------- | --------------------------------------------------- |
| Does this Terraform parse, validate and plan?                              | Ministack                                           |
| Does this manifest get admitted, and does the controller do what I expect? | Kind                                                |
| Does a readiness probe actually gate Service endpoints?                    | Kind                                                |
| Does Argo CD clone from this repo URL?                                     | Kind                                                |
| Does this chart render?                                                    | Podman + `alpine/helm` (no cluster needed)          |
| Does the frontend look right?                                              | Podman single-container preview (no cluster needed) |

### Harness

`scripts/kind-sandbox.sh` in this repo wraps the lifecycle. It writes a repo-local,
git-ignored kubeconfig (`.kubeconfig-kind-sandbox`) and never touches `~/.kube/config`,
matching the rule the EKS kubeconfig already follows.

```bash
make -f Makefile.test kind-up          # create (idempotent)
export KUBECONFIG="$(bash scripts/kind-sandbox.sh kubeconfig)"
kubectl get nodes
make -f Makefile.test kind-down        # delete cluster + kubeconfig
```
````

`KIND_SANDBOX_NAME` overrides the cluster name so a test can run its own cluster
without stepping on the one you are working in. `tests/kind-sandbox.sh` uses this.

### Why this exists in a repo about EKS

The whole point of this project is a cluster you tear down nightly, so the expensive
thing is not compute, it is the minutes between "I changed a manifest" and "I know
whether it worked". Kind closes that loop in seconds against the same API server
version family, for nothing. Bring the EKS cluster up to verify the AWS-shaped parts
(IRSA, the ALB controller, EBS CSI) and nothing else.

### What Kind cannot tell you

Anything that is really AWS: IRSA token exchange, real IAM, the AWS Load Balancer
Controller provisioning an actual ALB, EBS volumes, RDS reachability. A green Kind run
is necessary before spending money, never sufficient. Say so explicitly when reporting
results, rather than letting a Kind pass read as a full pass.

### Teardown

Kind clusters survive reboots and each one holds a container plus its images. Always
`kind-down` when finished, and `kind get clusters` if something feels slow.

````

- [ ] **Step 8: Commit**

```bash
git add scripts/kind-sandbox.sh tests/kind-sandbox.sh Makefile.test .gitignore .claude/skills/container-sandbox/SKILL.md
git commit -m "test: kind sandbox harness for \$0 local cluster testing"
````

---

## Phase 1: Answers TOML as the single source of truth

Today `scenarios/03-*.md`, `PRACTICE_ANSWERS.html` and `scenario_testing/check.sh` agree only because someone remembered to keep them in step. After this phase, scenario 03's answer block is generated, so drift is impossible for 03 while the other eleven pass through byte-identically.

### Task 1.1: The answers TOML schema and its loader

**Files:**

- Create: `scenarios/answers/03.toml`
- Create: `scripts/answers.py`
- Test: `tests/test_answers.py`

**Interfaces:**

- Consumes: nothing.
- Produces (`scripts/answers.py`):
  - `load(scenario: str) -> dict` - reads `scenarios/answers/<scenario>.toml`, validates it, returns the parsed dict. Raises `AnswersError` with a message naming the file and the problem on any validation failure.
  - `available() -> list[str]` - sorted list of scenario numbers that have a TOML file, e.g. `["03"]`.
  - `class AnswersError(Exception)`.
  - The validated shape, which Task 1.2 and Phase 2 both depend on:
    - top level: `schema` (int, must be `1`), `scenario` (str, two digits), `title` (str), `time` (str), `needs` (str), `ticket` (str), `tasks` (list, non-empty).
    - each task: `id` (str), `prompt` (str), `grader` (str, one of `command`, `file`, `prose`), `answer` (table with optional `pre` list of str and optional `prose` str), and grader-specific keys.
    - `grader = "command"` tasks carry `accept` (list of tables with `verb`, and optional `resource`, `namespace`, `name`, `flags`) and optional `hints` (list of tables with `when` and `text`).
    - `grader = "file"` tasks carry `path`, `key` (dotted path into the YAML), `accept_pattern` (regex string), and optional `hints`.
    - `grader = "prose"` tasks carry `must_include` (list of str) and optional `hints`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_answers.py`. This repo has no test runner dependency, so it is a plain script with a `main()` that returns an exit code, matching the style of `tests/scrub-git-identity.sh`.

```python
#!/usr/bin/env python3
"""Unit tests for scripts/answers.py - the answers TOML loader and validator.

Pure functions over files. No cluster, no AWS, no network.
Run: python3 tests/test_answers.py
"""
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import answers  # noqa: E402

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  PASS  {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")


def expect_error(fn, needle, label):
    try:
        fn()
    except answers.AnswersError as e:
        if needle in str(e):
            ok(f"{label}: rejected with '{needle}'")
        else:
            bad(f"{label}: rejected but message was {e!r}, wanted '{needle}'")
    except Exception as e:  # noqa: BLE001
        bad(f"{label}: raised {type(e).__name__} instead of AnswersError: {e}")
    else:
        bad(f"{label}: accepted invalid input")


def load_text(text):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "99.toml"
        p.write_text(text, encoding="utf-8")
        return answers.load_path(p)


def test_real_03_loads():
    data = answers.load("03")
    if data["scenario"] == "03":
        ok("03.toml loads and reports scenario 03")
    else:
        bad(f"03.toml scenario is {data['scenario']!r}")
    if data["schema"] == 1:
        ok("03.toml declares schema 1")
    else:
        bad(f"03.toml schema is {data['schema']!r}")
    if len(data["tasks"]) == 6:
        ok("03.toml has 6 tasks, matching the card")
    else:
        bad(f"03.toml has {len(data['tasks'])} tasks, card has 6")
    graders = {t["grader"] for t in data["tasks"]}
    if graders <= {"command", "file", "prose"}:
        ok(f"03.toml graders are all known: {sorted(graders)}")
    else:
        bad(f"03.toml has unknown graders: {sorted(graders)}")


def test_available_includes_03():
    if "03" in answers.available():
        ok("available() includes 03")
    else:
        bad(f"available() returned {answers.available()}")


def test_missing_scenario():
    expect_error(lambda: answers.load("99"), "no answers file", "missing scenario")


def test_wrong_schema():
    expect_error(
        lambda: load_text('schema = 2\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "prose"\nmust_include = ["a"]\n'),
        "schema",
        "unsupported schema version",
    )


def test_unknown_grader():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "vibes"\n'),
        "grader",
        "unknown grader",
    )


def test_command_task_needs_accept():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "command"\n'),
        "accept",
        "command task with no accept block",
    )


def test_no_tasks():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n'),
        "tasks",
        "no tasks",
    )


def test_duplicate_task_ids():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "prose"\nmust_include = ["a"]\n[[tasks]]\nid = "1"\nprompt = "q"\ngrader = "prose"\nmust_include = ["b"]\n'),
        "duplicate",
        "duplicate task ids",
    )


def main():
    for fn in (
        test_real_03_loads,
        test_available_includes_03,
        test_missing_scenario,
        test_wrong_schema,
        test_unknown_grader,
        test_command_task_needs_accept,
        test_no_tasks,
        test_duplicate_task_ids,
    ):
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"answers: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 tests/test_answers.py`
Expected: FAIL with `ModuleNotFoundError: No module named 'answers'`.

- [ ] **Step 3: Write the answers TOML for scenario 03**

Create `scenarios/answers/03.toml`. Every task, prompt, accepted command and prose answer comes from the existing card (`scenarios/03-rolling-update-rollback.md`) and the existing answer block (`PRACTICE_ANSWERS.html` lines 194-224), so nothing new is invented and nothing existing is lost.

```toml
# Answers for scenario 03. This file is the SINGLE SOURCE OF TRUTH:
#   - scripts/gen-answers.py renders it into PRACTICE_ANSWERS.html
#   - the drill GUI grades submissions against it
# Do not edit the 03 block in PRACTICE_ANSWERS.html by hand; it is generated.

schema   = 1
scenario = "03"
title    = "Rolling update + rollback"
time     = "~30 min"
needs    = "cluster up, app deployed"
ticket   = "Bump the frontend nginx to the next minor. Ship it with zero downtime, then practise the oh-no path: roll it back."

# ---------------------------------------------------------------------------
[[tasks]]
id      = "1"
prompt  = "Using kubectl, find the frontend Deployment's current image tag and its rollout history (namespace practice-app, deployment practice-app-frontend)."
grader  = "command"

  [[tasks.accept]]
  verb      = "rollout-history"
  resource  = "deployment"
  namespace = "practice-app"
  name      = "practice-app-frontend"

  [[tasks.accept]]
  verb      = "get"
  resource  = "deployment"
  namespace = "practice-app"
  name      = "practice-app-frontend"

  [[tasks.hints]]
  when = "missing-namespace"
  text = "The app is not in the default namespace. Every command in this drill needs -n practice-app."

  [[tasks.hints]]
  when = "wrong-resource"
  text = "You are looking at pods. Rollout history belongs to the Deployment that owns them, not to the pods."

  [tasks.answer]
  pre = [
    "kubectl -n practice-app rollout history deploy/practice-app-frontend",
    "kubectl -n practice-app get deploy practice-app-frontend -o jsonpath='{.spec.template.spec.containers[0].image}'",
  ]
  prose = "Rollout history is owned by the Deployment. A fresh install shows revision 1 only, which is why task 3 needs an actual change before there is anything to roll back to."

# ---------------------------------------------------------------------------
[[tasks]]
id             = "2"
prompt         = "Bump the frontend image tag in helm/practice-app/values.yaml (1.27-alpine -> 1.28-alpine) and deploy."
grader         = "file"
path           = "helm/practice-app/values.yaml"
key            = "frontend.image.tag"
accept_pattern = "^1\\.28-alpine$"

  [[tasks.hints]]
  when = "unchanged"
  text = "values.yaml still says 1.27-alpine. Edit it in the editor panel - autosave writes to the workspace, but Argo only sees it once you commit."

  [[tasks.hints]]
  when = "uncommitted"
  text = "The file is right but the change is not committed, so cluster git has not changed and Argo has nothing to sync. Commit, then sync."

  [tasks.answer]
  pre = [
    "# values.yaml: frontend.image.tag: 1.28-alpine",
    "git add helm/practice-app/values.yaml && git commit -m 'bump frontend to 1.28-alpine'",
  ]
  prose = "Editing the file is not the deploy. Autosave puts it on disk, the commit publishes it to cluster git, and only then does Argo have something to converge on. That gap is the whole GitOps lesson."

# ---------------------------------------------------------------------------
[[tasks]]
id           = "3"
prompt       = "Watch the rolling update live. What is the default surge/unavailable behaviour of a Deployment?"
grader       = "prose"
must_include = ["25", "maxSurge", "maxUnavailable"]

  [[tasks.hints]]
  when = "no-numbers"
  text = "Name the actual defaults, not just the field names. kubectl explain deployment.spec.strategy.rollingUpdate has them."

  [tasks.answer]
  pre  = ["kubectl -n practice-app rollout status deploy/practice-app-frontend"]
  prose = "RollingUpdate with 25% maxSurge and 25% maxUnavailable. With readiness probes set, requests should not fail during the roll."

# ---------------------------------------------------------------------------
[[tasks]]
id     = "4"
prompt = "Curl the app in a loop during the rollout. Did any request fail?"
grader = "command"

  [[tasks.accept]]
  verb = "curl-loop"

  [[tasks.accept]]
  verb      = "port-forward"
  resource  = "service"
  namespace = "practice-app"

  [[tasks.hints]]
  when = "no-loop"
  text = "One curl proves nothing - the whole question is whether any request in a stream fails. Put it in a while loop."

  [tasks.answer]
  pre = [
    "kubectl -n practice-app port-forward svc/practice-app-frontend 8081:80",
    "while true; do curl -so /dev/null -w '%{http_code}\\n' localhost:8081; sleep .3; done",
  ]
  prose = "No failures, because readiness gates the new pods and maxUnavailable keeps enough old ones serving. A missing or wrong readiness probe is exactly what turns this into dropped requests, which is scenario 10's break/fix."

# ---------------------------------------------------------------------------
[[tasks]]
id     = "5"
prompt = "Roll back two ways: kubectl rollout undo, and the GitOps way. When would the first bite you in a GitOps shop?"
grader = "command"

  [[tasks.accept]]
  verb      = "rollout-undo"
  resource  = "deployment"
  namespace = "practice-app"
  name      = "practice-app-frontend"

  [[tasks.accept]]
  verb = "git-revert"

  [[tasks.hints]]
  when = "only-imperative"
  text = "That is the fast way. Now do it the way that survives the next sync - the cluster is not the source of truth here."

  [tasks.answer]
  pre = [
    "kubectl -n practice-app rollout undo deploy/practice-app-frontend   # fast, imperative",
    "git revert <commit> && git push                                     # the GitOps way",
  ]
  prose = "rollout undo in a GitOps shop is a trap: Argo CD sees drift and puts the bad version back, immediately with self-heal on and at the next sync without it. Git must be reverted for the rollback to stick."

# ---------------------------------------------------------------------------
[[tasks]]
id             = "6"
prompt         = "Bonus: set a bad tag (1.99-alpine), deploy, and watch what a stuck rollout looks like. Then fix it."
grader         = "prose"
must_include   = ["ImagePullBackOff"]

  [[tasks.hints]]
  when = "no-signature"
  text = "Name the pod status you saw. That string is the signature you will pattern-match on for the rest of your career."

  [tasks.answer]
  prose = "With a bad tag you get ImagePullBackOff. The rollout waits forever on unready new pods while the old pods keep serving, which is maxUnavailable protecting you. Fix the tag or kubectl rollout undo."
```

- [ ] **Step 4: Write the loader**

Create `scripts/answers.py`:

```python
#!/usr/bin/env python3
"""Load and validate a scenario's answers TOML.

The TOML is the single source of truth for a scenario: scripts/gen-answers.py
renders it into PRACTICE_ANSWERS.html, and the drill GUI grades against it.
Validation is strict on purpose - a typo here silently degrades grading, which
is worse than a loud failure at generation time.

Stdlib only (tomllib), matching scripts/bootstrap.py.
"""
from __future__ import annotations

import tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ANSWERS_DIR = REPO / "scenarios" / "answers"

SCHEMA_VERSION = 1
GRADERS = ("command", "file", "prose")
TOP_LEVEL_STR = ("scenario", "title", "time", "needs", "ticket")


class AnswersError(Exception):
    """Raised when an answers file is missing, unparseable, or invalid."""


def available() -> list[str]:
    """Scenario numbers that have an answers TOML, sorted."""
    if not ANSWERS_DIR.is_dir():
        return []
    return sorted(p.stem for p in ANSWERS_DIR.glob("*.toml"))


def load(scenario: str) -> dict:
    """Load and validate scenarios/answers/<scenario>.toml."""
    path = ANSWERS_DIR / f"{scenario}.toml"
    if not path.is_file():
        raise AnswersError(f"no answers file for scenario {scenario} (looked for {path})")
    return load_path(path)


def load_path(path: Path) -> dict:
    """Load and validate an answers TOML at an explicit path (used by tests)."""
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise AnswersError(f"{path}: not valid TOML: {e}") from e
    _validate(data, path)
    return data


def _validate(data: dict, path: Path) -> None:
    got = data.get("schema")
    if got != SCHEMA_VERSION:
        raise AnswersError(
            f"{path}: schema is {got!r}, this loader only understands schema {SCHEMA_VERSION}"
        )

    for key in TOP_LEVEL_STR:
        if not isinstance(data.get(key), str) or not data[key].strip():
            raise AnswersError(f"{path}: top-level '{key}' must be a non-empty string")

    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise AnswersError(f"{path}: needs a non-empty [[tasks]] array")

    seen: set[str] = set()
    for i, task in enumerate(tasks):
        where = f"{path}: tasks[{i}]"
        tid = task.get("id")
        if not isinstance(tid, str) or not tid.strip():
            raise AnswersError(f"{where}: 'id' must be a non-empty string")
        if tid in seen:
            raise AnswersError(f"{path}: duplicate task id {tid!r}")
        seen.add(tid)

        if not isinstance(task.get("prompt"), str) or not task["prompt"].strip():
            raise AnswersError(f"{where} (id {tid}): 'prompt' must be a non-empty string")

        grader = task.get("grader")
        if grader not in GRADERS:
            raise AnswersError(
                f"{where} (id {tid}): unknown grader {grader!r}, expected one of {GRADERS}"
            )
        _validate_grader(task, grader, f"{where} (id {tid})")
        _validate_hints(task, f"{where} (id {tid})")


def _validate_grader(task: dict, grader: str, where: str) -> None:
    if grader == "command":
        accept = task.get("accept")
        if not isinstance(accept, list) or not accept:
            raise AnswersError(f"{where}: a 'command' task needs a non-empty [[tasks.accept]] array")
        for j, acc in enumerate(accept):
            if not isinstance(acc.get("verb"), str) or not acc["verb"].strip():
                raise AnswersError(f"{where}: accept[{j}] needs a non-empty 'verb'")
    elif grader == "file":
        for key in ("path", "key", "accept_pattern"):
            if not isinstance(task.get(key), str) or not task[key].strip():
                raise AnswersError(f"{where}: a 'file' task needs a non-empty '{key}'")
    elif grader == "prose":
        must = task.get("must_include")
        if not isinstance(must, list) or not must:
            raise AnswersError(f"{where}: a 'prose' task needs a non-empty 'must_include' list")
        for j, item in enumerate(must):
            if not isinstance(item, str) or not item.strip():
                raise AnswersError(f"{where}: must_include[{j}] must be a non-empty string")


def _validate_hints(task: dict, where: str) -> None:
    hints = task.get("hints", [])
    if not isinstance(hints, list):
        raise AnswersError(f"{where}: 'hints' must be an array of tables")
    for j, hint in enumerate(hints):
        for key in ("when", "text"):
            if not isinstance(hint.get(key), str) or not hint[key].strip():
                raise AnswersError(f"{where}: hints[{j}] needs a non-empty '{key}'")
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `python3 tests/test_answers.py`
Expected: PASS on all assertions, ending `answers: 11 passed, 0 failed`.

- [ ] **Step 6: Create the shared invalid-TOML fixtures**

The TOML is read by two validators in two languages: this one, and `drill/server/src/grader/answers.ts` in Task 2.4.
Two implementations of one ruleset drift, and when they drift a file passes generation and fails grading, which is the worst of both.
The fix is one fixture set that both must reject, so drift becomes a test failure instead of a support ticket.

Create `tests/fixtures/answers-invalid/`, one file per rule, each named after the rule it breaks:

```
tests/fixtures/answers-invalid/
  schema-too-new.toml        # schema = 2
  no-tasks.toml              # valid header, no [[tasks]]
  unknown-grader.toml        # grader = "vibes"
  duplicate-task-id.toml     # two tasks with id = "1"
  command-without-accept.toml
  command-accept-without-verb.toml
  file-without-key.toml
  prose-without-must-include.toml
  hint-without-text.toml
  empty-title.toml
```

Each file is a minimal valid document with exactly one thing wrong, so a rejection can only be caused by the rule under test.
For example `tests/fixtures/answers-invalid/unknown-grader.toml`:

```toml
schema   = 1
scenario = "99"
title    = "fixture"
time     = "x"
needs    = "x"
ticket   = "x"

[[tasks]]
id     = "1"
prompt = "p"
grader = "vibes"
```

Add the conformance test to `tests/test_answers.py`:

```python
def test_every_invalid_fixture_is_rejected():
    """The same fixtures are run through the TypeScript validator in Task 2.4.
    If one side accepts what the other rejects, the two loaders have drifted."""
    fixtures = sorted((ROOT / "tests" / "fixtures" / "answers-invalid").glob("*.toml"))
    if not fixtures:
        bad("no invalid fixtures found - the conformance set is the drift alarm")
        return
    for path in fixtures:
        try:
            answers.load_path(path)
        except answers.AnswersError:
            ok(f"{path.name} rejected")
        else:
            bad(f"{path.name} was ACCEPTED - the validator is missing a rule")
```

Register it in `main()`'s tuple alongside the others.

- [ ] **Step 7: Run it**

Run: `python3 tests/test_answers.py`
Expected: PASS, with one line per fixture. Any fixture that is accepted means the validator is missing that rule; fix the validator, not the fixture.

- [ ] **Step 8: Commit**

```bash
git add scenarios/answers/03.toml scripts/answers.py tests/test_answers.py tests/fixtures/answers-invalid/
git commit -m "feat: answers TOML schema, loader, and cross-language conformance fixtures"
```

---

### Task 1.2: Generate PRACTICE_ANSWERS.html from the TOML, mixed mode

The generator must render 03 from TOML and pass the other eleven hand-written blocks through untouched. The proof is byte-identity, tested two ways: pure passthrough must reproduce the committed file exactly, and mixed mode must leave all eleven other blocks exactly as they were.

**Files:**

- Create: `scripts/gen-answers.py`
- Test: `tests/test_gen_answers.py`
- Modify: `Makefile` (add a `answers-gen` target)
- Modify: `Makefile.test` (add `answers-check` to the `test` target)

**Interfaces:**

- Consumes: `answers.load`, `answers.available` from Task 1.1.
- Produces (`scripts/gen-answers.py`):
  - `split(html: str) -> tuple[str, dict[str, str], str]` - returns `(head, {scenario_number: full_details_block}, tail)`. Every block string includes its own `<details>` and `</details>` lines and the newline that followed it, so `head + "".join(blocks.values()) + tail == html` exactly.
  - `render(data: dict) -> str` - renders one validated answers dict into a `<details>` block matching the existing HTML shape byte-for-byte in structure: `<details>\n      <summary>\n        <h2 style="display: inline">NN - Title</h2>\n      </summary>\n ... </details>\n`.
  - `generate(html: str, scenarios: list[str]) -> str` - replaces each named scenario's block with `render(load(n))`, leaves the rest untouched, returns the whole document.
  - CLI: `python3 scripts/gen-answers.py` rewrites `PRACTICE_ANSWERS.html` in place; `--check` exits 1 with a diff if the file is stale; `--stdout` prints without writing.

- [ ] **Step 1: Write the failing test**

Create `tests/test_gen_answers.py`:

```python
#!/usr/bin/env python3
"""Tests for scripts/gen-answers.py.

The contract that matters: generating with NO scenarios must reproduce the
committed PRACTICE_ANSWERS.html byte-for-byte, and generating scenario 03 must
leave the other eleven blocks byte-for-byte unchanged. If either breaks, the
generator is rewriting hand-authored prose it was never asked to touch.

Run: python3 tests/test_gen_answers.py
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("gen_answers", ROOT / "scripts" / "gen-answers.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

HTML = (ROOT / "PRACTICE_ANSWERS.html").read_text(encoding="utf-8")

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  PASS  {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")


def test_split_is_lossless():
    head, blocks, tail = gen.split(HTML)
    rebuilt = head + "".join(blocks[k] for k in sorted(blocks)) + tail
    if rebuilt == HTML:
        ok("split() round-trips byte-for-byte")
    else:
        bad(f"split() lost data: {len(rebuilt)} chars vs {len(HTML)}")


def test_split_finds_twelve():
    _, blocks, _ = gen.split(HTML)
    want = {f"{i:02d}" for i in range(1, 13)}
    if set(blocks) == want:
        ok("split() found all twelve scenario blocks")
    else:
        bad(f"split() found {sorted(blocks)}, wanted {sorted(want)}")


def test_passthrough_is_identical():
    out = gen.generate(HTML, [])
    if out == HTML:
        ok("generate() with no scenarios is byte-identical")
    else:
        bad("generate() with no scenarios changed the file")


def test_mixed_leaves_others_untouched():
    out = gen.generate(HTML, ["03"])
    _, before, _ = gen.split(HTML)
    _, after, _ = gen.split(out)
    changed = [k for k in sorted(before) if before[k] != after.get(k)]
    if changed == ["03"]:
        ok("generating 03 changed only the 03 block")
    else:
        bad(f"generating 03 also changed: {[c for c in changed if c != '03']}")


def test_head_and_tail_survive_generation():
    out = gen.generate(HTML, ["03"])
    head_b, _, tail_b = gen.split(HTML)
    head_a, _, tail_a = gen.split(out)
    if head_a == head_b and tail_a == tail_b:
        ok("head (styles, seal) and tail (script) are untouched")
    else:
        bad("generation modified the document head or tail")


def test_rendered_block_is_serveable():
    """serve-answers.sh greps for '<h2[^>]*>NN - ' to scope to one card."""
    out = gen.generate(HTML, ["03"])
    _, blocks, _ = gen.split(out)
    if '<h2 style="display: inline">03 - ' in blocks["03"]:
        ok("rendered 03 block still matches the serve-answers.sh awk pattern")
    else:
        bad("rendered 03 block would break `make serve-answers N=03`")


def test_rendered_block_contains_the_answers():
    out = gen.generate(HTML, ["03"])
    _, blocks, _ = gen.split(out)
    body = blocks["03"]
    for needle in ("rollout history", "1.28-alpine", "rollout undo", "ImagePullBackOff"):
        if needle in body:
            ok(f"rendered 03 contains {needle!r}")
        else:
            bad(f"rendered 03 is missing {needle!r}")


def test_html_is_escaped():
    """Angle brackets from the TOML must not become live markup."""
    out = gen.generate(HTML, ["03"])
    _, blocks, _ = gen.split(out)
    if "&lt;commit&gt;" in blocks["03"]:
        ok("angle brackets in answers are HTML-escaped")
    else:
        bad("'<commit>' was not escaped - the generator emits raw markup")


def main():
    for fn in (
        test_split_is_lossless,
        test_split_finds_twelve,
        test_passthrough_is_identical,
        test_mixed_leaves_others_untouched,
        test_head_and_tail_survive_generation,
        test_rendered_block_is_serveable,
        test_rendered_block_contains_the_answers,
        test_html_is_escaped,
    ):
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"gen-answers: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 tests/test_gen_answers.py`
Expected: FAIL with `FileNotFoundError` on `scripts/gen-answers.py`.

- [ ] **Step 3: Write the generator**

Create `scripts/gen-answers.py`:

```python
#!/usr/bin/env python3
"""Generate PRACTICE_ANSWERS.html from per-scenario answers TOML.

MIXED MODE ON PURPOSE. Scenarios with a file in scenarios/answers/ are rendered
from it; every other scenario's hand-written block is passed through byte-for-byte.
That is what lets the twelve cards migrate one at a time instead of in a big bang.

  python3 scripts/gen-answers.py            # rewrite PRACTICE_ANSWERS.html in place
  python3 scripts/gen-answers.py --check    # exit 1 if the file is stale (CI / make test)
  python3 scripts/gen-answers.py --stdout   # print, do not write

Stdlib only. The hand-written blocks are the reason this is a surgical splice
rather than a template render: regenerating the whole document from scratch would
mean re-authoring eleven scenarios' worth of prose that is already correct.
"""
from __future__ import annotations

import difflib
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import answers  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
TARGET = REPO / "PRACTICE_ANSWERS.html"

# Matches a whole <details>...</details> block and captures the scenario number
# out of its summary heading. DOTALL because blocks span many lines; non-greedy
# so consecutive blocks do not get swallowed into one.
BLOCK_RE = re.compile(
    r"[ \t]*<details>.*?<h2[^>]*>(\d{2}) - .*?</details>\n",
    re.DOTALL,
)


def split(doc: str) -> tuple[str, dict[str, str], str]:
    """Split into (head, {number: block}, tail). Lossless: the parts reassemble exactly."""
    blocks: dict[str, str] = {}
    spans: list[tuple[int, int]] = []
    for m in BLOCK_RE.finditer(doc):
        blocks[m.group(1)] = m.group(0)
        spans.append((m.start(), m.end()))
    if not spans:
        return doc, {}, ""
    head = doc[: spans[0][0]]
    tail = doc[spans[-1][1] :]
    # Anything between blocks (blank lines) belongs to the preceding block so the
    # round-trip stays exact. The regex already consumes the trailing newline.
    for (prev_start, prev_end), (next_start, _) in zip(spans, spans[1:]):
        gap = doc[prev_end:next_start]
        if gap:
            num = next(k for k, v in blocks.items() if v == doc[prev_start:prev_end])
            blocks[num] = blocks[num] + gap
    return head, blocks, tail


def _esc(text: str) -> str:
    return html.escape(text, quote=False)


def render(data: dict) -> str:
    """Render one validated answers dict into a <details> block."""
    out: list[str] = []
    out.append("    <details>\n")
    out.append("      <summary>\n")
    out.append(f'        <h2 style="display: inline">{_esc(data["scenario"])} - {_esc(data["title"])}</h2>\n')
    out.append("      </summary>\n")

    for task in data["tasks"]:
        ans = task.get("answer", {})
        pre = ans.get("pre", [])
        prose = ans.get("prose", "")
        out.append(f'      <h3>{_esc(task["id"])}. {_esc(task["prompt"])}</h3>\n')
        if pre:
            body = "\n".join(_esc(line) for line in pre)
            out.append(f"      <pre>\n{body}</pre>\n")
        if prose:
            out.append(f"      <p>{_esc(prose)}</p>\n")

    out.append("    </details>\n")
    return "".join(out)


def generate(doc: str, scenarios: list[str]) -> str:
    """Replace the named scenarios' blocks with rendered ones; leave the rest alone."""
    head, blocks, tail = split(doc)
    for num in scenarios:
        if num not in blocks:
            raise answers.AnswersError(f"scenario {num} has an answers file but no block in {TARGET.name}")
        trailing = blocks[num][len(blocks[num].rstrip("\n")) :]
        blocks[num] = render(answers.load(num)).rstrip("\n") + trailing
    return head + "".join(blocks[k] for k in sorted(blocks)) + tail


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else ""
    doc = TARGET.read_text(encoding="utf-8")
    out = generate(doc, answers.available())

    if mode == "--stdout":
        sys.stdout.write(out)
        return 0
    if mode == "--check":
        if out == doc:
            print(f"gen-answers: {TARGET.name} is up to date")
            return 0
        diff = difflib.unified_diff(
            doc.splitlines(keepends=True),
            out.splitlines(keepends=True),
            fromfile=f"{TARGET.name} (committed)",
            tofile=f"{TARGET.name} (generated)",
        )
        sys.stdout.writelines(diff)
        print(f"\ngen-answers: {TARGET.name} is STALE - run `make answers-gen`", file=sys.stderr)
        return 1

    if out == doc:
        print(f"gen-answers: {TARGET.name} already up to date")
        return 0
    TARGET.write_text(out, encoding="utf-8")
    print(f"gen-answers: rewrote {TARGET.name} from {', '.join(answers.available())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 tests/test_gen_answers.py`
Expected: PASS on all assertions. If `test_split_is_lossless` fails, the gap-handling in `split()` is wrong for this document and must be fixed before anything else, because every other guarantee depends on it.

- [ ] **Step 5: Regenerate and inspect the diff by hand**

```bash
python3 scripts/gen-answers.py --check
```

Expected: a diff limited to the 03 block. Read it. The generated 03 block will differ from the hand-written one in structure, because the TOML carries per-task headings the hand-written block did not have. That is the intended improvement, but confirm nothing was lost:

```bash
python3 scripts/gen-answers.py --stdout | python3 -c "
import sys, importlib.util, pathlib
spec = importlib.util.spec_from_file_location('g', 'scripts/gen-answers.py')
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
_, b, _ = g.split(sys.stdin.read())
print(b['03'])"
```

- [ ] **Step 6: Write the file and verify serve-answers still scopes**

```bash
python3 scripts/gen-answers.py
bash scripts/serve-answers.sh 03 &
sleep 2 && curl -s "http://localhost:${PORT:-8000}" | grep -c '<details>'
kill %1
```

Expected: exactly `1`. This confirms the awk scoper in `scripts/serve-answers.sh` still matches the generated block, which is the only external consumer of the HTML's shape.

- [ ] **Step 7: Add the Makefile targets**

In `Makefile`, add `answers-gen` to `.PHONY` and add the target after `serve-answers`:

```makefile
answers-gen: ## Regenerate PRACTICE_ANSWERS.html from scenarios/answers/*.toml
	$(PYTHON) scripts/gen-answers.py
```

In `Makefile.test`, add `answers-check` to `.PHONY`, add it to the `test` target's prerequisites, and add:

```makefile
answers-check: ## Fail if PRACTICE_ANSWERS.html is stale vs scenarios/answers/*.toml
	python3 scripts/gen-answers.py --check
	python3 tests/test_answers.py
	python3 tests/test_gen_answers.py
```

The `test` line becomes:

```makefile
test: fmt-check validate helm-lint history-scrubber answers-check ## Static checks (terraform + chart + answers; helm via Podman)
```

- [ ] **Step 8: Run the full static suite**

Run: `make -f Makefile.test test`
Expected: PASS. This is now the gate that makes card/answers/HTML drift impossible for any ported scenario.

- [ ] **Step 9: Commit**

```bash
git add scripts/gen-answers.py tests/test_gen_answers.py PRACTICE_ANSWERS.html Makefile Makefile.test
git commit -m "feat: generate the scenario 03 answer block from TOML, mixed mode"
```

---

## Phase 2: The grader

Pure functions over strings and files. No cluster, no AWS, no network. This is where the drill actually decides whether you were right, and it is deliberately built and tested before anything can call it.

### Task 2.1: The TypeScript workspace, in Podman

**Files:**

- Create: `drill/package.json`, `drill/tsconfig.base.json`, `drill/.gitignore`
- Create: `drill/shared/package.json`, `drill/shared/tsconfig.json`, `drill/shared/src/index.ts`
- Create: `drill/server/package.json`, `drill/server/tsconfig.json`, `drill/server/src/index.ts`
- Create: `drill/README.md`
- Modify: `Makefile.test` (add `drill-install`, `drill-test`, `drill-build`)
- Modify: `.gitignore`

**Interfaces:**

- Consumes: nothing.
- Produces:
  - npm workspaces rooted at `drill/`, with `@drill/shared` and `@drill/server`.
  - `make -f Makefile.test drill-test` runs `npm test` for every workspace inside Podman.
  - `drill/shared/src/index.ts` exports the websocket protocol types every later task adds to.

- [ ] **Step 1: Add git-ignore entries before creating anything**

Append to `.gitignore`:

```
# ---- drill GUI (node) ----
drill/**/node_modules/
drill/**/dist/
drill/**/.vite/
drill/**/*.tsbuildinfo
```

- [ ] **Step 2: Create the workspace root**

`drill/package.json`:

```json
{
  "name": "drill",
  "private": true,
  "type": "module",
  "workspaces": ["shared", "server", "web"],
  "engines": { "node": ">=20" },
  "scripts": {
    "build": "npm run build --workspaces --if-present",
    "test": "npm run test --workspaces --if-present",
    "typecheck": "npm run typecheck --workspaces --if-present"
  }
}
```

`drill/tsconfig.base.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "bundler",
    "lib": ["ES2022"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "exactOptionalPropertyTypes": true,
    "declaration": true,
    "sourceMap": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  }
}
```

`drill/README.md`:

````markdown
# drill - the in-cluster drill GUI

The mothership. One long-lived pod that serves the terminal, the editor, the
answers panel and the help panel, and is the only surface a drill is run from.

## Layout

| Workspace | What                                                                                                                  |
| --------- | --------------------------------------------------------------------------------------------------------------------- |
| `shared/` | The websocket protocol types. Imported by both ends, so a mismatch is a compile error rather than a runtime surprise. |
| `server/` | Fastify. Serves the built web app, the PTY websocket, the grader, and the reverse proxy to Argo CD and Grafana.       |
| `web/`    | React + Vite. xterm.js terminal, Monaco editor, answers and help panels.                                              |

## Running it

Node never runs on the host - everything goes through Podman, per
`.claude/skills/container-sandbox/SKILL.md`.

```bash
make -f Makefile.test drill-install    # npm install, in a container
make -f Makefile.test drill-test       # unit tests, in a container
make -f Makefile.test drill-dev        # Vite dev server on a probed port (this is the visual)
```
````

## Why TypeScript on both ends

The websocket carries a real protocol - terminal bytes, resize events, grader
verdicts, file saves, sync status - and the two ends are written months apart.
Shared types turn a protocol mismatch into a compile error.

````

- [ ] **Step 3: Create the shared protocol package**

`drill/shared/package.json`:

```json
{
  "name": "@drill/shared",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "scripts": {
    "build": "tsc -b",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": { "typescript": "^5.6.0" }
}
````

`drill/shared/tsconfig.json`:

```json
{
  "extends": "../tsconfig.base.json",
  "compilerOptions": { "outDir": "dist", "rootDir": "src", "composite": true },
  "include": ["src"]
}
```

`drill/shared/src/index.ts`:

```typescript
/**
 * The websocket protocol between the drill GUI's browser half and its server half.
 *
 * Both ends import these types, so adding a message without handling it is a
 * compile error rather than a runtime surprise. Every message is a discriminated
 * union on `type`.
 */

/** Which grader a task uses. Mirrors the `grader` key in scenarios/answers/*.toml. */
export type GraderKind = "command" | "file" | "prose";

/** The result of grading one submission. */
export interface Verdict {
  taskId: string;
  passed: boolean;
  /** Shown to the user. On failure this is the hint, keyed to the misconception. */
  message: string;
  /** Which hint fired, if any. Useful for telling "wrong" from "wrong in a known way". */
  hint?: string;
}

/** Browser -> server. */
export type ClientMessage =
  | { type: "term:input"; data: string }
  | { type: "term:resize"; cols: number; rows: number }
  | { type: "file:save"; path: string; content: string }
  | { type: "submit"; taskId: string; answer: string }
  | { type: "hint:request"; taskId: string };

/** Server -> browser. */
export type ServerMessage =
  | { type: "term:output"; data: string }
  | { type: "verdict"; verdict: Verdict }
  | { type: "session"; state: SessionState }
  | { type: "deps"; deps: DependencyStatus[] }
  | { type: "error"; message: string };

/** One link in the startup dependency chain, surfaced in the GUI's status view. */
export interface DependencyStatus {
  name: "cluster-git" | "argocd" | "practice-app";
  state: "ready" | "starting" | "waiting" | "absent";
  detail: string;
}

/** Live drill state. Mirrored into the drill-state ConfigMap. */
export interface SessionState {
  scenario: string;
  sessionId: string;
  startedAt: string;
  currentTaskId: string;
  passed: string[];
  attempts: Attempt[];
}

/** One submission. Append-only: nothing here is ever rewritten or deleted. */
export interface Attempt {
  taskId: string;
  at: string;
  submitted: string;
  passed: boolean;
  message: string;
}
```

- [ ] **Step 4: Create the server package stub**

`drill/server/package.json`:

```json
{
  "name": "@drill/server",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -b",
    "test": "node --test --experimental-strip-types 'src/**/*.test.ts'",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@drill/shared": "*",
    "smol-toml": "^1.3.0",
    "yaml": "^2.5.0"
  },
  "devDependencies": {
    "@types/node": "^20.16.0",
    "typescript": "^5.6.0"
  }
}
```

`drill/server/tsconfig.json`:

```json
{
  "extends": "../tsconfig.base.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src",
    "types": ["node"]
  },
  "references": [{ "path": "../shared" }],
  "include": ["src"]
}
```

`drill/server/src/index.ts`:

```typescript
/** Entry point. Fastify wiring lands in Phase 5; this keeps the workspace buildable. */
export const VERSION = "0.0.0";
```

- [ ] **Step 5: Add the Podman-backed Makefile targets**

In `Makefile.test`, add `drill-install drill-test drill-build drill-typecheck` to `.PHONY`, and add:

```makefile
# Node runs inside Podman - nothing is installed on the host.
NODE_IMAGE := docker.io/node:20-alpine
NODE       := podman run --rm --userns=keep-id -v $(CURDIR)/drill:/app:Z -w /app $(NODE_IMAGE)

drill-install: ## npm install for the drill workspaces (inside Podman)
	$(NODE) npm install

drill-typecheck: ## tsc --noEmit across the drill workspaces (inside Podman)
	$(NODE) npm run typecheck

drill-test: ## Unit tests for the drill workspaces (inside Podman)
	$(NODE) npm test

drill-build: ## Build the drill workspaces (inside Podman)
	$(NODE) npm run build
```

- [ ] **Step 6: Verify the workspace installs and typechecks**

```bash
make -f Makefile.test drill-install
make -f Makefile.test drill-typecheck
```

Expected: install completes and typecheck is clean. If Podman complains about `--userns=keep-id`, drop that flag and re-run; note it in `drill/README.md` if so.

- [ ] **Step 7: Commit**

```bash
git add drill/ Makefile.test .gitignore
git commit -m "feat: drill TypeScript workspace and shared protocol types"
```

---

### Task 2.2: Alias expansion

The user's shell aliases (`k`, `kg`, `kgp`, `kgn`, `kgs`, `kd`, `kl`, `kaf`, `kp`) must be expanded before anything is parsed, or a correct answer typed the way the user actually types it grades as wrong.

**Files:**

- Create: `drill/server/src/grader/aliases.ts`
- Test: `drill/server/src/grader/aliases.test.ts`

**Interfaces:**

- Consumes: nothing.
- Produces:
  - `export const ALIASES: Readonly<Record<string, string>>` - the alias table.
  - `export function expandAliases(command: string): string` - expands the leading word only, recursively, capped at 8 rounds. Returns the input unchanged when the first word is not an alias. Preserves the rest of the command verbatim, including quoting and pipes.

- [ ] **Step 1: Write the failing test**

Create `drill/server/src/grader/aliases.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { expandAliases } from "./aliases.ts";

test("expands a bare alias", () => {
  assert.equal(expandAliases("kgp"), "kubectl get pods");
});

test("expands and keeps the rest of the command verbatim", () => {
  assert.equal(
    expandAliases("kgp -n practice-app -o wide"),
    "kubectl get pods -n practice-app -o wide",
  );
});

test("leaves a non-alias untouched", () => {
  assert.equal(
    expandAliases("helm upgrade practice-app ."),
    "helm upgrade practice-app .",
  );
});

test("leaves a full kubectl command untouched", () => {
  const cmd =
    "kubectl -n practice-app rollout undo deploy/practice-app-frontend";
  assert.equal(expandAliases(cmd), cmd);
});

test("expands k, the shortest alias, without touching a word that starts with k", () => {
  assert.equal(expandAliases("k get pods"), "kubectl get pods");
  assert.equal(expandAliases("kustomize build ."), "kustomize build .");
});

test("preserves quoting and pipes in the tail", () => {
  assert.equal(
    expandAliases(`kg deploy -o jsonpath='{.items[0].spec}' | jq .`),
    `kubectl get deploy -o jsonpath='{.items[0].spec}' | jq .`,
  );
});

test("tolerates leading and repeated whitespace", () => {
  assert.equal(
    expandAliases("   kgp    -n  practice-app"),
    "kubectl get pods    -n  practice-app",
  );
});

test("expands recursively but terminates on a cycle", () => {
  // A malformed table must not hang the server; the cap is the guarantee.
  assert.doesNotThrow(() => expandAliases("kgp"));
});

test("empty input is empty output", () => {
  assert.equal(expandAliases(""), "");
  assert.equal(expandAliases("   "), "   ");
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make -f Makefile.test drill-test`
Expected: FAIL with `Cannot find module './aliases.ts'`.

- [ ] **Step 3: Write the implementation**

Create `drill/server/src/grader/aliases.ts`:

```typescript
/**
 * Shell alias expansion, run before any command is parsed.
 *
 * Without this, a correct answer typed the way the user actually types it
 * ("kgp -n practice-app") grades as wrong, which teaches nothing except that
 * the grader is brittle. The table mirrors the aliases in the user's shell rc.
 */

export const ALIASES: Readonly<Record<string, string>> = Object.freeze({
  k: "kubectl",
  kg: "kubectl get",
  kgp: "kubectl get pods",
  kgn: "kubectl get nodes",
  kgs: "kubectl get svc",
  kd: "kubectl describe",
  kl: "kubectl logs",
  kaf: "kubectl apply -f",
  kp: "kubectl port-forward",
});

/** Guard against a cyclic table. Real expansion never needs more than one round. */
const MAX_ROUNDS = 8;

/**
 * Expand the leading word if it is an alias, leaving the rest byte-identical.
 *
 * Only the first word is considered, matching how shells expand aliases, so a
 * literal "kgp" appearing later in the command (a pod name, a jsonpath) is safe.
 */
export function expandAliases(command: string): string {
  let current = command;
  for (let round = 0; round < MAX_ROUNDS; round++) {
    const match = /^(\s*)(\S+)(.*)$/s.exec(current);
    if (!match) return current;
    const [, lead, head, tail] = match as unknown as [
      string,
      string,
      string,
      string,
    ];
    const replacement = ALIASES[head];
    if (replacement === undefined) return current;
    const next = `${lead}${replacement}${tail}`;
    if (next === current) return current;
    current = next;
  }
  return current;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make -f Makefile.test drill-test`
Expected: PASS, 9 tests.

- [ ] **Step 5: Tell the user about their broken alias**

Their shell rc contains `alias kd='kubectl describe'0` - the stray trailing `0` makes `kd` expand to `kubectl describe0`. The grader's table is correct; their shell is not. Mention it, do not silently encode the typo.

- [ ] **Step 6: Commit**

```bash
git add drill/server/src/grader/aliases.ts drill/server/src/grader/aliases.test.ts
git commit -m "feat: kubectl alias expansion for the grader"
```

---

### Task 2.3: Semantic command parsing

A regex over the raw string grades `kubectl get deploy -n practice-app` and `kubectl -n practice-app get deployment` differently, which is wrong. Parse into a canonical shape instead, then compare shapes.

**Files:**

- Create: `drill/server/src/grader/parse.ts`
- Test: `drill/server/src/grader/parse.test.ts`

**Interfaces:**

- Consumes: `expandAliases` from Task 2.2.
- Produces:
  - `export interface ParsedCommand { tool: string; verb: string; resource?: string; name?: string; namespace?: string; allNamespaces: boolean; flags: Record<string, string | true>; raw: string; }`
  - `export function parseCommand(input: string): ParsedCommand` - expands aliases, then parses. Normalises resource aliases (`deploy`/`deployments` -> `deployment`, `po`/`pods` -> `pod`, `svc`/`services` -> `service`, `ns` -> `namespace`, `cm` -> `configmap`, `sts` -> `statefulset`, `ds` -> `daemonset`, `ing` -> `ingress`). Splits `deploy/name` into `resource` plus `name`. Recognises `-n`, `--namespace`, `-A`, `--all-namespaces`. Collapses the two-word verbs `rollout history`, `rollout undo`, `rollout status`, `rollout restart` into `rollout-history` etc.
  - `export function normaliseResource(word: string): string`
  - Non-kubectl input is still parsed: `tool` becomes `git`, `helm`, `curl` or whatever the first word is, and `verb` its second word. Shell control (`while`, `for`) sets `tool` to `shell` and `verb` to the loop keyword, which is what lets the `curl-loop` accept rule in scenario 03 task 4 work.

- [ ] **Step 1: Write the failing test**

Create `drill/server/src/grader/parse.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCommand, normaliseResource } from "./parse.ts";

test("flag order does not change the parse", () => {
  const a = parseCommand("kubectl get deploy -n practice-app");
  const b = parseCommand("kubectl -n practice-app get deployment");
  assert.equal(a.verb, b.verb);
  assert.equal(a.resource, b.resource);
  assert.equal(a.namespace, b.namespace);
  assert.equal(a.resource, "deployment");
  assert.equal(a.namespace, "practice-app");
});

test("slash form splits into resource and name", () => {
  const p = parseCommand(
    "kubectl -n practice-app rollout undo deploy/practice-app-frontend",
  );
  assert.equal(p.verb, "rollout-undo");
  assert.equal(p.resource, "deployment");
  assert.equal(p.name, "practice-app-frontend");
  assert.equal(p.namespace, "practice-app");
});

test("space form is equivalent to slash form", () => {
  const slash = parseCommand(
    "kubectl rollout history deploy/practice-app-frontend -n practice-app",
  );
  const space = parseCommand(
    "kubectl rollout history deployment practice-app-frontend -n practice-app",
  );
  assert.equal(slash.verb, space.verb);
  assert.equal(slash.resource, space.resource);
  assert.equal(slash.name, space.name);
  assert.equal(slash.verb, "rollout-history");
});

test("aliases are expanded before parsing", () => {
  const p = parseCommand("kgp -n practice-app");
  assert.equal(p.tool, "kubectl");
  assert.equal(p.verb, "get");
  assert.equal(p.resource, "pod");
  assert.equal(p.namespace, "practice-app");
});

test("--namespace long form is recognised", () => {
  assert.equal(
    parseCommand("kubectl get pods --namespace practice-app").namespace,
    "practice-app",
  );
  assert.equal(
    parseCommand("kubectl get pods --namespace=practice-app").namespace,
    "practice-app",
  );
});

test("-A sets allNamespaces and leaves namespace undefined", () => {
  const p = parseCommand("kubectl get pods -A");
  assert.equal(p.allNamespaces, true);
  assert.equal(p.namespace, undefined);
});

test("missing namespace is undefined, not a guess", () => {
  assert.equal(parseCommand("kubectl get pods").namespace, undefined);
});

test("flags are captured with and without values", () => {
  const p = parseCommand("kubectl get deploy -o wide --watch");
  assert.equal(p.flags["-o"], "wide");
  assert.equal(p.flags["--watch"], true);
});

test("git commands parse as tool git", () => {
  const p = parseCommand("git revert abc123");
  assert.equal(p.tool, "git");
  assert.equal(p.verb, "revert");
});

test("a while loop parses as shell", () => {
  const p = parseCommand(
    "while true; do curl -so /dev/null localhost:8081; sleep .3; done",
  );
  assert.equal(p.tool, "shell");
  assert.equal(p.verb, "while");
});

test("raw is preserved exactly", () => {
  const raw = "kubectl   get   pods   -n practice-app";
  assert.equal(parseCommand(raw).raw, raw);
});

test("resource normalisation covers the common short forms", () => {
  assert.equal(normaliseResource("deploy"), "deployment");
  assert.equal(normaliseResource("deployments"), "deployment");
  assert.equal(normaliseResource("po"), "pod");
  assert.equal(normaliseResource("svc"), "service");
  assert.equal(normaliseResource("ing"), "ingress");
  assert.equal(normaliseResource("widget"), "widget");
});

test("empty input does not throw", () => {
  const p = parseCommand("");
  assert.equal(p.tool, "");
  assert.equal(p.verb, "");
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make -f Makefile.test drill-test`
Expected: FAIL with `Cannot find module './parse.ts'`.

- [ ] **Step 3: Write the implementation**

Create `drill/server/src/grader/parse.ts`:

```typescript
/**
 * Parse a command into a canonical shape so grading compares meaning, not text.
 *
 * `kubectl get deploy -n practice-app` and `kubectl -n practice-app get deployment`
 * are the same command. A regex says they are different. This says they are the same,
 * which is the difference between grading understanding and grading typing.
 */
import { expandAliases } from "./aliases.ts";

export interface ParsedCommand {
  /** kubectl, git, helm, curl, shell, or whatever led the line. */
  tool: string;
  /** get, describe, rollout-history, revert, while... */
  verb: string;
  resource?: string;
  name?: string;
  namespace?: string;
  allNamespaces: boolean;
  flags: Record<string, string | true>;
  /** The input, byte for byte, for showing back to the user. */
  raw: string;
}

const RESOURCE_ALIASES: Readonly<Record<string, string>> = Object.freeze({
  deploy: "deployment",
  deployments: "deployment",
  deployment: "deployment",
  po: "pod",
  pods: "pod",
  pod: "pod",
  svc: "service",
  services: "service",
  service: "service",
  ns: "namespace",
  namespaces: "namespace",
  namespace: "namespace",
  cm: "configmap",
  configmaps: "configmap",
  configmap: "configmap",
  sts: "statefulset",
  statefulsets: "statefulset",
  statefulset: "statefulset",
  ds: "daemonset",
  daemonsets: "daemonset",
  daemonset: "daemonset",
  ing: "ingress",
  ingresses: "ingress",
  ingress: "ingress",
  rs: "replicaset",
  replicasets: "replicaset",
  replicaset: "replicaset",
  no: "node",
  nodes: "node",
  node: "node",
  hpa: "horizontalpodautoscaler",
  pvc: "persistentvolumeclaim",
  secrets: "secret",
  secret: "secret",
});

/** kubectl verbs whose meaning needs their second word. */
const TWO_WORD_VERBS = new Set([
  "rollout",
  "config",
  "auth",
  "create",
  "api-resources",
]);

/** Shell keywords that mean "this is a loop or a control structure, not a tool call". */
const SHELL_KEYWORDS = new Set(["while", "for", "until", "if"]);

/** Flags that take a value as the next word rather than after an `=`. */
const VALUE_FLAGS = new Set([
  "-n",
  "--namespace",
  "-o",
  "--output",
  "-l",
  "--selector",
  "-f",
  "--filename",
  "-c",
  "--container",
]);

export function normaliseResource(word: string): string {
  return RESOURCE_ALIASES[word.toLowerCase()] ?? word.toLowerCase();
}

export function parseCommand(input: string): ParsedCommand {
  const raw = input;
  const expanded = expandAliases(input).trim();
  const out: ParsedCommand = {
    tool: "",
    verb: "",
    allNamespaces: false,
    flags: {},
    raw,
  };
  if (!expanded) return out;

  const words = expanded.split(/\s+/);
  const first = words[0] ?? "";

  if (SHELL_KEYWORDS.has(first)) {
    out.tool = "shell";
    out.verb = first;
    return out;
  }

  out.tool = first;
  const rest = words.slice(1);

  // First pass: pull out flags, leaving positional words behind.
  const positional: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    const word = rest[i] ?? "";
    if (!word.startsWith("-")) {
      positional.push(word);
      continue;
    }
    const eq = word.indexOf("=");
    if (eq > 0) {
      out.flags[word.slice(0, eq)] = word.slice(eq + 1);
      continue;
    }
    if (VALUE_FLAGS.has(word) && i + 1 < rest.length) {
      out.flags[word] = rest[i + 1] ?? "";
      i++;
      continue;
    }
    out.flags[word] = true;
  }

  out.namespace = (out.flags["-n"] ?? out.flags["--namespace"]) as
    string | undefined;
  if (typeof out.namespace !== "string") out.namespace = undefined;
  out.allNamespaces =
    out.flags["-A"] === true || out.flags["--all-namespaces"] === true;

  // Second pass: verb, resource, name from the positional words.
  const verbWord = positional[0] ?? "";
  if (TWO_WORD_VERBS.has(verbWord) && positional[1]) {
    out.verb = `${verbWord}-${positional[1]}`;
    positional.splice(0, 2);
  } else {
    out.verb = verbWord;
    positional.splice(0, 1);
  }

  const target = positional[0];
  if (target) {
    if (target.includes("/")) {
      const [res, name] = target.split("/", 2);
      out.resource = normaliseResource(res ?? "");
      out.name = name;
    } else {
      out.resource = normaliseResource(target);
      if (positional[1]) out.name = positional[1];
    }
  }

  return out;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make -f Makefile.test drill-test`
Expected: PASS, 22 tests across both grader files.

- [ ] **Step 5: Commit**

```bash
git add drill/server/src/grader/parse.ts drill/server/src/grader/parse.test.ts
git commit -m "feat: semantic kubectl command parsing for the grader"
```

---

### Task 2.4: Grading and hints

Three graders behind one interface, plus the hint dispatch that turns "wrong" into "wrong in a known way, and here is the misconception".

**Files:**

- Create: `drill/server/src/grader/index.ts`
- Create: `drill/server/src/grader/answers.ts`
- Test: `drill/server/src/grader/index.test.ts`

**Interfaces:**

- Consumes: `parseCommand`, `ParsedCommand` from Task 2.3; `Verdict` from `@drill/shared`.
- Produces:
  - `answers.ts`: `export interface AnswerTask { id: string; prompt: string; grader: GraderKind; accept?: AcceptRule[]; hints?: Hint[]; path?: string; key?: string; accept_pattern?: string; must_include?: string[]; answer?: { pre?: string[]; prose?: string }; }`, `export interface AnswerSet { schema: number; scenario: string; title: string; time: string; needs: string; ticket: string; tasks: AnswerTask[] }`, `export interface AcceptRule { verb: string; resource?: string; namespace?: string; name?: string; flags?: Record<string, string> }`, `export interface Hint { when: string; text: string }`, and `export function loadAnswers(scenario: string, dir: string): Promise<AnswerSet>` which parses the TOML with `smol-toml` and throws on the same conditions `scripts/answers.py` rejects.
  - `index.ts`: `export function gradeCommand(task: AnswerTask, submitted: string): Verdict`, `export function gradeProse(task: AnswerTask, submitted: string): Verdict`, `export function gradeFile(task: AnswerTask, fileContent: string): Verdict`, and `export function grade(task: AnswerTask, submitted: string, fileContent?: string): Verdict` dispatching on `task.grader`.
  - Hint keys the graders can fire, matched against `Hint.when`: `missing-namespace`, `wrong-namespace`, `wrong-resource`, `wrong-name`, `no-loop`, `only-imperative`, `no-numbers`, `no-signature`, `unchanged`, `uncommitted`.

- [ ] **Step 1: Write the failing test**

Create `drill/server/src/grader/index.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { grade, gradeCommand, gradeProse, gradeFile } from "./index.ts";
import type { AnswerTask } from "./answers.ts";

const rolloutTask: AnswerTask = {
  id: "1",
  prompt: "find the rollout history",
  grader: "command",
  accept: [
    {
      verb: "rollout-history",
      resource: "deployment",
      namespace: "practice-app",
      name: "practice-app-frontend",
    },
    {
      verb: "get",
      resource: "deployment",
      namespace: "practice-app",
      name: "practice-app-frontend",
    },
  ],
  hints: [
    {
      when: "missing-namespace",
      text: "Every command in this drill needs -n practice-app.",
    },
    {
      when: "wrong-resource",
      text: "Rollout history belongs to the Deployment, not the pods.",
    },
  ],
};

test("an exactly correct command passes", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl -n practice-app rollout history deploy/practice-app-frontend",
  );
  assert.equal(v.passed, true);
  assert.equal(v.taskId, "1");
});

test("the same command written differently still passes", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl rollout history deployment practice-app-frontend --namespace=practice-app",
  );
  assert.equal(v.passed, true);
});

test("an alias form passes", () => {
  const v = gradeCommand(
    {
      ...rolloutTask,
      accept: [{ verb: "get", resource: "pod", namespace: "practice-app" }],
    },
    "kgp -n practice-app",
  );
  assert.equal(v.passed, true);
});

test("a second accept rule also passes", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl -n practice-app get deploy practice-app-frontend",
  );
  assert.equal(v.passed, true);
});

test("missing namespace fails with the namespace hint, not a bare failure", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl rollout history deploy/practice-app-frontend",
  );
  assert.equal(v.passed, false);
  assert.equal(v.hint, "missing-namespace");
  assert.match(v.message, /-n practice-app/);
});

test("wrong resource fails with the resource hint", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl -n practice-app rollout history pod/practice-app-frontend",
  );
  assert.equal(v.passed, false);
  assert.equal(v.hint, "wrong-resource");
});

test("an unrelated command fails without inventing a hint", () => {
  const v = gradeCommand(rolloutTask, "helm list -A");
  assert.equal(v.passed, false);
  assert.equal(v.hint, undefined);
});

test("a rule with no namespace accepts a command with any namespace", () => {
  const loose: AnswerTask = {
    id: "4",
    prompt: "curl loop",
    grader: "command",
    accept: [{ verb: "while" }],
  };
  assert.equal(
    gradeCommand(loose, "while true; do curl localhost:8081; done").passed,
    true,
  );
});

test("prose grading is case-insensitive and needs every term", () => {
  const task: AnswerTask = {
    id: "3",
    prompt: "surge behaviour",
    grader: "prose",
    must_include: ["25", "maxSurge", "maxUnavailable"],
    hints: [{ when: "no-numbers", text: "Name the actual defaults." }],
  };
  assert.equal(
    gradeProse(task, "RollingUpdate: 25% maxsurge and 25% maxunavailable")
      .passed,
    true,
  );
  const missing = gradeProse(
    task,
    "It rolls pods gradually using maxSurge and maxUnavailable",
  );
  assert.equal(missing.passed, false);
  assert.equal(missing.hint, "no-numbers");
  assert.match(missing.message, /Name the actual defaults/);
});

test("file grading reads a dotted key out of YAML", () => {
  const task: AnswerTask = {
    id: "2",
    prompt: "bump the tag",
    grader: "file",
    path: "helm/practice-app/values.yaml",
    key: "frontend.image.tag",
    accept_pattern: "^1\\.28-alpine$",
    hints: [{ when: "unchanged", text: "values.yaml still says 1.27-alpine." }],
  };
  const before =
    "frontend:\n  image:\n    repository: nginx\n    tag: 1.27-alpine\n";
  const after =
    "frontend:\n  image:\n    repository: nginx\n    tag: 1.28-alpine\n";
  assert.equal(gradeFile(task, after).passed, true);
  const v = gradeFile(task, before);
  assert.equal(v.passed, false);
  assert.equal(v.hint, "unchanged");
});

test("file grading reports a missing key rather than crashing", () => {
  const task: AnswerTask = {
    id: "2",
    prompt: "bump the tag",
    grader: "file",
    path: "x.yaml",
    key: "frontend.image.tag",
    accept_pattern: "^1\\.28-alpine$",
  };
  const v = gradeFile(task, "backend:\n  replicas: 1\n");
  assert.equal(v.passed, false);
  assert.match(v.message, /frontend\.image\.tag/);
});

test("file grading survives unparseable YAML", () => {
  const task: AnswerTask = {
    id: "2",
    prompt: "p",
    grader: "file",
    path: "x.yaml",
    key: "a.b",
    accept_pattern: "^c$",
  };
  const v = gradeFile(task, "\tthis: is: not: yaml:\n  - [unclosed\n");
  assert.equal(v.passed, false);
  assert.match(v.message, /could not be parsed/i);
});

test("grade() dispatches on the grader kind", () => {
  assert.equal(
    grade(
      rolloutTask,
      "kubectl -n practice-app get deploy practice-app-frontend",
    ).passed,
    true,
  );
});

test("a verdict always carries the task id", () => {
  for (const v of [
    gradeCommand(rolloutTask, "nonsense"),
    gradeProse(
      { id: "3", prompt: "p", grader: "prose", must_include: ["x"] },
      "y",
    ),
  ]) {
    assert.ok(v.taskId.length > 0);
  }
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make -f Makefile.test drill-test`
Expected: FAIL with `Cannot find module './index.ts'`.

- [ ] **Step 3: Write the answers loader**

Create `drill/server/src/grader/answers.ts`:

```typescript
/**
 * Read a scenario's answers TOML.
 *
 * The TOML is the cross-language contract: scripts/answers.py reads it to render
 * PRACTICE_ANSWERS.html and never grades; this reads it to grade and never renders.
 * The validation here mirrors scripts/answers.py deliberately - if the two drift,
 * a file can pass generation and fail grading, which is the worst of both.
 */
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { parse as parseToml } from "smol-toml";
import type { GraderKind } from "@drill/shared";

export const SCHEMA_VERSION = 1;

export interface AcceptRule {
  verb: string;
  resource?: string;
  namespace?: string;
  name?: string;
  flags?: Record<string, string>;
}

export interface Hint {
  when: string;
  text: string;
}

export interface AnswerTask {
  id: string;
  prompt: string;
  grader: GraderKind;
  accept?: AcceptRule[];
  hints?: Hint[];
  path?: string;
  key?: string;
  accept_pattern?: string;
  must_include?: string[];
  answer?: { pre?: string[]; prose?: string };
}

export interface AnswerSet {
  schema: number;
  scenario: string;
  title: string;
  time: string;
  needs: string;
  ticket: string;
  tasks: AnswerTask[];
}

export class AnswersError extends Error {}

export async function loadAnswers(
  scenario: string,
  dir: string,
): Promise<AnswerSet> {
  const path = join(dir, `${scenario}.toml`);
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch {
    throw new AnswersError(
      `no answers file for scenario ${scenario} (looked for ${path})`,
    );
  }
  let data: unknown;
  try {
    data = parseToml(text);
  } catch (e) {
    throw new AnswersError(`${path}: not valid TOML: ${(e as Error).message}`);
  }
  return validate(data as AnswerSet, path);
}

export function validate(data: AnswerSet, where: string): AnswerSet {
  if (data.schema !== SCHEMA_VERSION) {
    throw new AnswersError(
      `${where}: schema is ${data.schema}, this loader understands ${SCHEMA_VERSION}`,
    );
  }
  if (!Array.isArray(data.tasks) || data.tasks.length === 0) {
    throw new AnswersError(`${where}: needs a non-empty [[tasks]] array`);
  }
  const seen = new Set<string>();
  for (const task of data.tasks) {
    if (!task.id) throw new AnswersError(`${where}: a task has no id`);
    if (seen.has(task.id))
      throw new AnswersError(`${where}: duplicate task id ${task.id}`);
    seen.add(task.id);
    if (
      task.grader === "command" &&
      (!task.accept || task.accept.length === 0)
    ) {
      throw new AnswersError(
        `${where}: task ${task.id} is a command task with no accept rules`,
      );
    }
    if (
      task.grader === "file" &&
      (!task.path || !task.key || !task.accept_pattern)
    ) {
      throw new AnswersError(
        `${where}: task ${task.id} is a file task missing path/key/accept_pattern`,
      );
    }
    if (
      task.grader === "prose" &&
      (!task.must_include || task.must_include.length === 0)
    ) {
      throw new AnswersError(
        `${where}: task ${task.id} is a prose task with no must_include`,
      );
    }
  }
  return data;
}
```

- [ ] **Step 4: Write the graders**

Create `drill/server/src/grader/index.ts`:

```typescript
/**
 * Grading. Three kinds behind one interface.
 *
 * A failure is only useful if it names the misconception, so every grader tries to
 * classify HOW the answer was wrong and looks up a hint keyed to that. A bare
 * "incorrect" teaches nothing, which is the whole reason this is not a regex match.
 */
import type { Verdict } from "@drill/shared";
import { parse as parseYaml } from "yaml";
import {
  parseCommand,
  normaliseResource,
  type ParsedCommand,
} from "./parse.ts";
import type { AnswerTask, AcceptRule } from "./answers.ts";

export function grade(
  task: AnswerTask,
  submitted: string,
  fileContent?: string,
): Verdict {
  switch (task.grader) {
    case "command":
      return gradeCommand(task, submitted);
    case "prose":
      return gradeProse(task, submitted);
    case "file":
      return gradeFile(task, fileContent ?? "");
  }
}

function hintFor(
  task: AnswerTask,
  key: string,
): { hint?: string; message: string } | undefined {
  const hit = task.hints?.find((h) => h.when === key);
  return hit ? { hint: key, message: hit.text } : undefined;
}

function pass(task: AnswerTask, message: string): Verdict {
  return { taskId: task.id, passed: true, message };
}

function fail(
  task: AnswerTask,
  key: string | undefined,
  fallback: string,
): Verdict {
  const hinted = key ? hintFor(task, key) : undefined;
  return hinted
    ? {
        taskId: task.id,
        passed: false,
        message: hinted.message,
        hint: hinted.hint,
      }
    : { taskId: task.id, passed: false, message: fallback };
}

/** Does one parsed command satisfy one accept rule? Unset rule fields mean "do not care". */
function matches(rule: AcceptRule, cmd: ParsedCommand): boolean {
  if (rule.verb !== cmd.verb) return false;
  if (rule.resource && normaliseResource(rule.resource) !== cmd.resource)
    return false;
  if (rule.namespace && rule.namespace !== cmd.namespace) return false;
  if (rule.name && rule.name !== cmd.name) return false;
  for (const [flag, want] of Object.entries(rule.flags ?? {})) {
    if (cmd.flags[flag] !== want) return false;
  }
  return true;
}

export function gradeCommand(task: AnswerTask, submitted: string): Verdict {
  const cmd = parseCommand(submitted);
  const rules = task.accept ?? [];

  if (rules.some((r) => matches(r, cmd))) {
    return pass(task, "Correct.");
  }

  // Classify the near misses, most specific first. Only rules whose verb already
  // matched are considered, so a completely different command gets no hint rather
  // than a misleading one.
  const verbMatched = rules.filter((r) => r.verb === cmd.verb);
  for (const rule of verbMatched) {
    if (rule.namespace && cmd.namespace === undefined && !cmd.allNamespaces) {
      return fail(
        task,
        "missing-namespace",
        `Close - but which namespace? Expected -n ${rule.namespace}.`,
      );
    }
    if (
      rule.namespace &&
      cmd.namespace !== undefined &&
      cmd.namespace !== rule.namespace
    ) {
      return fail(
        task,
        "wrong-namespace",
        `Wrong namespace: you used ${cmd.namespace}, the app lives in ${rule.namespace}.`,
      );
    }
    if (rule.resource && cmd.resource !== normaliseResource(rule.resource)) {
      return fail(
        task,
        "wrong-resource",
        `Wrong resource: you asked about ${cmd.resource ?? "nothing"}, this is about a ${rule.resource}.`,
      );
    }
    if (rule.name && cmd.name !== rule.name) {
      return fail(
        task,
        "wrong-name",
        `Right idea, wrong object: expected ${rule.name}.`,
      );
    }
  }

  return fail(
    task,
    undefined,
    "Not what this task is asking for. Re-read the prompt, and try `hint` if you are stuck.",
  );
}

export function gradeProse(task: AnswerTask, submitted: string): Verdict {
  const haystack = submitted.toLowerCase();
  const missing = (task.must_include ?? []).filter(
    (term) => !haystack.includes(term.toLowerCase()),
  );
  if (missing.length === 0) return pass(task, "Correct.");

  // Give the first hint the task defines; a prose task's misconceptions are not
  // mechanically distinguishable the way a command's are.
  const key = task.hints?.[0]?.when;
  return fail(task, key, `Missing from your answer: ${missing.join(", ")}.`);
}

export function gradeFile(task: AnswerTask, fileContent: string): Verdict {
  let doc: unknown;
  try {
    doc = parseYaml(fileContent);
  } catch (e) {
    return fail(
      task,
      undefined,
      `${task.path} could not be parsed as YAML: ${(e as Error).message}`,
    );
  }

  const parts = (task.key ?? "").split(".");
  let cursor: unknown = doc;
  for (const part of parts) {
    if (cursor === null || typeof cursor !== "object") {
      cursor = undefined;
      break;
    }
    cursor = (cursor as Record<string, unknown>)[part];
  }

  if (cursor === undefined || cursor === null) {
    return fail(task, undefined, `${task.path} has no value at ${task.key}.`);
  }

  const value = String(cursor);
  if (new RegExp(task.accept_pattern ?? "").test(value)) {
    return pass(task, "Correct.");
  }
  return fail(
    task,
    "unchanged",
    `${task.key} is ${value}, which is not what this task wants.`,
  );
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `make -f Makefile.test drill-test`
Expected: PASS, 36 tests across the three grader files.

- [ ] **Step 6: Cross-check the grader against the real TOML**

The Python and TypeScript loaders must agree about what is valid. Add this check to `drill/server/src/grader/answers.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { loadAnswers } from "./answers.ts";

test("the real scenario 03 answers file loads and validates", async () => {
  const set = await loadAnswers("03", "../../scenarios/answers");
  assert.equal(set.scenario, "03");
  assert.equal(set.tasks.length, 6);
  assert.deepEqual(
    set.tasks.map((t) => t.grader),
    ["command", "file", "prose", "command", "command", "prose"],
  );
});
```

Then add the other half of the conformance set from Task 1.1, so the two validators are pinned to each other rather than merely both existing:

```typescript
import { readdir } from "node:fs/promises";
import { AnswersError } from "./answers.ts";

/**
 * The same fixtures scripts/answers.py rejects in tests/test_answers.py.
 *
 * Two implementations of one ruleset drift. When they drift, a TOML file passes
 * generation and fails grading, or worse, passes grading with a rule silently
 * unenforced. This turns that drift into a red test on whichever side moved.
 */
test("every invalid fixture is rejected here too", async () => {
  const dir = "../../tests/fixtures/answers-invalid";
  const files = (await readdir(dir)).filter((f) => f.endsWith(".toml"));
  assert.ok(
    files.length > 0,
    "no fixtures found - the conformance set is the drift alarm",
  );

  for (const file of files) {
    await assert.rejects(
      () => loadAnswers(file.replace(/\.toml$/, ""), dir),
      AnswersError,
      `${file} was ACCEPTED by the TypeScript validator but rejected by the Python one`,
    );
  }
});
```

Run: `make -f Makefile.test drill-test`
Expected: PASS, with every fixture rejected. A fixture that passes here means this validator is missing a rule `scripts/answers.py` has; add the rule, never delete the fixture.

If the path resolution fails inside the container, the mount is `/app` and the repo root is its parent, which is not mounted. Fix by mounting the repo root instead: change `NODE` in `Makefile.test` to mount `$(CURDIR)` at `/repo` with `-w /repo/drill`, and use `../scenarios/answers` and `../tests/fixtures/answers-invalid`. Do this once here; Tasks 5.1 onward assume the repo-root mount.

- [ ] **Step 7: Commit**

```bash
git add drill/server/src/grader/
git commit -m "feat: semantic grading with misconception-keyed hints"
```

---

## Phase 3: Terraform - cluster git

Everything here is verified with `terraform validate` plus a ministack plan. No AWS.

### Task 3.1: Config values and variable threading

Three new values enter the config in this phase and the next. This task adds all three at once, because threading a variable through five files is one mechanical change and splitting it across two tickets doubles the merge conflicts for no review benefit.

**Files:**

- Modify: `scripts/config.example.toml`
- Modify: `terraform/envs/dev/variables.tf`
- Modify: `terraform/envs/dev/main.tf`
- Modify: `terraform/modules/stack/variables.tf`
- Modify: `terraform/modules/stack/main.tf`
- Modify: `terraform/modules/platform/variables.tf`
- Modify: the user's `scripts/config.toml` (git-ignored; tell the user rather than editing silently if it differs from the example)

**Interfaces:**

- Consumes: nothing.
- Produces three variables available inside `terraform/modules/platform`:
  - `enable_cluster_git` (bool) - install the in-cluster git server in namespace `git`.
  - `drill_ingress_group_name` (string) - the shared `alb.ingress.kubernetes.io/group.name`, consumed in Phase 4.
  - `drill_allowed_cidrs` (list(string)) - source-IP allow list for the drill ALB, consumed in Phase 4.

- [ ] **Step 1: Add the documented values to the config template**

In `scripts/config.example.toml`, in the `# ---- platform toggles ----` block, after the `enable_monitoring` / `kube_prometheus_stack_chart_version` lines:

```toml
enable_cluster_git           = true  # in-cluster git server (ns "git") - the ONLY repo Argo CD reads; drill sessions need it
```

And add a new block after `# ---- practice app plumbing ----`:

```toml
# ---- drill platform (the in-cluster GUI: scenarios/answers, terminal, editor) ----
# One shared ALB carries every ops UI (drill GUI, Argo CD, Grafana). Sharing the
# group keeps cost flat as more UIs are added instead of one ALB per Ingress.
drill_ingress_group_name = "daily-eks-practice-ops"  # any name; all ops Ingresses must match it
# WHO CAN REACH THE DRILL GUI. This is an unauthenticated web terminal running as
# cluster-admin, so leaving it open is not a mild misconfiguration - it is a remote
# shell on your cluster.
#
# The single entry "auto" resolves to your current public /32 every time bootstrap.py
# runs, so a DHCP lease change can never silently lock you out. Prefer it.
# A literal CIDR still works and is what you want for a static IP or for CI, where
# "your IP" is not a meaningful idea.
#   drill_allowed_cidrs = ["auto"]              <- resolved at plan time
#   drill_allowed_cidrs = ["203.0.113.10/32"]   <- pinned
# Find yours with: curl -s https://checkip.amazonaws.com
drill_allowed_cidrs = ["auto"]   # generic default: ["auto"]; NEVER ["0.0.0.0/0"]
```

- [ ] **Step 2: Declare them in the env, with no defaults**

In `terraform/envs/dev/variables.tf`, matching the file's existing style:

```hcl
variable "enable_cluster_git" {
  description = "Install the in-cluster git server (namespace \"git\") that Argo CD reads from."
  type        = bool
}

variable "drill_ingress_group_name" {
  description = "Shared ALB IngressGroup name for every ops UI, so they share one load balancer."
  type        = string
}

variable "drill_allowed_cidrs" {
  description = "Source CIDRs allowed to reach the drill ALB. The GUI is an unauthenticated cluster-admin terminal; keep this to your own IP."
  type        = list(string)
}
```

- [ ] **Step 3: Pass them into the stack**

In `terraform/envs/dev/main.tf`, inside the single `module "stack"` block, add:

```hcl
  enable_cluster_git       = var.enable_cluster_git
  drill_ingress_group_name = var.drill_ingress_group_name
  drill_allowed_cidrs      = var.drill_allowed_cidrs
```

- [ ] **Step 4: Declare them in the stack and forward to platform**

Add the same three `variable` blocks verbatim to `terraform/modules/stack/variables.tf`, then in `terraform/modules/stack/main.tf`, inside `module "platform"`, after the `enable_monitoring` pair:

```hcl
  enable_cluster_git       = var.enable_cluster_git
  drill_ingress_group_name = var.drill_ingress_group_name
  drill_allowed_cidrs      = var.drill_allowed_cidrs
```

- [ ] **Step 5: Declare them in the platform module**

Add the same three `variable` blocks verbatim to `terraform/modules/platform/variables.tf`.

- [ ] **Step 6: Verify no default slipped in**

```bash
grep -rn "default[[:space:]]*=" terraform/modules/*/variables.tf terraform/envs/dev/variables.tf
```

Expected: no output. A single `default =` breaks the repo's config-driven rule and hides a missing config value until it surprises someone at apply time.

- [ ] **Step 7: Validate**

```bash
make -f Makefile.test fmt-check validate
```

Expected: PASS. It will fail with "No value for required variable" only if the generated tfvars are stale; run `make config` first if so.

- [ ] **Step 8: Tell the user to update their real config**

`scripts/config.toml` is git-ignored and hand-maintained. Print the three lines they need to add:

```bash
echo "Add to the [common] table in scripts/config.toml:"
echo "  enable_cluster_git       = true"
echo "  drill_ingress_group_name = \"daily-eks-practice-ops\""
echo "  drill_allowed_cidrs      = [\"auto\"]"
```

Print `"auto"` rather than resolving their address here. The resolver added in Steps 9 to 11 does it at plan time, and echoing a personal IP into a terminal transcript is a leak the sentinel exists to avoid.

Do not write to `scripts/config.toml` without asking. It holds their account-specific values.

- [ ] **Step 9: Write the failing test for the `"auto"` resolver**

Create `tests/test_resolve_auto_cidrs.py`:

```python
"""bootstrap.py resolves the "auto" CIDR sentinel to the caller's public /32.

The drill ALB's allow list is the only control on an unauthenticated cluster-admin
terminal, so a stale entry is a lockout and a wrong entry is an exposure. These tests
pin the three behaviours that matter: literals are never touched, "auto" becomes a
/32, and a failed lookup is loud rather than silently wide open.
"""
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import bootstrap  # noqa: E402


class ResolveAutoCidrs(unittest.TestCase):
    def test_literal_cidrs_pass_through_untouched(self):
        cfg = {"drill_allowed_cidrs": ["203.0.113.10/32", "198.51.100.0/24"]}
        bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg["drill_allowed_cidrs"], ["203.0.113.10/32", "198.51.100.0/24"])

    def test_auto_becomes_the_public_slash_32(self):
        cfg = {"drill_allowed_cidrs": ["auto"]}
        with mock.patch.object(bootstrap, "public_ip", return_value="203.0.113.10"):
            bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg["drill_allowed_cidrs"], ["203.0.113.10/32"])

    def test_auto_mixed_with_literals_resolves_only_the_sentinel(self):
        cfg = {"drill_allowed_cidrs": ["auto", "198.51.100.0/24"]}
        with mock.patch.object(bootstrap, "public_ip", return_value="203.0.113.10"):
            bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg["drill_allowed_cidrs"], ["203.0.113.10/32", "198.51.100.0/24"])

    def test_lookup_failure_exits_instead_of_dropping_the_entry(self):
        cfg = {"drill_allowed_cidrs": ["auto"]}
        with mock.patch.object(bootstrap, "public_ip", return_value=None):
            with self.assertRaises(SystemExit):
                bootstrap.resolve_auto_cidrs(cfg)

    def test_key_absent_is_a_no_op(self):
        cfg = {"region": "us-east-2"}
        bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg, {"region": "us-east-2"})


if __name__ == "__main__":
    unittest.main()
```

The fourth test is the important one. If a lookup failure quietly dropped `"auto"` from the list, the allow list would become empty; if it fell back to a wildcard, it would become open. Both are worse than refusing to run.

- [ ] **Step 10: Run it to verify it fails**

```bash
python3 -m unittest tests.test_resolve_auto_cidrs -v
```

Expected: FAIL with `AttributeError: module 'bootstrap' has no attribute 'resolve_auto_cidrs'`.

- [ ] **Step 11: Implement the resolver**

In `scripts/bootstrap.py`, add after `deep_merge()`:

```python
def public_ip() -> str | None:
    """This machine's public IPv4 as the internet sees it, or None.

    Uses AWS's checkip because the tfvars this feeds are consumed by an AWS security
    group, so the address that matters is the one AWS observes. Stdlib only - the repo
    deliberately has no Python dependencies.
    """
    import urllib.request

    try:
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10) as r:
            ip = r.read().decode().strip()
    except Exception:
        return None
    try:
        ipaddress.IPv4Address(ip)
    except ValueError:
        return None
    return ip


def resolve_auto_cidrs(merged: dict) -> None:
    """Replace the "auto" sentinel in drill_allowed_cidrs with this machine's /32.

    Residential addresses are DHCP-assigned, so a pinned literal goes stale on a lease
    change and locks you out of your own drill with no error message - the browser just
    hangs. Resolving at plan time means the allow list cannot drift from reality.

    Literals are left alone: a static IP or a CI runner has no meaningful "your IP".
    """
    cidrs = merged.get("drill_allowed_cidrs")
    if not isinstance(cidrs, list) or "auto" not in cidrs:
        return
    ip = public_ip()
    if ip is None:
        sys.exit(
            "bootstrap: drill_allowed_cidrs is [\\"auto\\"] but your public IP could not be "
            "determined (no network?). Set a literal CIDR in scripts/config.toml, or retry."
        )
    merged["drill_allowed_cidrs"] = [f"{ip}/32" if c == "auto" else c for c in cidrs]
    log(f"bootstrap: drill_allowed_cidrs \\"auto\\" resolved to your current public /32")
```

Add `import ipaddress` to the imports at the top of the file.

Note the log line does not print the address. It goes into the tfvars, which are git-ignored, and terminal output is the more exposed of the two.

Call it in `main()` immediately after `merged` is built and validated, so both the `--print` path and the tfvars write see resolved values:

```python
    if not merged:
        sys.exit(f"bootstrap: no config found for env '{env}'")

    resolve_auto_cidrs(merged)
```

- [ ] **Step 12: Run the test to verify it passes**

```bash
python3 -m unittest tests.test_resolve_auto_cidrs -v
```

Expected: 5 tests, PASS. Only `test_auto_becomes_the_public_slash_32` and the mixed case touch the network, and both mock it, so the suite stays offline.

- [ ] **Step 13: Commit**

```bash
git add scripts/config.example.toml scripts/bootstrap.py tests/test_resolve_auto_cidrs.py terraform/
git commit -m "feat: config values for cluster git and the drill ALB"
```

---

### Task 3.2: The cluster git server

A pod serving a bare repo in namespace `git`, with a readiness probe that only passes once the repo is genuinely seeded, plus the kind test that proves Argo CD can actually read it.

**The cluster git protocol risk.**
This task carries the one genuinely unproven assumption in the plan: that Argo CD will clone from a git server inside the same cluster, over plain HTTP, with no credentials.

Why it is not obvious. Argo's repo-server clones with `--depth 1`. Shallow fetch is a capability of the _smart_ HTTP transport. A bare repo served by static nginx is _dumb_ HTTP, which does not implement it, so Step 7 may fail with `dumb http transport does not support shallow capabilities` or similar.

Why it is not a gate. A failure never invalidates the design, it only changes which container serves the repo. So instead of proving it in a throwaway spike first, Step 7 proves it on kind against the manifests that ship, and the alternatives are ranked here in advance:

| #   | Option                                                        | Fidelity                               | Cost of switching                                       | What it costs you                                          |
| --- | ------------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------- |
| 1   | Dumb HTTP, static nginx over a bare repo (what Step 1 writes) | full GitOps                            | baseline                                                | may fail on Argo's `--depth 1` shallow clone               |
| 2   | Smart HTTP: `git http-backend` CGI behind `fcgiwrap`          | full GitOps                            | one ConfigMap and one image swap                        | nothing functional; more container config to read          |
| 3   | `git daemon` on 9418, `git://` repoURL                        | full GitOps                            | one image swap, plus confirming Argo accepts the scheme | nothing, if Argo takes `git://`                            |
| 4   | Gitea with the sqlite backend                                 | full GitOps **and a browsable web UI** | ~150MB image and a handful of env vars                  | more moving parts; arguably an upgrade for a learning repo |
| 5   | No Argo; the drill server runs `helm upgrade` on submit       | **simulated**                          | rewrites Phase 6                                        | the entire GitOps lesson                                   |

Work down the ladder in order.

Rung 5 is the floor, not a peer of the others: there are three better rungs above it and it is the only one that stops teaching GitOps. Do not reach for it because it is quick.

**"Argo reads GitHub directly" is deliberately absent from this ladder.** It was rung 5 in an earlier draft and was deleted, not demoted, because the self-contained git rule at the top of this plan forbids it. Leaving it on the ladder would mean a failure at rung 4 could slide straight back into the thing the rule rejects. If every rung here fails, that is a conversation with the user, not a licence to point Argo at github.com.

If the ladder is entered at all, record which rung won and why in a comment at the top of `cluster-git.tf`, and report it to the user before continuing to Task 3.3, because rungs 3 to 5 change `cluster_git_url` and therefore Task 3.3's Argo Application.

**Files:**

- Create: `terraform/modules/platform/cluster-git.tf`
- Modify: `terraform/modules/platform/outputs.tf`
- Test: ministack plan

**Interfaces:**

- Consumes: `enable_cluster_git` from Task 3.1; `scripts/kind-sandbox.sh` from Task 0.1.
- Produces:
  - Namespace `git`, a `git-server` Deployment, Service `git-server` on port 80, PVC `git-repo`, ConfigMap `git-nginx`.
  - Platform module outputs: `cluster_git_url` (string, `http://git-server.git.svc.cluster.local/repo.git`, empty when disabled), `cluster_git_namespace` (string), `cluster_git_deployment` (string). Stack forwards all three; the env re-exports them so `make git-seed` can find the pod without hardcoding names.

- [ ] **Step 1: Write the manifests**

Create `terraform/modules/platform/cluster-git.tf`. Raw manifests via `kubectl_manifest` rather than a chart, matching how `app_namespace` and `db_secret` are already done in this module and keeping it readable for someone learning.

```hcl
# ---------------------------------------------------------------------------
# Cluster git - the ONLY repository Argo CD ever reads.
#
# Argo pointing at GitHub and a drill pointing at a workspace would be two
# Applications fighting over one namespace. Pointing Argo at a repo that lives in
# the cluster removes the conflict instead of managing it: there is one
# Application, permanently, and GitHub becomes the upstream rather than the source.
#
# Seeding is deliberately NOT done here. An init container cloning GitHub would
# need a PAT in the cluster and would fail for a private repo on first apply.
# Instead the init container creates an empty bare repo, and `make git-seed`
# streams a git bundle in from the laptop. The readiness probe requires the
# .seeded marker, so until that lands the Service has no endpoints and Argo
# retries cleanly. The danger was never that Argo errors - it is that Argo
# SUCCEEDS against a half-served repo and syncs a broken state that looks fine.
# ---------------------------------------------------------------------------

locals {
  git_ns     = "git"
  git_repo   = "repo.git"
  git_svc    = "git-server"
  cluster_git_url = var.enable_cluster_git ? "http://${local.git_svc}.${local.git_ns}.svc.cluster.local/${local.git_repo}" : ""
}

resource "kubectl_manifest" "git_namespace" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = local.git_ns, labels = { "app.kubernetes.io/part-of" = "drill-platform" } }
  })
}

# The repo outlives pod restarts but dies with the cluster, which is correct:
# GitHub is the durable copy and drill-progress/ is the durable practice record.
resource "kubectl_manifest" "git_pvc" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "PersistentVolumeClaim"
    metadata   = { name = "git-repo", namespace = local.git_ns }
    spec = {
      accessModes = ["ReadWriteOnce"]
      resources   = { requests = { storage = "1Gi" } }
    }
  })

  depends_on = [kubectl_manifest.git_namespace]
}

resource "kubectl_manifest" "git_nginx_conf" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "git-nginx", namespace = local.git_ns }
    data = {
      "default.conf" = <<-EOT
        server {
          listen 8080;
          root /srv;
          autoindex off;
          location / { try_files $uri $uri/ =404; }
          # /healthz is served from disk and only exists once seeding wrote it,
          # which is what makes the readiness probe mean "the repo is complete".
          location = /healthz { try_files /repo.git/.seeded =503; }
        }
      EOT
    }
  })

  depends_on = [kubectl_manifest.git_namespace]
}

resource "kubectl_manifest" "git_server" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "Deployment"
    metadata   = { name = local.git_svc, namespace = local.git_ns }
    spec = {
      replicas = 1
      strategy = { type = "Recreate" } # one RWO volume; two pods cannot both mount it
      selector = { matchLabels = { app = local.git_svc } }
      template = {
        metadata = { labels = { app = local.git_svc } }
        spec = {
          # Init containers run to completion before any main container starts, so
          # nginx can never serve a directory that has not been initialised yet.
          initContainers = [{
            name    = "init-repo"
            image   = "alpine/git:latest"
            command = ["/bin/sh", "-c"]
            args = [<<-EOT
              set -e
              if [ ! -d /srv/${local.git_repo} ]; then
                git init --bare /srv/${local.git_repo}
                touch /srv/${local.git_repo}/git-daemon-export-ok
                git -C /srv/${local.git_repo} update-server-info
                echo "init-repo: created an empty bare repo, waiting for 'make git-seed'"
              else
                echo "init-repo: repo already present, leaving it alone"
              fi
            EOT
            ]
            volumeMounts = [{ name = "repo", mountPath = "/srv" }]
          }]
          containers = [{
            name  = "nginx"
            image = "nginx:1.27-alpine"
            ports = [{ name = "http", containerPort = 8080 }]
            volumeMounts = [
              { name = "repo", mountPath = "/srv" },
              { name = "conf", mountPath = "/etc/nginx/conf.d" },
            ]
            readinessProbe = {
              httpGet             = { path = "/healthz", port = "http" }
              initialDelaySeconds = 2
              periodSeconds       = 3
            }
            livenessProbe = {
              tcpSocket           = { port = "http" }
              initialDelaySeconds = 10
              periodSeconds       = 20
            }
            resources = {
              requests = { cpu = "25m", memory = "32Mi" }
              limits   = { memory = "96Mi" }
            }
          }]
          volumes = [
            { name = "repo", persistentVolumeClaim = { claimName = "git-repo" } },
            { name = "conf", configMap = { name = "git-nginx" } },
          ]
        }
      }
    }
  })

  depends_on = [kubectl_manifest.git_pvc, kubectl_manifest.git_nginx_conf]
}

resource "kubectl_manifest" "git_service" {
  count = var.enable_cluster_git ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = local.git_svc, namespace = local.git_ns }
    spec = {
      selector = { app = local.git_svc }
      ports    = [{ name = "http", port = 80, targetPort = "http" }]
    }
  })

  depends_on = [kubectl_manifest.git_server]
}
```

This is rung 1 of the ladder. Do not pre-emptively climb it: write the simple thing, and let Step 7 tell you whether it holds. If Step 7 sends you up the ladder, keep the `/healthz`-from-disk readiness gate no matter which rung you land on (adapt the path if the new server has a different docroot), because that gate is what stops Argo syncing a half-served repo and it is independent of the protocol.

- [ ] **Step 2: Add the outputs**

Append to `terraform/modules/platform/outputs.tf`:

```hcl
output "cluster_git_url" {
  description = "In-cluster repo URL Argo CD reads from (\"\" when cluster git is disabled)."
  value       = local.cluster_git_url
}

output "cluster_git_namespace" {
  description = "Namespace the cluster git server runs in."
  value       = var.enable_cluster_git ? local.git_ns : ""
}

output "cluster_git_deployment" {
  description = "Deployment name of the cluster git server, for `kubectl exec` seeding."
  value       = var.enable_cluster_git ? local.git_svc : ""
}
```

- [ ] **Step 3: Forward them through stack and env**

Append the same three `output` blocks to `terraform/modules/stack/outputs.tf` with `value = module.platform.cluster_git_url` (and so on), and again to `terraform/envs/dev/outputs.tf` with `value = module.stack.cluster_git_url`.

- [ ] **Step 4: Validate and format**

```bash
make -f Makefile.test fmt-check validate
```

Expected: PASS.

- [ ] **Step 5: Run the ministack plan**

```bash
make -f Makefile.test ministack
```

Expected: a plan that includes the five new `kubectl_manifest` resources. Ministack mocks AWS, not Kubernetes, so the kubectl provider resources will show as planned-to-create without being applied, which is exactly the coverage wanted here: it proves the HCL is well-formed, the `yamlencode` blocks render, and nothing broke the existing plan.

- [ ] **Step 6: Prove the manifests actually admit, on kind**

Ministack cannot tell you whether Kubernetes accepts these. Kind can, for free.

```bash
make -f Makefile.test kind-up
export KUBECONFIG="$(bash scripts/kind-sandbox.sh kubeconfig)"
terraform -chdir=terraform/modules/platform show -json >/dev/null 2>&1 || true
# Render the manifests the module would apply, and apply them directly:
kubectl apply -f - <<'YAML'
# paste the five rendered manifests here, or extract them with:
#   terraform -chdir=terraform/envs/dev plan -out=tf.plan && terraform show -json tf.plan \
#     | jq -r '.. | .yaml_body? // empty'
YAML
kubectl -n git rollout status deploy/git-server --timeout=120s
kubectl -n git get endpoints git-server
```

Expected: the Deployment rolls out, and `endpoints` shows **no addresses**, because `/healthz` 503s until `.seeded` exists. That empty endpoint list is the whole point of the probe - confirm it before moving on.

- [ ] **Step 7: Seed it, and prove Argo CD can read it - the acceptance test**

Step 6 proved Kubernetes accepts the manifests. This proves the thing the manifests exist for. This is the assumption named in "The cluster git protocol risk" above, and it is the gate on Task 3.3.

Still on the same kind cluster:

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
```

Seed the bare repo by streaming a bundle in. This is the mechanism Task 3.3 ships, so running it here proves the server and the seeding path in one pass:

```bash
POD=$(kubectl -n git get pod -l app=git-server -o name | head -1)
git bundle create - --all \
  | kubectl -n git exec -i "$POD" -c nginx -- /bin/sh -c 'cat > /tmp/seed.bundle'
kubectl -n git exec "$POD" -c nginx -- /bin/sh -c '
  command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null 2>&1
  git -C /srv/repo.git fetch --force /tmp/seed.bundle "refs/heads/*:refs/heads/*"
  git -C /srv/repo.git symbolic-ref HEAD refs/heads/main
  git -C /srv/repo.git update-server-info
  date -u +%Y-%m-%dT%H:%M:%SZ > /srv/repo.git/.seeded'
kubectl -n git get endpoints git-server
```

Expected: `endpoints` now shows **one address**. The probe flipping from zero to one endpoints on the `.seeded` marker is the ordering guarantee working. Record whether `apk add git` was needed, because if it was, the shipped image must bundle `git` rather than install it at runtime on a cluster that may have no egress.

Now point an Argo Application at it:

```bash
kubectl apply -f - <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-git-acceptance
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://git-server.git.svc.cluster.local/repo.git
    targetRevision: main
    path: helm/practice-app
  destination:
    server: https://kubernetes.default.svc
    namespace: acceptance-app
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
YAML
sleep 20
kubectl -n argocd get application cluster-git-acceptance \
  -o jsonpath='{.status.sync.status}{"\n"}{.status.conditions}{"\n"}'
kubectl -n argocd logs deploy/argocd-repo-server --tail=60 | grep -iE 'git|clone|fail|error'
```

**Expected on success:** sync status is `OutOfSync`, not `Unknown`, and `.status.conditions` is empty. That combination means Argo cloned the repo and rendered the chart, and is only holding back because sync is manual. The repo-server log shows a successful `ls-remote` or fetch against the in-cluster URL.

**Expected on failure:** sync status `Unknown` with a `ComparisonError` condition, and the repo-server log carrying the reason. If that reason mentions shallow capabilities or the dumb transport, go to rung 2 of the ladder, redo Steps 1 and 4 to 7, and record which rung won. Report to the user before starting Task 3.3 if you landed anywhere below rung 2, because rungs 3 to 6 change `cluster_git_url`.

Tear down when the verdict is in:

```bash
make -f Makefile.test kind-down
```

- [ ] **Step 8: Commit**

```bash
git add terraform/modules/platform/cluster-git.tf terraform/modules/platform/outputs.tf terraform/modules/stack/outputs.tf terraform/envs/dev/outputs.tf
git commit -m "feat: in-cluster git server as the single source Argo CD reads"
```

---

### Task 3.3: Seed cluster git and repoint the Argo Application

**Files:**

- Create: `scripts/git-seed.py`
- Modify: `scripts/gen-argocd-app.py`
- Modify: `Makefile` (add `git-seed`, make `app-deploy` depend on it)
- Test: `tests/test_git_seed.py`

**Interfaces:**

- Consumes: `cluster_git_url`, `cluster_git_namespace`, `cluster_git_deployment` outputs from Task 3.2.
- Produces:
  - `scripts/git-seed.py` - streams `git bundle create - --all` from the local repo into the cluster git pod, unbundles, sets HEAD, runs `git update-server-info`, writes `.seeded`. Idempotent: re-running force-updates refs and rewrites the marker.
  - `make git-seed` - the target that runs it.
  - `scripts/gen-argocd-app.py` now emits `repoURL` pointing at cluster git when `enable_cluster_git` is on, falling back to the GitHub URL when it is off, so the existing behaviour still works for anyone who leaves the toggle false.

- [ ] **Step 1: Write the failing test**

Create `tests/test_git_seed.py`, covering the pure parts (URL selection and the command construction) without needing a cluster:

```python
#!/usr/bin/env python3
"""Unit tests for scripts/git-seed.py's pure helpers.

The kubectl exec itself needs a cluster and is covered by the kind run in Step 5.
What is testable here is the part that silently does the wrong thing if it breaks:
which URL Argo gets pointed at.
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("git_seed", ROOT / "scripts" / "git-seed.py")
gs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gs)

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  PASS  {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")


def test_unbundle_script_is_idempotent():
    script = gs.unbundle_script("repo.git")
    for needle in ("update-server-info", "symbolic-ref HEAD", ".seeded", "--force"):
        if needle in script:
            ok(f"unbundle script contains {needle!r}")
        else:
            bad(f"unbundle script is missing {needle!r}")


def test_unbundle_script_writes_marker_last():
    """If .seeded is written before the refs land, the probe passes too early and
    Argo clones a half-served repo - the exact failure the probe exists to stop."""
    script = gs.unbundle_script("repo.git")
    if script.index("update-server-info") < script.index(".seeded"):
        ok("the .seeded marker is written after update-server-info")
    else:
        bad("the .seeded marker is written too early")


def main():
    for fn in (test_unbundle_script_is_idempotent, test_unbundle_script_writes_marker_last):
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"git-seed: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 tests/test_git_seed.py`
Expected: FAIL, `scripts/git-seed.py` does not exist.

- [ ] **Step 3: Write the seeder**

Create `scripts/git-seed.py`:

```python
#!/usr/bin/env python3
"""Seed the in-cluster git server from this local clone.

    make git-seed

Streams `git bundle create - --all` from the local repo straight into the pod over
`kubectl exec`, so nothing hits disk on the way and no port-forward has to be held
open. A bundle carries every ref and object in one file, which is why the same
primitive works in reverse for saving drill progress.

This exists instead of an init container that clones GitHub because that would need
a PAT inside the cluster and would fail outright for a private repo on first apply.
Seeding from the laptop needs no credentials and no egress.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def unbundle_script(repo_dir: str) -> str:
    """The shell run inside the pod. Order matters: the marker is written LAST.

    If .seeded appeared before update-server-info, the readiness probe would pass
    while the refs were still incomplete, and Argo would clone a half-served repo
    and sync a broken state that looks like it worked.
    """
    return f"""
set -e
command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null 2>&1
git -C /srv/{repo_dir} fetch --force /tmp/seed.bundle 'refs/heads/*:refs/heads/*'
git -C /srv/{repo_dir} symbolic-ref HEAD refs/heads/main
git -C /srv/{repo_dir} update-server-info
rm -f /tmp/seed.bundle
date -u +%Y-%m-%dT%H:%M:%SZ > /srv/{repo_dir}/.seeded
echo "git-seed: refs published"
"""


def tf_output(name: str) -> str:
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "output", "-raw", name],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        sys.exit(f"git-seed: could not read terraform output {name!r} - is the cluster up?\n{out.stderr}")
    return out.stdout.strip()


def main() -> int:
    ns = tf_output("cluster_git_namespace")
    deploy = tf_output("cluster_git_deployment")
    if not ns or not deploy:
        sys.exit("git-seed: cluster git is disabled (enable_cluster_git = false in scripts/config.toml)")

    print(f"git-seed: waiting for {deploy} in namespace {ns} to have a running pod...")
    subprocess.run(
        ["kubectl", "-n", ns, "wait", "--for=condition=Initialized", "pod",
         "-l", f"app={deploy}", "--timeout=180s"],
        check=True,
    )
    pod = subprocess.check_output(
        ["kubectl", "-n", ns, "get", "pod", "-l", f"app={deploy}", "-o", "jsonpath={.items[0].metadata.name}"],
        text=True,
    ).strip()

    print(f"git-seed: streaming a bundle of {REPO.name} into {pod}")
    bundle = subprocess.Popen(
        ["git", "-C", str(REPO), "bundle", "create", "-", "--all"],
        stdout=subprocess.PIPE,
    )
    copy = subprocess.run(
        ["kubectl", "-n", ns, "exec", "-i", pod, "-c", "nginx", "--",
         "/bin/sh", "-c", "cat > /tmp/seed.bundle"],
        stdin=bundle.stdout,
    )
    bundle.wait()
    if bundle.returncode != 0 or copy.returncode != 0:
        sys.exit("git-seed: streaming the bundle failed")

    unbundle = subprocess.run(
        ["kubectl", "-n", ns, "exec", pod, "-c", "nginx", "--",
         "/bin/sh", "-c", unbundle_script("repo.git")],
    )
    if unbundle.returncode != 0:
        sys.exit("git-seed: unbundling inside the pod failed")

    print("git-seed: waiting for the readiness probe to pass...")
    subprocess.run(["kubectl", "-n", ns, "rollout", "status", f"deploy/{deploy}", "--timeout=120s"], check=True)
    print(f"git-seed: cluster git is serving. Argo CD can now read {tf_output('cluster_git_url')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 tests/test_git_seed.py`
Expected: PASS, 5 assertions.

- [ ] **Step 5: Repoint the Argo Application generator**

In `scripts/gen-argocd-app.py`, replace the hard use of the GitHub URL with a cluster-git-first choice. Read the terraform output; if it is non-empty use it, otherwise fall back to `repo_https_url()` exactly as today:

```python
def source_repo_url() -> str:
    """Argo reads cluster git when it exists, GitHub otherwise.

    One Application, permanently. Cluster git is the source; GitHub is the upstream
    the workspace pushes to. Falling back keeps the toggle honest: with
    enable_cluster_git = false everything behaves exactly as it did before.
    """
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "output", "-raw", "cluster_git_url"],
        capture_output=True,
        text=True,
    )
    url = out.stdout.strip() if out.returncode == 0 else ""
    if url:
        print(f"gen-argocd-app: pointing Argo CD at cluster git ({url})")
        return url
    print("gen-argocd-app: cluster git is off - pointing Argo CD at GitHub")
    return repo_https_url()
```

Use `source_repo_url()` where `repo_https_url()` is currently called to build `spec.source.repoURL`.

Two notes on how this sits with the self-contained git rule at the top of this plan.

The GitHub fallback is not a violation. It is the pre-drill path, reached only when `enable_cluster_git = false`, which is how the repo behaves today for anyone who never turns the drill on. On the drill path the toggle is on and the fallback is unreachable. What the rule forbids is Argo reading GitHub _while a drill is running_, and that cannot happen here.

Leave `scripts/argo-repo.py` alone. It registers the GitHub credential, which is still needed for the push half of scenarios 09 and 12, and `scenarios/09-gitops-argocd.md` teaches that registration as its lesson. The drill simply never calls `make argo-repo`. Deleting the script to satisfy the rule would break a scenario that ships today, in service of a rule about a scenario that does not exist yet.

- [ ] **Step 6: Add the Makefile target and wire the ordering**

In `Makefile`, add `git-seed` to `.PHONY` and add the target before `app-deploy`:

```makefile
git-seed: ## Publish this repo into the in-cluster git server (Argo CD's only source)
	$(PYTHON) scripts/git-seed.py
```

Change `app-deploy` to depend on it, so the dependency chain in the spec is enforced rather than remembered:

```makefile
app-deploy: git-seed ## Register the practice app with Argo CD (reads from cluster git)
	$(PYTHON) scripts/gen-argocd-app.py
	kubectl apply -f argocd/generated/practice-app.yaml
	@echo ""
	@echo "Argo CD now owns the app, reading from cluster git. Run 'make argo-sync'."
```

Also update the header comment block at the top of `Makefile` to list `make git-seed`.

- [ ] **Step 7: End-to-end on kind**

This is the first time the whole Phase 3 chain runs together, and it is free.

```bash
make -f Makefile.test kind-up
export KUBECONFIG="$(bash scripts/kind-sandbox.sh kubeconfig)"
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
# Apply the rendered cluster-git manifests (from Task 3.2 Step 6), then:
python3 scripts/git-seed.py     # will need the tf_output calls stubbed for kind; see below
kubectl -n git get endpoints git-server
```

For the kind run, `tf_output` has no terraform state to read. Add an env override at the top of `main()` so the same script works in both places:

```python
    ns = os.environ.get("CLUSTER_GIT_NS") or tf_output("cluster_git_namespace")
    deploy = os.environ.get("CLUSTER_GIT_DEPLOY") or tf_output("cluster_git_deployment")
```

Then: `CLUSTER_GIT_NS=git CLUSTER_GIT_DEPLOY=git-server python3 scripts/git-seed.py`

Expected: `git-seed: refs published`, then `kubectl -n git get endpoints git-server` shows an address, because `.seeded` now exists and `/healthz` returns 200.

- [ ] **Step 8: Prove Argo syncs from it**

```bash
kubectl apply -f - <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: practice-app, namespace: argocd }
spec:
  project: default
  source:
    repoURL: http://git-server.git.svc.cluster.local/repo.git
    targetRevision: main
    path: helm/practice-app
  destination: { server: https://kubernetes.default.svc, namespace: practice-app }
  syncPolicy: { syncOptions: ["CreateNamespace=true"] }
YAML
sleep 20
kubectl -n argocd get application practice-app -o jsonpath='{.status.sync.status}{"\n"}'
```

Expected: `OutOfSync`, not `Unknown`. The backend pod will not become healthy on kind because there is no RDS, which is fine and expected - what is being proved is that Argo cloned and rendered.

- [ ] **Step 9: Tear down and commit**

```bash
make -f Makefile.test kind-down
git add scripts/git-seed.py scripts/gen-argocd-app.py tests/test_git_seed.py Makefile
git commit -m "feat: seed cluster git from the local clone and point Argo CD at it"
```

---

## Phase 4: Terraform - the ALB

One internet-facing ALB shared by every ops UI, restricted to the user's own IP, with a teardown path that does not orphan it.

### Task 4.1: The shared IngressGroup and the source-IP security group

**Source IP is the only control, deliberately, and here is the trigger to revisit that.**

The spec's Condition 3 says it plainly: without the security group the drill GUI is an unauthenticated web terminal running as `cluster-admin`, reachable by anyone who finds the hostname, over plain HTTP. There is no second layer. That makes the value of `drill_allowed_cidrs` load-bearing in a way a normal firewall rule is not.

Adding application-level auth (a shared secret checked by the Fastify server on every request and websocket upgrade, seeded from `config.toml`) was considered and **deferred** on 2026-08-19. It is cheap, roughly 30 lines in Task 5.1, needs no ACM certificate and no domain, and would turn "found the hostname" into "found the hostname and the token". It was deferred because the deployment target was checked and found to be a residential connection with a **directly assigned** public IPv4 rather than one behind carrier-grade NAT, so the configured `/32` genuinely identifies one machine.

That check is what makes source-IP-only defensible, and it is also exactly what stops being true in these cases. **Add the shared secret before drilling from any of them:**

- A cafe, hotel, airport, or any shared or guest network.
- A phone tether or any mobile carrier connection, which is almost always carrier-NAT.
- A corporate network, where the egress IP is the whole company.
- A commercial VPN exit node, which is shared with every other user of that node.
- Any second person using this platform, which is also the point where the spec's ALB OIDC growth path stops being premature.

In all of those the allow list stops meaning "my laptop" and starts meaning "everyone sharing this egress address", against a resource whose worst case is a root shell on the cluster.

**Files:**

- Create: `terraform/modules/platform/drill-ingress.tf`
- Modify: `terraform/modules/platform/outputs.tf`
- Test: ministack plan

**Interfaces:**

- Consumes: `drill_ingress_group_name`, `drill_allowed_cidrs`, `enable_alb_controller`, `vpc_id` (already present).
- Produces:
  - `aws_security_group.drill_alb` - ingress on 80 from `drill_allowed_cidrs` only, egress all.
  - Output `drill_alb_security_group_id` (string) for the Ingress annotation.
  - Output `drill_ingress_group_name` (string), re-exported so the drill Ingress in Phase 5 and any future ops Ingress use the same value without hardcoding it.
  - The Ingress resource itself ships in Phase 5 with the GUI; this task provides only what it annotates against, so the ALB is never created before something needs it.

- [ ] **Step 1: Write the security group**

Create `terraform/modules/platform/drill-ingress.tf`:

```hcl
# ---------------------------------------------------------------------------
# Security group for the shared ops ALB.
#
# This is not a hardening nicety. The drill GUI serves a real PTY in a pod whose
# ServiceAccount is cluster-admin, over plain HTTP with no login. Without a source
# restriction it is a remote root shell on the cluster for anyone who finds the
# hostname. The allow list lives in scripts/config.toml, which is git-ignored, so
# a personal IP never reaches the remote.
#
# HTTPS + ALB OIDC auth is the documented growth path and is deferred only because
# it needs an ACM cert, which needs a Route53 zone this project does not configure
# yet (enable_external_dns = false, dns_zone_name = ""). It is a good scenario in
# its own right.
# ---------------------------------------------------------------------------

resource "aws_security_group" "drill_alb" {
  count = var.enable_alb_controller ? 1 : 0

  name        = "${var.name_prefix}-drill-alb"
  description = "Source-restricted access to the shared ops ALB (drill GUI, Argo CD, Grafana)"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-drill-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "drill_alb_http" {
  for_each = var.enable_alb_controller ? toset(var.drill_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.drill_alb[0].id
  description       = "HTTP from an allowed operator IP"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "drill_alb_all" {
  count = var.enable_alb_controller ? 1 : 0

  security_group_id = aws_security_group.drill_alb[0].id
  description       = "ALB to targets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

- [ ] **Step 2: Add a guard against the obvious foot-gun**

Add to the same file, so an open allow list fails at plan time rather than at 3am:

```hcl
# A wide-open allow list on an unauthenticated cluster-admin terminal is not a
# configuration choice, it is an incident. Fail the plan instead of the postmortem.
resource "terraform_data" "drill_cidr_guard" {
  count = var.enable_alb_controller ? 1 : 0

  lifecycle {
    precondition {
      condition     = !contains(var.drill_allowed_cidrs, "0.0.0.0/0")
      error_message = "drill_allowed_cidrs must not contain 0.0.0.0/0 - the drill GUI is an unauthenticated cluster-admin web terminal. Set it to your own /32 in scripts/config.toml (curl -s https://checkip.amazonaws.com)."
    }
    precondition {
      condition     = length(var.drill_allowed_cidrs) > 0
      error_message = "drill_allowed_cidrs is empty - nothing would be able to reach the drill GUI."
    }
  }
}
```

- [ ] **Step 3: Add the outputs**

Append to `terraform/modules/platform/outputs.tf`:

```hcl
output "drill_alb_security_group_id" {
  description = "Security group id to annotate on every ops Ingress (\"\" when the ALB controller is off)."
  value       = var.enable_alb_controller ? aws_security_group.drill_alb[0].id : ""
}

output "drill_ingress_group_name" {
  description = "Shared IngressGroup name; every ops Ingress must use it or it gets its own ALB."
  value       = var.drill_ingress_group_name
}
```

Forward both through `terraform/modules/stack/outputs.tf` and `terraform/envs/dev/outputs.tf`.

- [ ] **Step 4: Validate and plan**

```bash
make -f Makefile.test fmt-check validate
make -f Makefile.test ministack
```

Expected: PASS, with the security group and its two rules in the plan.

- [ ] **Step 5: Prove the guard fires**

```bash
python3 scripts/bootstrap.py dev --generate-only
# temporarily set drill_allowed_cidrs = ["0.0.0.0/0"] in scripts/config.toml, then:
make -f Makefile.test ministack
```

Expected: the plan FAILS with the precondition message naming `drill_allowed_cidrs`. Restore the real value afterwards. Ask the user before editing `scripts/config.toml`; if they would rather not, note that the guard is untested and say so plainly.

- [ ] **Step 6: Add `make drill-allow`, the lockout recovery path**

The `"auto"` sentinel from Task 3.1 keeps the allow list fresh at plan time, but it only runs when you plan. If a DHCP lease rotates while the cluster is up, the GUI stops answering mid-drill and the only fix so far is a full `terraform apply` on a billing cluster to change one firewall rule. This target fixes just the rule.

Add to `Makefile`, near the other cluster-side targets, and add `drill-allow` to the `.PHONY` list:

```make
drill-allow: ## Re-point the drill ALB security group at your CURRENT public IP
	@$(PYTHON) scripts/drill-allow.py
```

Create `scripts/drill-allow.py`:

```python
#!/usr/bin/env python3
"""Re-point the drill ALB security group at this machine's current public IP.

Residential addresses are DHCP-assigned. When the lease rotates mid-drill the GUI
simply stops answering - no error, the browser just hangs - and the fix would
otherwise be a full `terraform apply` on a cluster that is billing by the hour, to
change one firewall rule. This does only the rule.

Terraform stays the source of truth: the next `make plan` re-reads config.toml,
re-resolves "auto", and converges to the same place. This is the fast path, not a
second owner of the resource.
"""
import ipaddress
import json
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from bootstrap import public_ip  # noqa: E402  - single definition, shared


def tf_output(name: str) -> str:
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "output", "-raw", name],
        capture_output=True,
        text=True,
    )
    return out.stdout.strip() if out.returncode == 0 else ""


def aws(*args: str) -> dict:
    cmd = ["aws", *args, "--output", "json"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"drill-allow: {' '.join(cmd)} failed:\\n{out.stderr.strip()}")
    return json.loads(out.stdout) if out.stdout.strip() else {}


def main() -> int:
    sg = tf_output("drill_alb_security_group_id")
    if not sg:
        sys.exit("drill-allow: no drill ALB security group in state - is the cluster up?")

    ip = public_ip()
    if ip is None:
        sys.exit("drill-allow: could not determine your public IP (no network?).")
    want = f"{ip}/32"

    desc = aws("ec2", "describe-security-groups", "--group-ids", sg)
    perms = desc["SecurityGroups"][0]["IpPermissions"]
    have = {
        r["CidrIp"]
        for p in perms
        if p.get("FromPort") == 80
        for r in p.get("IpRanges", [])
    }

    if have == {want}:
        print(f"drill-allow: already correct, nothing to do ({len(have)} rule)")
        return 0

    for stale in have - {want}:
        aws("ec2", "revoke-security-group-ingress", "--group-id", sg,
            "--protocol", "tcp", "--port", "80", "--cidr", stale)
        print("drill-allow: revoked a stale rule")

    if want not in have:
        aws("ec2", "authorize-security-group-ingress", "--group-id", sg,
            "--protocol", "tcp", "--port", "80", "--cidr", want)
        print("drill-allow: authorised your current public /32")

    print("drill-allow: done. Terraform will converge to the same state on the next plan.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Two deliberate choices. It never prints the address, matching Task 3.1's reasoning that terminal output is more exposed than the git-ignored files the value normally lives in. And it revokes stale rules rather than only adding, because an allow list that accumulates every cafe you have ever worked from is not an allow list.

- [ ] **Step 7: Test it without AWS**

There is no cluster, so exercise the failure path and the parsing, which is where the bugs would be:

```bash
python3 scripts/drill-allow.py
```

Expected: exits non-zero with `no drill ALB security group in state - is the cluster up?`. That confirms the terraform-output lookup, the guard, and the import of `public_ip` from `bootstrap` all work. The AWS calls themselves are verified in Phase 7 Step 3, which is the first time a real security group exists.

- [ ] **Step 8: Commit**

```bash
git add terraform/modules/platform/drill-ingress.tf terraform/modules/platform/outputs.tf terraform/modules/stack/outputs.tf terraform/envs/dev/outputs.tf scripts/drill-allow.py Makefile
git commit -m "feat: source-restricted security group for the shared ops ALB"
```

---

### Task 4.2: Teardown that does not orphan the ALB

The AWS Load Balancer Controller creates the ALB, so it is not a Terraform resource and Terraform cannot sequence its deletion. Destroying the cluster first leaves a load balancer billing about $16/month that nothing in the account points at, plus security groups that make VPC deletion hang. Same failure shape as an orphaned PVC.

**Files:**

- Create: `scripts/pre-destroy.py`
- Modify: `Makefile` (`down` runs it first)
- Test: `tests/test_pre_destroy.py`

**Interfaces:**

- Consumes: nothing beyond kubectl and the terraform outputs.
- Produces:
  - `scripts/pre-destroy.py` - deletes every Ingress in every namespace, deletes every `LoadBalancer` Service, deletes the drill PVC and the cluster git PVC, then polls until no ALB or NLB tagged with this cluster remains. Exits non-zero if anything is still there after the timeout, so `make down` stops rather than destroying into a hanging state.
  - `make down` runs it before `terraform destroy`, and prints what it removed.
  - `SKIP_PRE_DESTROY=1 make down` bypasses it, for the case where the cluster is already gone and the pre-destroy would just hang on an unreachable API.

- [ ] **Step 1: Write the failing test**

Create `tests/test_pre_destroy.py` covering the pure logic - which objects are targeted and the ordering:

```python
#!/usr/bin/env python3
"""Unit tests for scripts/pre-destroy.py's planning logic.

The kubectl calls need a cluster; what is testable here is the part that costs
money when it is wrong: whether the plan covers every billable object and whether
it deletes them before it starts waiting.
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pre_destroy", ROOT / "scripts" / "pre-destroy.py")
pd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pd)

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  PASS  {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")


def test_plan_covers_every_billable_kind():
    kinds = {step.kind for step in pd.plan()}
    for kind in ("ingress", "service", "persistentvolumeclaim"):
        if kind in kinds:
            ok(f"plan covers {kind}")
        else:
            bad(f"plan does NOT cover {kind} - it will orphan and keep billing")


def test_deletes_before_waiting():
    steps = pd.plan()
    last_delete = max(i for i, s in enumerate(steps) if s.action == "delete")
    first_wait = min(i for i, s in enumerate(steps) if s.action == "wait")
    if last_delete < first_wait:
        ok("every delete happens before the first wait")
    else:
        bad("a wait is scheduled before a delete, so it would time out on its own inaction")


def test_wait_has_a_timeout():
    waits = [s for s in pd.plan() if s.action == "wait"]
    if waits and all(s.timeout_seconds > 0 for s in waits):
        ok("every wait step has a positive timeout")
    else:
        bad("a wait step has no timeout - make down could hang forever")


def main():
    for fn in (test_plan_covers_every_billable_kind, test_deletes_before_waiting, test_wait_has_a_timeout):
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"pre-destroy: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 tests/test_pre_destroy.py`
Expected: FAIL, the script does not exist.

- [ ] **Step 3: Write the pre-destroy hook**

Create `scripts/pre-destroy.py`:

```python
#!/usr/bin/env python3
"""Remove everything Terraform cannot sequence, before `terraform destroy`.

Two classes of object outlive a destroy and keep billing:

  * ALBs and NLBs, because the AWS Load Balancer Controller created them from an
    Ingress or a Service, not from a Terraform resource. Destroy the cluster first
    and the controller is gone before it can clean up. The load balancer bills about
    $16/month with nothing in the account pointing at what made it, and its security
    groups keep the VPC deletion hanging.
  * EBS volumes behind PVCs, for the same reason via the EBS CSI driver.

So: delete the Kubernetes objects, let the controllers do their own cleanup, and
only then hand over to Terraform. Ordering is the whole point.

    make down                  # runs this first
    SKIP_PRE_DESTROY=1 make down   # skip it (cluster already gone / API unreachable)
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from dataclasses import dataclass

WAIT_SECONDS = 300
POLL_SECONDS = 10


@dataclass(frozen=True)
class Step:
    action: str          # "delete" | "wait"
    kind: str
    description: str
    timeout_seconds: int = 0


def plan() -> list[Step]:
    """What pre-destroy does, in order. Deletes first, then one wait for all of it."""
    return [
        Step("delete", "ingress", "every Ingress in every namespace (releases the shared ALB)"),
        Step("delete", "service", "every LoadBalancer Service (releases any NLB)"),
        Step("delete", "persistentvolumeclaim", "every PVC (releases the EBS volumes behind them)"),
        Step("wait", "loadbalancer", "poll until no load balancer remains for this cluster", WAIT_SECONDS),
    ]


def kubectl(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, check=check)


def api_reachable() -> bool:
    return kubectl("version", "--request-timeout=10s").returncode == 0


def delete_all(kind: str, selector: str | None = None) -> None:
    args = ["delete", kind, "--all-namespaces", "--all", "--ignore-not-found", "--timeout=120s"]
    if kind == "service":
        # There is no field selector for spec.type, so list and filter.
        out = kubectl("get", "svc", "-A", "-o",
                      "jsonpath={range .items[?(@.spec.type==\"LoadBalancer\")]}{.metadata.namespace} {.metadata.name}{\"\\n\"}{end}")
        for line in out.stdout.splitlines():
            if not line.strip():
                continue
            ns, name = line.split()
            print(f"  deleting LoadBalancer service {ns}/{name}")
            kubectl("-n", ns, "delete", "svc", name, "--ignore-not-found", "--timeout=120s")
        return
    print(f"  deleting all {kind}")
    kubectl(*args)


def remaining_load_balancers() -> int:
    """Ask AWS, not Kubernetes - the object can be gone while the ALB still exists."""
    cluster = subprocess.run(
        [sys.executable, "scripts/bootstrap.py", "dev", "output", "-raw", "cluster_name"],
        capture_output=True, text=True,
    ).stdout.strip()
    if not cluster:
        return 0
    out = subprocess.run(
        ["aws", "elbv2", "describe-load-balancers", "--query",
         "length(LoadBalancers[?contains(LoadBalancerName, `k8s-`)])", "--output", "text"],
        capture_output=True, text=True,
    )
    try:
        return int(out.stdout.strip() or "0")
    except ValueError:
        return 0


def main() -> int:
    if os.environ.get("SKIP_PRE_DESTROY"):
        print("pre-destroy: skipped (SKIP_PRE_DESTROY is set)")
        return 0
    if not api_reachable():
        print("pre-destroy: cluster API is unreachable - nothing to clean up, continuing")
        return 0

    print("pre-destroy: removing everything the controllers own before terraform destroy")
    for step in plan():
        if step.action == "delete":
            print(f"- {step.description}")
            delete_all(step.kind)

    print(f"- waiting up to {WAIT_SECONDS}s for load balancers to disappear")
    deadline = time.time() + WAIT_SECONDS
    while time.time() < deadline:
        n = remaining_load_balancers()
        if n == 0:
            print("pre-destroy: no load balancers remain - safe to destroy")
            return 0
        print(f"  {n} load balancer(s) still present, waiting...")
        time.sleep(POLL_SECONDS)

    print("pre-destroy: load balancers are STILL present after the timeout.", file=sys.stderr)
    print("Destroying now would orphan them (about $16/month each) and probably hang on VPC deletion.", file=sys.stderr)
    print("Check the AWS console, delete them by hand, then re-run `make down`.", file=sys.stderr)
    print("To destroy anyway: SKIP_PRE_DESTROY=1 make down", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python3 tests/test_pre_destroy.py`
Expected: PASS, 5 assertions.

- [ ] **Step 5: Wire it into `make down`**

In `Makefile`, change the `down` target:

```makefile
down: guard-env ## terraform destroy, auto-approved (RUN THIS WHEN DONE to stop charges)
	@$(PYTHON) scripts/pre-destroy.py
	$(BOOT) $(ENV) init -input=false
	$(BOOT) $(ENV) destroy -auto-approve
```

The `@` matters: pre-destroy prints a lot and its own output is the useful part.

- [ ] **Step 6: Add it to the static suite**

In `Makefile.test`, add the two new tests to `answers-check`, or better, rename that target to `py-tests` and have it run every Python test:

```makefile
py-tests: ## Run every stdlib Python test in tests/
	python3 scripts/gen-answers.py --check
	python3 tests/test_answers.py
	python3 tests/test_gen_answers.py
	python3 tests/test_git_seed.py
	python3 tests/test_pre_destroy.py
```

Update `test:` to depend on `py-tests` instead of `answers-check`.

- [ ] **Step 7: Run the full static suite**

Run: `make -f Makefile.test test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add scripts/pre-destroy.py tests/test_pre_destroy.py Makefile Makefile.test
git commit -m "feat: pre-destroy hook so make down never orphans an ALB or a PVC"
```

---

## Phase 5: The mothership GUI

**This phase produces the first thing to look at.** Task 5.3 serves a working UI from a Vite dev server in Podman, on a probed port in 30000+, with no cluster and no AWS. Everything before it is code with tests; this is where it becomes a product.

The quality bar is explicit: this should feel like a tool someone chose, not a form someone was given.

### Task 5.1: Fastify server, static hosting, and the websocket

**Files:**

- Create: `drill/server/src/server.ts`, `drill/server/src/config.ts`, `drill/server/src/ws.ts`
- Modify: `drill/server/src/index.ts`, `drill/server/package.json`
- Test: `drill/server/src/server.test.ts`

**Interfaces:**

- Consumes: `ClientMessage`, `ServerMessage` from `@drill/shared`.
- Produces:
  - `createServer(opts: ServerOptions): Promise<FastifyInstance>` where `ServerOptions = { port: number; host: string; webRoot: string; answersDir: string; workspaceDir: string; scenario: string }`.
  - `GET /healthz` -> `200 {"ok":true}`.
  - `GET /api/session` -> the current `SessionState`.
  - `GET /api/tasks` -> the scenario's tasks with `answer` **stripped**, because the answer key must never reach the browser.
  - `POST /api/submit` `{taskId, answer}` -> a `Verdict`.
  - `WS /ws` -> the `ClientMessage`/`ServerMessage` protocol.
  - `loadConfig(env: NodeJS.ProcessEnv): ServerOptions` reading `DRILL_PORT` (default 8090), `DRILL_HOST` (default `0.0.0.0`), `DRILL_WEB_ROOT`, `DRILL_ANSWERS_DIR`, `DRILL_WORKSPACE`, `DRILL_SCENARIO`.

- [ ] **Step 1: Add the dependencies**

In `drill/server/package.json`, add to `dependencies`:

```json
    "fastify": "^5.0.0",
    "@fastify/static": "^8.0.0",
    "@fastify/websocket": "^11.0.0",
    "@fastify/http-proxy": "^10.0.0",
    "node-pty": "^1.0.0",
    "@kubernetes/client-node": "^1.0.0",
    "ws": "^8.18.0"
```

and to `devDependencies`: `"@types/ws": "^8.5.0"`.

Run: `make -f Makefile.test drill-install`

`node-pty` is a native module. If it fails to build in `node:20-alpine`, switch `NODE_IMAGE` in `Makefile.test` to `docker.io/node:20-bookworm-slim` and note why in `drill/README.md`. The runtime image in Task 5.6 must match whichever one builds.

- [ ] **Step 2: Write the failing test**

Create `drill/server/src/server.test.ts`:

```typescript
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "./server.ts";
import type { FastifyInstance } from "fastify";

let app: FastifyInstance;

before(async () => {
  app = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: new URL("../test-fixtures/web", import.meta.url).pathname,
    answersDir: new URL("../../../scenarios/answers", import.meta.url).pathname,
    workspaceDir: new URL("../test-fixtures/workspace", import.meta.url)
      .pathname,
    scenario: "03",
  });
});

after(async () => {
  await app.close();
});

test("healthz is up", async () => {
  const res = await app.inject({ method: "GET", url: "/healthz" });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { ok: true });
});

test("tasks are served without the answers", async () => {
  const res = await app.inject({ method: "GET", url: "/api/tasks" });
  assert.equal(res.statusCode, 200);
  const tasks = res.json() as Array<Record<string, unknown>>;
  assert.equal(tasks.length, 6);
  for (const t of tasks) {
    assert.ok(t.prompt, "task keeps its prompt");
    assert.equal(t.answer, undefined, "task must NOT carry the answer");
    assert.equal(t.accept, undefined, "task must NOT carry the accept rules");
    assert.equal(t.must_include, undefined, "task must NOT carry must_include");
    assert.equal(
      t.accept_pattern,
      undefined,
      "task must NOT carry accept_pattern",
    );
  }
});

test("hints are not served up front either", async () => {
  const res = await app.inject({ method: "GET", url: "/api/tasks" });
  for (const t of res.json() as Array<Record<string, unknown>>) {
    assert.equal(
      t.hints,
      undefined,
      "hints arrive with a verdict, not in the task list",
    );
  }
});

test("a correct submission grades as passed", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: {
      taskId: "1",
      answer:
        "kubectl -n practice-app rollout history deploy/practice-app-frontend",
    },
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().passed, true);
});

test("a wrong submission returns the hint, not the answer", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: {
      taskId: "1",
      answer: "kubectl rollout history deploy/practice-app-frontend",
    },
  });
  const verdict = res.json();
  assert.equal(verdict.passed, false);
  assert.equal(verdict.hint, "missing-namespace");
  assert.ok(
    !JSON.stringify(verdict).includes("jsonpath"),
    "the canonical answer must not leak in a verdict",
  );
});

test("an unknown task id is a 404, not a crash", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: { taskId: "99", answer: "x" },
  });
  assert.equal(res.statusCode, 404);
});

test("session state starts at the first task with nothing passed", async () => {
  const res = await app.inject({ method: "GET", url: "/api/session" });
  const state = res.json();
  assert.equal(state.scenario, "03");
  assert.equal(state.currentTaskId, "1");
  assert.deepEqual(state.passed, []);
});

test("a submission is recorded as an attempt whether it passed or not", async () => {
  await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: { taskId: "1", answer: "nonsense" },
  });
  const state = (
    await app.inject({ method: "GET", url: "/api/session" })
  ).json();
  assert.ok(
    state.attempts.length > 0,
    "attempts are append-only, including failures",
  );
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make -f Makefile.test drill-test`
Expected: FAIL, `Cannot find module './server.ts'`.

- [ ] **Step 4: Write the config module**

Create `drill/server/src/config.ts`:

```typescript
/** Everything the server needs, from the environment, with no hidden defaults for paths. */
export interface ServerOptions {
  port: number;
  host: string;
  webRoot: string;
  answersDir: string;
  workspaceDir: string;
  scenario: string;
}

/**
 * 8090 on purpose: `make argo-ui` holds 8080 and `make grafana-ui` holds 3000, and
 * colliding with either during local development is a confusing five minutes.
 */
export const DEFAULT_PORT = 8090;

export function loadConfig(env: NodeJS.ProcessEnv): ServerOptions {
  const required = (key: string): string => {
    const value = env[key];
    if (!value)
      throw new Error(
        `${key} is not set - the drill server needs an explicit path, not a guess`,
      );
    return value;
  };
  return {
    port: Number(env.DRILL_PORT ?? DEFAULT_PORT),
    host: env.DRILL_HOST ?? "0.0.0.0",
    webRoot: required("DRILL_WEB_ROOT"),
    answersDir: required("DRILL_ANSWERS_DIR"),
    workspaceDir: required("DRILL_WORKSPACE"),
    scenario: required("DRILL_SCENARIO"),
  };
}
```

- [ ] **Step 5: Write the server**

Create `drill/server/src/server.ts`:

```typescript
/**
 * The drill server.
 *
 * One rule shapes every route here: the answer key never reaches the browser.
 * The client sends what the user did; the server decides whether it was right and
 * sends back a verdict and, on failure, a hint. Ship the accept rules to the client
 * and the drill becomes a reading exercise.
 */
import Fastify, { type FastifyInstance } from "fastify";
import fastifyStatic from "@fastify/static";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { SessionState, Verdict, Attempt } from "@drill/shared";
import {
  loadAnswers,
  type AnswerSet,
  type AnswerTask,
} from "./grader/answers.ts";
import { grade } from "./grader/index.ts";
import type { ServerOptions } from "./config.ts";

/** The task shape the browser is allowed to see. */
interface PublicTask {
  id: string;
  prompt: string;
  grader: AnswerTask["grader"];
  /** Only for file tasks, so the editor can open the right file. Not the expected value. */
  path?: string;
}

function toPublic(task: AnswerTask): PublicTask {
  const out: PublicTask = {
    id: task.id,
    prompt: task.prompt,
    grader: task.grader,
  };
  if (task.grader === "file" && task.path) out.path = task.path;
  return out;
}

export async function createServer(
  opts: ServerOptions,
): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  const answers: AnswerSet = await loadAnswers(opts.scenario, opts.answersDir);

  const state: SessionState = {
    scenario: opts.scenario,
    sessionId: process.env.DRILL_SESSION_ID ?? "local",
    startedAt: new Date().toISOString(),
    currentTaskId: answers.tasks[0]?.id ?? "",
    passed: [],
    attempts: [],
  };

  app.get("/healthz", async () => ({ ok: true }));

  app.get("/api/session", async () => state);

  app.get("/api/tasks", async () => answers.tasks.map(toPublic));

  app.post<{ Body: { taskId: string; answer: string } }>(
    "/api/submit",
    async (req, reply) => {
      const { taskId, answer } = req.body ?? { taskId: "", answer: "" };
      const task = answers.tasks.find((t) => t.id === taskId);
      if (!task)
        return reply
          .code(404)
          .send({ error: `no task ${taskId} in scenario ${opts.scenario}` });

      // A file task grades the workspace on disk, not something the user typed. The
      // point of the task is that the file really changed, which a text box cannot prove.
      let fileContent: string | undefined;
      if (task.grader === "file" && task.path) {
        try {
          fileContent = await readFile(
            join(opts.workspaceDir, task.path),
            "utf8",
          );
        } catch {
          fileContent = "";
        }
      }

      const verdict: Verdict = grade(task, answer, fileContent);

      const attempt: Attempt = {
        taskId,
        at: new Date().toISOString(),
        submitted: answer,
        passed: verdict.passed,
        message: verdict.message,
      };
      // Append-only. A failed attempt is the record of how you got there, and
      // deleting it would turn the log into a report card.
      state.attempts.push(attempt);

      if (verdict.passed && !state.passed.includes(taskId)) {
        state.passed.push(taskId);
        const next = answers.tasks.find((t) => !state.passed.includes(t.id));
        state.currentTaskId = next?.id ?? "";
      }

      return verdict;
    },
  );

  await app.register(fastifyStatic, { root: opts.webRoot, wildcard: false });
  app.setNotFoundHandler((req, reply) => {
    // SPA fallback, but only for navigations - a missing /api path stays a 404.
    if (req.url.startsWith("/api"))
      return reply.code(404).send({ error: "not found" });
    return reply.sendFile("index.html");
  });

  return app;
}
```

- [ ] **Step 6: Create the test fixtures**

```bash
mkdir -p drill/server/test-fixtures/web drill/server/test-fixtures/workspace/helm/practice-app
printf '<!doctype html><title>fixture</title>\n' > drill/server/test-fixtures/web/index.html
cp helm/practice-app/values.yaml drill/server/test-fixtures/workspace/helm/practice-app/values.yaml
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `make -f Makefile.test drill-test`
Expected: PASS, 8 new tests. The answer-leak assertions are the ones that matter most; if any fails, fix the serialisation before continuing.

- [ ] **Step 8: Commit**

```bash
git add drill/server/src/server.ts drill/server/src/config.ts drill/server/src/server.test.ts drill/server/test-fixtures/ drill/server/package.json
git commit -m "feat: drill server with answer-key-never-leaves-the-server API"
```

---

### Task 5.2: The PTY, tmux, and scrollback that survives a restart

**Files:**

- Create: `drill/server/src/pty.ts`
- Modify: `drill/server/src/server.ts` (register the `/ws` route)
- Test: `drill/server/src/pty.test.ts`

**Interfaces:**

- Consumes: `ClientMessage`, `ServerMessage`.
- Produces:
  - `class TerminalSession { constructor(opts: { cwd: string; sessionName: string; logPath: string }); onData(cb: (chunk: string) => void): void; write(data: string): void; resize(cols: number, rows: number): void; replay(): Promise<string>; dispose(): void; }`
  - The PTY runs `tmux new-session -A -s <sessionName>`, so a browser disconnect leaves the session running and a reconnect reattaches to exactly where it was.
  - Every byte the PTY emits is teed to `logPath` on the PVC, and `replay()` returns the tail (capped at 256 KB) so a **pod** restart still shows recent scrollback. tmux handles disconnects; the log handles restarts. They are different failures and both are worth solving.

- [ ] **Step 1: Write the failing test**

Create `drill/server/src/pty.test.ts`:

```typescript
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TerminalSession } from "./pty.ts";

const settle = (ms = 400) => new Promise((r) => setTimeout(r, ms));

test("a PTY echoes what is written to it", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-echo",
    logPath: join(dir, "pty.log"),
    shell: "/bin/sh",
  });
  let seen = "";
  term.onData((c) => {
    seen += c;
  });
  term.write("echo hello-drill\n");
  await settle(800);
  assert.match(seen, /hello-drill/);
  term.dispose();
});

test("output is teed to the log file", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const logPath = join(dir, "pty.log");
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-log",
    logPath,
    shell: "/bin/sh",
  });
  term.write("echo persisted-line\n");
  await settle(800);
  term.dispose();
  assert.match(await readFile(logPath, "utf8"), /persisted-line/);
});

test("replay returns the log tail so a pod restart keeps scrollback", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const logPath = join(dir, "pty.log");
  const first = new TerminalSession({
    cwd: dir,
    sessionName: "test-replay",
    logPath,
    shell: "/bin/sh",
  });
  first.write("echo before-restart\n");
  await settle(800);
  first.dispose();

  const second = new TerminalSession({
    cwd: dir,
    sessionName: "test-replay",
    logPath,
    shell: "/bin/sh",
  });
  assert.match(await second.replay(), /before-restart/);
  second.dispose();
});

test("replay is capped so a long drill does not blow up the first frame", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const logPath = join(dir, "pty.log");
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-cap",
    logPath,
    shell: "/bin/sh",
  });
  term.write("yes drill-filler | head -50000\n");
  await settle(2500);
  const tail = await term.replay();
  assert.ok(
    tail.length <= 256 * 1024,
    `replay was ${tail.length} bytes, cap is 256KB`,
  );
  term.dispose();
});

test("resize does not throw", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-resize",
    logPath: join(dir, "pty.log"),
    shell: "/bin/sh",
  });
  assert.doesNotThrow(() => term.resize(120, 40));
  term.dispose();
});

test("replay on a fresh session with no log is empty, not an error", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-fresh",
    logPath: join(dir, "nope.log"),
    shell: "/bin/sh",
  });
  assert.equal(await term.replay(), "");
  term.dispose();
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make -f Makefile.test drill-test`
Expected: FAIL, `Cannot find module './pty.ts'`.

- [ ] **Step 3: Write the implementation**

Create `drill/server/src/pty.ts`:

```typescript
/**
 * The terminal.
 *
 * Two different things can interrupt a drill and they need different fixes:
 *
 *   a browser disconnect  -> tmux keeps the session alive; reattaching lands you
 *                            exactly where you were, mid-command if need be.
 *   a pod restart         -> tmux dies with the pod, so every byte is also teed to
 *                            the PVC and the tail is replayed into the new terminal.
 *
 * Solving only the first leaves you staring at a blank screen after an OOM kill;
 * solving only the second loses your running command. Both are cheap.
 */
import { spawn, type IPty } from "node-pty";
import { createWriteStream, type WriteStream } from "node:fs";
import { open, mkdir } from "node:fs/promises";
import { dirname } from "node:path";

const REPLAY_CAP_BYTES = 256 * 1024;

export interface TerminalOptions {
  cwd: string;
  /** tmux session name. Reused across reconnects on purpose. */
  sessionName: string;
  /** Where the PTY log is teed. Lives on the PVC in the cluster. */
  logPath: string;
  /** Overridable for tests; production is tmux. */
  shell?: string;
}

export class TerminalSession {
  private pty: IPty;
  private log: WriteStream | undefined;
  private readonly logPath: string;

  constructor(opts: TerminalOptions) {
    this.logPath = opts.logPath;

    // `new-session -A` attaches if it exists and creates it if it does not, which
    // makes reconnect and first-connect the same code path.
    const [file, args] = opts.shell
      ? [opts.shell, [] as string[]]
      : ["tmux", ["new-session", "-A", "-s", opts.sessionName]];

    this.pty = spawn(file, args, {
      name: "xterm-256color",
      cols: 120,
      rows: 32,
      cwd: opts.cwd,
      env: { ...process.env, TERM: "xterm-256color" },
    });

    void this.openLog();
  }

  private async openLog(): Promise<void> {
    await mkdir(dirname(this.logPath), { recursive: true });
    this.log = createWriteStream(this.logPath, { flags: "a" });
    this.pty.onData((chunk) => this.log?.write(chunk));
  }

  onData(cb: (chunk: string) => void): void {
    this.pty.onData(cb);
  }

  write(data: string): void {
    this.pty.write(data);
  }

  resize(cols: number, rows: number): void {
    try {
      this.pty.resize(cols, rows);
    } catch {
      // A resize race against a dying PTY is not worth crashing the server over.
    }
  }

  /** The tail of the log, capped, for painting the terminal on reconnect. */
  async replay(): Promise<string> {
    let handle;
    try {
      handle = await open(this.logPath, "r");
    } catch {
      return "";
    }
    try {
      const { size } = await handle.stat();
      const start = Math.max(0, size - REPLAY_CAP_BYTES);
      const buf = Buffer.alloc(Math.min(size, REPLAY_CAP_BYTES));
      await handle.read(buf, 0, buf.length, start);
      return buf.toString("utf8");
    } finally {
      await handle.close();
    }
  }

  dispose(): void {
    this.log?.end();
    try {
      this.pty.kill();
    } catch {
      // Already gone.
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make -f Makefile.test drill-test`
Expected: PASS, 6 new tests. The container must have `/bin/sh`; if `node-pty` fails to load, revisit the image choice from Task 5.1 Step 1.

- [ ] **Step 5: Wire the websocket into the server**

In `drill/server/src/server.ts`, register `@fastify/websocket` and add the `/ws` route, replaying scrollback as the first frame:

```typescript
await app.register(fastifyWebsocket);
app.register(async (scoped) => {
  scoped.get("/ws", { websocket: true }, async (socket) => {
    const send = (msg: ServerMessage) => socket.send(JSON.stringify(msg));
    const term = new TerminalSession({
      cwd: opts.workspaceDir,
      sessionName: `drill-${opts.scenario}`,
      logPath: join(opts.workspaceDir, "..", "pty", `${opts.scenario}.log`),
    });

    // Paint the tail first, so a reconnect never opens onto a blank screen.
    const tail = await term.replay();
    if (tail) send({ type: "term:output", data: tail });
    send({ type: "session", state });

    term.onData((data) => send({ type: "term:output", data }));

    socket.on("message", (raw: Buffer) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString()) as ClientMessage;
      } catch {
        return send({ type: "error", message: "malformed message" });
      }
      switch (msg.type) {
        case "term:input":
          return term.write(msg.data);
        case "term:resize":
          return term.resize(msg.cols, msg.rows);
        default:
          return;
      }
    });

    // tmux keeps the shell alive; only the local handle is dropped.
    socket.on("close", () => term.dispose());
  });
});
```

- [ ] **Step 6: Commit**

```bash
git add drill/server/src/pty.ts drill/server/src/pty.test.ts drill/server/src/server.ts
git commit -m "feat: PTY over websocket with tmux sessions and replayable scrollback"
```

---

### Task 5.3: The React shell - **the first visual**

Four panels: terminal, editor, answers, help. The design language is already in this repo, in `PRACTICE_ANSWERS.html`: dark by default with a light toggle, `--bg: #10141a`, `--accent: #7aa2f7`, `--good: #9ece6a`, `--warn: #e0af68`. Reuse it rather than inventing a second one, so the drill GUI and the answer key look like parts of the same product.

**Files:**

- Create: `drill/web/package.json`, `drill/web/tsconfig.json`, `drill/web/vite.config.ts`, `drill/web/index.html`
- Create: `drill/web/src/main.tsx`, `drill/web/src/App.tsx`, `drill/web/src/theme.css`
- Create: `drill/web/src/panels/TerminalPanel.tsx`, `EditorPanel.tsx`, `AnswersPanel.tsx`, `HelpPanel.tsx`, `StatusBar.tsx`
- Create: `drill/web/src/lib/ws.ts`
- Modify: `Makefile.test` (add `drill-dev`)

**Interfaces:**

- Consumes: `ClientMessage`, `ServerMessage`, `SessionState`, `Verdict` from `@drill/shared`.
- Produces:
  - `useDrillSocket(): { send: (m: ClientMessage) => void; onMessage: (cb: (m: ServerMessage) => void) => () => void; connected: boolean }`
  - A four-panel layout: resizable split, terminal bottom-left, editor top-left, answers right, help behind a tab on the right.
  - `make -f Makefile.test drill-dev` starts Vite in Podman on a probed port and prints the URL.

- [ ] **Step 1: Scaffold the web workspace**

`drill/web/package.json`:

```json
{
  "name": "@drill/web",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite --host 0.0.0.0",
    "build": "tsc -b && vite build",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@drill/shared": "*",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "@xterm/xterm": "^5.5.0",
    "@xterm/addon-fit": "^0.10.0",
    "@xterm/addon-webgl": "^0.18.0",
    "@monaco-editor/react": "^4.6.0",
    "react-resizable-panels": "^2.1.0"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.0",
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0",
    "typescript": "^5.6.0",
    "vite": "^5.4.0"
  }
}
```

`drill/web/vite.config.ts` - the API proxy target comes from an env var, per the container-sandbox skill's rule about `API_PROXY_TARGET`:

```typescript
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const target = process.env.API_PROXY_TARGET ?? "http://127.0.0.1:8090";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    proxy: {
      "/api": { target, changeOrigin: true },
      "/ws": { target: target.replace(/^http/, "ws"), ws: true },
    },
  },
  build: { outDir: "dist", emptyOutDir: true },
});
```

- [ ] **Step 2: Write the theme, lifted from the repo's own answer key**

Create `drill/web/src/theme.css`:

```css
/* The design language already exists in PRACTICE_ANSWERS.html. Reusing it means the
   drill GUI and the answer key read as one product rather than two side projects. */
:root {
  --bg: #10141a;
  --panel: #161b22;
  --panel-2: #1c232c;
  --border: #263041;
  --fg: #d7dee9;
  --dim: #8b98ab;
  --accent: #7aa2f7;
  --good: #9ece6a;
  --warn: #e0af68;
  --bad: #f7768e;
  --radius: 10px;
  --gap: 12px;
  --mono: ui-monospace, "JetBrains Mono", "SF Mono", Menlo, monospace;
  --sans: ui-sans-serif, -apple-system, "Segoe UI", Inter, sans-serif;
}

:root[data-theme="light"] {
  --bg: #f6f8fa;
  --panel: #ffffff;
  --panel-2: #f0f3f6;
  --border: #d5dce5;
  --fg: #1c2530;
  --dim: #5b6878;
  --accent: #3b6fd4;
}

* {
  box-sizing: border-box;
}

html,
body,
#root {
  height: 100%;
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font-family: var(--sans);
  /* Antialiasing matters at this size; the default rendering looks muddy on dark. */
  -webkit-font-smoothing: antialiased;
}

.panel {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  display: flex;
  flex-direction: column;
  overflow: hidden;
  min-height: 0; /* without this a flex child refuses to shrink and the layout scrolls */
}

.panel > header {
  padding: 8px 12px;
  border-bottom: 1px solid var(--border);
  font-size: 12px;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  color: var(--dim);
  display: flex;
  align-items: center;
  gap: 8px;
  flex: 0 0 auto;
}

.panel > .body {
  flex: 1 1 auto;
  min-height: 0;
  overflow: auto;
}

.dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--dim);
}
.dot.ready {
  background: var(--good);
}
.dot.starting {
  background: var(--warn);
}
.dot.absent {
  background: var(--bad);
}
```

- [ ] **Step 3: Write the websocket hook**

Create `drill/web/src/lib/ws.ts`:

```typescript
import { useEffect, useRef, useState, useCallback } from "react";
import type { ClientMessage, ServerMessage } from "@drill/shared";

/**
 * One socket for the whole app.
 *
 * It reconnects with backoff because a drill runs for half an hour and a dropped
 * frame should not mean a page refresh - tmux kept the shell alive, so the UI
 * should be able to catch up to it.
 */
export function useDrillSocket() {
  const socketRef = useRef<WebSocket | null>(null);
  const handlers = useRef(new Set<(m: ServerMessage) => void>());
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    let closed = false;
    let attempt = 0;
    let timer: number | undefined;

    const connect = () => {
      if (closed) return;
      const proto = location.protocol === "https:" ? "wss" : "ws";
      const ws = new WebSocket(`${proto}://${location.host}/ws`);
      socketRef.current = ws;

      ws.onopen = () => {
        attempt = 0;
        setConnected(true);
      };
      ws.onmessage = (ev) => {
        let msg: ServerMessage;
        try {
          msg = JSON.parse(ev.data as string) as ServerMessage;
        } catch {
          return;
        }
        for (const h of handlers.current) h(msg);
      };
      ws.onclose = () => {
        setConnected(false);
        if (closed) return;
        const delay = Math.min(1000 * 2 ** attempt++, 10_000);
        timer = window.setTimeout(connect, delay);
      };
    };

    connect();
    return () => {
      closed = true;
      if (timer) clearTimeout(timer);
      socketRef.current?.close();
    };
  }, []);

  const send = useCallback((msg: ClientMessage) => {
    socketRef.current?.readyState === WebSocket.OPEN &&
      socketRef.current.send(JSON.stringify(msg));
  }, []);

  const onMessage = useCallback((cb: (m: ServerMessage) => void) => {
    handlers.current.add(cb);
    return () => {
      handlers.current.delete(cb);
    };
  }, []);

  return { send, onMessage, connected };
}
```

- [ ] **Step 4: Write the terminal panel**

Create `drill/web/src/panels/TerminalPanel.tsx`:

```tsx
import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import type { ClientMessage, ServerMessage } from "@drill/shared";

interface Props {
  send: (m: ClientMessage) => void;
  onMessage: (cb: (m: ServerMessage) => void) => () => void;
}

export function TerminalPanel({ send, onMessage }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!hostRef.current) return;

    const term = new Terminal({
      fontFamily: "ui-monospace, 'JetBrains Mono', 'SF Mono', Menlo, monospace",
      fontSize: 13,
      // Slightly open leading; the default is cramped at this size and it is the
      // single biggest thing separating a terminal that feels good from one that does not.
      lineHeight: 1.25,
      cursorBlink: true,
      cursorStyle: "bar",
      allowProposedApi: true,
      theme: {
        background: "#161b22",
        foreground: "#d7dee9",
        cursor: "#7aa2f7",
        selectionBackground: "#7aa2f733",
        black: "#1c232c",
        red: "#f7768e",
        green: "#9ece6a",
        yellow: "#e0af68",
        blue: "#7aa2f7",
        magenta: "#bb9af7",
        cyan: "#7dcfff",
        white: "#d7dee9",
      },
    });

    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(hostRef.current);
    try {
      term.loadAddon(new WebglAddon());
    } catch {
      /* software rendering is fine */
    }
    fit.fit();

    term.onData((data) => send({ type: "term:input", data }));

    const unsubscribe = onMessage((msg) => {
      if (msg.type === "term:output") term.write(msg.data);
    });

    // ResizeObserver rather than a window listener: the panel is resizable
    // independently of the window, and a mis-sized PTY corrupts every redraw.
    const ro = new ResizeObserver(() => {
      fit.fit();
      send({ type: "term:resize", cols: term.cols, rows: term.rows });
    });
    ro.observe(hostRef.current);

    return () => {
      unsubscribe();
      ro.disconnect();
      term.dispose();
    };
  }, [send, onMessage]);

  return (
    <section className="panel" style={{ height: "100%" }}>
      <header>
        <span className="dot ready" /> terminal
      </header>
      <div className="body" ref={hostRef} style={{ padding: 8 }} />
    </section>
  );
}
```

- [ ] **Step 5: Write the remaining panels and App**

`AnswersPanel.tsx` renders the task list from `GET /api/tasks`, marks passed tasks with `--good`, posts to `/api/submit`, and shows the returned verdict inline. A failed verdict shows the hint in `--warn`, never a red X alone - the hint is the product.

`HelpPanel.tsx` shows the card's ticket text plus the dependency-chain status from the `deps` message, so "waiting on Argo" is visible rather than mysterious.

`EditorPanel.tsx` mounts Monaco against the file named by the current file task, with a 600ms debounced autosave posting `{type:"file:save"}` and a subtle "saved" indicator - the same contract as VS Code, so nothing has to be explained.

`StatusBar.tsx` is a single row: scenario, session id, connected dot, tasks passed, and an "exit and tear down" button that is deliberately not styled like a primary action.

`App.tsx` composes them with `react-resizable-panels`: a horizontal split with the editor over the terminal on the left, and the answers/help tabs on the right.

- [ ] **Step 6: Add the dev target and look at it**

In `Makefile.test`, add `drill-dev` to `.PHONY`:

```makefile
drill-dev: ## Vite dev server for the drill GUI, in Podman, on a probed free port
	@PORT=$$(python3 -c "import socket;s=socket.socket();s.bind(('',0));print(s.getsockname()[1])"); \
	 echo "drill GUI -> http://localhost:$$PORT"; \
	 podman run --rm -it --userns=keep-id -p $$PORT:5173 \
	   -v $(CURDIR)/drill:/app:Z -w /app/web \
	   -e API_PROXY_TARGET=http://host.containers.internal:8090 \
	   $(NODE_IMAGE) npm run dev -- --port 5173
```

Run it:

```bash
make -f Makefile.test drill-install
make -f Makefile.test drill-dev
```

Expected: Vite prints its ready line and the URL works. **This is the point to stop and show the user.** They asked to see a visual of what is being built; this is it, and it needs no cluster and no AWS. Get their reaction on the layout, the density, the terminal's feel, and the theme before building the remaining panels out.

- [ ] **Step 7: Commit**

```bash
git add drill/web/ Makefile.test
git commit -m "feat: drill GUI shell - terminal, editor, answers and help panels"
```

---

### Task 5.4: The Argo CD widget and the reverse proxy

**Expanded from interface level on 2026-08-21**, after the Task 5.3 review, as the plan's self-review requires.
What the review changed is recorded at the end of this task under "What the review changed".

**Files:**

- Create: `drill/server/src/integrations/k8s.ts`, `drill/server/src/integrations/argo.ts`, `drill/server/src/integrations/deps.ts`, `drill/server/src/proxy.ts`
- Create: `drill/web/src/panels/ArgoWidget.tsx`
- Modify: `drill/server/src/server.ts` (two routes), `drill/server/src/config.ts` (three option fields), `drill/web/src/App.tsx` (a third tab), `drill/web/src/lib/api.ts`, `drill/web/src/theme.css`
- Test: `drill/server/src/integrations/argo.test.ts`, `drill/server/src/integrations/deps.test.ts`

**Interfaces:**

- Consumes: `DependencyStatus` from `@drill/shared`.
- Produces:
  - `K8sReader` - a three-method read-only seam over the Kubernetes API.
  - `getApplication(reader, name, namespace): Promise<ArgoApplication>` carrying `sync`, `health`, `revision` and a resource tree.
  - `checkDependencies(reader, opts): Promise<DependencyStatus[]>` - one entry each for `cluster-git`, `argocd` and `practice-app`.
  - `registerProxy(app, { argo, grafana })` - `@fastify/http-proxy` at `/argo/*` and `/grafana/*`, stripping the framing headers on the way through.

**Why the Kubernetes API and not Argo's REST API.**

Argo's own API needs a bearer token, which needs an account, which needs rotating, and it is a second network hop to a service that may not be up.
The `Application` CRD's `.status` already carries sync state, health, the synced revision and the full resource tree, and the drill pod's ServiceAccount is `cluster-admin`, so reading the CRD needs no new credential at all.
This is the same reasoning that put cluster git behind `git daemon` rather than behind an authenticated host: fewer credentials beats more features when the feature is a status read.

- [ ] **Step 1: Build the reader seam first, because it is what makes the rest testable**

Create `drill/server/src/integrations/k8s.ts`.
It holds one interface and one factory, and deliberately holds no logic:

```ts
export interface K8sReader {
  readCustomObject(g: CustomObjectRef): Promise<unknown | undefined>;
  readDeployment(
    name: string,
    namespace: string,
  ): Promise<DeploymentSnapshot | undefined>;
  readEndpoints(name: string, namespace: string): Promise<number | undefined>;
}
```

Every method returns `undefined` for "not found" and throws only for something that is genuinely wrong, which is the distinction the widget renders as "absent" versus an error banner.

`clusterReader()` wires `@kubernetes/client-node` and is the only place in the repo that imports it.
That containment is the point of the seam: the generated client's surface changed wholesale between 0.x and 1.x and will change again, and when it does exactly one 60-line file needs editing.
Everything with logic in it takes a `K8sReader` and is tested against a fake.

A 403 must not be swallowed.
`cluster-admin` means a 403 is a misconfigured ServiceAccount, not a missing object, and a widget that renders empty in that case sends the reader looking at Argo instead of at their RBAC.
Map it to a thrown error whose message names the ServiceAccount.

- [ ] **Step 2: Write the failing tests for the Application mapping**

Create `drill/server/src/integrations/argo.test.ts` with a fake `K8sReader` and assert:

1. A synced, healthy Application maps to `{ sync: "Synced", health: "Healthy" }` and carries its `revision`.
2. A missing Application returns `present: false` rather than throwing, because Argo not having been told about the app yet is a normal state during startup.
3. A 403 propagates as an error naming the ServiceAccount, rather than as an empty widget.
4. `OutOfSync` plus `Progressing` survives the mapping unchanged - the mapper must not normalise or prettify the strings, because they are Argo's vocabulary and the learner is going to type them into `argocd app get`.
5. The resource tree is flattened to `{ kind, name, status }` and a resource with no `status` becomes `"Unknown"` rather than disappearing.
6. A short revision is preserved and a 40-character sha is truncated to 7 for display, with the full value kept - the panel is narrow and a full sha pushes the health column off the edge.

- [ ] **Step 3: Run them red, then implement `argo.ts`**

The whole file is a mapper over `.status`.
Resist adding a cache: the widget polls every three seconds, a `get` on one CRD is a single etcd read, and a cache is a way to show a stale sync state during exactly the fifteen seconds the drill is about.

- [ ] **Step 4: `deps.ts` and its tests**

`checkDependencies` answers the startup question the help panel already has a slot for.
Three entries, and the derivation of each is the part worth testing:

| name           | ready when                                          | starting when                       | waiting when                                    | absent when        |
| -------------- | --------------------------------------------------- | ----------------------------------- | ----------------------------------------------- | ------------------ |
| `cluster-git`  | Service has at least one ready endpoint             | Deployment exists, no endpoints yet | -                                               | Deployment missing |
| `argocd`       | `argocd-server` Deployment has `readyReplicas >= 1` | Deployment exists, not ready        | -                                               | Deployment missing |
| `practice-app` | frontend Deployment ready                           | Deployment exists, not ready        | Argo Application exists but Deployment does not | neither exists     |

`waiting` for `practice-app` is the one that earns its place.
"Argo knows about it, Kubernetes has not made it yet" is the normal state for the first ninety seconds of a drill, and it is a genuinely different thing from "nothing has been told to create this", which is what `absent` means.
Collapsing the two produces a status line that says the app is missing while Argo is actively creating it.

Every lookup is wrapped so one failure cannot take the whole list down: a dependency that throws becomes `{ state: "absent", detail: <the error> }`, because the panel is a diagnostic and the moment it needs to work is the moment something is broken.

- [ ] **Step 5: Serve it, and push deps down the socket**

Add `GET /api/argo` and `GET /api/deps` to `server.ts`, both behind the same optional-reader pattern `readCommitted` uses: no reader configured means the route answers `{ present: false }` and the widget says so, rather than the server refusing to start outside a cluster.
That is what makes `make -f Makefile.test drill-dev` keep working on the laptop with no cluster anywhere.

`ServerMessage` already carries `deps`, so the websocket pushes the dependency list on connect and every ten seconds after.
Ten rather than three: the startup chain changes on the scale of pods starting, and this one is three API reads rather than one.

- [ ] **Step 6: The widget**

A third tab in the right-hand panel, beside `tasks` and `card`, labelled `argo`.
The rail is for sidebar views and this is not one; the review approved the right panel's shape, and a third tab is the change that leaves it approved.

It shows sync state, health, the short revision, and the resource tree, styled as this application rather than as an iframe of Argo.
Sync and health get the same dot vocabulary the status bar already uses, so `Synced`/`Healthy` reads at a glance and `OutOfSync` does not.

For scenario 03 task 5 this panel is the entire lesson.
You run `kubectl rollout undo`, the pods roll back, and then you watch Argo notice, mark the app `OutOfSync`, and put the bad version back - next to the terminal where you ran the command that did not stick.
The `only-imperative` hint already tells you this in words. The widget is the same sentence told in a way you cannot argue with.

- [ ] **Step 7: The proxy, built and deliberately not exercised**

`registerProxy` mounts `@fastify/http-proxy` at `/argo` and `/grafana`, taking upstreams from config so neither hostname is compiled in.
Both upstreams refuse to be framed by default, so the reply hook strips `X-Frame-Options` and rewrites CSP `frame-ancestors` - without that the iframe renders a blank rectangle and the browser console is the only clue why.

Not registered unless the upstream is configured.
An unconfigured proxy that answers with a connection error is worse than a route that is not there.

What is deferred, and why deferring is right: serving under a subpath needs Grafana's `root_url` plus `serve_from_sub_path`, and Argo CD's `server.rootpath`.
Both are Helm values already under our control, and both are version-sensitive enough to be worth verifying against the charts actually installed rather than from memory.
Scenario 07 is what installs those charts, so that is when to verify them.
Do not do subpath surgery now for a scenario that does not exist yet.

- [ ] **Step 8: Commit**

```bash
git add drill/server/src/integrations/ drill/server/src/proxy.ts drill/web/src/panels/ArgoWidget.tsx
git commit -m "feat: native Argo CD widget and the reverse proxy for full-app integrations"
```

**What the review changed.**

Two things, both small, both recorded so the next reader does not wonder whether this task was written before or after somebody looked at the product:

- The widget is a third tab in the existing right-hand panel rather than a fourth panel or a rail view. The user approved the layout as it stands and asked for no changes to it, so the correct move is the one that adds the widget without moving anything.
- The dot vocabulary and the theme variables come from what shipped at 5.3 rather than being invented here. There are five themes now, and a widget with its own hardcoded green is a widget that looks broken in four of them.

---

### Task 5.5: Container image and in-cluster deployment

**Expanded from interface level on 2026-08-21**, after the Task 5.3 review.

**Files:**

- Create: `drill/Containerfile`, `.containerignore` (repo root, because the build context is the repo root)
- Create: `scripts/drill-image.py`, `.github/workflows/drill-image.yml`
- Create: `terraform/modules/platform/drill-gui.tf`
- Modify: `Makefile` (add `drill-image`), `scripts/config.example.toml`, the variable chain from `envs/dev` down to `modules/platform`
- Test: `tests/test_containerignore.py` (static), plus the built-image assertion in Step 4 and the kind deploy in Step 8

**Five things this task must get right, each of which fails silently.**

Listed first because every one of them produces a drill that comes up and looks correct:

1. **The workspace is populated by `git clone`, never by a copy.** The workspace is the learner's working tree and `git push` from it is scenario 03's model answer. A copied directory has no remote, and the push fails at the moment the drill is testing.
2. **`readCommitted` must be filled.** The seam has been sitting unimplemented since Task 5.1. Left unset it means "commit state is not known", the `uncommitted` hint never fires, and the gap between saved and committed - the GitOps lesson - goes ungraded while every test stays green.
3. **The runtime image stays Alpine.** `node-pty` was compiled against musl in the builder. Copy those artifacts into a glibc runtime and the module fails to load, which surfaces as a terminal that never connects rather than as a build error.
4. **`*.test.ts` must not reach `dist/`.** `tsc -b` compiles what the tsconfig includes, and the test files sit beside the source. They pull `node:test` into a production image and inflate it for nothing.
5. **The image needs `scenarios/answers/`; the workspace must not have it.** These are two different trees and conflating them undoes the fix from 2026-08-21. The image carries the answer key because the grader reads it server-side. The workspace is a clone of cluster git, which carries `helm/` only.

- [ ] **Step 1: Thread `drill_gui_image` through the config chain**

Add to `scripts/config.example.toml`, in the drill platform block:

```toml
# The drill GUI image, in YOUR OWN registry. Published by `make drill-image`
# (local) or by .github/workflows/drill-image.yml (on push to main).
# Make the GHCR package PUBLIC so the cluster needs no imagePullSecret - this
# repo is public and the answer key is already committed, so the image holds
# nothing that is not already readable.
drill_gui_image = "ghcr.io/<your-github-username>/daily-eks-practice-drill-gui"
drill_gui_tag   = "latest"
enable_drill_gui = true
```

Three values, not one.
`drill_gui_tag` is separate because the repository path is a property of who you are and the tag is a property of which build you are running, and pinning a sha for a debugging session should not mean editing the value that carries your username.
`enable_drill_gui` mirrors `enable_cluster_git` so the GUI can be switched off without unpicking the module, which matters because it is the only thing in the stack that creates an ALB.

Declare each with **no `default =`** in `envs/dev/variables.tf`, `modules/stack/variables.tf` and `modules/platform/variables.tf`, and wire them through `envs/dev/main.tf` and `modules/stack/main.tf`, exactly as Task 3.1 did.

- [ ] **Step 2: Write the Containerfile**

Multi-stage. Builder is `node:22-alpine` plus `python3 make g++` for `node-pty`'s node-gyp build - the same toolchain `drill/Containerfile.build` already documents, and for the same reason: there is no prebuilt binary for linux-x64 on either libc.

Runtime is `node:22-alpine` plus `tmux`, `git`, `kubectl`, `helm` and `curl`.
The terminal is only useful if the tools the card names are on `PATH`, and a card that says `helm upgrade` against an image without helm is a broken drill that looks like a broken answer.

The runtime **must stay Alpine**, per the list above.

Run as a non-root user with a writable workspace mount.
`git` refuses to serve or operate on a repo whose owner uid differs from the running uid, which is the same "dubious ownership" trap `cluster-git.tf` already documents - use one uid, 1001, and an `fsGroup` to match, so the cloned workspace is owned by the user that will be committing in it.

- [ ] **Step 3: The deny-by-default `.containerignore`**

The build context is the repo root, not `drill/`, because the grader reads `scenarios/answers/<scenario>.toml` at runtime.
Widening the context is what makes this file security-critical rather than a build-speed optimisation: with the root in scope, `scripts/config.toml` is in scope, and that file holds the AWS account id, the profile name and the operator's public IP.
Baking those into a **public** image publishes all three.

So the file denies everything and then allows, rather than listing things to exclude:

```
# Deny by default. An exclude-list leaks the next secret file somebody adds;
# an allow-list cannot.
*
!drill/
!scenarios/answers/
```

Create it at the repo root as `.containerignore`.

Add `tests/test_containerignore.py` to the static suite asserting the file starts with a bare `*` and that no `!` line would re-admit `scripts/`, `.kubeconfig*` or `terraform/`.
An allow-list is one careless `!` from being an exclude-list, and the static test catches that in a second where the built-image check in Step 4 needs a build.

- [ ] **Step 4: Prove the ignore file holds, against the built image**

This is the one build failure that ships a credential rather than breaking a pipeline, so it is checked against the image and not against the file.

```bash
podman build -t localhost/drill-gui:dev -f drill/Containerfile .
podman run --rm --entrypoint /bin/sh localhost/drill-gui:dev -c \
  'ls /app/scripts/config.toml /app/.kubeconfig-daily-eks-practice 2>&1; ls /app/scenarios/answers/'
```

Expected: both secret paths report `No such file or directory`, and `03.toml` is listed.
If `config.toml` is present, stop and fix `.containerignore` before pushing anything anywhere.

This is `AC-H3`.

- [ ] **Step 5: Authenticate to GHCR by extending the existing `gh` grant**

**Scope the token `gh` already holds. Do not create a personal access token.**
Settled 2026-08-19, and it applies to any future GHCR or GitHub API scope this project needs.

```bash
gh auth refresh -h github.com -s write:packages
gh auth token | podman login ghcr.io -u "$(gh api user -q .login)" --password-stdin
```

`gh auth refresh` is interactive - it prints a one-time code and blocks on a browser - so an agent cannot run it.
Print the command, wait, then confirm with `gh auth status`.
**Done on 2026-08-21**; `write:packages` is in the scopes line and no PAT was created.

Why this rather than a PAT: a PAT has to live somewhere, and every candidate is worse.
`scripts/config.toml` is serialised into `config.auto.tfvars.json` and thence into Terraform state; a shell export lands in `~/.zsh_history`; a dotfile is one `git add -A` from being committed.
`gh` keeps its token in its own config outside this repo, and `scripts/argo-repo.py` already depends on that path working, so this is not a new dependency.

**Escape hatch, not an option.** If an org SSO configuration refuses the scope change, a classic PAT with `write:packages` is the only way through - reach for it only after the refresh has actually failed, say plainly that it was forced, and use `read -rsp` so the token never reaches a file or a history entry.
Fine-grained tokens are not a substitute; GHCR writes expect a classic token.

- [ ] **Step 6: `make drill-image` and the CI workflow**

`scripts/drill-image.py` reads `drill_gui_image` through `bootstrap.py --print`, refuses the `<your-github-username>` placeholder, tags with the short git sha **and** `latest`, and warns on a dirty tree because that tag will not reproduce from git.

`.github/workflows/drill-image.yml` publishes on push to `main` under `paths:` covering `drill/**` and `scenarios/answers/**`, using the automatic `GITHUB_TOKEN` with `permissions: packages: write`.
It derives the owner from `GITHUB_REPOSITORY_OWNER` lowercased, so no username is committed there either.
CI is the long-term publishing path because it builds from what is on `main`; the local target is for iterating.

- [ ] **Step 7: The Kubernetes manifests**

`terraform/modules/platform/drill-gui.tf`, following `cluster-git.tf`'s shape - `kubectl_manifest` with `yamlencode`, counted on `enable_drill_gui`.

Namespace `practice-drill`, ServiceAccount `drill` bound to `cluster-admin`, Deployment `drill-gui`, Service on 8090, a 15 GB gp3 PVC, and an Ingress in the shared group.

`cluster-admin` is deliberate and gets a comment: a read-only role cannot do scenario 10's break/fix, which is the entire reason that scenario exists.

An **init container clones cluster git into the PVC**, and clones rather than copies for the reason at the top of this task.
It must be idempotent - the PVC survives pod restarts, so a second start finds a populated workspace and must leave it alone rather than clobbering a half-finished drill.

The Ingress carries `alb.ingress.kubernetes.io/group.name` set to `drill_ingress_group_name` and `alb.ingress.kubernetes.io/security-groups` set to the source-restricted SG from Task 4.1.
Without the group annotation every ops Ingress provisions its own ALB, which is the difference between one load balancer and three - and it is the first point at which `WO-20260819-1fea`'s carried AC-H3 is observable at all.

**No `imagePullSecret` anywhere**, because the package is public. That is `AC-H5`.

- [ ] **Step 8: Deploy to kind and click through it**

```bash
make -f Makefile.test kind-up
export KUBECONFIG="$(bash scripts/kind-sandbox.sh kubeconfig)"
podman build -t localhost/drill-gui:dev -f drill/Containerfile .
kind load docker-image localhost/drill-gui:dev --name daily-eks-drill-sandbox
kubectl apply -f <rendered manifests>
kubectl -n practice-drill port-forward svc/drill-gui 8090:8090
```

Expected: the GUI loads at `http://localhost:8090`, the terminal attaches, and `kubectl get nodes` works from inside it.
**Second point to show the user**, this time running the way it will actually run. That is `AC-H4`.

The Ingress is not exercised here - kind has no ALB controller - so `AC-H3` from `WO-20260819-1fea` is evidenced from the rendered manifest and the `terraform plan`, not from a live load balancer. Say which it was.

- [ ] **Step 9: Commit**

```bash
git add drill/Containerfile .containerignore scripts/drill-image.py .github/workflows/drill-image.yml \
  Makefile terraform/ scripts/config.example.toml tests/test_containerignore.py
git commit -m "feat: drill GUI image and in-cluster deployment behind the shared ALB"
```

If the classic-PAT escape hatch was used, say so in the commit message along with what blocked `gh auth refresh`, so the next person does not rediscover it.

---

## Phase 6: Session lifecycle

Progress that survives a teardown, a watcher that keeps it current, and the Makefile handover.

**Expanded from interface level on 2026-08-21**, when `WO-20260819-7840` was started, exactly as this plan's self-review said it would be.
What the expansion changed is recorded at the end of the phase under "What the expansion changed".
The interface-level text below each task's heading is preserved; the steps are new.

### The one design decision the expansion had to make first

The interface-level plan had a single `POST /api/teardown` behind one `EXIT` button.
That was wrong, and it was wrong in a way only visible once the GUI existed: **`EXIT` is not one action.**

A learner who is done with scenario 03 wants one of several different things, and the button cannot tell which:
they want to restart it because they made a mess, or move to 06 because 03 clicked, or go back to 02 because it did not, or stop for the day, or stop for the day _and_ stop the bill.
Collapsing those into one destructive verb makes the common cases - restart, next - reachable only by tearing the whole environment down and building it again, which costs six minutes and the control plane charge for all of it.

**So `EXIT` opens a pause menu.** Every entry except the last two is a scenario transition, and a transition is the converge path Task 6.3 already builds, pointed at a different `N`.
That is the whole reason this is affordable: switching scenarios is not a new subsystem, it is `scenario.py` with a different argument and a loading screen in front of it.

```text
  ┌─ PAUSED ──────────── scenario 03 ─┐
  │  4/6 tasks passed                 │
  │                                   │
  │  ▸ RESUME                         │
  │  ▸ RESTART       fresh session    │
  │  ▸ NEXT          04 · not ported  │  (dim)
  │  ▸ PREVIOUS      02 · not ported  │  (dim)
  │  ▸ SELECT...                      │
  │  ▸ QUIT          end the run      │
  │  ▸ SHUT IT DOWN  destroy it all   │
  └───────────────────────────────────┘
   SELECT ->  01 ░ 02 ░ [03] 04 ░ 05 ░ 06 ░
              07 ░ 08 ░ 09 ░ 10 ░ 11 ░ 12 ░
              ░ = not ported yet
```

**All twelve scenarios are on the menu, and the eleven unported ones render disabled with the reason.**
Approved by the user at the Phase 6 kickoff.
The alternative - list only what works - was rejected because it hides the shape of the curriculum and changes the menu's geometry under the learner every time a scenario is ported.
This is the same call Phase 5 made when it shipped the `EXIT` button disabled and honest rather than absent.

**`SHUT IT DOWN` is a sanctioned exception to `CLAUDE.md` hard rule 1**, granted explicitly by the user at the Phase 6 kickoff, and hard rule 1 is amended in the same commit to say so.
An unwritten exception does not narrow a rule, it voids it - the next reader finds code that destroys AWS resources and a rule saying that never happens, and concludes the rule is decorative.
The exception is narrow and every clause of it is load-bearing:

- The browser requires the literal string `DESTROY` to be typed, and **the server re-checks it** rather than trusting the UI. A confirmation enforced only in the client is a suggestion.
- The pod does not destroy anything. It writes an intent into a ConfigMap. The destroy is executed by `scripts/drill-watch.py`, **a process the user started themselves, on their own laptop, in their own checkout**, against the Terraform state that lives there.
- The watcher prints a ten-second countdown that `ctrl-c` aborts, so the last gate is in the terminal the user is sitting at.
- It runs `make down`, which runs `scripts/pre-destroy.py` first. Ingresses, `LoadBalancer` Services and PVCs go before the cluster, and it exits 1 rather than destroying into a mess. The safe teardown path is not bypassed; it is the one being invoked.

**`QUIT` is not that.** It ends the run, syncs progress, deletes what the _scenario_ created, and leaves the drill pod, its PVC and the ALB up so the browser lands on a game-over screen with the menu still reachable.
Nothing the GUI does may strand the user outside the browser, because the browser is the only interface - that is the north star, and a `QUIT` that killed the pod would be a change to the loop rather than a feature in it.

### The state machine, and who owns which ConfigMap

Two ConfigMaps in `practice-drill`, and **each has exactly one writer**.
This is the whole contract, and it exists because a single object with two authors races on `resourceVersion` and loses a write at the moment progress matters most.

| Object          | Written by                                       | Read by          | Carries                                                   |
| --------------- | ------------------------------------------------ | ---------------- | --------------------------------------------------------- |
| `drill-state`   | the drill server, only                           | `drill-watch.py` | the live `SessionState`, including its `phase`            |
| `drill-request` | `scripts/scenario.py` and `drill-watch.py`, only | the drill server | which scenario to converge, and which saved session it is |

`SessionState` gains a `phase`, and the phase is what the two sides communicate through:

```text
   active ──────────────► switching ──────────► active
     │                    (target: "06")        (scenario 06)
     │
     ├──► ended               QUIT
     └──► destroy-requested   SHUT IT DOWN
```

The server polls `drill-request` every two seconds rather than watching it.
The laptop watcher watches `drill-state` with `kubectl --watch` rather than polling it.
**That asymmetry is deliberate and is not an inconsistency.**
The watcher is on the far side of a network from the API server, where a watch is genuinely better and is also the primitive every controller is built from - keeping the tool that teaches Kubernetes built out of Kubernetes is worth something on its own.
The server is _inside_ the cluster, microseconds from the API, where a poll of one small object costs nothing and a watch adds reconnects, bookmarks and `410 Gone` handling.
A watch that silently stops delivering is exactly the failure that makes a scenario switch hang forever with nothing in any log, and this project has already been bitten twice by silent-drop bugs of that family - the dropped websocket resize and the un-subscribed tmux burst.

### What cannot be tested in this phase, stated up front

**Only scenario 03 is ported.** The switch machinery can be proven - against a test fixture scenario, with a real converge, a real bundle round trip and a real session swap - but the thing it is ultimately for cannot be:

> drill 03, switch to 06, drill 06, switch back to 03, and find 03 exactly where you left it.

That round trip is **the exit-condition test for whichever epic ports the second scenario**, and it is recorded as such in `BACKLOG.md`, in this ticket's notes, and as a row in `CONTEXT_STATE.md`.
It is not a gap being hidden. It is a test whose fixture does not exist yet, said out loud in four places so it cannot lapse the way `AC-H3` nearly did in Phase 4.

---

### Task 6.1: drill-progress on the laptop

**Files:**

- Modify: `.gitignore`
- Create: `scripts/progress.py`
- Modify: `README.md`
- Test: `tests/test_progress.py`

**Interfaces:**

- Consumes: nothing.
- Produces:
  - `drill-progress/` layout, append-only:
    ```
    drill-progress/
      curriculum.json                    # running totals across all scenarios
      baseline.bundle                    # cluster git as git-seed left it
      current.json                       # which scenario is live, if any
      .watcher.pid
      .gui-owns-the-wheel
      03/
        index.json                       # results table + current-session pointer
        sessions/
          2026-08-19T14-03-11Z/
            state.json
            workspace.bundle
    ```
  - `session_dir(scenario: str, started_at: datetime) -> Path` - timestamps carry **no colons** and the current-session pointer is JSON, not a symlink, because Windows 11 is a supported target and both would break there.
  - `new_session(scenario) -> Path`, `record_result(scenario, session_id, passed, total)`, `current_session(scenario) -> str | None`, `write_atomic(path, data)`.
  - Every write is atomic: temp file then rename. Losing one task is annoying; a half-written save file is losing everything.

- [ ] **Step 1: Add the git-ignore entry before anything can create the directory**

This is `AC-H1` and it is Step 1 for a reason.
The directory holds a `git bundle` of the learner's working tree; if it can exist before `.gitignore` mentions it, it is one `git add -A` from being committed, and the first person to do that publishes their own practice history to a public repo.

```
# ---- your personal drill history (never commit; nobody wants to fork it) ----
drill-progress/
```

- [ ] **Step 2: Write the failing test**

`tests/test_progress.py` asserts: timestamps contain no `:` and no character illegal on Windows; a second session for the same scenario creates a new directory rather than replacing the first; `index.json` accumulates a results row per session and never loses one; `write_atomic` leaves the previous file intact when the write raises partway; `current_session` returns the newest.

Three of those need saying more precisely than the interface sketch did, because each is a real trap:

1. **The illegal-character set is `<>:"/\|?*`, plus the ASCII control range, plus a trailing dot or space.** A timestamp only trips the colon, but the assertion is written against the whole set so that a later change to the id format - adding the scenario, adding a counter - cannot introduce a name that works on Linux and makes the directory uncreatable on Windows. The failure mode there is `make scenario` dying inside `mkdir` on somebody else's machine, which is not a thing to discover in a bug report.
2. **"A second session creates a new directory" is really a same-second collision test.** Drive it with a fixed clock, because that is the only way to make the collision deterministic - and the collision is genuine: restart a drill twice inside one second and both sessions want `2026-08-19T14-03-11Z`. `new_session` disambiguates with a `-2`, `-3` suffix, and the test pins that the first directory still holds its original contents afterwards.
3. **`write_atomic` is tested by making the write fail partway**, with a data object whose serialisation raises after some bytes are already out. Assert the original file is byte-identical and no `.tmp` is left behind. Testing it by writing successfully proves nothing - every implementation passes that, including the one that truncates first.

- [ ] **Step 3: Implement, run the test, and document it in the README**

`write_atomic` writes a sibling temp file in the **same directory** and `os.replace`s it.
Not `tempfile.mkstemp` in the system temp dir: `os.replace` is only atomic within a filesystem, and on Linux `/tmp` is frequently a different one, which turns the atomic rename back into a copy that can be interrupted.

The README section must say what `drill-progress/` is and why it is ignored: it is your practice record, it is personal, and nobody forking this project wants to inherit someone else's attempt log.
It survives because it is on your laptop, not because it is committed.

- [ ] **Step 4: Commit**

```bash
git add .gitignore scripts/progress.py tests/test_progress.py README.md
git commit -m "feat: append-only drill-progress on the laptop"
```

---

### Task 6.2: The ConfigMap and the sync watcher

**Files:**

- Create: `scripts/clustergit.py`, `scripts/drill-watch.py`
- Create: `drill/server/src/state.ts`
- Modify: `drill/shared/src/index.ts` (`SessionState.phase`), `drill/server/src/server.ts`, `drill/server/src/integrations/k8s.ts`, `scripts/git-seed.py`
- Test: `tests/test_drill_watch.py`, `drill/server/src/state.test.ts`, plus a kind run

**Interfaces:**

- Consumes: `progress.py` from Task 6.1; `cluster_git_namespace`/`cluster_git_deployment` from Task 3.2.
- Produces:
  - ConfigMap `drill-state` in `practice-drill`, written by the server on every state change. It survives pod restarts, which is the failure that matters, and dies with the cluster, which is correct because the drill dies with the cluster anyway.
  - `scripts/drill-watch.py` - watches with `kubectl get cm drill-state -n practice-drill --watch`, not polling. The API server pushes changes, so there is no interval to tune and no lag on a task pass, and it is the primitive every controller is built on, which keeps the tool that teaches Kubernetes built out of Kubernetes.
  - PID file at `drill-progress/.watcher.pid`. Re-running is a no-op if the PID is live; a dead watcher is restarted by converge exactly like a dead pod; it syncs immediately on start to catch up on anything missed while it was down.

- [ ] **Step 1: Factor the cluster-git plumbing out of `git-seed.py` before anything else needs it**

`scripts/clustergit.py` takes `tf_outputs()`, `settings()`, `pod_name()`, `stream_command()` and `unbundle_script()` out of `git-seed.py` verbatim, and adds the two directions as named functions: `push_bundle()` and `pull_bundle()`.
`git-seed.py` becomes a caller and keeps its module docstring, its `DRILL_PATHS` filter and its `drill_tree()` builder, which are its own concerns and nobody else's.

This is not tidying.
Task 6.2 pulls a bundle out of the git server and Task 6.3 pushes one back in, and both are the same `kubectl exec` streaming primitive that `git-seed.py` already got right after a measured data-corruption bug.
Re-implementing either from memory is how `/bin/sh -c 'cat > file'` comes back, silently truncates a **save file** this time, and surfaces days later as `fatal: early EOF` when somebody tries to resume.
One implementation, one place, with the reason written on it.

`tests/test_git_seed.py` already puts `scripts/` on `sys.path` before loading the module, so the new import resolves under test with no change to the harness.
Keep every assertion in that file green - it pins the `tee` shape and the marker-last ordering, and both must survive the move unchanged.

- [ ] **Step 2: Give `SessionState` a phase, in `@drill/shared`**

```ts
export type SessionPhase =
  "active" | "switching" | "ended" | "destroy-requested";
```

`SessionState` gains `phase: SessionPhase`, an optional `target` (set only while `switching`) and an optional `endedAt`.
No new `ServerMessage` variant: the existing `session` message already carries the whole state, so the phase reaches the browser through a channel that is already tested.
Adding a message the web half does not handle is a compile error in this workspace, which is the property that makes the shared package worth having - do not weaken it by widening the union when the payload already fits.

- [ ] **Step 3: Add the writer seam to `k8s.ts`, and keep `K8sReader` read-only**

`k8s.ts` remains the only file in the repo importing `@kubernetes/client-node`.
It gains a **second, separate** interface rather than three more methods on `K8sReader`:

```ts
export interface K8sStateWriter {
  writeConfigMap(
    name: string,
    ns: string,
    data: Record<string, string>,
  ): Promise<void>;
}
```

The separation is the point.
`K8sReader`'s header says nothing the GUI does on the user's behalf mutates, and that rule is what stops a widget from passing a task the learner never performed - the same rule that keeps stage and commit buttons off the source control view.
The server writing **its own** session state is not an action on the user's behalf, it is the process's own bookkeeping, and a distinct type is what makes that distinction checkable instead of a comment somebody has to believe.
A route that takes a `K8sStateWriter` cannot be handed a reader, and a panel that takes a `K8sReader` cannot be handed a writer.

`writeConfigMap` reads, then replaces, and creates on 404.
A blind create fails on the second write; a blind replace fails on the first.

- [ ] **Step 4: `state.ts` - mirror the state, and guard the size**

`saveState(writer, state, opts)` serialises `SessionState` to one `state.json` key and writes it to `drill-state`.

**A ConfigMap is capped at 1 MiB and the API server rejects the whole object over it.**
`attempts` is append-only and unbounded by design, so the cap is reachable - not by a learner working through six tasks, but by a submit loop, a stuck client retrying, or the twentieth scenario in a long session.
The failure without a guard is the worst shape available: every write from that moment on fails, the ConfigMap silently stops advancing, the watcher keeps writing the last good state, and the learner's progress stops being saved with no symptom until they try to resume.

So `saveState` measures the encoded size, and above a threshold drops the **oldest** attempts until it fits, recording `attemptsDropped: n` in the payload.
Dropping the oldest is right: the recent ones are what a resume needs and what the `only-imperative` nudge reads. The count is recorded rather than the drop being silent, because a save file that quietly is not the whole story is the thing this repo has now been burned by three times - a vacuous `AC-H5` pass, a truncated git bundle, and `undefined` collapsing into "not committed".

`state.test.ts` covers it with a fake writer: a normal state round-trips whole; an oversized one fits, keeps the newest attempts, and reports the count; a writer that throws does not take the submit down with it.

- [ ] **Step 5: Wire it into the server, and make the ConfigMap the owner of `DRILL_SCENARIO`**

Every mutation of `state` calls `saveState`. That is `POST /api/submit` and the lifecycle routes from Task 6.5.
Submits are human-paced, so there is nothing to debounce and a debounce would only add a window in which a pass is not yet saved.

**A save failure must never fail a submit.** The learner answered correctly; whether we managed to mirror it is our problem, not theirs. Log it and return the verdict.

At startup the server reads `drill-request`. If it names a scenario, that wins and the env var is ignored; if there is none, `DRILL_SCENARIO` is the fallback and the server writes its initial `drill-state`.
This is what discharges the placeholder `terraform/modules/platform/drill-gui.tf` has carried since Task 5.5 - its `DRILL_SCENARIO = "03"` comment says in as many words that Phase 6's ConfigMap takes ownership, and this is the step that takes it.
The env var stays as the fallback rather than being deleted, because it is what makes `make -f Makefile.test drill-dev` work with no cluster anywhere.

- [ ] **Step 6: Write the failing test for the watcher's pure parts**

`tests/test_drill_watch.py` covers the pure parts: PID liveness detection, the bundle path construction, and that a sync writes to a temp file and renames rather than truncating the live one.

Two additions the interface sketch did not anticipate, both found by writing the thing:

1. **`kubectl get --watch -o json` emits a stream of concatenated JSON objects, not a JSON array and not one per line.** Nothing in the stdlib parses that directly. The reader is an incremental `json.JSONDecoder().raw_decode` over an accumulating buffer, and it is a pure function of a byte stream, so it is unit-tested: split an object across chunk boundaries, mid-string and mid-escape, and assert the same objects come out. A parser that works only when a chunk happens to end on an object boundary passes every naive test and fails intermittently in production.
2. **PID liveness cannot be `os.kill(pid, 0)`.** That is POSIX-only and Windows 11 is a supported target here. Worse, a bare PID is ambiguous on every platform - PIDs are reused, and a stale file naming a recycled PID reports a live watcher that is actually somebody's text editor, so converge never restarts the real one. The file records the PID **and** the process start time, and liveness requires both to match.

- [ ] **Step 7: Implement, and verify on kind**

On every change it writes `state.json` and re-bundles:

```bash
kubectl exec -n git deploy/git-server -- git -C /repos/repo.git bundle create - --all \
  > drill-progress/03/sessions/<id>/workspace.bundle
```

streamed in one shot, so no port-forward is held open for the length of a drill.
The repo path comes from the `cluster_git_repo_path` terraform output through `clustergit.py`, never from the literal above - the interface sketch wrote `/srv/repo.git`, which is what the path **was** before Task 3.2 moved it, because `bitnami/git` ships `/srv` as a symlink to `/var/srv` and a volume mounted there lands somewhere other than where every manifest says.

The bundle is written to a temp file, **verified with `git bundle verify`, and only then renamed** over the live one.
A bundle that cannot be cloned back out is not a save file, it is a file, and the moment to find that out is now rather than at the resume that needed it.

Change the ConfigMap by hand and confirm the watcher reacts within a second and the bundle on disk changes.
Then `git clone` that bundle into a scratch directory and confirm the chart is there at the expected revision.

- [ ] **Step 8: Handle the terminal phases**

The watcher is where `QUIT` and `SHUT IT DOWN` actually land, because the pod can write an intent but cannot reach a process on somebody's laptop:

| phase               | the watcher does                                                                                                |
| ------------------- | --------------------------------------------------------------------------------------------------------------- |
| `active`            | sync `state.json`, re-bundle                                                                                    |
| `switching`         | sync and bundle **first**, then restore the target's newest bundle into cluster git, then write `drill-request` |
| `ended`             | final sync, `record_result`, clear the current-session pointer and the handover flag, exit 0                    |
| `destroy-requested` | everything `ended` does, then the countdown, then `make down`                                                   |

Sync-before-switch is the ordering that must not be got wrong.
The switch is the one moment the previous scenario's work is about to be overwritten in cluster git, so a bundle taken afterwards saves the _next_ scenario's baseline under the _previous_ scenario's session id - which looks like it worked and loses the drill.

The countdown is ten seconds, prints what it is about to destroy, and `ctrl-c` aborts it.
`DRILL_ALLOW_DESTROY=0` disables the branch entirely for anyone who wants the pause menu without the last entry armed.

- [ ] **Step 9: Record the caveat in the code**

The bundle captures everything that lives in git and nothing that does not.
Scenario 03 is entirely chart-driven so the bundle is complete for this slice, but a scenario that creates state imperatively (scenario 02's HPA via `kubectl autoscale`) lives only in the cluster and will need a declared `resume` block per task in the answers TOML.
That is the per-scenario variation this design already expects; note it where the next person will read it.

- [ ] **Step 10: Commit**

```bash
git add scripts/clustergit.py scripts/drill-watch.py tests/test_drill_watch.py \
        drill/server/src/state.ts drill/server/src/state.test.ts \
        drill/server/src/integrations/k8s.ts drill/shared/src/index.ts \
        drill/server/src/server.ts scripts/git-seed.py
git commit -m "feat: watch-based sync from the drill ConfigMap to local drill-progress"
```

---

### Task 6.3: `make scenario N=03` converges a session

**Files:**

- Modify: `Makefile` (`scenario`, new `scenario-clean`)
- Create: `scripts/scenario.py`
- Test: `tests/test_scenario.py`

**Interfaces:**

- Consumes: everything above.
- Produces:
  - `make scenario N=03` **converges** rather than creates: it starts a session if none is open, restores from the newest bundle if one exists, restarts the watcher if it died, and prints the GUI URL. Running it twice shows the same thing rather than making a second one.
  - `make scenario-clean N=03` ends the session, stops the watcher, and removes what the drill created - without destroying the cluster, which is the gap the spec opens with.
  - Starting scenario 05 while 03 is open **refuses**, because scenarios mutate the same app and concurrent drills make cluster state unattributable.

- [ ] **Step 1: Decide what happens to the eleven unported scenarios, because today this target is all they have**

`make scenario N=07` prints a card today, and that is the only way to read one outside the GUI.
Converting the target wholesale to "converge a drill session" is a silent regression for eleven twelfths of the curriculum, which is not a trade this phase is entitled to make.

So the target **branches on whether the scenario is ported**, meaning whether `scenarios/answers/NN.toml` exists:

| `N`                       | behaviour                                                                    |
| ------------------------- | ---------------------------------------------------------------------------- |
| ported (`03` today)       | converge a drill session, print the GUI URL                                  |
| not ported                | today's behaviour exactly: prereq check, then print the card                 |
| ported, but no cluster up | refuse by name, point at `make up`, and print how to read the card meanwhile |

The third row matters more than it looks.
"Converge" with no cluster has nothing to converge against and no GUI URL to print, so the honest answer is a refusal - but a refusal that leaves the learner with no way to read the card is a worse target than the one being replaced, so it names `cat scenarios/03-*.md` on its way out.

- [ ] **Step 2: Write the failing test**

`tests/test_scenario.py` asserts idempotency (converging twice produces one session), the concurrent-scenario refusal names the open scenario, and `scenario-clean` is safe to run when nothing is open.

Sharpen each of the three, because as sketched they can all be passed by an implementation that is wrong:

1. **Idempotency is asserted on the filesystem, not on the exit code.** Converge twice and assert `drill-progress/03/sessions/` holds exactly one directory and `index.json` exactly one row. An implementation that creates a second session and exits 0 passes an exit-code test and fails `AC-H2`.
2. **The refusal must name the open scenario _and_ its title.** Assert the message contains both `03` and the title read from the card, not merely that the exit code is 1. "Another scenario is running" is a refusal the learner cannot act on; "scenario 03 - Rolling update and rollback is open, finish or `make scenario-clean N=03`" is.
3. **`scenario-clean` with nothing open exits 0 and changes nothing.** Assert the tree before and after are identical. A cleanup that errors when there is nothing to clean is a cleanup nobody runs twice, and this one is in the teardown path.

- [ ] **Step 3: Implement converge**

The order is fixed by what each step depends on:

1. Refuse if a **different** scenario is live, reading `drill-progress/current.json`. The same scenario is not a conflict, it is the idempotent case, and conflating them breaks `AC-H2` with `AC-H3`.
2. Refuse if the cluster is unreachable. `kubectl version --request-timeout=10s` does exit 1 against a dead endpoint - this was verified rather than assumed, after it was wrongly suspected of the exits-zero problem.
3. Capture `drill-progress/baseline.bundle` if it does not exist yet. This is cluster git as `make git-seed` left it, and it is what a fresh start of any scenario restores from. Without it, the second scenario a learner starts inherits the first one's finished working tree as its starting state.
4. Reuse the open session for `N` if there is one, restoring its newest bundle; otherwise create a session and restore the baseline.
5. Write `drill-request`.
6. Start the watcher if the PID file says it is not live.
7. Write `drill-progress/.gui-owns-the-wheel` for Task 6.4.
8. Print the GUI URL, from the Ingress address when there is one and as a `kubectl port-forward` line when there is not - which is always, on kind.

- [ ] **Step 4: Implement `scenario-clean`, and verify on kind**

Stop the watcher, close the session, delete the Argo `Application` and the `practice-app` namespace, clear the handover flag.
It does **not** destroy the cluster and it does **not** touch `drill-progress/`: the save files are the point of the phase, and a "clean" that deleted them would be the single most destructive command in the repo wearing the friendliest name.

- [ ] **Step 5: Commit**

```bash
git add scripts/scenario.py tests/test_scenario.py Makefile
git commit -m "feat: make scenario N=03 converges a drill session"
```

---

### Task 6.4: The Makefile handover

The Makefile is **demoted, never archived**. If the GUI is the only way to drive the cluster and the GUI breaks, there is no way in. Keeping it working, just locked while the GUI holds the wheel, preserves the recovery path.

**Files:**

- Modify: `Makefile`
- Create: `scripts/handover.py`
- Test: `tests/test_handover.py`

**Interfaces:**

- Produces:
  - `scripts/handover.py --check <target>` - exits 0 if the target may run, 1 with an explanation if the GUI owns it.
  - Locked while the GUI is up: `app-deploy`, `argo-sync`, `argo-repo`, `app-status`, `argo-password`, `argo-ui`, `grafana-ui`, `scenario`, `check`, `serve-answers`.
  - Never locked, because you cannot create a cluster from a pod that does not exist yet nor destroy the floor you are standing on: `up`, `plan`, `apply`, `down`, `kubeconfig`, `config`, and everything in `Makefile.test`.
  - A refusal **names the consequence**, not just the rule: "this would re-apply the Argo Application and fight the drill", not only "the GUI owns this now". That costs one line per target and fits a project whose whole job is teaching why things break.
  - `FORCE=1 make app-deploy` overrides. This exists for the same reason the Makefile was demoted rather than archived: if the GUI wedges and the handover flag goes stale, the only alternative is destroying a cluster you are mid-drill on. Removing the escape hatch removes the recovery path.

- [ ] **Step 1: Resolve the conflict between locking `scenario` and `AC-H2`**

The list above locks `scenario`, and `AC-H2` requires `make scenario N=03` to be runnable twice with the second run "not an error".
The first run sets the handover flag, so a flat lock makes the target refuse itself on the second run and the acceptance criterion unsatisfiable.

The lock on `scenario` is therefore **scoped to the argument**, not applied to the target:

- `make scenario N=<the live scenario>` is always allowed. It is the converge path and converging is idempotent.
- `make scenario N=<a different one>` is refused, and the refusal points at the GUI's pause menu, which is now where switching scenarios belongs.
- `make scenario N=<not ported>` is allowed, because printing a card does not touch the cluster.

This is a deviation from the interface-level list and it is a correction of it: the flat version was written before the pause menu existed, when the laptop was the only way to change scenario.

- [ ] **Step 2: Write the failing test**

`tests/test_handover.py` asserts: every locked target refuses when the flag is set; every unlocked target still runs; `FORCE=1` overrides every lock; each refusal message mentions a consequence, not only the lock; and the never-locked list is exactly the four bootstrap and teardown targets plus `Makefile.test`, so a future edit cannot quietly lock the recovery path.

Add one more, and it is the one that will actually catch something:

**The test parses the `Makefile` itself** and asserts that every target in `LOCKED` carries the guard prerequisite and no target in `NEVER_LOCKED` does.
A test that only exercises `handover.py` proves the policy object is correct while the Makefile forgets to consult it, which is precisely the edit a future change will make - somebody adds a target, copies the recipe above it, and does not notice the guard is what they left out.
The consequence in the other direction is worse: a guard accidentally added to `down` locks the user out of stopping the bill.

- [ ] **Step 3: Implement, wire the Makefile, and commit**

The guard is a pattern rule, `check-handover-%`, listed as the **first** prerequisite of each locked target.
`app-deploy` is why it must be a prerequisite rather than the first recipe line: it depends on `git-seed`, and a recipe-line check runs after prerequisites, so the seed would already have happened before the refusal.

Add `.NOTPARALLEL:` to the `Makefile` in the same edit.
GNU make does not guarantee left-to-right prerequisite order under `-j`, and the guard is only a guard if it runs first.
Nothing in this Makefile benefits from parallelism - it is a lifecycle driver where every target is a network round trip that must happen in order.

```bash
git add scripts/handover.py tests/test_handover.py Makefile
git commit -m "feat: Makefile handover - one steering wheel at a time, with FORCE=1"
```

---

### Task 6.5: Exit and tear down from the GUI

**Files:**

- Modify: `drill/server/src/server.ts` (the lifecycle routes)
- Create: `drill/web/src/panels/PauseMenu.tsx`, `drill/web/src/panels/TransitionScreen.tsx`
- Modify: `drill/web/src/panels/StatusBar.tsx`, `drill/web/src/App.tsx`, `drill/web/src/lib/api.ts`, `drill/web/src/theme.css`
- Test: `drill/server/src/server.test.ts`

**Interfaces:**

- Produces: a teardown path from inside the GUI, available at pass, at fail, or whenever the user wants, that ends the session, stops the watcher, syncs progress one last time, and removes what the drill created. The off-menu terminal equivalent is already tracked as an easter egg in `BACKLOG.md` and is not built here.

- [ ] **Step 1: The routes**

Five, and the shapes matter more than the count:

| route                       | body                     | does                                                           |
| --------------------------- | ------------------------ | -------------------------------------------------------------- |
| `GET /api/scenarios`        | -                        | the twelve menu slots: id, title, `ported`, and why not if not |
| `POST /api/session/restart` | -                        | same scenario, new session                                     |
| `POST /api/session/switch`  | `{ target }`             | phase `switching`, hand off to the watcher                     |
| `POST /api/session/quit`    | -                        | phase `ended`, delete the scenario's cluster resources         |
| `POST /api/session/destroy` | `{ confirm: "DESTROY" }` | phase `destroy-requested`                                      |

`GET /api/scenarios` reads titles from the cards and `ported` from the presence of an answers TOML.
It must not read the TOML's contents - the menu needs a title and a boolean, and a route that loads the answer file to decide whether it exists is one refactor away from serving it.

`POST /api/session/destroy` rejects anything but the exact literal `DESTROY`, server-side.
The browser also asks for it, and that is the friendly copy; this is the boundary.

These routes mutate, which every other route in this server deliberately does not.
That is not a new exposure - the terminal next to them is a `cluster-admin` shell, so anyone who can reach these can already do strictly more - but it is a change in the shape of the API and it gets said in the file rather than discovered.

- [ ] **Step 2: The switch handshake, and its timeout**

`switch` writes `phase: "switching", target: N` and returns immediately. The work happens elsewhere:
the watcher bundles the current session, restores `N`'s newest bundle (or the baseline) into cluster git, and writes `drill-request`.
The server, polling `drill-request` every two seconds, sees the new session id and converges: new answers, new state, phase back to `active`.

**If no watcher is running, that handshake never completes**, and a menu entry that hangs forever is worse than one that refuses.
After 60 seconds with no `drill-request`, the server converges by itself to a **fresh** session of `N` and says so in as many words: started fresh, no saved progress restored, no laptop watcher was listening.
It does not pretend to have resumed, and it does not sit there.

- [ ] **Step 3: The pause menu**

`Esc` opens and closes it, and so does the status bar's `exit` button, which has been sitting there disabled since Phase 5 waiting for this.
The overlay is styled from the theme variables that shipped at 5.3 - there are five themes and a menu with its own hardcoded green looks broken in four of them.

All twelve scenarios are listed. The eleven without an answers TOML are disabled and say `not ported yet` rather than being hidden.
`NEXT` and `PREVIOUS` are `SELECT` with the arithmetic done for you, and both are disabled when the neighbour is not ported, showing which one it would have been.

- [ ] **Step 4: The transition screen**

Full-screen while `phase === "switching"`, and it is **not a spinner**.
`/api/deps` already models the startup chain as `DependencyStatus[]` with `ready`/`starting`/`waiting`/`absent` per link, which is exactly the list of things being waited on - so the loading screen is that chain, rendered large, with the real state of each link.

This is the cheapest honest thing available and it is better than a spinner on both counts.
It entertains, because something is visibly happening and it is the truth.
And when a switch is slow, the screen already says which link is slow, so "the drill is stuck" arrives with its own diagnosis attached instead of as a bug report.

The client polls `/api/deps` every second while transitioning, rather than leaning on the websocket's ten-second push. Ten seconds is right for a status line and far too slow for a progress screen.

- [ ] **Step 5: The game-over screen**

Shown while `phase === "ended"`. Scenario, tasks passed, elapsed time, where it was saved, and the way back in: pick another scenario, or replay this one.
Plus the cost reminder, because the cluster is still up and still billing, and this is the screen the learner is looking at when they decide whether they are done for the day.

- [ ] **Step 6: Verify on kind, and commit**

The last sync before teardown is the part that must not be skipped.
Tearing down without it loses the session the user just finished, which is the one moment their progress matters most.

```bash
git add drill/server/src/server.ts drill/web/src/panels/
git commit -m "feat: pause menu - restart, switch, quit and tear down a drill from the GUI"
```

---

### What the expansion changed

Recorded so a later reader can tell which parts of Phase 6 were written before the GUI existed and which after.

- **`EXIT` became a pause menu**, and `POST /api/teardown` became five lifecycle routes. The single-button version could not express restart or switch at all.
- **`SHUT IT DOWN` exists**, and `CLAUDE.md` hard rule 1 was amended in the same commit to carry the exception rather than be contradicted by it.
- **Two ConfigMaps, one writer each**, instead of the sketch's single `drill-state`. A switch needs the laptop to talk back, and a second author on one object loses writes.
- **The lock on `scenario` became argument-scoped**, because the flat version made `AC-H2` unsatisfiable.
- **`make scenario N=<unported>` still prints a card.** The sketch would have regressed eleven of the twelve scenarios.
- **`clustergit.py` was factored out of `git-seed.py`** so the bundle push and pull are one implementation, not three.
- **A baseline bundle is captured at first converge.** Without it the second scenario a learner starts inherits the first one's finished working tree.
- **The transition screen is the dependency chain**, not a spinner - reusing `DependencyStatus` from Task 5.4 rather than inventing a progress model.

---

## Phase 7: Live verification on real EKS

**STOP. This phase costs money and needs explicit approval before any step runs.**

Everything up to here is proven on kind, ministack and Podman. What kind cannot prove is the AWS-shaped half: IRSA, the AWS Load Balancer Controller actually provisioning an ALB, the source-IP security group actually restricting it, EBS volumes behind the PVCs, and the teardown ordering that keeps them from orphaning.

Approximate cost for one 30-hour cycle: EKS control plane about $3.00, ALB about $1.00, NAT gateway about $1.35, nodes on SPOT about $0.60, RDS about $0.50, EBS about $0.05. Call it **$6.50**, of which the drill platform's own share is roughly the $1.05 for the ALB and the volume.

- [ ] **Step 1: Ask for approval, with the number**

Do not run `make up`. Present the cost, what will be verified, and wait.

- [ ] **Step 2: Bring it up and seed cluster git**

```bash
make up
make kubeconfig
make git-seed
make app-deploy
make argo-sync
```

- [ ] **Step 3: Verify the AWS-shaped things kind could not**

Confirm: exactly **one** ALB exists, not three (the shared IngressGroup working); the GUI is reachable from the user's IP and refused from anywhere else (the SG working); the PVC bound a real EBS volume; and Argo is reading `http://git-server.git.svc.cluster.local/repo.git` rather than GitHub.

Also run `make drill-allow` here. This is the first time a real security group exists, so it is the first time the AWS calls in `scripts/drill-allow.py` are exercised at all - Task 4.1 Step 7 could only reach the guard. Run it twice: the first run should report either a revoke-and-authorise or `already correct`, and the second must report `already correct, nothing to do`. A second run that changes something means the comparison logic is wrong and the target would churn the rule on every invocation.

- [ ] **Step 4: Actually drill scenario 03 end to end**

This is the point of the whole vertical slice. Work through all six tasks in the GUI, submit real answers, get real verdicts, and confirm task 5 shows Argo putting the bad version back after a `rollout undo`. Note anything that felt wrong - the standard here is pixel perfection and a terminal that feels good, not just green checks.

- [ ] **Step 5: Verify progress survives a teardown**

Tear down, bring the cluster back, and confirm `make scenario N=03` restores from the bundle to exactly where you left off. Resume works by converging to a declared state, not by replaying actions, so this either works completely or it does not work at all - there is no partial.

- [ ] **Step 6: Verify teardown does not orphan anything**

```bash
make down
aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName, `k8s-`)]' --output table
aws ec2 describe-volumes --filters Name=status,Values=available --output table
```

Expected: both empty. Anything left here bills indefinitely with nothing pointing at what created it.

- [ ] **Step 7: Report honestly**

Say plainly what passed, what did not, and what was skipped. A kind pass is necessary before spending money and never sufficient; the same honesty applies in reverse here.

---

## Self-review

Run against the spec, `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`.

**Spec coverage.** Every section maps to a task. Vocabulary and the autosave/commit/push split -> Tasks 5.3 and 6.2. Startup dependency chain -> Task 5.4's `checkDependencies`. Makefile handover -> Task 6.4. Q1 (one Argo source) -> Tasks 3.2 and 3.3. Q2 (save file, not diary) -> Task 6.1. Q2a (the watcher) -> Task 6.2. Q3 (ALB with three conditions) -> Tasks 4.1 and 4.2; the shared IngressGroup lands in Task 5.5 with the Ingress that needs it. Q4 (contextual integrations) -> Task 5.4. Q5 (one long-lived pod, append-only sessions) -> Tasks 5.5 and 6.1. Q6 (TypeScript both ends) -> Task 2.1. Q7 (refusal and port 8090) -> Tasks 6.4 and 5.1. Build-time items: `drill-progress/` in `.gitignore` -> Task 6.1 Step 1, before the directory can exist; three config values -> Task 3.1; port 8090 -> `config.ts`. Answers TOML as source of truth generating the HTML -> Phase 1. Semantic grading with the alias table -> Phase 2. `cluster-admin` -> Task 5.5. Concurrent-scenario refusal -> Task 6.3. Exit and tear down from the GUI -> Task 6.5. Testing section -> grader unit tests (Phase 2), byte-identical generator test (Task 1.2), `make -f Makefile.test test` kept passing throughout, the Argo acceptance test on kind (Task 3.2 Step 7), and live drilling (Phase 7 Step 4).

**Two known gaps, both deliberate.** Phases 6.1 through 6.5 and Tasks 5.4 and 5.5 were specified at interface-and-intent level rather than with full TDD code blocks, because they depend on choices Phase 5's first visual will change - panel layout, what the session state actually needs to carry, and what the user says when they see it. Expanding them earlier would have been writing code against a UI nobody had looked at. **Tasks 5.4 and 5.5 were expanded on 2026-08-21**, after the Task 5.3 review, and each now carries a "what the review changed" note so the ordering is auditable. **Tasks 6.1 through 6.5 were expanded on 2026-08-21**, when `WO-20260819-7840` was started, and Phase 6 carries a "what the expansion changed" note for the same reason. That note is worth reading: holding Phase 6 back was the right call, because the expansion changed the design rather than merely detailing it - the single `EXIT` button became a pause menu, and that is a thing nobody could have known before there was a GUI to sit in. The second gap: Task 5.4's proxy is designed and stubbed but only exercised when scenario 07 is ported, exactly as the spec says.

**Type consistency.** `Verdict`, `SessionState`, `Attempt` and `DependencyStatus` are defined once in `@drill/shared` (Task 2.1) and used unchanged in Tasks 2.4, 5.1, 5.2, 5.3 and 5.4. `AnswerTask` and `AcceptRule` are defined in Task 2.4's `answers.ts` and consumed in 2.4 and 5.1. `ParsedCommand` is defined in Task 2.3 and consumed only in 2.4. The `grader` discriminator has the same three values in `scripts/answers.py`, `drill/server/src/grader/answers.ts` and `GraderKind`.

**Placeholder scan.** Clean through Task 6.5. Nothing in this plan is now specified at interface level. One thing is deliberately deferred and is flagged rather than hidden: Phase 6's scenario-switch path can be proven mechanically but its real exit-condition test - drill 03, switch to 06, drill 06, switch back, find 03 where you left it - needs a second ported scenario to exist. It belongs to whichever epic ports one, and it is recorded in `BACKLOG.md`, in `WO-20260819-7840`'s notes and in `CONTEXT_STATE.md` so it cannot lapse.

---

## What to do when this plan is done

Scenario 03 is one of twelve. The other eleven are ported one at a time, each getting its own answers TOML and whatever grader kinds it needs, and each may extend the schema - which is why `schema = 1` and the `grader` discriminator exist. Scenario 04's card also needs rewriting, because the platform ALB is now the ops plane: it becomes "join the existing ALB with a new Ingress, then stand up an NLB separately to feel the difference", which is closer to what you would actually do at work than provisioning a load balancer from scratch.

One spec amendment to make: the self-contained git rule, documented under "The self-contained git rule" at the top of this plan. It supersedes the spec's Q1 sentence about an init container cloning GitHub with a token, and it is a standing rule rather than a one-off deviation, so the spec should not be left saying the opposite. The language split is not an amendment, because the spec never assigned the grader a language; it is written up under "Where each language runs, and why" as a decision this plan made.
