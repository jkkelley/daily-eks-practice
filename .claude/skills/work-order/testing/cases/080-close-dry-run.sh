#!/usr/bin/env bash
# --dry-run prints the whole plan and touches nothing.
source "${SKILL:-/skill}/testing/assert.sh"

d=$(git_project)
export PATH="$(gh_stub "$WORK/stub-dry" MERGED deadbeefcafe):$PATH"

wo new --project "$d" --title "Dry run me" --type chore --problem P --out X --ac "works" --top-level >/dev/null
id=$(wo list --project "$d" --json | jq -r '.[0].id')
git -C "$d" add -A && git -C "$d" commit -qm "add"
wo approve --project "$d" --id "$id" --no-lavish --reason t >/dev/null
# approve rewrites the ticket; commit it or start will refuse a dirty tree.
git -C "$d" add -A && git -C "$d" commit -qm "approve"
wo start --project "$d" --id "$id" >/dev/null
wo submit --project "$d" --id "$id" --pr 7 >/dev/null
f=$(find "$d/work-orders" -name 'WO-*.md'); sed -i 's/^- \[ \] /- [x] /' "$f"
git -C "$d" add -A && git -C "$d" commit -qm "work"
wo done --project "$d" --id "$id" >/dev/null

before=$(git -C "$d" rev-parse HEAD)
branch=$(git -C "$d" rev-parse --abbrev-ref HEAD)
run 0 "--dry-run exits 0" wo close --project "$d" --id "$id" --dry-run
capture out wo close --project "$d" --id "$id" --dry-run
case $out in *"DRY RUN"*) _pass "says it is a dry run" ;; *) _fail "says it is a dry run" "got: ${out:0:200}" ;; esac
case $out in *deadbeefcafe*) _pass "shows the merge SHA it would record" ;; *) _fail "shows the merge SHA" "got: ${out:0:200}" ;; esac
case $out in *"git branch -D"*) _pass "shows the destructive step it would run" ;; *) _fail "shows the destructive step" "got: ${out:0:200}" ;; esac

assert_eq "$before" "$(git -C "$d" rev-parse HEAD)" "--dry-run created no commit"
assert_eq "$branch" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" "--dry-run did not switch branch"
assert_file "$f" "--dry-run did not archive the ticket"
finish
