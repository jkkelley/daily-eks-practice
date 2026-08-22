#!/usr/bin/env bash
# AC-H4: does a drill session actually survive the cluster being destroyed?
#
#   make -f Makefile.test ministack        # produces the plan this reads
#   make -f Makefile.test drill-resume-test
#
# This is the criterion the whole phase exists for, and it is the one that cannot
# be faked by a unit test: it needs a real git server, a real bundle, a real
# teardown and a real rebuild.
#
#   1. bring up kind, seed cluster git
#   2. the learner works: a commit lands in cluster git
#   3. a session is mirrored into drill-state, and the watcher saves it
#   4. DESTROY THE CLUSTER - the whole thing, not a pod
#   5. bring a new one up, empty
#   6. converge, and check the learner's commit is back
#
# Resume works by converging to a declared state, not by replaying actions, so it
# either works completely or it does not work at all. Step 6 asserts the actual
# file contents, not that a command exited 0 - "it ran" is exactly the kind of
# vacuous pass this repo has been bitten by before.
#
# The manifests are NOT duplicated here; they are extracted from the ministack
# plan, the same way tests/drill-gui-kind.sh and tests/cluster-git-argo.sh do, so
# this tests the Terraform that actually ships rather than a copy of it.
#
# $0 throughout. No AWS, no image build - this exercises the git/bundle path,
# which is what AC-H4 is about. The pod itself is drill-gui-kind.sh's job.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAN="${DRILL_PLAN:-$ROOT/terraform/envs/dev/test/ministack.tfplan}"
TFDIR="$ROOT/terraform/envs/dev"
KEEP="${KEEP_CLUSTER:-0}"

# A throwaway drill-progress/, so a real one on this machine is never touched.
PROGRESS="$(mktemp -d -t drill-resume-XXXXXX)"
export DRILL_PROGRESS_DIR="$PROGRESS"

# There is no terraform state in the kind sandbox, so the scripts are pointed at
# the git server by env rather than by output. Same overrides the other harnesses use.
export CLUSTER_GIT_NS="git"
export CLUSTER_GIT_DEPLOY="git-server"
# `git`, and it is worth saying where that comes from: it is the container name in
# terraform/modules/platform/cluster-git.tf, surfaced as the `cluster_git_container`
# output. This harness has no terraform state to read it from, so it is repeated
# here - and the first version of this file guessed "git-daemon", which is the
# BINARY's name, and every assertion downstream failed with a BadRequest that only
# showed up once the output was unmuted.
export CLUSTER_GIT_CONTAINER="git"
export CLUSTER_GIT_REPO_PATH="/repos/repo.git"

pass=0
fail=0
check() {
  if [ "$2" = "0" ]; then
    echo "  PASS  $1"
    pass=$((pass + 1))
  else
    echo "  FAIL  $1${3:+: $3}"
    fail=$((fail + 1))
  fi
}

kube() { kubectl "$@"; }

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "KEEP_CLUSTER=1 - leaving the kind cluster up; progress at $PROGRESS"
    return
  fi
  bash "$ROOT/scripts/kind-sandbox.sh" down >/dev/null 2>&1 || true
  rm -rf "$PROGRESS"
}
trap cleanup EXIT

extract_git() {
  terraform -chdir="$TFDIR" show -json "test/$(basename "$PLAN")" 2>/dev/null |
    python3 -c "
import json, sys
plan = json.load(sys.stdin)
bodies = [
    r['change']['after']['yaml_body']
    for r in plan['resource_changes']
    if r['type'] == 'kubectl_manifest'
    and '.git_' in r['address']
    and r['change']['after'].get('yaml_body')
]
if not bodies:
    sys.exit('no cluster-git manifests in the plan')
print('\n---\n'.join(bodies))
"
}

