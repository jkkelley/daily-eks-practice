#!/usr/bin/env bash
# The reason this command exists.
#
# close checks the status before it checks out main, and then works on main's
# copy of the ticket - a different file. If the commit carrying the `done`
# transition has not reached main, that copy still says `ready` or `in-review`,
# and close would stamp a merge SHA onto a ticket that never finished.
#
# It refuses, and the refusal is the point of this case. It used to surface as a
# raw `illegal_transition` reading "status is 'in-review'", which a caller who
# had just watched the ticket say `done` on their branch reads as the script
# being wrong - and they go looking in the wrong place. `done_not_merged` names
# the actual cause and says what to do about it.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(git_project)
# gh lies: it reports MERGED with a merge commit, so the only thing standing
# between this ticket and a wrongly stamped archive is main's own copy of it.
export PATH="$(gh_stub "$WORK/stub-220" MERGED d00dd00dd00d "$d"):$PATH"

wo new --project "$d" --title "Not on main" --type feature --problem P --top-level \
   --out X --ac "works" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
wo approve --project "$d" --id "$id" --no-lavish --reason t >/dev/null
# Everything up to `ready` lands on main. Nothing after it does.
git -C "$d" add -A && git -C "$d" commit -qm "add and approve"
git -C "$d" push -q origin main

wo start --project "$d" --id "$id" >/dev/null
branch=$(git -C "$d" rev-parse --abbrev-ref HEAD)
wo evidence --project "$d" --id "$id" --index 1 --observed "the command passed" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "work"
wo submit --project "$d" --id "$id" --pr 7 >/dev/null
wo done --project "$d" --id "$id" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "done"
git -C "$d" push -q origin "$branch"
# and deliberately never merged into main.

run 0 "the ticket really is done on the feature branch" bash -c \
  "bash '$SKILL/scripts/work-order.sh' show --project '$d' --id '$id' --json \
     | jq -e '.status == \"done\"' >/dev/null"

run 3 "close refuses when main's copy of the ticket is not done" \
  wo close --project "$d" --id "$id"
run 0 "and refuses by a name that says what is actually wrong" bash -c \
  "bash '$SKILL/scripts/work-order.sh' close --project '$d' --id '$id' --json \
     | jq -e '.error == \"done_not_merged\"' >/dev/null"

# A refusal that dumps the caller on main - or worse, on a half-built close-out
# branch - makes them reconstruct where they were before they can fix anything.
assert_eq "$branch" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" \
  "the caller is left on the branch they ran it from"
git -C "$d" rev-parse --verify "$branch" >/dev/null 2>&1 \
  && _pass "the feature branch still exists" \
  || _fail "the feature branch still exists" "branch was deleted"
git -C "$d" rev-parse --verify "close-out/$id" >/dev/null 2>&1 \
  && _fail "no close-out branch was cut" "close-out/$id exists" \
  || _pass "no close-out branch was cut"

f=$(find "$d/work-orders" -name "${id}-*.md")
assert_file "$f" "the ticket was not archived"
assert_contains "$f" '"merge_sha": null' "no merge SHA was stamped onto it"

# Merge it, and the same command goes through. The refusal was about the state of
# main, not about the ticket, so fixing main is all it should take.
git -C "$d" checkout -q main && git -C "$d" merge -q --no-ff -m "merge #7" "$branch"
git -C "$d" push -q origin main && git -C "$d" checkout -q "$branch"
run 0 "once the transition reaches main, close succeeds" wo close --project "$d" --id "$id"
assert_file "$d/work-orders/archive/2026/${id}-not-on-main.md" "and the ticket is archived"
finish
