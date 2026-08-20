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

# The harness must never write the user's default kubeconfig. kind merges a new
# context into it unless --kubeconfig is passed, so this is a live regression
# guard, not a formality. Only the mtime is sampled - the file is never read.
USER_KUBECONFIG="${HOME}/.kube/config"
user_kc_stamp() { stat -c '%Y' "$USER_KUBECONFIG" 2>/dev/null || echo "absent"; }
USER_KC_BEFORE="$(user_kc_stamp)"

echo "== status on a cluster that does not exist =="
bash "$HARNESS" status >/dev/null 2>&1 && bad "status exited 0 with no cluster" || ok "status is non-zero with no cluster"

echo "== up =="
bash "$HARNESS" up >/dev/null 2>&1 && ok "up succeeded" || bad "up failed"
bash "$HARNESS" status >/dev/null 2>&1 && ok "status is 0 after up" || bad "status non-zero after up"

echo "== kubeconfig points somewhere real =="
# Never let KUBECONFIG go empty here. An empty value makes kubectl fall back to
# the user's ~/.kube/config, which this repo must never read, and which hangs the
# test on whatever unreachable endpoint that file happens to hold.
KC="$(bash "$HARNESS" kubeconfig)"
[ -n "$KC" ] && [ -f "$KC" ] && ok "kubeconfig exists at $KC" || bad "no kubeconfig at '$KC'"
if [ -n "$KC" ]; then
  KUBECONFIG="$KC" kubectl --request-timeout=15s get nodes >/dev/null 2>&1 && ok "kubectl works against it" || bad "kubectl failed"
else
  bad "kubectl not attempted - harness printed no kubeconfig path"
fi

echo "== up is idempotent =="
bash "$HARNESS" up >/dev/null 2>&1 && ok "second up succeeded" || bad "second up failed"

echo "== down =="
bash "$HARNESS" down >/dev/null 2>&1 && ok "down succeeded" || bad "down failed"
bash "$HARNESS" status >/dev/null 2>&1 && bad "status exited 0 after down" || ok "status non-zero after down"
[ -f "$KC" ] && bad "kubeconfig survived down" || ok "kubeconfig removed by down"

echo "== the user's default kubeconfig was never written =="
[ "$(user_kc_stamp)" = "$USER_KC_BEFORE" ] && ok "~/.kube/config untouched" || bad "~/.kube/config was modified"

echo ""
echo "kind-sandbox: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