bring_up_cluster_git() {
  bash "$ROOT/scripts/kind-sandbox.sh" up >/dev/null 2>&1 || return 1
  KUBECONFIG="$(bash "$ROOT/scripts/kind-sandbox.sh" kubeconfig)"
  export KUBECONFIG
  [ -n "$KUBECONFIG" ] || return 1
  kube apply -f "$GIT_MANIFESTS" >/dev/null 2>&1 || return 1
  kube -n git wait --for=jsonpath='{.status.phase}'=Running pod \
    -l app=git-server --timeout=180s >/dev/null 2>&1 || return 1
  # The namespace the two lifecycle ConfigMaps live in. Terraform creates it with
  # the GUI, which this harness does not deploy.
  kube create namespace practice-drill >/dev/null 2>&1
  return 0
}

git_pod() {
  kube -n git get pod -l app=git-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

echo "== 0. extracting cluster-git manifests from the shipped Terraform =="
GIT_MANIFESTS="$(mktemp)"
extract_git >"$GIT_MANIFESTS" || {
  echo "ERROR: could not read $PLAN - run: make -f Makefile.test ministack"
  exit 1
}
echo "  $(grep -c '\"kind\"' "$GIT_MANIFESTS") manifests"   # yamlencode quotes its keys

# --------------------------------------------------------------------------
echo "== 1. a cluster, seeded, with a drill session in it =="
# --------------------------------------------------------------------------
bring_up_cluster_git
check "kind is up and cluster git is Running" $?

python3 "$ROOT/scripts/git-seed.py" >/dev/null 2>&1
check "cluster git is seeded" $?

POD="$(git_pod)"
[ -n "$POD" ]
check "the git pod is addressable" $?

# --------------------------------------------------------------------------
echo "== 2. the learner does some work, and it reaches cluster git =="
# --------------------------------------------------------------------------
# A real commit, made the way the drill makes one: clone, edit, commit, push.
# Not a file written into the bare repo - the bundle has to carry a real ref.
WORK="$(mktemp -d)"
kube -n git exec "$POD" -c "$CLUSTER_GIT_CONTAINER" -- /bin/sh -c "
  set -e
  rm -rf /tmp/work
  git clone -q ${CLUSTER_GIT_REPO_PATH} /tmp/work
  cd /tmp/work
  git config user.email drill@localhost
  git config user.name drill
  sed -i 's/tag: .*/tag: THE-LEARNERS-CHANGE/' helm/practice-app/values.yaml
  git commit -aqm 'the learner bumped the image tag'
  git push -q origin main
" >/dev/null 2>&1
check "the learner's commit is pushed to cluster git" $?

BEFORE="$(kube -n git exec "$POD" -c "$CLUSTER_GIT_CONTAINER" -- \
  git -C "$CLUSTER_GIT_REPO_PATH" show main:helm/practice-app/values.yaml 2>/dev/null | grep -c 'THE-LEARNERS-CHANGE')"
check "cluster git holds the change before teardown" "$([ "$BEFORE" -ge 1 ] && echo 0 || echo 1)" "grep found $BEFORE"

BEFORE_SHA="$(kube -n git exec "$POD" -c "$CLUSTER_GIT_CONTAINER" -- \
  git -C "$CLUSTER_GIT_REPO_PATH" rev-parse main 2>/dev/null | tr -d '\r\n')"

# --------------------------------------------------------------------------
echo "== 3. the session is mirrored, and the watcher saves it =="
# --------------------------------------------------------------------------
SESSION="2026-08-21T20-00-00Z"
STATE="{\"scenario\":\"03\",\"sessionId\":\"$SESSION\",\"startedAt\":\"2026-08-21T20:00:00.000Z\",\"currentTaskId\":\"3\",\"passed\":[\"1\",\"2\"],\"attempts\":[],\"phase\":\"active\"}"
kube -n practice-drill create configmap drill-state \
  --from-literal=state.json="$STATE" --dry-run=client -o json 2>/dev/null | kube apply -f - >/dev/null 2>&1
check "drill-state is written, the way the pod writes it" $?

python3 "$ROOT/scripts/drill-watch.py" --once >/dev/null 2>&1
check "the watcher synced once" $?

BUNDLE="$PROGRESS/03/sessions/$SESSION/workspace.bundle"
[ -s "$BUNDLE" ]
check "a save file exists on the laptop" $? "expected $BUNDLE"

git bundle verify "$BUNDLE" >/dev/null 2>&1
check "and it VERIFIES - a bundle that cannot be cloned back is not a save file" $?

[ -s "$PROGRESS/03/sessions/$SESSION/state.json" ]
check "state.json was written beside it" $?

python3 - <<PY
import json, sys
from pathlib import Path
s = json.loads(Path("$PROGRESS/03/sessions/$SESSION/state.json").read_text())
sys.exit(0 if s.get("passed") == ["1", "2"] else 1)
PY
check "the save records what had been passed" $?

# --------------------------------------------------------------------------
echo "== 4. DESTROY THE CLUSTER =="
# --------------------------------------------------------------------------
bash "$ROOT/scripts/kind-sandbox.sh" down >/dev/null 2>&1
check "the cluster is gone" $?

# Prove it is really gone rather than assuming it. A vacuous pass here would make
# every assertion after it meaningless - this is the AC-H5 lesson from Phase 5.
kube -n git get pod -l app=git-server --request-timeout=10s >/dev/null 2>&1
check "the API server is genuinely unreachable, not merely empty" \
  "$([ $? -ne 0 ] && echo 0 || echo 1)" "kubectl still answered"

[ -s "$BUNDLE" ]
check "the save file survived the cluster it came from" $?

# --------------------------------------------------------------------------
echo "== 5. a brand new, empty cluster =="
# --------------------------------------------------------------------------
bring_up_cluster_git
check "a fresh kind cluster is up with an empty cluster git" $?

POD="$(git_pod)"
EMPTY="$(kube -n git exec "$POD" -c "$CLUSTER_GIT_CONTAINER" -- \
  git -C "$CLUSTER_GIT_REPO_PATH" rev-parse main 2>&1 | grep -c 'unknown revision\|ambiguous argument\|fatal')"
check "the new cluster git has NO history - nothing up our sleeve" \
  "$([ "$EMPTY" -ge 1 ] && echo 0 || echo 1)" "it already had a main ref"

# --------------------------------------------------------------------------
echo "== 6. restore, and check the learner's actual work came back =="
# --------------------------------------------------------------------------
python3 - <<PY >/dev/null 2>&1
import sys
sys.path.insert(0, "$ROOT/scripts")
import clustergit, progress
cfg = clustergit.settings()
pod = clustergit.pod_name(cfg, timeout="120s")
src = progress.latest_bundle("03")
if src is None:
    raise SystemExit("no bundle to restore")
clustergit.push_bundle(cfg, pod, clustergit.bundle_from_file(src))
PY
check "the save file is pushed back into the new cluster git" $?

POD="$(git_pod)"
AFTER="$(kube -n git exec "$POD" -c "$CLUSTER_GIT_CONTAINER" -- \
  git -C "$CLUSTER_GIT_REPO_PATH" show main:helm/practice-app/values.yaml 2>/dev/null | grep -c 'THE-LEARNERS-CHANGE')"
check "THE LEARNER'S EDIT IS BACK, in a cluster that never saw it" \
  "$([ "$AFTER" -ge 1 ] && echo 0 || echo 1)" "grep found $AFTER"

AFTER_SHA="$(kube -n git exec "$POD" -c "$CLUSTER_GIT_CONTAINER" -- \
  git -C "$CLUSTER_GIT_REPO_PATH" rev-parse main 2>/dev/null | tr -d '\r\n')"
check "and at the very same commit, not merely similar content" \
  "$([ -n "$BEFORE_SHA" ] && [ "$BEFORE_SHA" = "$AFTER_SHA" ] && echo 0 || echo 1)" \
  "before=$BEFORE_SHA after=$AFTER_SHA"

# The session bookkeeping has to survive too, or `make scenario N=03` starts a new
# attempt instead of resuming the one just restored.
python3 - <<PY
import os, sys
sys.path.insert(0, "$ROOT/scripts")
import progress
sys.exit(0 if progress.current_session("03") == "$SESSION" else 1)
PY
check "the laptop still points at the session that was restored" $?

echo ""
echo "AC-H4: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
