#!/usr/bin/env bash
# ministack sandbox test - runs `terraform plan` against a local mock AWS API so you
# can catch wiring/dependency bugs with ZERO cloud spend. Implements the
# container-sandbox skill's Terraform/Ministack flow. Podman required.
#
# IMPORTANT: ministack emulates the AWS API surface - it validates the Terraform graph.
# It does NOT reproduce a live EKS control-plane version upgrade. That is real-AWS only.
set -euo pipefail

ENV="${1:-dev}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TFDIR="$REPO/terraform/envs/$ENV"
[ -d "$TFDIR" ] || { echo "no such env: $ENV"; exit 1; }

command -v podman >/dev/null 2>&1 || { echo "ERROR: podman not found. This test needs Podman."; exit 1; }

echo "== ministack sandbox (env=$ENV) =="

# 1. Never hardcode 4566 - probe a free high port so parallel sessions don't collide.
PORT="$(python3 - <<'PY'
import socket, random
for p in random.sample(range(30000, 65001), 200):
    try:
        with socket.socket() as s:
            s.bind(("127.0.0.1", p)); print(p); break
    except OSError:
        continue
PY
)"
[ -n "$PORT" ] || { echo "ERROR: no free port in 30000-65000"; exit 1; }
NAME="ministack_${PORT}"

OVERRIDE="$TFDIR/ministack_override.tf"
cleanup() {
  rm -f "$OVERRIDE"
  podman stop "$NAME" >/dev/null 2>&1 || true
  podman rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT
rm -f "$OVERRIDE" # clear any stray override from a previous run

echo "starting $NAME on 127.0.0.1:${PORT}"
podman run -d --name "$NAME" \
  -p "${PORT}:4566" \
  -v "$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock:Z" \
  docker.io/ministackorg/ministack:full >/dev/null

# 2. Wait for readiness.
for _ in $(seq 1 40); do
  if curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then break; fi
  sleep 1
done
echo -n "status: "; podman ps --filter "name=$NAME" --format '{{.Status}}' || true

# 3. Point Terraform at ministack (fake creds; all module vars already have defaults).
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-2
export AWS_ENDPOINT_URL="http://127.0.0.1:${PORT}"

mkdir -p "$TFDIR/test"

# Generate this env's tfvars from scripts/config.toml (there are no defaults without it).
python3 "$REPO/scripts/bootstrap.py" "$ENV" --generate-only

# Neutralize the S3 backend for local testing: an override file (gitignored via
# *_override.tf) swaps it for a local backend so no real AWS is ever touched.
cat > "$OVERRIDE" <<'EOF'
terraform {
  backend "local" {}
}
EOF

cd "$TFDIR"

# 4. Validate + plan against the mock (local state, no S3, no real AWS).
terraform init -reconfigure -input=false
terraform validate
if terraform plan -input=false -out=test/ministack.tfplan; then
  echo ""
  echo "OK: plan saved to $TFDIR/test/ministack.tfplan"
  echo "    review with: terraform -chdir=$TFDIR show test/ministack.tfplan"
else
  echo ""
  echo "PLAN FAILED against ministack. ministack's EKS/add-on coverage is partial, so"
  echo "some resources may not resolve here - read the error and decide if it's a real"
  echo "wiring bug or an emulator gap. This is a correctness aid, not a guarantee."
  exit 1
fi
