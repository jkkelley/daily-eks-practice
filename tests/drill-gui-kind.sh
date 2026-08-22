#!/usr/bin/env bash
# Acceptance test for the drill GUI: does the pod actually come up and serve the
# console, running the way it will actually run?
#
#   make -f Makefile.test ministack        # produces the plan this reads
#   make -f Makefile.test drill-gui-test
#
# This is Task 5.5 Step 8, and it is `AC-H4` of WO-20260819-ca7c. It runs on kind for
# $0 and never touches AWS.
#
# The manifests are NOT duplicated here. They are extracted from the ministack plan,
# exactly as tests/cluster-git-argo.sh does, so this tests the Terraform that actually
# ships rather than a copy of it that can drift.
#
# What it asserts, in order:
#   1. The image builds, and carries no credential - the AC-H3 check, run against the
#      built image rather than against .containerignore.
#   2. Cluster git comes up and is seeded, because the drill workspace is a CLONE of
#      it and there is nothing to clone from otherwise.
#   3. The init container clones into the PVC, and the pod reaches Ready.
#   4. /healthz answers, and the API routes the four panels read all answer.
#   5. The workspace on the PVC is a real git repo with a real remote - not a copy.
#      Scenario 03's model answer is `git revert && git push`, and a copy has no
#      remote, so this is the assertion that would catch the most damaging silent
#      failure in the whole deployment.
#   6. The workspace does NOT contain the answer key. Two trees, easy to conflate.
#   7. kubectl works from inside the pod, because the ServiceAccount is cluster-admin
#      and half the cards start with a kubectl command.
#
# The INGRESS is not exercised: kind has no ALB controller. AC-H3 of
# WO-20260819-1fea - one ALB across three Ingresses - is evidenced from the rendered
# manifest and the plan, not from a live load balancer. Say which when you evidence it.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAN="${DRILL_PLAN:-$ROOT/terraform/envs/dev/test/ministack.tfplan}"
TFDIR="$ROOT/terraform/envs/dev"
KEEP="${KEEP_CLUSTER:-0}"
IMAGE="${DRILL_IMAGE:-localhost/drill-gui:dev}"
CLUSTER="daily-eks-drill-sandbox"
NS="practice-drill"

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

kube() { kubectl --context "kind-$CLUSTER" "$@"; }

cleanup() {
  [ "$KEEP" = "1" ] && {
    echo "KEEP_CLUSTER=1 - leaving the kind cluster up"
    return
  }
  bash "$ROOT/scripts/kind-sandbox.sh" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --------------------------------------------------------------------------
echo "== 1. building the image, and proving it carries no credential =="
# --------------------------------------------------------------------------
podman build -q -t "$IMAGE" -f "$ROOT/drill/Containerfile" "$ROOT" >/dev/null || {
  echo "ERROR: image build failed"
  exit 1
}

LEAKS="$(podman run --rm --entrypoint /bin/sh "$IMAGE" -c \
  'ls -d /app/scripts /app/terraform /app/.git /app/scripts/config.toml /app/.kubeconfig* 2>/dev/null | wc -l')"
check "no config.toml, kubeconfig, terraform or .git in the image" \
  "$([ "$LEAKS" = "0" ] && echo 0 || echo 1)" "found $LEAKS"

podman run --rm --entrypoint /bin/sh "$IMAGE" -c 'test -f /app/scenarios/answers/03.toml' >/dev/null 2>&1
check "the answer key IS in the image, where the grader reads it" $?

# --------------------------------------------------------------------------
echo "== 2. extracting the manifests from the shipped Terraform =="
# --------------------------------------------------------------------------
MANIFESTS="$(mktemp)"
GIT_MANIFESTS="$(mktemp)"
extract() {
  terraform -chdir="$TFDIR" show -json "test/$(basename "$PLAN")" 2>/dev/null |
    python3 -c "
import json, sys
plan = json.load(sys.stdin)
want = sys.argv[1]
bodies = [
    r['change']['after']['yaml_body']
    for r in plan['resource_changes']
    if r['type'] == 'kubectl_manifest'
    and want in r['address']
    # The Ingress body is UNKNOWN at plan time: it interpolates the security
    # group id, which does not exist until apply. Dropping it here is the same
    # decision as dropping it below - kind has no ALB controller - it just
    # happens for a second, independent reason.
    and r['change']['after'].get('yaml_body')
]
if not bodies:
    sys.exit('no manifests matching ' + want)
print('\n---\n'.join(bodies))
" "$1"
}

extract ".git_" >"$GIT_MANIFESTS" || {
  echo "ERROR: could not extract cluster-git manifests from $PLAN"
  echo "  run: make -f Makefile.test ministack"
  exit 1
}
# The Ingress is dropped: kind has no ALB controller, and an Ingress referencing a
# non-existent IngressClass would sit Pending and add nothing to this test.
extract ".drill_" | python3 -c "
import sys
docs = sys.stdin.read().split('\n---\n')
keep = [d for d in docs if '\"kind\": \"Ingress\"' not in d and 'kind: Ingress' not in d]
print('\n---\n'.join(keep))
" >"$MANIFESTS" || {
  echo "ERROR: could not extract drill manifests from $PLAN"
  exit 1
}
echo "  cluster-git: $(grep -c 'kind' "$GIT_MANIFESTS") manifests"
echo "  drill:       $(grep -c 'kind' "$MANIFESTS") manifests"

