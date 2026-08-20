#!/usr/bin/env bash
# approve is a gate, not a rubber stamp.
source "${SKILL:-/skill}/testing/assert.sh"

# An unchecked open question must block promotion to ready.
d=$(new_project)
wo new --project "$d" --title "Has a question" --type feature --problem P --top-level \
   --out X --ac "it works" --question "which API version?" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
run 3 "unchecked open questions block approval" \
  wo approve --project "$d" --id "$id" --no-lavish --reason r

# A ticket with no acceptance criteria at all must also block.
d2=$(new_project)
wo new --project "$d2" --title "No criteria" --type chore --problem P --out X --top-level >/dev/null
id2=$(wo list --project "$d2" --json | jq -r '.[0].id')
run 3 "a ticket with no acceptance criteria cannot be approved" \
  wo approve --project "$d2" --id "$id2" --no-lavish --reason r
finish
