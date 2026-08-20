#!/usr/bin/env bash
# The reason this command exists.
#
# `close` runs git branch -D, git push --delete and gh pr merge. If it believes
# the caller's claim that a PR merged, it deletes unmerged work. So it asks gh
# instead, and refuses anything that is not MERGED.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(git_project); fig=$(figma_dir "$WORK/fig070")
export PATH="$(gh_stub "$WORK/stub-open" OPEN ""):$PATH"

wo new --project "$d" --title "Cart empty" --type feature --problem P --out X --top-level \
   --ac "it works" --from-figma "$fig" >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
git -C "$d" add -A && git -C "$d" commit -qm "add $id"

wo approve --project "$d" --id "$id" --no-lavish --reason "test" >/dev/null
# approve rewrites the ticket; commit it or start will refuse a dirty tree.
git -C "$d" add -A && git -C "$d" commit -qm "approve"
wo start --project "$d" --id "$id" >/dev/null
branch=$(git -C "$d" rev-parse --abbrev-ref HEAD)
assert_eq "feat/cart-empty" "$branch" "start created the branch from the slug"

wo submit --project "$d" --id "$id" --pr 7 >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "work"
# Tick the criteria, as `done` requires.
f=$(find "$d/work-orders" -name 'WO-*.md')
sed -i 's/^- \[ \] /- [x] /' "$f"
git -C "$d" add -A && git -C "$d" commit -qm "tick"
wo done --project "$d" --id "$id" >/dev/null
git -C "$d" add -A && git -C "$d" commit -qm "done"

# gh says OPEN. Nothing may be destroyed.
run 3 "close refuses when gh reports the PR is not MERGED" \
  wo close --project "$d" --id "$id"

git -C "$d" rev-parse --verify "$branch" >/dev/null 2>&1 \
  && _pass "the feature branch still exists after the refusal" \
  || _fail "the feature branch still exists after the refusal" "branch was deleted"
assert_file "$f" "the ticket was not archived"
assert_contains "$f" '"merge_sha": null' "no merge SHA was invented"

# MERGED but with no merge commit is also refused - a half-answer is not a yes.
export PATH="$(gh_stub "$WORK/stub-nosha" MERGED ""):$PATH"
run 3 "close refuses MERGED with no merge commit" wo close --project "$d" --id "$id"
finish
