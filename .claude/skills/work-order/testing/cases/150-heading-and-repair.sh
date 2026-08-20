#!/usr/bin/env bash
# The ticket heading, the guard, and the repair for tickets written before it worked.
#
# `# %%ID%% - %%TITLE%%` is not a whole-line token, so the substitution pass never
# matched it and every ticket this skill ever wrote carried the raw placeholder as
# its H1. The frontmatter held the right values, so nothing downstream broke and
# nobody noticed for 27 tickets. That is why the guard is the more important half:
# the fix stops this token leaking, the guard stops the next one.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(new_project)
wo new --project "$d" --title "Empty cart state" --type feature --top-level \
   --problem "The cart shows nothing when empty" \
   --out "payment errors" --ac "npm test passes" >/dev/null
f=$(find "$d/work-orders" -name 'WO-*.md')
id=$(wo list --project "$d" --json | jq -r '.[0].id')

assert_not_contains "$f" '%%' "a rendered ticket carries no placeholder anywhere"
assert_contains "$f" "# $id - Empty cart state" "the H1 shows the real id and title"

head1=$(awk 'f && NF {print; exit} NR>1 && /^---$/ {f=1}' "$f")
assert_eq "# $id - Empty cart state" "$head1" "the H1 is the first line of the body"

# --- the guard ---------------------------------------------------------------
# A template token nobody wired up must stop the write rather than ship a ticket
# with a raw placeholder in it. That needs a doctored template, so the skill is
# copied out of its read-only mount first.
sk="$WORK/skill-copy"
mkdir -p "$sk"
cp -r "$SKILL/scripts" "$SKILL/references" "$sk/"
printf '\n%%%%UNWIRED%%%%\n' >>"$sk/references/ticket.tmpl"
d3=$(new_project)
run 3 "an unwired template token refuses the write" \
  bash "$sk/scripts/work-order.sh" new --project "$d3" --title "Guarded" --type chore \
    --problem P --out X --ac "it works"
run 0 "and no ticket file was written" bash -c \
  "[ -z \"\$(find '$d3/work-orders' -name 'WO-*.md' 2>/dev/null)\" ]"

# --- repair ------------------------------------------------------------------
# Put the legacy heading back deliberately: this is exactly what every ticket
# written before the fix looks like on disk. A scratch fixture is the only place a
# ticket is ever touched outside the script.
sed -i "s/^# ${id} - Empty cart state\$/# %%ID%% - %%TITLE%%/" "$f"
assert_contains "$f" '# %%ID%% - %%TITLE%%' "the legacy heading is reconstructed"

cp "$f" "$d/before.md"
run 0 "repair --dry-run exits 0" wo repair --project "$d" --dry-run
assert_same "$d/before.md" "$f" "--dry-run wrote nothing at all"
wo repair --project "$d" --dry-run >"$d/plan.txt" 2>/dev/null
assert_contains "$d/plan.txt" "would repair work-orders/" "--dry-run prints the plan on stdout"

run 0 "repair rewrites the heading" wo repair --project "$d"
assert_contains "$f" "# $id - Empty cart state" "the H1 is rebuilt from the frontmatter"
assert_not_contains "$f" '%%' "no placeholder survives the repair"
run 0 "frontmatter still parses after a repair" bash -c \
  "awk 'NR==1{next} /^---\$/{exit} {print}' '$f' | jq -e . >/dev/null"

# The repair must touch the H1 and nothing else. A ticket minted from the same
# inputs under the same fixed clock is the reference: byte-identical, or the
# repair changed something it had no business changing.
d2=$(new_project)
wo new --project "$d2" --title "Empty cart state" --type feature --top-level \
   --problem "The cart shows nothing when empty" \
   --out "payment errors" --ac "npm test passes" >/dev/null
f2=$(find "$d2/work-orders" -name 'WO-*.md')
assert_same "$f" "$f2" "a repaired ticket matches a freshly minted one byte for byte"

# Idempotent: a healed repository is a no-op, not a rewrite.
cp "$f" "$d/after.md"
run 0 "a second repair exits 0" wo repair --project "$d"
assert_same "$d/after.md" "$f" "repair is idempotent"
run 0 "repair --json reports nothing left to repair" bash -c \
  "bash '$SKILL/scripts/work-order.sh' repair --project '$d' --json | jq -e '.repaired == 0' >/dev/null"
finish
