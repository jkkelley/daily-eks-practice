#!/usr/bin/env bash
# Scenario end-state checker - `make check N=03` runs `check.sh 03`.
# These are OUTCOME checks against the LIVE cluster (kubectl/aws), so you can
# grade yourself after a drill. They never mutate anything.
# Repo-level validation (fmt/validate/ministack/helm) lives in tests/ instead.
set -uo pipefail

N="${1:-}"
[ -n "$N" ] || { echo "usage: check.sh <scenario number, e.g. 03>"; exit 2; }

# The playground uses a repo-local kubeconfig (make kubeconfig), never ~/.kube/config.
# `make check` exports KUBECONFIG already; this covers running check.sh directly.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO_ROOT/.kubeconfig-daily-eks-practice" ] && export KUBECONFIG="$REPO_ROOT/.kubeconfig-daily-eks-practice"

PASS=0; FAIL=0
ok()   { echo "  PASS  $*"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL+1)); }
note() { echo "  NOTE  $*"; }

need() { # need <cmd>
  command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1"; exit 2; }
}
need kubectl

APP_NS="${APP_NS:-practice-app}"

ready_deploy() { # ready_deploy <ns> <name-substring> "<label for messages>"
  local ns="$1" sub="$2" label="$3" line
  line=$(kubectl -n "$ns" get deploy 2>/dev/null | awk -v s="$sub" 'index($1, s) {print; exit}')
  if [ -z "$line" ]; then bad "$label: no deployment matching '$sub' in $ns"; return 1; fi
  local name ready
  name=$(echo "$line" | awk '{print $1}')
  ready=$(echo "$line" | awk '{print $2}')
  if [ "${ready%/*}" = "${ready#*/}" ] && [ "${ready%/*}" != "0" ]; then
    ok "$label: $name is fully ready ($ready)"
  else
    bad "$label: $name not fully ready ($ready)"
  fi
}

