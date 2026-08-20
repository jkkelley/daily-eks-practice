#!/usr/bin/env bash
# resolve, and the gate it exists to serve.
#
# `new --question` writes an unchecked box and approve refuses while one is still
# unchecked. That gate is correct, so the assertion that earns its keep here is
# not that resolve works - it is that approve is *still* refused while any
# question is outstanding. What was broken was the absence of a verb that could
# record an answer: a ticket minted with a question could only be freed by hand
# editing the file, which is the one thing this skill exists to prevent.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(new_project)
wo new --project "$d" --title "Two questions" --type feature --problem P --top-level \
   --out X --ac "it works" \
   --question "which API version?" --question "who owns the DNS record?" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
f=$(find "$d/work-orders" -name 'WO-*.md')

# --- the refusals, all of which must happen before anything is written --------
run 6 "an unknown ticket id is not found" \
  wo resolve --project "$d" --id WO-20260805-ffff --index 1 --answer "v2"
run 2 "an answer is mandatory - a question closed without one is just deleted" \
  wo resolve --project "$d" --id "$id" --index 1
run 2 "a selector is mandatory" wo resolve --project "$d" --id "$id" --answer "v2"
run 2 "--index and --match together is a usage error" \
  wo resolve --project "$d" --id "$id" --index 1 --match api --answer "v2"
run 2 "a non-numeric index is a usage error" \
  wo resolve --project "$d" --id "$id" --index two --answer "v2"
run 3 "an out-of-range index is refused" \
  wo resolve --project "$d" --id "$id" --index 3 --answer "v2"
run 3 "a match that hits nothing is refused" \
  wo resolve --project "$d" --id "$id" --match "billing" --answer "v2"
run 3 "an ambiguous match is refused rather than guessed" \
  wo resolve --project "$d" --id "$id" --match "wh" --answer "v2"
assert_contains "$f" '- [ ] which API version?' "no refusal touched the ticket"

# --- the happy path ----------------------------------------------------------
run 0 "resolve records an answer" \
  wo resolve --project "$d" --id "$id" --index 1 --answer "v2 only, v1 is retired"
assert_contains "$f" '- [x] which API version?' "the box is checked"
assert_contains "$f" 'v2 only, v1 is retired' "the answer is recorded"
assert_contains "$f" '- answer `2026-08-05`' "the answer carries the date it was given"
assert_contains "$f" '- [ ] who owns the DNS record?' "the other question is untouched"

# resolve changes the record, never the state. It carries no status check at all,
# so nothing about where a ticket sits can block writing down an answer.
run 0 "resolve leaves the status alone" bash -c \
  "bash '$SKILL/scripts/work-order.sh' show --project '$d' --id '$id' --json | jq -e '.status == \"draft\"' >/dev/null"
run 0 "frontmatter still parses after a resolve" bash -c \
  "awk 'NR==1{next} /^---\$/{exit} {print}' '$f' | jq -e . >/dev/null"

run 3 "an already-resolved question is refused, by name" \
  wo resolve --project "$d" --id "$id" --index 1 --answer "again"

# THE assertion. One answered, one outstanding: the gate must still hold.
run 3 "approve still refuses while any question is unresolved" \
  wo approve --project "$d" --id "$id" --no-lavish --reason r

run 0 "the second question resolves by substring" \
  wo resolve --project "$d" --id "$id" --match "DNS" --answer "platform team owns it"
run 0 "only now does the ticket reach ready" \
  wo approve --project "$d" --id "$id" --no-lavish --reason "no lavish in CI"
assert_contains "$f" '"status": "ready"' "ready was reached through script verbs alone"
assert_contains "$f" 'platform team owns it' "both answers survive into the approved ticket"

run 0 "resolve --json emits parseable JSON" bash -c \
  "bash '$SKILL/scripts/work-order.sh' resolve --project '$d' --id '$id' --index 1 \
     --answer x --json | jq -e '.error == \"already_resolved\"' >/dev/null"

# A ticket with no questions has nowhere to put an answer, and says so.
read -r d2 id2 <<<"$(drafted_project)"
run 3 "a ticket with no questions refuses" \
  wo resolve --project "$d2" --id "$id2" --index 1 --answer "n/a"
finish
