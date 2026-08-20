#!/usr/bin/env bash
# The reason this command exists.
#
# A dependency edge is written on both tickets, so removing it from one leaves a
# half-edge: `next` still refuses to start the dependent from one side, and the
# other side shows nothing to explain why. The only previous way out was hand
# editing the frontmatter of both files.
#
# Worse, `link --detach --depends-on B` read like a removal and was not: detach
# dropped the parent, and --depends-on went on to ADD the very edge the caller
# was trying to drop. Removal has its own flags now, and the ambiguous pairing is
# refused rather than guessed at.
source "${SKILL:-/skill}/testing/assert.sh"

mk() {
  local d="$1" t="$2"; shift 2
  wo new --project "$d" --title "$t" --type feature --problem "p" \
     --out "non-goal" --ac "checked by a command" "$@" 2>/dev/null | tail -1
}

d=$(new_project)
a=$(mk "$d" "Runner first" --top-level --priority p1)
b=$(mk "$d" "Depends on the runner" --top-level --priority p1 --depends-on "$a")
fa="$d/work-orders/$a/${a}-runner-first.md"
fb="$d/work-orders/$b/${b}-depends-on-the-runner.md"

assert_contains "$fb" "\"$a\"" "the edge starts out recorded on the dependent"
assert_contains "$fa" "\"$b\"" "and on the dependency"

# --- the ambiguity that used to add the edge you meant to drop ---------------
run 2 "--detach with --depends-on is refused rather than guessed at" \
  wo link --project "$d" --id "$b" --detach --depends-on "$a"
run 2 "--detach with --blocks is refused too" \
  wo link --project "$d" --id "$a" --detach --blocks "$b"
assert_contains "$fb" "\"$a\"" "the refused run added nothing"

# Adding and removing the same edge in one run is a coin toss with a permanent
# result, so it is refused rather than resolved by whichever loop ran first.
run 2 "adding and removing the same edge in one run is refused" \
  wo link --project "$d" --id "$b" --depends-on "$a" --no-depends-on "$a"

run 2 "--no-depends-on validates the id format" \
  wo link --project "$d" --id "$b" --no-depends-on nonsense

# --- the removal, from both sides --------------------------------------------
run 0 "--no-depends-on removes the edge" wo link --project "$d" --id "$b" --no-depends-on "$a"
assert_eq "0" "$(wo show --project "$d" --id "$b" --json | jq '.depends_on | length')" \
  "the dependent no longer waits on it"
assert_eq "0" "$(wo show --project "$d" --id "$a" --json | jq '.blocks | length')" \
  "and the inverse edge is gone from the other ticket too"

# A half-removed edge is worse than never having removed one: `next` would still
# refuse the dependent with nothing left anywhere to explain why.
wo approve --project "$d" --id "$a" --no-lavish --reason t >/dev/null
wo approve --project "$d" --id "$b" --no-lavish --reason t >/dev/null
capture out wo next --project "$d" --json
assert_eq "2" "$(printf '%s' "$out" | jq 'length')" \
  "both tickets are startable now that nothing waits on anything"

# --- removing again, and removing what was never there -----------------------
run 0 "removing an edge that is already gone is a no-op, not an error" \
  wo link --project "$d" --id "$b" --no-depends-on "$a"

# A dangling edge to a ticket that has gone is precisely what somebody runs this
# flag to clear, so a missing target is not refused the way an addition is.
run 0 "--no-depends-on accepts a target that no longer exists" \
  wo link --project "$d" --id "$b" --no-depends-on WO-20260805-ffff

# --- the other direction ------------------------------------------------------
run 0 "--blocks records the edge again" wo link --project "$d" --id "$a" --blocks "$b"
assert_eq "1" "$(wo show --project "$d" --id "$b" --json | jq '.depends_on | length')" \
  "the inverse edge is back on the dependent"
run 0 "--no-blocks removes it" wo link --project "$d" --id "$a" --no-blocks "$b"
assert_eq "0" "$(wo show --project "$d" --id "$b" --json | jq '.depends_on | length')" \
  "--no-blocks cleared the inverse edge as well"
assert_eq "0" "$(wo show --project "$d" --id "$a" --json | jq '.blocks | length')" \
  "and its own side"
finish
