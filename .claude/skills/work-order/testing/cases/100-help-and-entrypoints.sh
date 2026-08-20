#!/usr/bin/env bash
# Every entry point at least loads. --help catches a syntax error in a path the
# happy path never touches.
source "${SKILL:-/skill}/testing/assert.sh"

run 0 "--help exits 0" wo --help
run 2 "no arguments is a usage error" wo
run 2 "an unknown command is a usage error" wo nonsense

verbs=(new amend link note resolve evidence approve start submit done close cancel
       reopen verify resync show list next tree reindex reflow repair)
for c in "${verbs[@]}"; do
  run 0 "$c --help loads" wo "$c" --help
done

# The unknown-command string is the only listing an agent that guessed wrong ever
# sees, so a verb missing from it is a verb that agent never finds. Checking it
# against the same list the loop above walks is what keeps the two from drifting.
wo nonsense 2>"$WORK/unknown.txt" || true
missing=""
for c in "${verbs[@]}"; do
  grep -qF -- "|$c|" <<<"|$(sed -n 's/.*(\(.*\)).*/\1/p' "$WORK/unknown.txt")|" || missing+=" $c"
done
assert_eq "" "$missing" "the unknown-command message lists every verb the dispatcher accepts"

run 0 "the scripts are syntactically valid" bash -n "$SKILL/scripts/work-order.sh"
run 0 "lib/wo.sh is syntactically valid" bash -n "$SKILL/scripts/lib/wo.sh"
run 0 "lib/common.sh is syntactically valid" bash -n "$SKILL/scripts/lib/common.sh"
finish
