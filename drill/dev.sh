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

# ONLY what the learner's repository holds, which is what scripts/git-seed.py
# seeds cluster git with - see DRILL_PATHS there. The preview has to match, or it
# shows a workspace nobody will ever get.
#
# Not scenarios/ (which contains the ANSWER KEY), not docs/ (the plan, which
# explains every task), not drill/ (the grader's source), not CLAUDE.md or
# COMPASS.md or README.md. The terminal is a real shell in this tree, so anything
# copied here is something `ls` and `cat` reach, and the server's care over never
# sending accept rules to the browser would be pointless.
cp -r /repo/helm "$WORKSPACE/helm"

# A real repo, so the terminal's git behaves and `git status` shows the edit the
# editor just made. The remote is a dead end on purpose: this preview has no
# cluster git to push to, and it must not inherit the repo's real origin.
if [ ! -d "$WORKSPACE/.git" ]; then
  # -b main, because that is what git-seed.py creates and what the Argo CD
  # Application targets. A preview on `master` would be a different environment.
  git -C "$WORKSPACE" init -q -b main
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
