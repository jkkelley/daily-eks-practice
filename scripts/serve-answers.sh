#!/usr/bin/env bash
# Serve PRACTICE_ANSWERS.html on a local static server and open it.
# Linux / macOS / WSL. Usage: bash scripts/serve-answers.sh   (or: make serve-answers)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="PRACTICE_ANSWERS.html"
[ -f "$ROOT/$FILE" ] || { echo "ERROR: $FILE not found in repo root."; exit 1; }

PORT="${PORT:-}"
if [ -z "$PORT" ]; then
  PORT="$(python3 - <<'PY'
import socket, random
for p in random.sample(range(8000, 8999), 60):
    try:
        with socket.socket() as s:
            s.bind(("127.0.0.1", p)); print(p); break
    except OSError:
        continue
PY
)"
fi

URL="http://127.0.0.1:${PORT}/${FILE}"
echo "Serving the sealed answer key at:  $URL"
echo "(Ctrl+C to stop)"

# Best-effort open a browser without blocking the server.
( sleep 1
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1 || true
  elif command -v open   >/dev/null 2>&1; then open "$URL"     >/dev/null 2>&1 || true
  elif command -v wslview >/dev/null 2>&1; then wslview "$URL" >/dev/null 2>&1 || true
  fi ) &

cd "$ROOT"
exec python3 -m http.server "$PORT" --bind 127.0.0.1
