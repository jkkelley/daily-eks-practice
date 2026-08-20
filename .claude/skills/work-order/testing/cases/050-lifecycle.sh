#!/usr/bin/env bash
# The status set is closed and every transition is validated. An illegal move is
# refused by name rather than silently allowed.
source "${SKILL:-/skill}/testing/assert.sh"

read -r d id <<<"$(drafted_project)"

run 3 "start refuses while still draft" wo start --project "$d" --id "$id"
run 3 "done refuses while still draft" wo done --project "$d" --id "$id"
run 4 "approve refuses when lavish-axi is absent" wo approve --project "$d" --id "$id"
run 2 "approve --no-lavish refuses without a --reason" \
  wo approve --project "$d" --id "$id" --no-lavish
run 0 "approve --no-lavish --reason records the exception" \
  wo approve --project "$d" --id "$id" --no-lavish --reason "no lavish in CI"

f=$(find "$d/work-orders" -name 'WO-*.md')
assert_contains "$f" '"via": "override"' "the override is recorded in the ticket, not silent"
assert_contains "$f" 'no lavish in CI' "the reason is recorded"
assert_contains "$f" '"status": "ready"' "reached ready"

run 6 "an unknown id is not found" wo show --project "$d" --id WO-20260805-ffff
run 2 "a malformed id is a usage error" wo show --project "$d" --id nonsense
run 0 "list --json emits parseable JSON" bash -c \
  "bash '$SKILL/scripts/work-order.sh' list --project '$d' --json | jq -e '.[0].status == \"ready\"' >/dev/null"
finish
