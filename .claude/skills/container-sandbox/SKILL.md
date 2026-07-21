---
name: container-sandbox
description: Run all dependency-heavy tasks (npm, go, pip) in isolated Podman containers. Also use when showing the user a localhost frontend that makes API calls — a real or mock backend must be running in the same compose stack.
---

# Dependency Isolation Protocol

**RULE:** Never run `npm install`, `go mod download`, or `pip install` on the host.

## 1. Choosing the Sandbox
- **Small Tasks:** Use the **Single-Use Container** (Podman).
- **Cluster Tasks:** Use the **Kind Sandbox** (Kind + Podman).
- **Terraform Tasks:** Use the **Ministack Sandbox** (see section below).

## 2. Dependency Management (The "No-Clutter" Way)

### Node.js (npm)
Instead of `npm install`, tell the agent to run:

**Step 1 — check for a project golden image first.**
Look in the project's `CLAUDE.md`, `Dockerfile`, or pipeline config for a GHCR base image tagged `:latest-amd64`. If one exists, prefer it over upstream — it will be already patched, non-root, and have `dumb-init`.

```bash
# Log in once per session (username resolved dynamically — no hardcoding)
GHCR_USER=$(gh api user --jq .login)
gh auth token | podman login ghcr.io -u "$GHCR_USER" --password-stdin

# Run with the project golden image
# --userns=keep-id maps host UID into the container so volume-mounted files are writable
podman run --rm --userns=keep-id -v .:/app:Z -w /app \
  ghcr.io/${GHCR_USER}/<project>-base:latest-amd64 \
  sh -c "npm install && npm test"
```

**Fallback** — if no golden image exists or GHCR auth is unavailable:
```bash
podman run --rm -v .:/app:Z -w /app node:24-alpine sh -c "npm install && npm test"
```

## Terraform / Ministack Sandbox

**RULE:** Use Ministack any time Terraform files are written or modified, unless the user explicitly says not to. This includes `terraform validate` — syntax-only checks are not enough. No exceptions.

### Step 1 — Gitignore Pre-Flight

Before anything else, verify these entries exist in `.gitignore`. If any are missing, add them. These files must never be committed:

```
test/
**/.terraform/
*.tfvars
*.tfstate.backup
**/.terraform.lock.hcl
```

```bash
REQUIRED=("test/" "**/.terraform/" "*.tfvars" "*.tfstate.backup" "**/.terraform.lock.hcl")
for entry in "${REQUIRED[@]}"; do
  grep -qxF "$entry" .gitignore 2>/dev/null || echo "$entry" >> .gitignore
done
```

Commit `.gitignore` if it was modified before continuing.

### Step 2 — Start Ministack

Multiple Claude sessions may run simultaneously. Never hardcode port 4566 — always detect a free port in the high range first so sessions don't collide or kill each other's containers.

```bash
# Find a free port in 30000-65000
MINISTACK_PORT=$(python3 -c "
import socket, random
for p in random.sample(range(30000, 65001), 200):
    try:
        with socket.socket() as s:
            s.bind(('127.0.0.1', p))
            print(p)
            break
    except OSError:
        continue
")
if [ -z "$MINISTACK_PORT" ]; then
  echo "ERROR: No free port found in range 30000-65000. Cannot start Ministack."
  exit 1
fi
echo "Starting Ministack on port $MINISTACK_PORT"
```

```bash
podman run -d \
  --name ministack_${MINISTACK_PORT} \
  -p ${MINISTACK_PORT}:4566 \
  -v $XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock:Z \
  ministackorg/ministack:full
```

Verify it is up before continuing:

```bash
podman ps --filter name=ministack_${MINISTACK_PORT} --format "{{.Status}}"
# Must show "Up"
```

If the container fails to start, **stop and report the exact error to the user**. Do not proceed.

### Step 3 — Seed a Throwaway terraform.tfvars

Variables without defaults will cause `terraform validate` and `terraform plan` to fail with missing-value errors. Create a temporary `terraform.tfvars` with fake seed values for the test run. This file goes in the module root, never in source code — it is already covered by the `*.tfvars` gitignore entry and will never be committed.

Fake values go in this file, not into `variables.tf` defaults or hardcoded into resources:

```hcl
# terraform.tfvars — ministack test seed, never commit
aws_region   = "us-east-1"
account_id   = "000000000000"
domain       = "test.example.com"
cluster_name = "test-cluster"
```

Adapt the keys to match whatever variables the module actually declares. If a variable has a default, skip it. Only seed what's required.

### Step 4 — Point Terraform at Ministack

