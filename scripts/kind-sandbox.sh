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
    # --kubeconfig is not optional. Without it kind merges the new context into
    # the user's ~/.kube/config, which this repo must never write.
    kind create cluster --name "$NAME" --wait 120s --kubeconfig "$KUBECONFIG_FILE" || return 1
  fi
  kind get kubeconfig --name "$NAME" > "$KUBECONFIG_FILE" || return 1
  echo "kind-sandbox: wrote $KUBECONFIG_FILE"
  echo "  use it with:  export KUBECONFIG=$KUBECONFIG_FILE"
}

cmd_down() {
  need kind
  # --kubeconfig again, so the delete prunes the repo-local file and leaves the
  # user's ~/.kube/config untouched.
  exists && kind delete cluster --name "$NAME" --kubeconfig "$KUBECONFIG_FILE"
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
