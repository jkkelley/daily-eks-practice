#!/usr/bin/env bash
# One pull request per ticket, and the fallback for when main cannot take it.
#
# close used to cut a close-out/<id> branch and open a second PR for it, whose
# entire content was a file move and a regenerated index. That doubled the review
# surface for one piece of work and bought nothing: close cannot run at all until
# the ticket's own PR is MERGED and main's copy says done, both of which it
# asserts first. So the record now follows the work straight onto main.
#
# The branch-and-PR route survives as a fallback for a repository that protects
# main. It is a fallback, not a mode - nothing selects it, a rejected push does.
# Everything on that path is still written to be repeatable, because the dead end
# that prompted the original fix is still reachable there: an attempt that dies
# after the branch is cut must not leave a ticket only a human can close.
source "${SKILL:-/skill}/testing/assert.sh"

# ===========================================================================
# Part one - the normal path. Straight to main, and gh is not even consulted.
# ===========================================================================
d=$(git_project)
# The stub whose `pr create` fails. On this path it is never called, which is
# precisely what the run below proves: a broken gh cannot block a close-out that
# no longer needs a PR.
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

run 0 "close succeeds even though gh cannot open a PR - because it does not need one" \
  env PATH="$broken:$PATH" bash "$SKILL/scripts/work-order.sh" close --project "$d" --id "$id"

git -C "$d" rev-parse --verify "close-out/$id" >/dev/null 2>&1 \
  && _fail "no close-out branch is cut on the normal path" "close-out/$id exists" \
  || _pass "no close-out branch is cut on the normal path"
git -C "$d" rev-parse --verify "origin/close-out/$id" >/dev/null 2>&1 \
  && _fail "and none is pushed" "origin/close-out/$id exists" \
  || _pass "and none is pushed"

assert_eq "main" "$(git -C "$d" rev-parse --abbrev-ref HEAD)" "the caller is left on main"
arch="$d/work-orders/archive/2026/${id}-retry-me.md"
assert_file "$arch" "the ticket is archived"
assert_contains "$arch" 'beefbeef1111' "the merge SHA is recorded"
assert_no_file "$d/work-orders/$id" "it left the active tree"
run 0 "the archive reached main, not just the working tree" bash -c \
  "git -C '$d' cat-file -e origin/main:'${arch#"$d"/}'"
run 3 "and the ticket is closed for good" \
  env PATH="$working:$PATH" bash "$SKILL/scripts/work-order.sh" close --project "$d" --id "$id"

# ===========================================================================
# Part two - main is protected. The fallback has to carry it, and has to be
# safe to re-run after dying half way, which is the original dead end.
# ===========================================================================
e=$(git_project)
bare="${e}.git"
git -C "$bare" config receive.advertisePushOptions true
# Rejects a direct push to main while the flag file exists. A push carrying the
# `pr-merge` push option is what a real merge queue does on the far side of a
# pull request, so it is allowed through - that is the whole distinction the
# fallback depends on.
cat >"$bare/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read -r old new ref; do
  [ "$ref" = "refs/heads/main" ] || continue
  [ -f "$GIT_DIR/reject-main" ] || continue
  i=0; allowed=0
  while [ "$i" -lt "${GIT_PUSH_OPTION_COUNT:-0}" ]; do
    eval "v=\$GIT_PUSH_OPTION_$i"
    [ "$v" = "pr-merge" ] && allowed=1
    i=$((i+1))
  done
  [ "$allowed" -eq 1 ] || { echo "protected branch: direct push to main refused" >&2; exit 1; }
done
exit 0
HOOK
chmod +x "$bare/hooks/pre-receive"

# A gh whose `pr merge` pushes the way a protected repository would - with the
# push option the hook lets through. `pr create` fails on the first stub so the
# fallback can be interrupted exactly where the original dead end was.
mkdir -p "$WORK/stub-210-prot-broken" "$WORK/stub-210-prot-ok"
for variant in broken ok; do
  dir="$WORK/stub-210-prot-$variant"
  cat >"$dir/gh" <<STUB