Set these environment variables before running any Terraform commands:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://localhost:${MINISTACK_PORT}
```

### Step 5 — Validate

`terraform plan` against Ministack runs a real plan simulation against the mock AWS API endpoints — it produces the same plan output you'd get against real AWS for supported services.

```bash
terraform init -backend=false
terraform validate
terraform plan -out=test/ministack.tfplan
```

The plan is saved to `test/ministack.tfplan`. This path is covered by the `test/` gitignore entry so it will never be committed. Running again overwrites the same file — no stale plans accumulate.

Tell the user: **"Plan saved to `test/ministack.tfplan`. Run `terraform show test/ministack.tfplan` to review it."**

If any command fails, **stop and report the exact error to the user**. Do not guess at a fix and re-run silently.

### Step 6 — Teardown

**This step is mandatory — do not skip it.** Leaving Ministack running holds the port open and consumes system resources. Always stop and remove the container when testing is done, regardless of whether the tests passed or failed.

```bash
podman stop ministack_${MINISTACK_PORT} && podman rm ministack_${MINISTACK_PORT}
```

---

## Lifecycle Management
- **Pre-flight:** Always run `./scripts/verify-readiness.sh` before starting a cluster.
- **Teardown:** When the task is complete, run `./scripts/cleanup-kind-podman.sh`.
- **Maintenance:** If disk space is low or images are outdated, run `./scripts/prune-images.sh`.

---

## 3. Frontend Dev With API Dependency — Full Stack Compose Rule

**RULE: Never ask the user to look at a page with no data.**

When a frontend feature makes API calls, spin up a `podman compose` stack with:
- The real backend (or a mock) seeded with realistic data
- The frontend dev server
- All services on the same compose network

Verify data flows end-to-end with `curl` before handing the URL to the user.

### Port convention — always probe for an open port in 30000+ before starting any container

Never hardcode a low port (3000, 8000, 13000, etc.). Multiple Claude sessions and dev servers share the same host — low ports are almost always in use or will collide.

**Required before every `podman run` or `podman compose up`:** run the probe below to find a port that is confirmed open, then use that port and only that port for the container mapping.

```bash
FREE_PORT=$(python3 -c "
import socket, random
for p in random.sample(range(30000, 65001), 200):
    try:
        with socket.socket() as s:
            s.bind(('127.0.0.1', p))
            print(p)
            break
    except OSError:
        continue
")
[ -z "$FREE_PORT" ] && echo "ERROR: no free port found in 30000-65000" && exit 1
echo "Using port $FREE_PORT"
```

Run the probe once per service that needs a host port. Each service gets its own `FREE_PORT` call.

| Service | Host port |
|---------|-----------|
| Frontend | `$FREE_PORT` — probed, confirmed open, 30000+ |
| Backend API | `$FREE_PORT_2` — separately probed, confirmed open, 30000+ |
| Mock backend | internal only — no host port needed |

---

### Single-container preview (no compose needed) — with 30-minute auto-stop

Use this pattern when you need to show the user a built frontend image without a backend dependency.

**Containers are cattle. They live 30 minutes and die.** Use `--rm` so Podman cleans up automatically on stop. Schedule a background kill so the container never becomes a zombie if the session ends.

```bash
# 1. Probe for a free port
FREE_PORT=$(python3 -c "
import socket, random
for p in random.sample(range(30000, 65001), 200):
    try:
        with socket.socket() as s:
            s.bind(('127.0.0.1', p))
            print(p)
            break
    except OSError:
        continue
")
[ -z "$FREE_PORT" ] && echo "ERROR: no free port" && exit 1

# 2. Give the container a unique timestamped name (no --replace needed)
CONTAINER_NAME=preview-$(date +%s)

# 3. Run detached with --rm so it self-cleans on stop
podman run -d --rm --name "$CONTAINER_NAME" -p "${FREE_PORT}:3000" <image>

# 4. Schedule auto-stop after 30 minutes in the background
(sleep 1800 && podman stop "$CONTAINER_NAME" 2>/dev/null) &

echo "Preview running at http://localhost:${FREE_PORT}"
echo "Auto-stops in 30 minutes (container: $CONTAINER_NAME)"
```

Then verify with curl before handing the URL to the user:
```bash
sleep 2 && curl -s -o /dev/null -w "%{http_code}" "http://localhost:${FREE_PORT}/"
# Must return 200 before reporting the URL
```

---

### Pattern — real backend stack

When the project already has a working backend image (`<service>:dev`):

1. **Create `test/start-be.sh`** — startup script baked into the be service that runs migrations, seeds data, then starts the server. This avoids one-shot init containers, which break `--requires` chains in podman-compose 1.0.6.

   ```sh
   #!/bin/sh
   set -e
   echo "[start-be] running migrations..."
   alembic upgrade head          # or your migration tool
   echo "[start-be] seeding..."
   python /init.py
   echo "[start-be] starting server..."
   exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
   ```

2. **Create `test/init.py`** — seed script using the same DB library already in the image (e.g. asyncpg). No extra installs.

3. **Create `compose.test.yml`** in the workspace root (parent of all service repos) so relative paths reach sibling repos:

   ```yaml
   services:
     postgres:
       image: docker.io/postgres:15-alpine
       environment:
         POSTGRES_DB: myapp
         POSTGRES_USER: myapp
         POSTGRES_PASSWORD: dev
       healthcheck:
         test: ["CMD-SHELL", "pg_isready -U myapp"]
         interval: 3s
         retries: 15

     be:
       image: myapp-be:dev           # pre-built dev image
       volumes:
         - ./myapp-be:/app:Z
         - ./test/init.py:/init.py:ro,Z
         - ./test/start-be.sh:/start-be.sh:ro,Z
       environment:
         DATABASE_URL: postgresql+asyncpg://myapp:dev@postgres:5432/myapp
       ports:
         - "18000:8000"
       command: sh /start-be.sh
       depends_on:
         postgres:
           condition: service_healthy

     frontend:
       # Prefer the project golden image (:latest-amd64) if available; fall back to node:24-alpine
       image: ghcr.io/${GHCR_USER}/<project>-base:latest-amd64
       user: "0"   # run as root in dev compose — avoids UID mismatch with volume mounts
       volumes:
         - ./myapp-fe:/app:Z
       working_dir: /app
       ports:
         - "13000:3000"             # or whatever port Vite uses
       environment:
         API_PROXY_TARGET: http://be:8000   # see proxy env var rule below
       command: npm run dev -- --host
       depends_on:
         - be
   ```

4. **Spin up:** `podman compose -f compose.test.yml up --build -d`

5. **Verify the API responds** before directing the user to the browser:
   ```bash
   curl -s http://localhost:18000/api/v1/<resource>/ | python3 -m json.tool | head -20
   curl -s http://localhost:13000/api/v1/<resource>/          # through the Vite proxy
   ```

   Both must return data. If the first works but the second doesn't, the proxy env var is wrong (see below).

6. **Direct user to:** `http://localhost:13000`

---

### Critical: Vite proxy env var — use API_PROXY_TARGET, not VITE_API_URL

Vite exposes **all** `VITE_*` env vars to the browser bundle at dev-server startup. If you set `VITE_API_URL=http://be:8000` in the container, Axios picks it up client-side and tries to fetch `http://be:8000/api/...` directly from the browser — which can't resolve the internal Docker hostname. The page loads but shows no data.

**The fix:** use a non-`VITE_` prefixed variable for the server-side proxy target only.

In `vite.config.ts`:
```ts
proxy: {
  '/api': {
    target: process.env.API_PROXY_TARGET || process.env.VITE_API_URL || 'http://localhost:8000',
    changeOrigin: true,
  },
},
```

In `compose.test.yml`:
```yaml
environment:
  API_PROXY_TARGET: http://be:8000   # server-side only — NOT exposed to browser
  # do NOT set VITE_API_URL here
```

With this, Axios uses an empty base URL → relative paths → Vite proxy routes them → `be:8000` resolves on the compose network.

---

### Pattern — mock backend (no real backend image available)

When there is no pre-built backend image, create a zero-dependency Node.js mock:

1. **Create `test/mock-api/server.mjs`** — uses only `node:http` built-in, no npm install.
   - Handles CORS (`Access-Control-Allow-Origin: *`)
   - Serves realistic seed data
   - Logs all requests so you can verify API contracts

2. **Create `test/mock-api/Dockerfile`**:
   ```dockerfile
   # Prefer the project golden image (:latest-amd64) if available; fall back to node:24-alpine
   FROM ghcr.io/${GHCR_USER}/<project>-base:latest-amd64
   COPY server.mjs .
   EXPOSE 9090
   CMD ["node", "server.mjs"]
   ```

3. Add to `compose.test.yml` as a `mock-api` service (internal only, no host port).

4. In the frontend service, set `API_PROXY_TARGET: http://mock-api:9090`.

---

### podman-compose 1.0.6 known limitations

- **One-shot containers in dependency chains don't work.** `depends_on: condition: service_completed_successfully` is ignored — podman uses `--requires` which requires the dependency to be *running*, not *completed*. A one-shot init container that exits will break the chain for all downstream services.
  - **Workaround:** merge migrations and seed into the main service startup script (see `start-be.sh` pattern above).

- **`condition: service_healthy`** works correctly for postgres with a `pg_isready` healthcheck.

- **`condition: service_started`** works for always-running services.

---

### Seed data guidelines
- Include enough records to exercise every UI state: empty results, filtered results, edge-case values.
- Use realistic names, addresses, phone numbers — not `"foo"` / `"bar"` / `999`.
- Insert seed data in **non-alphabetical order** when testing sort fixes — this is the only way to prove the sort is actually working.
- Use `ON CONFLICT DO NOTHING` so the script is safe to re-run.

### Teardown
```bash
podman compose -f compose.test.yml down
```
