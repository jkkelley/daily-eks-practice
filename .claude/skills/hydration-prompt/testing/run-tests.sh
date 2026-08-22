#!/usr/bin/env bash
# Drives hydration.sh through the cases that matter. Run in a container:
#
#   podman run --rm --user 0 -v "$PWD:/work:ro,Z" -w /tmp \
#     docker.io/library/bash:5 bash /work/testing/run-tests.sh
#
# The failure cases are the point. A green happy path cannot tell a working
# guard from a decorative one.
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HP="$HERE/../scripts/hydration.sh"
PASS=0; FAIL=0

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
hd()  { printf '\n=== %s\n' "$1"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# A body that passes check, parameterised so entries are distinguishable.
good_body() {
  local tag=$1 out=$2
  cat > "$out" <<EOF
### Ticket
WO-TEST-$tag - Test ticket $tag.

### What just landed
Landed $tag.

### What is NOT done
Nothing was applied for $tag.

### Stale or false in the docs
Nothing stale for $tag.

### Your scope
Scope $tag.

### Before you start
None.

### Read in this order
CLAUDE.md, then the ticket.

### Reuse, it is proven
The thing from $tag.

### The verification ladder
Container, then stub, then real.

### Traps, already paid for
Do not mount over /lib.

### Workflow
bash \$WO start --id WO-TEST-$tag

### Conventions
Plain language, no em dashes.
EOF
}

# ---------------------------------------------------------------- init
hd "init"
P="$WORK/proj"; mkdir -p "$P"
bash "$HP" init --project "$P" >/dev/null 2>&1 \
  && [ -f "$P/HYDRATION.md" ] && ok "creates HYDRATION.md" || bad "did not create HYDRATION.md"
BEFORE=$(md5sum "$P/HYDRATION.md" | cut -d' ' -f1)
bash "$HP" init --project "$P" >/dev/null 2>&1
AFTER=$(md5sum "$P/HYDRATION.md" | cut -d' ' -f1)
[ "$BEFORE" = "$AFTER" ] && ok "re-running init changes nothing" || bad "init is not idempotent"

bash "$HP" count --project "$WORK/nope" >/dev/null 2>&1
[ $? -eq 4 ] && ok "missing HYDRATION.md exits 4 (io)" || bad "wrong exit code for missing file"

# ---------------------------------------------------------------- add + order
hd "add and ordering"
good_body one "$WORK/b1.md"
bash "$HP" add --project "$P" --id WO-TEST-one --title "First ticket" --body-file "$WORK/b1.md" >/dev/null 2>&1 \
  && ok "adds an entry" || bad "add failed"
[ "$(bash "$HP" count --project "$P")" = "1" ] && ok "count is 1" || bad "count wrong after first add"

good_body two "$WORK/b2.md"
bash "$HP" add --project "$P" --id WO-TEST-two --title "Second ticket" --body-file "$WORK/b2.md" >/dev/null 2>&1
NEWEST=$(bash "$HP" latest --project "$P" --id-only)
[ "$NEWEST" = "WO-TEST-two" ] && ok "newest entry is on top" || bad "top entry was '$NEWEST', expected WO-TEST-two"

TITLE=$(bash "$HP" latest --project "$P" --title-only)
[ "$TITLE" = "Second ticket" ] && ok "title parses back out" || bad "title was '$TITLE'"

# latest must return ONE entry, not the file
LATEST_MARKS=$(bash "$HP" latest --project "$P" | grep -c 'hydration-entry:')
[ "$LATEST_MARKS" = "1" ] && ok "latest returns exactly one entry" || bad "latest returned $LATEST_MARKS entries"

# ---------------------------------------------------------------- the window
hd "the 10-entry window"
for n in $(seq 3 12); do
  good_body "n$n" "$WORK/bn.md"
  bash "$HP" add --project "$P" --id "WO-TEST-$n" --title "Ticket $n" --body-file "$WORK/bn.md" >/dev/null 2>&1
done
COUNT=$(bash "$HP" count --project "$P")
[ "$COUNT" = "10" ] && ok "holds exactly 10 after 12 adds" || bad "holds $COUNT, expected 10"

grep -q 'WO-TEST-one' "$P/HYDRATION.md" \
  && bad "the oldest entry was not dropped" || ok "oldest entry fell off the bottom"
[ "$(bash "$HP" latest --project "$P" --id-only)" = "WO-TEST-12" ] \
  && ok "newest is still on top after rotation" || bad "rotation disturbed the top entry"

grep -q '^# HYDRATION.md' "$P/HYDRATION.md" \
  && ok "the file preamble survives rotation" || bad "rotation ate the preamble"

# ---------------------------------------------------------------- check refuses
hd "check refuses malformed bodies"

good_body dup "$WORK/dup.md"
printf '\n### Traps, already paid for\nPasted in twice by accident.\n' >> "$WORK/dup.md"
bash "$HP" check --project "$P" --body-file "$WORK/dup.md" >/dev/null 2>&1
[ $? -eq 3 ] && ok "refuses a duplicated section" || bad "accepted a duplicated section"

good_body miss "$WORK/miss.md"
grep -v '^### Workflow$' "$WORK/miss.md" > "$WORK/miss2.md"
bash "$HP" check --project "$P" --body-file "$WORK/miss2.md" >/dev/null 2>&1
[ $? -eq 3 ] && ok "refuses a missing section" || bad "accepted a missing section"

good_body empt "$WORK/empt.md"
sed 's/^None\.$//' "$WORK/empt.md" > "$WORK/empt2.md"
bash "$HP" check --project "$P" --body-file "$WORK/empt2.md" >/dev/null 2>&1
[ $? -eq 3 ] && ok "refuses an empty 'Before you start'" || bad "accepted an empty prerequisites section"

good_body unk "$WORK/unk.md"
printf '\n### Some Other Heading\nStray paste.\n' >> "$WORK/unk.md"
bash "$HP" check --project "$P" --body-file "$WORK/unk.md" >/dev/null 2>&1
[ $? -eq 3 ] && ok "refuses an unknown section" || bad "accepted an unknown section"

# and the important one: a refused body must not reach the file
COUNT_BEFORE=$(bash "$HP" count --project "$P")
bash "$HP" add --project "$P" --id WO-TEST-bad --title "Bad" --body-file "$WORK/dup.md" >/dev/null 2>&1
COUNT_AFTER=$(bash "$HP" count --project "$P")
[ "$COUNT_BEFORE" = "$COUNT_AFTER" ] \
  && ok "a refused body is not written" || bad "a malformed entry reached the file"

# ---------------------------------------------------------------- the command
hd "the launch command"
CMD=$(bash "$HP" command --project "$P" --id WO-20260818-7a0b --title "CI/CD + GitOps")
EXPECT="claude -p \"Read Hydration Prompt located at $(cd "$P" && pwd)/HYDRATION.md, Process work order WO-20260818-7a0b per its acceptance criteria after you've read it.\" \\
  --permission-mode bypassPermissions \\
  -n \"Session: WO-20260818-7a0b - CI/CD + GitOps\""
[ "$CMD" = "$EXPECT" ] && ok "matches the template byte for byte" || {
  bad "command did not match the template"
  printf '    got:      %s\n    expected: %s\n' "$CMD" "$EXPECT"
}
printf '%s' "$CMD" | grep -q "^claude -p \"Read Hydration Prompt located at /" \
  && ok "path is absolute" || bad "path is not absolute"

bash "$HP" command --project "$WORK/nope" --id X --title Y >/dev/null 2>&1
[ $? -eq 4 ] && ok "refuses to emit a command for a missing file" || bad "emitted a command for a missing file"

# ---------------------------------------------------------------- no work order
hd "the no-work-order edge case"
Q="$WORK/adhoc"; mkdir -p "$Q"
bash "$HP" init --project "$Q" >/dev/null 2>&1
good_body ad "$WORK/ad.md"
bash "$HP" add --project "$Q" --title "Spike: can Lightsail hold an IAM role" --body-file "$WORK/ad.md" >/dev/null 2>&1 \
  && ok "add works with no --id" || bad "add refused an entry with no --id"

[ -z "$(bash "$HP" latest --project "$Q" --id-only)" ] \
  && ok "id-only is empty when there is no ticket" || bad "id-only returned something"
T=$(bash "$HP" latest --project "$Q" --title-only)
[ "$T" = "Spike: can Lightsail hold an IAM role" ] \
  && ok "the title survives intact" || bad "title was '$T'"

ACMD=$(bash "$HP" command --project "$Q")
AEXPECT="claude -p \"Read Hydration Prompt located at $(cd "$Q" && pwd)/HYDRATION.md\" \\
  -n \"Session: \""
[ "$ACMD" = "$AEXPECT" ] && ok "emits the no-work-order command shape" || {
  bad "no-work-order command did not match"
  printf '    got:      %s\n    expected: %s\n' "$ACMD" "$AEXPECT"
}
printf '%s' "$ACMD" | grep -q "Process work order" \
  && bad "the acceptance-criteria clause leaked into a ticketless command" \
  || ok "no acceptance-criteria clause when there is no ticket"
printf '%s' "$ACMD" | grep -q "permission-mode" \
  && bad "bypassPermissions leaked into a ticketless command" \
  || ok "no bypassPermissions when there is no ticket"
# The empty slot is the feature, not an oversight: the person pasting decides
# what this session is called, because ad-hoc work has no name until then.
[ "$(printf '%s' "$ACMD" | tail -n1)" = '  -n "Session: "' ] \
  && ok "the session name is left empty to be typed at paste time" \
  || bad "the session name slot was filled in"
printf '%s' "$ACMD" | grep -q "Spike: can Lightsail" \
  && bad "the entry title leaked into the session name" \
  || ok "the entry title does not leak into the session name"

# a title containing " - " must not be cut in half
good_body dash "$WORK/dash.md"
bash "$HP" add --project "$Q" --id WO-DASH-1 --title "Infra: Route53 - DNS-01 - passthrough" --body-file "$WORK/dash.md" >/dev/null 2>&1
DT=$(bash "$HP" latest --project "$Q" --title-only)
[ "$DT" = "Infra: Route53 - DNS-01 - passthrough" ] \
  && ok "a title containing ' - ' survives parsing" || bad "title was mangled to '$DT'"
[ "$(bash "$HP" latest --project "$Q" --id-only)" = "WO-DASH-1" ] \
  && ok "and its id still parses" || bad "id lost on a dashed title"

# derived form must agree with the explicit form
D1=$(bash "$HP" command --project "$Q")
D2=$(bash "$HP" command --project "$Q" --id WO-DASH-1 --title "Infra: Route53 - DNS-01 - passthrough")
[ "$D1" = "$D2" ] && ok "derived command matches the explicit one" || bad "derived and explicit commands differ"

# ---------------------------------------------------------------- whole file
hd "check on the file itself"
bash "$HP" check --project "$P" >/dev/null 2>&1 \
  && ok "the maintained file passes its own check" || bad "the maintained file fails check"

hd "Result"
printf '  %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
