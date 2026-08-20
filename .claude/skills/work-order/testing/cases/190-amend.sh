#!/usr/bin/env bash
# The reason this command exists.
#
# A draft is where a ticket is still being argued about, and the argument changes
# the acceptance criteria more often than anything else. Without a verb for it the
# only ways to correct a draft were to hand-edit the file - the one thing this
# skill exists to prevent - or to bin the ticket and mint a new one, which breaks
# every ID already handed to somebody.
#
# It is draft-only on purpose. Once a ticket is approved, its criteria are what
# somebody agreed to build; silently rewriting them afterwards means the work is
# measured against a bar that moved after the review.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(new_project); fig=$(figma_dir "$WORK/fig190")

wo new --project "$d" --title "Amend me" --type feature --problem "the old problem" \
   --top-level --in "the old in" --out "the old non-goal" \
   --ac "the old criterion" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
f=$(find "$d/work-orders" -name 'WO-*.md')

# --- the refusals ------------------------------------------------------------
run 6 "an unknown ticket id is not found" \
  wo amend --project "$d" --id WO-20260805-ffff --ac "x"
run 2 "amend with nothing to amend is a usage error" wo amend --project "$d" --id "$id"
# The Out list may be replaced but never emptied, for the same reason `new`
# requires one: a ticket with no non-goals is a ticket an agent may wander out of,
# and an amend is exactly the moment somebody is tempted to drop them.
run 3 "amend refuses to empty --out" wo amend --project "$d" --id "$id" --out ""
assert_contains "$f" 'the old non-goal' "the refused amend left the non-goals alone"

# --- replacing an acceptance criterion ---------------------------------------
run 0 "amend replaces the acceptance criteria on a draft" \
  wo amend --project "$d" --id "$id" --ac "the new criterion" --ac "a second new one"
assert_contains "$f" '- [ ] `AC-H1` *(human)* the new criterion' "the new criterion is written"
assert_contains "$f" '- [ ] `AC-H2` *(human)* a second new one' "and it renumbers from one"
assert_not_contains "$f" 'the old criterion' "the criterion it replaced is gone, not appended to"
run 0 "frontmatter still parses after an amend" bash -c \
  "awk 'NR==1{next} /^---\$/{exit} {print}' '$f' | jq -e . >/dev/null"

# Replacement is wholesale per section, so the sections not named are untouched.
assert_contains "$f" 'the old problem' "an unnamed section is left alone"
assert_contains "$f" 'the old non-goal' "and so are the non-goals"

run 0 "amend replaces the non-goals" wo amend --project "$d" --id "$id" --out "a new non-goal"
assert_contains "$f" 'a new non-goal' "the new non-goal is written"
assert_not_contains "$f" 'the old non-goal' "the one it replaced is gone"
assert_contains "$f" '- [ ] `AC-H1` *(human)* the new criterion' \
  "amending Out did not disturb the criteria"

run 0 "amend leaves the ticket in draft" bash -c \
  "bash '$SKILL/scripts/work-order.sh' show --project '$d' --id '$id' --json \
     | jq -e '.status == \"draft\"' >/dev/null"

# --- the frozen block is not the caller's to replace -------------------------
# It is derived from build-plan.json and checksummed against it, so --ac replaces
# the human criteria beneath it and carries the derived ones through untouched.
d2=$(new_project)
wo new --project "$d2" --title "Wireframed" --type feature --problem P --top-level \
   --out X --ac "a human criterion" --from-figma "$fig" >/dev/null
id2=$(wo list --project "$d2" --json | jq -r '.[0].id')
f2=$(find "$d2/work-orders" -name 'WO-*.md')
run 0 "amend succeeds on a wireframe-bound draft" \
  wo amend --project "$d2" --id "$id2" --ac "a replacement human criterion"
assert_contains "$f2" 'wo:frozen:start' "the frozen block survives"
assert_contains "$f2" 'wf/checkout-cart/empty/desktop' "the derived criteria survive"
assert_contains "$f2" 'a replacement human criterion' "the human criterion was replaced"
assert_not_contains "$f2" 'a human criterion*' "the one it replaced is gone"
run 0 "verify is still clean, so the checksum was not disturbed" wo verify --project "$d2"

# --- past draft, the bar stops moving ----------------------------------------
wo approve --project "$d" --id "$id" --no-lavish --reason "no lavish in CI" >/dev/null
run 3 "amend refuses a ready ticket" \
  wo amend --project "$d" --id "$id" --ac "moving the goalposts"
assert_contains "$f" '- [ ] `AC-H1` *(human)* the new criterion' \
  "the approved criteria are exactly what was approved"
finish
