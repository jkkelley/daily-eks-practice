#!/usr/bin/env bash
# The frozen block is derived from build-plan.json, not hand-written.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(new_project); fig=$(figma_dir "$WORK/fig030")
wo new --project "$d" --title "Cart empty" --type feature --problem P --top-level \
   --out "manual non-goal" --from-figma "$fig" >/dev/null
f=$(find "$d/work-orders" -name 'WO-*.md')

assert_contains "$f" '"source": "wireframe"' "evidence source is wireframe"
assert_contains "$f" 'wo:frozen:start' "frozen block opens"
assert_contains "$f" 'wo:frozen:end' "frozen block closes"
assert_contains "$f" 'checksum=cksum:' "frozen block carries a checksum"
assert_contains "$f" 'wf/checkout-cart/empty/desktop' "derives a criterion per frame"
assert_contains "$f" 'every frame renders at both breakpoints' "seeds done_when from the brief"
assert_contains "$f" 'logged-out variant' "adopts the brief's non_goals as Out items"
assert_contains "$f" 'manual non-goal' "keeps the caller's own non-goal too"

# --frames narrows the ticket to one screen, so a 5-screen brief is not one
# enormous work-order.
d2=$(new_project)
wo new --project "$d2" --title "Cart only" --type feature --problem P --out X --top-level \
   --from-figma "$fig" --frames 'wf/checkout-cart/*' >/dev/null
f2=$(find "$d2/work-orders" -name 'WO-*.md')
assert_contains "$f2" 'wf/checkout-cart/empty/desktop' "selected frame is present"
assert_not_contains "$f2" 'wf/order-history' "unselected frame is excluded"

run 3 "refuses a --frames glob that matches nothing" \
  wo new --project "$(new_project)" --title T --type feature --problem P --out X --top-level \
     --from-figma "$fig" --frames 'wf/nothing/*'
finish
