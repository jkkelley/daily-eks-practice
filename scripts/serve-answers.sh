#!/usr/bin/env bash
# Serve PRACTICE_ANSWERS.html on a local static server and open it.
# Linux / macOS / WSL.
#   bash scripts/serve-answers.sh          # whole answer key   (make serve-answers)
#   bash scripts/serve-answers.sh 02       # ONLY scenario 02   (make serve-answers N=02)
# Scoping to one scenario keeps you from seeing answers to drills you haven't done yet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="PRACTICE_ANSWERS.html"
[ -f "$ROOT/$FILE" ] || { echo "ERROR: $FILE not found in repo root."; exit 1; }

# Optional scenario number. Empty => serve the full key (back-compat).
N="${1:-}"
SERVE_DIR="$ROOT"
if [ -n "$N" ]; then
  # Normalise to the repo's zero-padded numbering (2 -> 02); 10# avoids octal on 08/09.
  N="$(printf '%02d' "$((10#$N))" 2>/dev/null || echo "$N")"
  SCOPED_DIR="$(mktemp -d)"
  trap 'rm -rf "$SCOPED_DIR"' EXIT

  # Keep the head/seal (everything before the first scenario), then only the one
  # <details> block whose summary <h2> starts with "NN - ", then the footer/script.
  awk -v n="$N" '
    BEGIN { header = 1 }
    header == 1 && /<details>/ { header = 0 }
    header == 1 { print; next }
    /<details>/ { indetails = 1; keep = 0; buf = $0 ORS; next }
    indetails == 1 {
      buf = buf $0 ORS
      if ($0 ~ ("<h2[^>]*>" n " - ")) keep = 1
      if ($0 ~ /<\/details>/) { if (keep) printf "%s", buf; indetails = 0; buf = "" }
      next
    }
    { print }
  ' "$ROOT/$FILE" > "$SCOPED_DIR/$FILE"

  # Fail loud if the number matched no scenario, rather than serving an empty page.
  if ! grep -q "<details>" "$SCOPED_DIR/$FILE"; then
    echo "ERROR: no scenario '$N' in $FILE (scenarios are 01-12)."; exit 1
  fi
  SERVE_DIR="$SCOPED_DIR"
  echo "Scoped to scenario $N only (other answers are not served)."
fi

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

cd "$SERVE_DIR"
exec python3 -m http.server "$PORT" --bind 127.0.0.1
