#!/usr/bin/env bash
# Acceptance test for cluster git: does Argo CD actually clone from an in-cluster
# git server, with no credentials and no contact with github.com?
#
#   make -f Makefile.test ministack        # produces the plan this reads
#   make -f Makefile.test cluster-git-test
#
# This is the one genuinely unproven assumption in the drill design - the whole
# GitOps half rests on it. It runs on kind for $0 and never touches AWS.
#
# The manifests are NOT duplicated here. They are extracted from the ministack plan,
# so this tests the Terraform that actually ships rather than a copy of it that can
# drift.
#
# It needs a FRESH cluster, which is why it tears the sandbox down on exit. Assertion
# 2 checks that the repo has not been seeded yet, so re-running against a cluster kept
# alive with KEEP_CLUSTER=1 will fail it - delete the `git` namespace first.
#
# What it asserts, in order:
#   1. Kubernetes admits the cluster-git manifests and the pod reaches Running.
#   2. The Service has NO endpoints before seeding, because the readiness probe
#      requires the .seeded marker. This is the gate that stops Argo syncing a
#      half-served repo - succeeding against an incomplete repo is far worse than
#      erroring against it.
#   3. Seeding streams a bundle in intact, publishes refs, and endpoints appear.
#   4. Argo CD reports OutOfSync with empty .status.conditions, which means it cloned
#      and rendered and is only holding back because sync is manual. `Unknown` plus a
#      ComparisonError means it could not read the repo.
#   5. A push succeeds, because scenario 03's model answer is `git revert && git push`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAN="${CLUSTER_GIT_PLAN:-$ROOT/terraform/envs/dev/test/ministack.tfplan}"
TFDIR="$ROOT/terraform/envs/dev"
ARGO_MANIFEST="${ARGO_MANIFEST:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"
KEEP="${KEEP_CLUSTER:-0}"

# Kept in step with terraform/modules/platform/cluster-git.tf. The Terraform outputs
# are the source of truth at runtime (scripts/git-seed.py reads them); this test runs
# without terraform state, so it restates them and would fail loudly on a drift.
SEED_CONTAINER="${SEED_CONTAINER:-git}"
REPO_PATH="${REPO_PATH:-/repos/repo.git}"
REPO_URL="${REPO_URL:-git://git-server.git.svc.cluster.local/repo.git}"

PASS=0
FAIL=0
ok() {
  echo "  PASS  $*"
  PASS=$((PASS + 1))
}
bad() {
  echo "  FAIL  $*"
  FAIL=$((FAIL + 1))
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "SKIP: $1 not installed"; exit 0; }; }
need kind
need kubectl
need terraform
need git

[ -f "$PLAN" ] || {
  echo "ERROR: no plan at $PLAN"
  echo "       run: make -f Makefile.test ministack"
  exit 1
}

cleanup() {
  [ "$KEEP" = "1" ] && {
    echo "KEEP_CLUSTER=1 - leaving the kind cluster up"
    return
  }
  bash "$ROOT/scripts/kind-sandbox.sh" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== extracting the cluster-git manifests from the shipped Terraform =="
MANIFESTS="$(mktemp)"
terraform -chdir="$TFDIR" show -json "$(basename "$(dirname "$PLAN")")/$(basename "$PLAN")" 2>/dev/null |
  python3 -c "
import json, sys
plan = json.load(sys.stdin)
bodies = [
    r['change']['after']['yaml_body']
    for r in plan['resource_changes']
    if r['type'] == 'kubectl_manifest' and '.git_' in r['address']
]
if not bodies:
    sys.exit('no cluster-git manifests in the plan')
print('\n---\n'.join(bodies))
" > "$MANIFESTS" || {
  echo "ERROR: could not extract manifests from $PLAN"
  exit 1
}
echo "  $(grep -c '"kind"' "$MANIFESTS") manifests extracted"

echo "== bringing up the kind sandbox =="
bash "$ROOT/scripts/kind-sandbox.sh" up || {
  echo "ERROR: kind-sandbox up failed"
  exit 1
}
KC="$(bash "$ROOT/scripts/kind-sandbox.sh" kubeconfig)"
[ -n "$KC" ] && [ -f "$KC" ] || {
  echo "ERROR: no kubeconfig"
  exit 1
}
export KUBECONFIG="$KC"

echo ""
echo "== 1. Kubernetes admits the manifests =="
kubectl apply -f "$MANIFESTS" && ok "the cluster-git manifests admit" || bad "kubectl apply rejected them"
# Wait for Running, NOT for `rollout status`. A Deployment behind a readiness gate
# that is designed to stay closed until seeding can never become Available, so
# `rollout status` here would burn its whole timeout and then fail, every run.
kubectl -n git wait --for=jsonpath='{.status.phase}'=Running pod -l app=git-server --timeout=300s >/dev/null 2>&1 &&
  ok "git-server pod is Running (init container finished)" || bad "git-server pod never reached Running"

echo ""
echo "== 2. no endpoints before seeding (the .seeded readiness gate) =="
kubectl -n git get pod -l app=git-server \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready'
ADDRS="$(kubectl -n git get endpoints git-server -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
[ -z "$ADDRS" ] && ok "endpoints are empty before .seeded exists" ||
  bad "endpoints already populated before seeding: $ADDRS"

