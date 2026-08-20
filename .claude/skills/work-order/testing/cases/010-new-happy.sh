#!/usr/bin/env bash
# new: the documented happy path, and the determinism the skill claims.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(new_project)
run 0 "new exits 0 on the documented example" \
  wo new --project "$d" --title "Empty cart state" --type feature --top-level \
     --problem "The cart shows nothing when empty" \
     --in "cart empty state" --out "payment errors" \
     --ac "npm test passes" --priority p2

id=$(find "$d/work-orders" -name 'WO-*.md' -exec basename {} \; | sed 's/-empty.*//')
assert_file "$d/work-orders/INDEX.md" "INDEX.md is generated"
assert_contains "$d/work-orders/INDEX.md" "$id" "INDEX lists the new ticket"

f=$(find "$d/work-orders" -name 'WO-*.md')
assert_contains "$f" '"status": "draft"' "starts in draft"
assert_contains "$f" 'Out - non-goals' "renders the non-goals section"
assert_contains "$f" 'payment errors' "records the non-goal"
assert_contains "$f" 'AC-H1' "records the human criterion"

# The frontmatter must be machine-readable, which is the entire reason it is JSON.
run 0 "frontmatter parses as JSON" bash -c \
  "awk 'NR==1{next} /^---\$/{exit} {print}' '$f' | jq -e . >/dev/null"

# Determinism: same inputs + fixed clock => byte-identical ticket.
d2=$(new_project)
wo new --project "$d2" --title "Empty cart state" --type feature --top-level \
   --problem "The cart shows nothing when empty" \
   --in "cart empty state" --out "payment errors" \
   --ac "npm test passes" --priority p2 >/dev/null
f2=$(find "$d2/work-orders" -name 'WO-*.md')
assert_same "$f" "$f2" "same input and clock produce an identical ticket"

finish
