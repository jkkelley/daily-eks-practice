#!/usr/bin/env bash
# Gap 2: figma-wireframe writes fixed filenames into the working directory, so
# wireframing a second feature would otherwise destroy the first ticket's
# evidence. The snapshot is what makes a ticket self-contained.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(new_project); fig=$(figma_dir "$WORK/fig040")
wo new --project "$d" --title "Cart empty" --type feature --problem P --out X --top-level \
   --from-figma "$fig" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')

assert_file "$d/work-orders/evidence/$id/build-plan.json" "build-plan.json is snapshotted"
assert_file "$d/work-orders/evidence/$id/wireframe-brief.json" "brief is snapshotted"
run 0 "verify is clean immediately after new" wo verify --project "$d"

# Now overwrite the source with a DIFFERENT feature, exactly as a second
# figma-wireframe run in the same repo would.
figma_dir "$fig" "wf" "other-product" >/dev/null
run 3 "verify flags the source as replaced, not merely stale" wo verify --project "$d"
capture out wo verify --project "$d"
case $out in *REPLACED*) _pass "reports REPLACED, distinguishing it from a rebuild" ;;
  *) _fail "reports REPLACED" "got: $out" ;; esac

# The ticket itself is untouched: its evidence still describes the real feature.
assert_contains "$d/work-orders/evidence/$id/build-plan.json" "shop" \
  "snapshot still holds the original brief after the source was clobbered"
finish
