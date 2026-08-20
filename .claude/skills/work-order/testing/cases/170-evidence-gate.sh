#!/usr/bin/env bash
# The reason this command exists.
#
# `done` refuses while any acceptance criterion is unchecked, and `evidence` is
# the only verb that ticks one. Those two facts only add up to a gate if evidence
# cannot be used before there is any work to observe - and it could. Every
# criterion on a draft could be ticked the minute the ticket was minted, and
# `done` would then sail through having observed nothing at all. The gate was
# load-bearing and open at the same time.
#
# So evidence now requires in-progress or in-review. This case is the lock on
# that: it walks a ticket through every status and asserts which ones may record
# an observation, so the hole cannot be reopened by a later refactor without a
# red test.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(git_project)
export PATH="$(gh_stub "$WORK/stub-170" MERGED cafebabe1234 "$d"):$PATH"

wo new --project "$d" --title "Gate me" --type feature --problem P --top-level \
   --out X --ac "the cart renders empty" --ac "the DNS record resolves" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
f=$(find "$d/work-orders" -name 'WO-*.md')
git -C "$d" add -A && git -C "$d" commit -qm "add"

# --- draft: the hole ---------------------------------------------------------
run 3 "evidence refuses on a draft - there is no work yet to have observed" \
  wo evidence --project "$d" --id "$id" --index 1 --observed "looks fine to me"
assert_contains "$f" '- [ ] `AC-H1` *(human)* the cart renders empty' \
  "the refused draft still carries an unchecked criterion"
run 0 "the refusal names the statuses that may record one" bash -c \
  "bash '$SKILL/scripts/work-order.sh' evidence --project '$d' --id '$id' --index 1 \
     --observed x --json | jq -e '.error == \"illegal_transition\"' >/dev/null"

# --- ready: still too early --------------------------------------------------
wo approve --project "$d" --id "$id" --no-lavish --reason "no lavish in CI" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "approve"
run 3 "evidence refuses on a ready ticket - approved is not started" \
  wo evidence --project "$d" --id "$id" --index 1 --observed "looks fine to me"

# --- in-progress: the point of the verb --------------------------------------
wo start --project "$d" --id "$id" >/dev/null
run 0 "evidence succeeds on in-progress" \
  wo evidence --project "$d" --id "$id" --index 1 --observed "rendered at both breakpoints"
assert_contains "$f" '- [x] `AC-H1` *(human)* the cart renders empty' "the box is checked"

# --- in-review: a reviewer's observation counts too ---------------------------
git -C "$d" add -A && git -C "$d" commit -qm "evidence"
wo submit --project "$d" --id "$id" --pr 7 >/dev/null
run 0 "evidence succeeds on in-review" \
  wo evidence --project "$d" --id "$id" --index 2 --observed "dig returned the A record"

# --- done: the record is closed ----------------------------------------------
wo done --project "$d" --id "$id" >/dev/null
run 3 "evidence refuses once the ticket is done" \
  wo evidence --project "$d" --id "$id" --index 1 --observed "one more thought"

# --- and the whole point of all of the above ---------------------------------
# A second ticket, driven exactly the way the hole used to allow: tick everything
# on the draft, then walk straight to done. Every tick must be refused, and the
# ticket must still be unable to reach done.
d2=$(git_project)
wo new --project "$d2" --title "No shortcut" --type feature --problem P --top-level \
   --out X --ac "one" --ac "two" >/dev/null
id2=$(wo list --project "$d2" --json | jq -r '.[0].id')
git -C "$d2" add -A && git -C "$d2" commit -qm "add"
run 3 "ticking criterion 1 on the draft is refused" \
  wo evidence --project "$d2" --id "$id2" --index 1 --observed "sure"
run 3 "ticking criterion 2 on the draft is refused" \
  wo evidence --project "$d2" --id "$id2" --index 2 --observed "sure"
wo approve --project "$d2" --id "$id2" --no-lavish --reason r >/dev/null
git -C "$d2" add -A && git -C "$d2" commit -qm "approve"
wo start --project "$d2" --id "$id2" >/dev/null
wo submit --project "$d2" --id "$id2" --pr 7 >/dev/null
run 3 "done still refuses, because nothing was ever actually observed" \
  wo done --project "$d2" --id "$id2"
finish
