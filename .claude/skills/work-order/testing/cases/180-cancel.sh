#!/usr/bin/env bash
# The reason this command exists.
#
# Before `cancel`, the only way out of the active tree was `close`, which demands
# a branch, a merged PR and an observation against every acceptance criterion.
# Nobody produces that for work that was abandoned, so an abandoned ticket either
# sat in the index forever - dragging `next` and every count with it - or was
# deleted by hand, which takes the reason with it. cancel is the terminal state
# for work that is not going to happen, and it records why.
#
# It deliberately does no git and no gh work: there is nothing to merge and
# nothing to prove about main, so a verb that opened a PR to record "we are not
# doing this" would be ceremony charged for nothing. It leaves the move staged
# for the caller to commit inside the change that explains it.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(git_project)
# cancel itself never calls gh, but the walk to `done` at the bottom of this case
# goes through submit, which does.
export PATH="$(gh_stub "$WORK/stub-180" MERGED aaaabbbbcccc "$d"):$PATH"

mk() { # mk <title> [extra...] -> id
  local t="$1"; shift
  wo new --project "$d" --title "$t" --type feature --problem "p" --top-level \
     --out "non-goal" --ac "checked by a command" "$@" 2>/dev/null | tail -1
}

doomed=$(mk "Doomed approach")
heir=$(mk "The approach that replaced it")
git -C "$d" add -A && git -C "$d" commit -qm "add"

# --- the refusals ------------------------------------------------------------
run 6 "an unknown ticket id is not found" \
  wo cancel --project "$d" --id WO-20260805-ffff --reason "gone"
# A cancellation with no reason is a deletion with extra steps: the ticket leaves
# the tree and takes the only record of why with it.
run 2 "cancel refuses without a --reason" wo cancel --project "$d" --id "$doomed"
run 2 "cancel refuses an empty --reason" wo cancel --project "$d" --id "$doomed" --reason ""
run 6 "--superseded-by is validated like any other edge target" \
  wo cancel --project "$d" --id "$doomed" --reason r --superseded-by WO-20260805-ffff
run 3 "a ticket cannot supersede itself" \
  wo cancel --project "$d" --id "$doomed" --reason r --superseded-by "$doomed"

f="$d/work-orders/$doomed/${doomed}-doomed-approach.md"
assert_file "$f" "no refusal moved the ticket"

# --- the happy path, from ready ----------------------------------------------
wo approve --project "$d" --id "$doomed" --no-lavish --reason "no lavish in CI" >/dev/null
head_before=$(git -C "$d" rev-parse HEAD)
branch_before=$(git -C "$d" rev-parse --abbrev-ref HEAD)

run 0 "cancel succeeds from ready" \
  wo cancel --project "$d" --id "$doomed" --reason "the vendor withdrew the API" \
     --superseded-by "$heir"

arch="$d/work-orders/archive/2026/${doomed}-doomed-approach.md"
assert_file "$arch" "the ticket is archived beside anything close filed"
assert_no_file "$d/work-orders/$doomed" "it left the active tree, directory and all"
assert_contains "$arch" '"status": "cancelled"' "status is cancelled"
assert_contains "$arch" "\"superseded_by\": \"$heir\"" \
  "what replaced it is a field, so the graph can answer it without reading English"
assert_contains "$arch" '## Outcome' "the Outcome section is written"
assert_contains "$arch" 'the vendor withdrew the API' "the reason survives into the archive"
assert_contains "$arch" 'nothing shipped' "the Outcome says plainly that nothing shipped"
run 0 "frontmatter still parses after a cancel" bash -c \
  "awk 'NR==1{next} /^---\$/{exit} {print}' '$arch' | jq -e . >/dev/null"

# --- and no git history was touched ------------------------------------------
# cancel has nothing to prove about main, so it commits nothing, pushes nothing
# and never moves the caller off their branch. The move is left staged.
assert_eq "$head_before" "$(git -C "$d" rev-parse HEAD)" "cancel made no commit"
assert_eq "$branch_before" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" \
  "cancel did not move the caller off their branch"
git -C "$d" rev-parse --verify "close-out/$doomed" >/dev/null 2>&1 \
  && _fail "cancel cut no close-out branch" "close-out/$doomed exists" \
  || _pass "cancel cut no close-out branch"

# --- the cancelled ticket is out of the way ----------------------------------
capture out wo next --project "$d" --json
assert_eq "0" "$(printf '%s' "$out" | jq "[.[] | select(.id == \"$doomed\")] | length")" \
  "a cancelled ticket disappears from next"
run 3 "cancelling it twice is refused" \
  wo cancel --project "$d" --id "$doomed" --reason "again"

# --- done is not cancellable --------------------------------------------------
# Work that finished is closed out, not cancelled. Letting `done` become
# `cancelled` would rewrite shipped work as abandoned in the one record of it.
wo approve --project "$d" --id "$heir" --no-lavish --reason r >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "approve"
wo start --project "$d" --id "$heir" >/dev/null
wo evidence --project "$d" --id "$heir" --index 1 --observed "the command passed" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "work"
wo submit --project "$d" --id "$heir" --pr 9 >/dev/null
wo done --project "$d" --id "$heir" >/dev/null
# Asserted rather than assumed: if the walk above quietly stopped short, the
# refusal below would pass for the wrong reason on a ticket that is not done.
run 0 "the second ticket really did reach done" bash -c \
  "bash '$SKILL/scripts/work-order.sh' show --project '$d' --id '$heir' --json \
     | jq -e '.status == \"done\"' >/dev/null"
run 3 "cancel refuses a ticket that is done" \
  wo cancel --project "$d" --id "$heir" --reason "changed my mind"
run 0 "and the done ticket is untouched" bash -c \
  "bash '$SKILL/scripts/work-order.sh' show --project '$d' --id '$heir' --json \
     | jq -e '.status == \"done\"' >/dev/null"
finish