echo ""
echo "== 3. seed the bare repo by streaming a git bundle in =="
POD="$(kubectl -n git get pod -l app=git-server -o jsonpath='{.items[0].metadata.name}')"
[ -n "$POD" ] || {
  echo "ERROR: no git-server pod"
  exit 1
}
# `tee`, exec'd directly. Wrapping the receiver in `/bin/sh -c 'cat > file'` - which
# is the obvious way to write it - silently truncates the stream: measured 443833
# bytes in and 98662 out, with kubectl still exiting 0. The corruption only surfaces
# later as "fatal: early EOF" from git. Do not reintroduce the shell wrapper.
BUNDLE_BYTES="$(git -C "$ROOT" bundle create - --all 2>/dev/null | wc -c)"
git -C "$ROOT" bundle create - --all 2>/dev/null |
  kubectl -n git exec -i "$POD" -c "$SEED_CONTAINER" -- tee /tmp/seed.bundle >/dev/null &&
  ok "bundle streamed into the pod" || bad "streaming the bundle failed"
LANDED="$(kubectl -n git exec "$POD" -c "$SEED_CONTAINER" -- stat -c%s /tmp/seed.bundle 2>/dev/null)"
[ "$LANDED" = "$BUNDLE_BYTES" ] && ok "all $BUNDLE_BYTES bytes arrived intact" ||
  bad "bundle truncated in transit: sent $BUNDLE_BYTES, landed ${LANDED:-0}"

kubectl -n git exec "$POD" -c "$SEED_CONTAINER" -- /bin/sh -c "
  set -e
  git -C $REPO_PATH fetch --force /tmp/seed.bundle 'refs/heads/*:refs/heads/*'
  git -C $REPO_PATH symbolic-ref HEAD refs/heads/main
  rm -f /tmp/seed.bundle
  date -u +%Y-%m-%dT%H:%M:%SZ > $REPO_PATH/.seeded
  echo 'seed: refs published'"
SEED_RC=$?
[ "$SEED_RC" -eq 0 ] && ok "the repo unbundled and .seeded was written" ||
  bad "unbundling inside the pod failed (rc=$SEED_RC)"

for _ in $(seq 1 20); do
  ADDRS="$(kubectl -n git get endpoints git-server -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)"
  [ -n "$ADDRS" ] && break
  sleep 3
done
[ -n "$ADDRS" ] && ok "endpoints appeared after seeding" || bad "endpoints still empty after seeding"
kubectl -n git get endpoints git-server

echo ""
echo "== 4. Argo CD clones it =="
kubectl create namespace argocd >/dev/null 2>&1
# --server-side is required, not stylistic: Argo's applicationsets CRD exceeds the
# 262144-byte last-applied-configuration annotation that a client-side apply writes,
# so a plain `kubectl apply` fails with "metadata.annotations: Too long".
kubectl apply --server-side --force-conflicts -n argocd -f "$ARGO_MANIFEST" >/dev/null 2>&1 &&
  ok "Argo CD manifests applied" || bad "could not apply the Argo CD install manifest"
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=420s >/dev/null 2>&1 &&
  ok "argocd-repo-server is up" || bad "argocd-repo-server did not come up"

# A stale Application from an earlier run carries a stale status, and the poll below
# would read it as this run's verdict.
kubectl -n argocd delete application cluster-git-acceptance --ignore-not-found >/dev/null 2>&1

kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cluster-git-acceptance
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $REPO_URL
    targetRevision: main
    path: helm/practice-app
  destination:
    server: https://kubernetes.default.svc
    namespace: acceptance-app
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
YAML

STATUS=""
CONDITIONS=""
for _ in $(seq 1 20); do
  STATUS="$(kubectl -n argocd get application cluster-git-acceptance -o jsonpath='{.status.sync.status}' 2>/dev/null)"
  CONDITIONS="$(kubectl -n argocd get application cluster-git-acceptance -o jsonpath='{.status.conditions}' 2>/dev/null)"
  { [ -n "$STATUS" ] && [ "$STATUS" != "Unknown" ]; } && break
  { [ -n "$CONDITIONS" ] && [ "$CONDITIONS" != "[]" ]; } && break
  sleep 5
done

echo "  sync status: ${STATUS:-<empty>}"
echo "  conditions : ${CONDITIONS:-<empty>}"
[ "$STATUS" = "OutOfSync" ] && ok "Argo reports OutOfSync - it cloned and rendered" ||
  bad "Argo reports '${STATUS:-<empty>}' (expected OutOfSync)"
{ [ -z "$CONDITIONS" ] || [ "$CONDITIONS" = "[]" ]; } && ok "no .status.conditions" ||
  bad "Argo raised conditions: $CONDITIONS"
RENDERED="$(kubectl -n argocd get application cluster-git-acceptance -o jsonpath='{.status.resources[*].kind}' 2>/dev/null)"
[ -n "$RENDERED" ] && ok "Argo rendered the chart: $RENDERED" || bad "Argo rendered nothing"

echo ""
echo "== 5. the drill can push (scenario 03 answers with 'git revert && git push') =="
kubectl -n argocd exec deploy/argocd-repo-server -- /bin/sh -c "
  rm -rf /tmp/pushprobe
  git clone -q --depth 1 $REPO_URL /tmp/pushprobe 2>&1 | head -2
  cd /tmp/pushprobe
  git -c user.email=drill@example.invalid -c user.name=drill commit -q --allow-empty -m 'push probe'
  git push -q origin HEAD:refs/heads/push-probe 2>&1 | head -2" >/dev/null 2>&1
kubectl -n git exec "$POD" -c "$SEED_CONTAINER" -- \
  git -C "$REPO_PATH" show-ref --verify --quiet refs/heads/push-probe &&
  ok "a push from in-cluster landed on the server" || bad "push did not land"

echo ""
echo "== repo-server log (the reason, whichever way it went) =="
kubectl -n argocd logs deploy/argocd-repo-server --tail=60 2>/dev/null |
  grep -iE 'clone|fail|error' | tail -12

rm -f "$MANIFESTS"
echo ""
echo "cluster-git-argo: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