case "$N" in
  01)
    nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
    [ "$nodes" -ge 1 ] && ok "$nodes Ready node(s)" || bad "no Ready nodes (is the cluster up? make kubeconfig?)"
    ready_deploy "$APP_NS" frontend "app frontend"
    ready_deploy "$APP_NS" backend "app backend"
    note "console familiarity is on you - could you find the node group scaling config blind?"
    ;;
  02)
    hpa=$(kubectl -n "$APP_NS" get hpa --no-headers 2>/dev/null | head -1)
    if [ -n "$hpa" ]; then
      ok "HPA exists: $(echo "$hpa" | awk '{print $1, "min="$5, "max="$6}')"
      echo "$hpa" | awk '{exit !($5==2 && $6==5)}' && ok "HPA bounds are 2..5" || note "HPA bounds differ from the card (2..5) - fine if intentional"
    else
      bad "no HPA in $APP_NS"
    fi
    ready_deploy "$APP_NS" frontend "frontend"
    ;;
  03)
    ready_deploy "$APP_NS" frontend "frontend"
    dep=$(kubectl -n "$APP_NS" get deploy -o name | grep frontend | head -1)
    revs=$(kubectl -n "$APP_NS" rollout history "$dep" 2>/dev/null | grep -c '^[0-9]')
    [ "${revs:-0}" -ge 2 ] && ok "rollout history has $revs revisions" || bad "rollout history has <2 revisions - did you roll?"
    img=$(kubectl -n "$APP_NS" get "$dep" -o jsonpath='{.spec.template.spec.containers[0].image}')
    note "running image: $img - confirm it matches helm/practice-app/values.yaml"
    ;;
  04)
    ready_deploy kube-system aws-load-balancer-controller "ALB controller"
    ing=$(kubectl -n "$APP_NS" get ingress --no-headers 2>/dev/null | wc -l)
    lbs=$(kubectl -n "$APP_NS" get svc --no-headers 2>/dev/null | awk '$2=="LoadBalancer"' | wc -l)
    if [ "$ing" -gt 0 ]; then
      addr=$(kubectl -n "$APP_NS" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
      [ -n "$addr" ] && ok "ingress live at $addr (remember to remove it before make down)" || bad "ingress exists but has no address yet"
    elif [ "$lbs" -gt 0 ]; then
      ok "LoadBalancer service present (NLB half of the drill)"
    else
      ok "no LB/ingress right now - clean state (fine if you already did + reverted the drill)"
    fi
    ;;
  05)
    ready_deploy kube-system coredns "CoreDNS"
    if kubectl run dnscheck-$$ --rm -i --restart=Never --image=busybox:1.36 --timeout=60s -- \
        nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
      ok "in-cluster DNS resolves from a test pod"
    else
      bad "in-cluster DNS lookup failed from a test pod"
    fi
    ;;
  06)
    if kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name} {.parameters.type}{"\n"}{end}' 2>/dev/null | grep -q gp3; then
      ok "a gp3 StorageClass exists"
    else
      bad "no gp3 StorageClass found"
    fi
    leftover=$(kubectl get pvc -A --no-headers 2>/dev/null | grep -v -E "monitoring|argocd" | wc -l)
    [ "$leftover" -eq 0 ] && ok "no leftover practice PVCs" || bad "$leftover PVC(s) still around - EBS bills per GB-month"
    note "S3 half: confirm you put+got an object via the s3-explorer service account"
    ;;
  07)
    ready_deploy monitoring grafana "Grafana"
    prom=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | awk '$3=="Running"' | wc -l)
    [ "$prom" -ge 1 ] && ok "Prometheus running" || bad "Prometheus not running in monitoring"
    ;;
  08)
    if command -v aws >/dev/null 2>&1; then
      cluster=$(kubectl config current-context 2>/dev/null | awk -F/ '{print $NF}')
      logs=$(aws eks describe-cluster --name "$cluster" \
        --query 'cluster.logging.clusterLogging[?enabled==`true`].types' --output text 2>/dev/null)
      [ -z "$logs" ] && ok "control-plane logging is OFF (cost hygiene)" || bad "control-plane logging still ON: $logs"
      ci=$(aws logs describe-log-groups --log-group-name-prefix "/aws/containerinsights/" \
        --query 'logGroups[].logGroupName' --output text 2>/dev/null)
      [ -z "$ci" ] && ok "no Container Insights log groups lingering" || bad "lingering log groups: $ci"
    else
      note "aws CLI not found - skipped the CloudWatch checks"
    fi
    ;;
  09)
    ready_deploy argocd argocd-server "Argo CD server"
    if kubectl -n argocd get application practice-app >/dev/null 2>&1; then
      sync=$(kubectl -n argocd get application practice-app -o jsonpath='{.status.sync.status}')
      health=$(kubectl -n argocd get application practice-app -o jsonpath='{.status.health.status}')
      [ "$sync" = "Synced" ] && ok "Application is Synced" || bad "Application sync status: ${sync:-unknown}"
      [ "$health" = "Healthy" ] && ok "Application is Healthy" || bad "Application health: ${health:-unknown}"
      auto=$(kubectl -n argocd get application practice-app -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')
      [ "$auto" = "true" ] && ok "automated sync + self-heal enabled" || bad "self-heal not enabled yet (task 5)"
    else
      bad "no practice-app Application in argocd (run make app-deploy)"
    fi
    ;;
  10)
    bad_pods=$(kubectl -n "$APP_NS" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
    [ "$bad_pods" -eq 0 ] && ok "no pods in a bad state" || bad "$bad_pods pod(s) unhealthy in $APP_NS"
    ready_deploy "$APP_NS" frontend "frontend"
    ready_deploy "$APP_NS" backend "backend"
    ;;
  11)
    ready_deploy "$APP_NS" backend "backend (post-rotation health)"
    if command -v aws >/dev/null 2>&1; then
      pub=$(aws rds describe-db-instances \
        --query 'DBInstances[?contains(DBInstanceIdentifier, `practice`)].PubliclyAccessible' --output text 2>/dev/null)
      [ "$pub" = "False" ] && ok "RDS is not publicly accessible" || note "couldn't confirm RDS public flag (got: '$pub')"
    fi
    note "secret-vs-DB agreement is proven by the backend being Ready and the app writing rows"
    ;;
  12)
    if command -v gh >/dev/null 2>&1; then
      gh variable list 2>/dev/null | grep -q AWS_ROLE_ARN && ok "repo variable AWS_ROLE_ARN set" || bad "AWS_ROLE_ARN repo variable missing"
      gh secret list 2>/dev/null | grep -q CONFIG_TOML && ok "repo secret CONFIG_TOML set" || bad "CONFIG_TOML repo secret missing"
      runs=$(gh run list --workflow terraform-plan --limit 5 --json conclusion -q '[.[]|select(.conclusion=="success")]|length' 2>/dev/null)
      [ "${runs:-0}" -ge 1 ] && ok "at least one green terraform-plan run" || bad "no green terraform-plan runs yet"
    else
      note "gh CLI not found - skipped the CI checks"
    fi
    ;;
  *)
    echo "unknown scenario '$N' (01-12)"; exit 2 ;;
esac

echo ""
echo "scenario $N: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
