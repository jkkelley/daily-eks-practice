#!/usr/bin/env bash
# The reason this command exists.
#
# This is the dead end that prompted the fix. The first version of close cut the
# close-out branch with `git checkout -b` and opened its PR with no idea whether
# one was already open. An attempt that died anywhere after the branch was cut -
# gh down, a network blip, a rejected push - left that branch behind, and every
# later run refused to create a branch that already existed. The ticket became
# permanently unclosable by the tool, and the only way out was to finish the
# close-out by hand, which is the exact failure this skill exists to remove.
#
# So every step from phase 2 on is written to be repeatable: `checkout -B` reuses
# and resets the branch, `push --force-with-lease` overwrites what the last
# attempt pushed, and `gh pr list --head` turns an already-open PR into a reuse
# rather than a hard stop. A second run has to reach the same end state as a
# clean first one.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(git_project)
# Two stubs, same fixture: the first cannot open a PR, the second can.
broken=$(gh_stub "$WORK/stub-210-broken" MERGED beefbeef1111 "$d" fail)
working=$(gh_stub "$WORK/stub-210-ok" MERGED beefbeef1111 "$d")

wo new --project "$d" --title "Retry me" --type feature --problem P --top-level \
   --out X --ac "works" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
git -C "$d" add -A && git -C "$d" commit -qm "add"
PATH="$working:$PATH" wo approve --project "$d" --id "$id" --no-lavish --reason t >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "approve"
PATH="$working:$PATH" wo start --project "$d" --id "$id" >/dev/null
branch=$(git -C "$d" rev-parse --abbrev-ref HEAD)
PATH="$working:$PATH" wo evidence --project "$d" --id "$id" --index 1 --observed "the command passed" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "work"
PATH="$working:$PATH" wo submit --project "$d" --id "$id" --pr 7 >/dev/null
PATH="$working:$PATH" wo done --project "$d" --id "$id" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "done"
git -C "$d" push -q origin "$branch"
# gh says MERGED, so origin/main must actually contain the work.
git -C "$d" checkout -q main && git -C "$d" merge -q --no-ff -m "merge #7" "$branch"
git -C "$d" push -q origin main && git -C "$d" checkout -q "$branch"

# --- attempt one: gh cannot open the close-out PR ----------------------------
run 4 "close fails when gh cannot open the close-out PR" \
  env PATH="$broken:$PATH" bash "$SKILL/scripts/work-order.sh" close --project "$d" --id "$id"

# The branch the caller started on was deleted by phase 1 on purpose, so main is
# the honest place to leave them. Being stranded on a half-built close-out branch
# is how the manual clean-up starts.
assert_eq "main" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" \
  "the failed run left the caller on main, not on the branch it was building"
git -C "$d" rev-parse --verify "close-out/$id" >/dev/null 2>&1 \
  && _pass "the failed attempt left its close-out branch behind - the dead end" \
  || _fail "the failed attempt left its close-out branch behind" "no close-out branch"
run 0 "and pushed it, so nothing on it is lost" \
  git -C "$d" rev-parse --verify "origin/close-out/$id"
assert_no_file "$d/work-orders/archive/2026/${id}-retry-me.md" \
  "main does not yet carry the archive"

# --- attempt two: from exactly that state, with gh working -------------------
run 0 "a second close from the abandoned state completes" \
  env PATH="$working:$PATH" bash "$SKILL/scripts/work-order.sh" close --project "$d" --id "$id"

assert_eq "main" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" "the retry ends on main"
arch="$d/work-orders/archive/2026/${id}-retry-me.md"
assert_file "$arch" "the ticket is archived"
assert_contains "$arch" 'beefbeef1111' "the merge SHA is recorded"
assert_no_file "$d/work-orders/$id" "it left the active tree"
run 0 "the archive reached main, not just the working tree" bash -c \
  "git -C '$d' cat-file -e origin/main:'${arch#"$d"/}'"
git -C "$d" rev-parse --verify "close-out/$id" >/dev/null 2>&1 \
  && _fail "the close-out branch is cleaned up" "close-out/$id still exists" \
  || _pass "the close-out branch is cleaned up"

# The end state is the same one a clean first run reaches, which is the whole
# claim the retry path makes.
run 3 "and the ticket is closed for good" \
  env PATH="$working:$PATH" bash "$SKILL/scripts/work-order.sh" close --project "$d" --id "$id"
finish
