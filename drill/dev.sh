#!/bin/sh
# The preview: the drill server and the Vite dev server, in one container.
#
# Both halves have to be reachable from the same origin or the websocket and the
# API get cross-origin rules that the real deployment never has, so Vite proxies
# /api and /ws to the server over loopback. Running them in one container rather
# than a compose stack is the whole difference between `make -f Makefile.test
# drill-dev` and a second file to maintain.
#
# The workspace is a scratch copy under /tmp, NOT a mount of the repo. Nothing here
# should be able to write to the working tree, and the editor panel autosaves.
set -eu

WORKSPACE=/tmp/drill-workspace
LOGS=/tmp/drill-pty
# Vite serves the UI in dev; the server still wants a web root that exists.
WEBROOT=/tmp/drill-web
SCENARIO=${DRILL_SCENARIO:-03}

rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE" "$LOGS" "$WEBROOT"

# A representative slice of the repo, not one file. The explorer is the point of
# the panel and a tree with a single leaf tells you nothing about whether it works.
# In the cluster this is a full git clone; here it is a copy of the parts a drill
# ever touches, and deliberately NOT scripts/, which holds config.toml.
for dir in helm scenarios; do
  cp -r "/repo/$dir" "$WORKSPACE/$dir"
done
cp /repo/README.md /repo/CLAUDE.md /repo/COMPASS.md "$WORKSPACE/" 2>/dev/null || true

# A real repo, so the terminal's git behaves and `git status` shows the edit the
# editor just made. The remote is a dead end on purpose: this preview has no
# cluster git to push to, and it must not inherit the repo's real origin.
if [ ! -d "$WORKSPACE/.git" ]; then
  git -C "$WORKSPACE" init -q
  git -C "$WORKSPACE" config user.email drill@localhost
  git -C "$WORKSPACE" config user.name "drill preview"
  git -C "$WORKSPACE" add -A
  git -C "$WORKSPACE" commit -qm "preview workspace"
fi

DRILL_WEB_ROOT="$WEBROOT" \
DRILL_ANSWERS_DIR=/repo/scenarios/answers \
DRILL_WORKSPACE="$WORKSPACE" \
DRILL_LOG_DIR="$LOGS" \
DRILL_TMUX_CONF=/repo/drill/tmux.conf \
DRILL_SCENARIO="$SCENARIO" \
DRILL_HOST=127.0.0.1 \
DRILL_SESSION_ID=preview \
  node --experimental-strip-types /repo/drill/server/src/index.ts &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null || true' EXIT INT TERM

# Vite serves the UI; the server above only answers /api and /ws here.
cd /repo/drill/web
exec npm run dev -- --host 0.0.0.0 --port 5173
