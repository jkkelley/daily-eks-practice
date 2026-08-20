#!/usr/bin/env bash
# The happy path, against a real bare origin: branch really is deleted, ticket
# really is archived, merge SHA really is recorded.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(git_project)
export PATH="$(gh_stub "$WORK/stub-merged" MERGED feedfacef00d "$d"):$PATH"

wo new --project "$d" --title "Close me" --type feature --problem P --out X --ac "works" --top-level >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
git -C "$d" add -A && git -C "$d" commit -qm "add"
wo approve --project "$d" --id "$id" --no-lavish --reason t >/dev/null
# approve rewrites the ticket; commit it or start will refuse a dirty tree.
git -C "$d" add -A && git -C "$d" commit -qm "approve"
wo start --project "$d" --id "$id" >/dev/null
branch=$(git -C "$d" rev-parse --abbrev-ref HEAD)
wo submit --project "$d" --id "$id" --pr 7 >/dev/null
f=$(find "$d/work-orders" -name 'WO-*.md'); sed -i 's/^- \[ \] /- [x] /' "$f"
git -C "$d" add -A && git -C "$d" commit -qm "work"
wo done --project "$d" --id "$id" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "done"
git -C "$d" push -q origin "$branch"
# gh says MERGED, so origin/main must actually contain the work. A fixture that
# claims a merge without performing one tests a world that cannot exist.
git -C "$d" checkout -q main && git -C "$d" merge -q --no-ff -m "merge #7" "$branch"
git -C "$d" push -q origin main && git -C "$d" checkout -q "$branch"

run 0 "close succeeds when gh reports MERGED" wo close --project "$d" --id "$id"

# close ends the caller on main rather than on a branch it deleted underneath
# them, and the close-out branch it cut is gone too.
assert_eq "main" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" "the caller is left on main"
git -C "$d" rev-parse --verify "close-out/$id" >/dev/null 2>&1 \
  && _fail "the close-out branch was cleaned up" "close-out/$id still exists" \
  || _pass "the close-out branch was cleaned up"

arch=$(find "$d/work-orders/archive" -name 'WO-*.md' 2>/dev/null | head -1)
assert_file "$arch" "the ticket is archived under archive/YYYY/"
assert_contains "$arch" 'feedfacef00d' "the real merge SHA is recorded"
assert_contains "$arch" '"status": "done"' "status is done"
assert_no_file "$d/work-orders/$id" "the ticket left the active tree, directory and all"

# The archive is only genuinely closed out if it reached main. Asserting on the
# working tree alone would pass for a close that never merged its own PR.
run 0 "the archive is on origin/main, not just in the working tree" bash -c \
  "git -C '$d' cat-file -e origin/main:'${arch#"$d"/}'"

# Every archive level explains itself, so a reader who lands in archive/ is not
# looking at a bare pile of years.
assert_file "$d/work-orders/archive/README.md" "archive/ carries a generated README"
assert_file "$d/work-orders/archive/2026/README.md" "archive/<year>/ carries one too"

git -C "$d" rev-parse --verify "$branch" >/dev/null 2>&1 \
  && _fail "the feature branch was deleted locally" "branch still exists" \
  || _pass "the feature branch was deleted locally"

assert_contains "$d/work-orders/INDEX.md" "archive/" "INDEX still finds the archived ticket"
run 3 "closing an already-archived ticket is refused" wo close --project "$d" --id "$id"
finish