# --------------------------------------------------------------------------
echo "== 3. bringing up kind and seeding cluster git =="
# --------------------------------------------------------------------------
bash "$ROOT/scripts/kind-sandbox.sh" up || {
  echo "ERROR: kind-sandbox up failed"
  exit 1
}

# The kubeconfig is REPO-LOCAL - this project never reads or writes ~/.kube/config -
# so until this is exported the context simply does not exist and every kubectl call
# fails with a message about the context rather than about the cluster.
KUBECONFIG="$(bash "$ROOT/scripts/kind-sandbox.sh" kubeconfig)"
export KUBECONFIG

kube apply -f "$GIT_MANIFESTS" >/dev/null 2>&1
kube -n git rollout status deploy/git-server --timeout=120s >/dev/null 2>&1
# The readiness probe needs the .seeded marker, so the Deployment is not Ready yet -
# wait on the POD being Running instead, which is what seeding needs.
kube -n git wait --for=jsonpath='{.status.phase}'=Running pod -l app=git-server --timeout=120s >/dev/null 2>&1
check "cluster git pod is Running" $?

# The CLUSTER_GIT_* overrides exist because there is no terraform state in the kind
# sandbox, so the seeder cannot read its usual outputs. Running the real seeder rather
# than a copy of its steps is the point: the workspace is a CLONE of what this puts
# there, so a seeding path that works only in the test proves nothing.
# Kept in step with terraform/modules/platform/cluster-git.tf.
SEED_OUT="$(
  CLUSTER_GIT_NS=git \
    CLUSTER_GIT_DEPLOY=git-server \
    CLUSTER_GIT_CONTAINER=git \
    CLUSTER_GIT_REPO_PATH=/repos/repo.git \
    python3 "$ROOT/scripts/git-seed.py" 2>&1
)"
check "cluster git seeded from the laptop" $? "$(echo "$SEED_OUT" | tail -3)"

kube -n git rollout status deploy/git-server --timeout=120s >/dev/null 2>&1
check "cluster git reports Ready once seeded" $?

# --------------------------------------------------------------------------
echo "== 4. deploying the drill GUI =="
# --------------------------------------------------------------------------
podman save "$IMAGE" -o /tmp/drill-gui.tar >/dev/null 2>&1
kind load image-archive /tmp/drill-gui.tar --name "$CLUSTER" >/dev/null 2>&1
rm -f /tmp/drill-gui.tar

