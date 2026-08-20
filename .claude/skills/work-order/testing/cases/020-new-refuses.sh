#!/usr/bin/env bash
# A validator that never rejects anything is not a validator.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(new_project)
base=(--project "$d" --title T --type feature --problem P --top-level)

run 3 "refuses with no --out (an empty non-goals list lets an agent wander)" \
  wo new "${base[@]}"
# Every ticket has a home. Without this, unrelated tickets pile up at the root of
# work-orders/ with nothing tying them together, which is the shape this refuses.
run 3 "refuses a ticket with neither --parent nor --top-level" \
  wo new --project "$d" --title T --type feature --problem P --out X
run 3 "refuses an unknown --type" \
  wo new --project "$d" --title T --type nonsense --problem P --out X --top-level
run 3 "refuses an unknown --priority" \
  wo new --project "$d" --title T --type feature --problem P --out X --top-level --priority p9
run 2 "refuses a missing --title" \
  wo new --project "$d" --type feature --problem P --out X --top-level
run 2 "refuses an unknown flag" \
  wo new --project "$d" --bogus
run 4 "refuses a --from-figma dir with no build-plan.json" \
  wo new --project "$d" --title T --type feature --problem P --out X --top-level --from-figma /work/nope

# Nothing may be left behind by a refused run.
assert_no_file "$d/work-orders" "a rejected new creates no work-orders/ directory"
finish
