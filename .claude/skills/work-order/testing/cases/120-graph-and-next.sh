#!/usr/bin/env bash
# Dependencies and `next`. The point of the graph is that "may I start this?" is
# answered by the script, so the cases that matter are the ones where the honest
# answer is no.
source "${SKILL:-/skill}/testing/assert.sh"

mk() {
  local d="$1" t="$2"; shift 2
  wo new --project "$d" --title "$t" --type feature --problem "p" \
     --out "non-goal" --ac "checked by a command" "$@" 2>/dev/null | tail -1
}
ready() { wo approve --project "$1" --id "$2" --no-lavish --reason "test" >/dev/null 2>&1; }

d=$(new_project)
a=$(mk "$d" "Runner first" --top-level --priority p1)
b=$(mk "$d" "Depends on the runner" --top-level --priority p1 --depends-on "$a")

# Both directions of the edge are written, so a ticket read on its own is enough.
assert_contains "$d/work-orders/$b/${b}-depends-on-the-runner.md" "\"$a\"" "the dependent records depends_on"
assert_contains "$d/work-orders/$a/${a}-runner-first.md" "\"$b\"" "the dependency records the inverse blocks edge"

capture out wo next --project "$d" --json
assert_eq "[]" "$out" "a draft is never startable, however free of dependencies"

ready "$d" "$a"; ready "$d" "$b"
capture out wo next --project "$d" --json
assert_eq "1" "$(printf '%s' "$out" | jq 'length')" "only the unblocked ticket is startable"
assert_eq "$a" "$(printf '%s' "$out" | jq -r '.[0].id')" "and it is the one nothing waits on"

assert_contains "$d/work-orders/INDEX.md" "| 2 | 1 | 1 | 0 | 0 |" "the index counts startable and blocked apart"
assert_contains "$d/work-orders/INDEX.md" "Runner first" "the startable ticket is named under Start now"

# Cycles. A dependency loop makes `next` permanently empty with no explanation,
# so the edge that would close one is refused rather than recorded.
run 3 "a dependency cycle is refused" wo link --project "$d" --id "$a" --depends-on "$b"
run 3 "self-dependency is refused" wo link --project "$d" --id "$a" --depends-on "$a"
run 6 "an edge to a missing ticket is refused" \
  wo link --project "$d" --id "$a" --depends-on WO-20260101-ffff
run 2 "link with nothing to link is a usage error" wo link --project "$d" --id "$a"

# Idempotence: re-running a link script must not double an edge.
wo link --project "$d" --id "$b" --depends-on "$a" >/dev/null 2>&1
assert_eq "1" "$(wo show --project "$d" --id "$b" --json | jq '.depends_on | length')" \
  "linking the same edge twice records it once"

finish