# The plan names the image from config.toml, which points at a GHCR repository that
# the kind node cannot pull and does not need to: the image is already loaded.
kube apply -f "$MANIFESTS" >/dev/null 2>&1
kube -n "$NS" set image deploy/drill-gui "drill-gui=$IMAGE" >/dev/null 2>&1
kube -n "$NS" patch deploy drill-gui --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' >/dev/null 2>&1

kube -n "$NS" rollout status deploy/drill-gui --timeout=180s >/dev/null 2>&1
check "the drill-gui pod reached Ready" $? "$(kube -n "$NS" get pods -o wide 2>&1 | tail -3)"

POD="$(kube -n "$NS" get pod -l app=drill-gui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [ -z "$POD" ]; then
  echo "  ABORT  no drill-gui pod exists - every assertion below would be vacuous"
  kube -n "$NS" get pods 2>&1 | tail -5
  kube -n "$NS" describe pod -l app=drill-gui 2>&1 | grep -iE "events|warning|failed|error" | tail -10
  echo
  echo "drill-gui-kind: $pass passed, $((fail + 1)) failed"
  exit 1
fi

# Asserted against a pod that is KNOWN to exist. Grepping for an absent field on an
# absent pod reports "no secret" and passes, which is the kind of green that hides a
# deployment that never happened.
kube -n "$NS" get pod "$POD" -o jsonpath='{.spec.imagePullSecrets}' 2>/dev/null | grep -q . && SECRET=1 || SECRET=0
check "AC-H5: no imagePullSecret anywhere on the pod" "$SECRET"

# --------------------------------------------------------------------------
echo "== 5. the workspace is a CLONE, not a copy =="
# --------------------------------------------------------------------------
kube -n "$NS" exec "$POD" -- sh -c 'test -d /home/drill/practice-app/.git' >/dev/null 2>&1
check "the workspace is a git repository" $?

REMOTE="$(kube -n "$NS" exec "$POD" -- git -C /home/drill/practice-app remote get-url origin 2>/dev/null)"
echo "$REMOTE" | grep -q '^git://' && R=0 || R=1
check "origin points at cluster git ($REMOTE)" "$R"

kube -n "$NS" exec "$POD" -- sh -c 'test -f /home/drill/practice-app/helm/practice-app/values.yaml' >/dev/null 2>&1
check "the chart Argo syncs is in the workspace" $?

# --------------------------------------------------------------------------
echo "== 6. the workspace does NOT carry the curriculum =="
# --------------------------------------------------------------------------
STOWAWAYS="$(kube -n "$NS" exec "$POD" -- sh -c \
  'ls -d /home/drill/practice-app/scenarios /home/drill/practice-app/docs /home/drill/practice-app/drill /home/drill/practice-app/CLAUDE.md 2>/dev/null | wc -l' 2>/dev/null)"
check "no answers, docs, grader source or CLAUDE.md in the workspace" \
  "$([ "${STOWAWAYS:-1}" = "0" ] && echo 0 || echo 1)" "found ${STOWAWAYS}"

# --------------------------------------------------------------------------
echo "== 7. the console answers, and the cluster is reachable from the terminal =="
# --------------------------------------------------------------------------
for route in /healthz /api/session /api/tasks /api/tree /api/git/status /api/deps /api/argo; do
  kube -n "$NS" exec "$POD" -- sh -c \
    "wget -qO- http://127.0.0.1:8090$route >/dev/null" >/dev/null 2>&1
  check "$route answers" $?
done

kube -n "$NS" exec "$POD" -- sh -c 'kubectl get nodes -o name' >/dev/null 2>&1
check "kubectl works from inside the pod (cluster-admin)" $?

kube -n "$NS" exec "$POD" -- sh -c 'command -v helm && command -v git && command -v tmux' >/dev/null 2>&1
check "helm, git and tmux are on PATH" $?

WHO="$(kube -n "$NS" exec "$POD" -- sh -lc 'whoami' 2>/dev/null | tr -d '\r\n')"
check "the account has a name of its own (got '$WHO')" \
  "$([ "$WHO" = "pilot" ] && echo 0 || echo 1)"

echo
echo "drill-gui-kind: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