#!/usr/bin/env bash
proj='$e'
case "\$*" in
  *"pr list"*)  : ;;
  *"pr create"*)
    if [ "$variant" = "broken" ]; then
      printf 'gh: could not create pull request\n' >&2; exit 1
    fi
    printf '{}\n' ;;
  *"pr merge"*)
    head=\$(git -C "\$proj" rev-parse --abbrev-ref HEAD)
    git -C "\$proj" push -q -o pr-merge origin "HEAD:main" || exit 1
    git -C "\$proj" push -q origin --delete "\$head" >/dev/null 2>&1 || true
    printf '{}\n' ;;
  *"--json state"*)       printf 'MERGED\n' ;;
  *"--json mergeCommit"*) printf 'cafe12345678\n' ;;
  *"--json number"*)      printf '{"number":9}\n' ;;
  *) printf '{}\n' ;;
esac
STUB
  chmod +x "$dir/gh"
done
pbroken="$WORK/stub-210-prot-broken"; pok="$WORK/stub-210-prot-ok"

wo new --project "$e" --title "Protected main" --type feature --problem P --top-level \
   --out X --ac "works" >/dev/null
id2=$(wo list --project "$e" --json | jq -r '.[0].id')
git -C "$e" add -A && git -C "$e" commit -qm "add"
PATH="$pok:$PATH" wo approve --project "$e" --id "$id2" --no-lavish --reason t >/dev/null
git -C "$e" add -A && git -C "$e" commit -qm "approve"
PATH="$pok:$PATH" wo start --project "$e" --id "$id2" >/dev/null
b2=$(git -C "$e" rev-parse --abbrev-ref HEAD)
PATH="$pok:$PATH" wo evidence --project "$e" --id "$id2" --index 1 --observed "ok" >/dev/null
git -C "$e" add -A && git -C "$e" commit -qm "work"
PATH="$pok:$PATH" wo submit --project "$e" --id "$id2" --pr 9 >/dev/null
PATH="$pok:$PATH" wo done --project "$e" --id "$id2" >/dev/null
git -C "$e" add -A && git -C "$e" commit -qm "done"
git -C "$e" push -q origin "$b2"
git -C "$e" checkout -q main && git -C "$e" merge -q --no-ff -m "merge #9" "$b2"
git -C "$e" push -q origin main && git -C "$e" checkout -q "$b2"

# Arm the protection only now, so the fixture above could be built normally.
touch "$bare/reject-main"

# --- the fallback, interrupted where the old dead end was --------------------
run 4 "with main protected and gh unable to open the PR, close fails" \
  env PATH="$pbroken:$PATH" bash "$SKILL/scripts/work-order.sh" close --project "$e" --id "$id2"

git -C "$e" rev-parse --verify "close-out/$id2" >/dev/null 2>&1 \
  && _pass "the fallback left its close-out branch behind" \
  || _fail "the fallback left its close-out branch behind" "no close-out branch"
run 0 "and pushed it, so nothing on it is lost" \
  git -C "$e" rev-parse --verify "origin/close-out/$id2"
assert_no_file "$e/work-orders/archive/2026/${id2}-protected-main.md" \
  "main does not yet carry the archive"

# --- and is safe to re-run from exactly that abandoned state -----------------
run 0 "a second close from the abandoned state completes through the fallback" \
  env PATH="$pok:$PATH" bash "$SKILL/scripts/work-order.sh" close --project "$e" --id "$id2"

assert_eq "main" "$(git -C "$e" rev-parse --abbrev-ref HEAD)" "the retry ends on main"
arch2="$e/work-orders/archive/2026/${id2}-protected-main.md"
assert_file "$arch2" "the ticket is archived"
assert_contains "$arch2" 'cafe12345678' "the merge SHA is recorded"
run 0 "the archive reached main through the pull request" bash -c \
  "git -C '$e' cat-file -e origin/main:'${arch2#"$e"/}'"
git -C "$e" rev-parse --verify "close-out/$id2" >/dev/null 2>&1 \
  && _fail "the close-out branch is cleaned up" "close-out/$id2 still exists" \
  || _pass "the close-out branch is cleaned up"

finish
