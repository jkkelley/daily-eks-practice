#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRUBBER="$REPO_ROOT/scripts/scrub-git-identity.sh"
TEST_ROOT="$(mktemp -d -t scrub-git-identity-test.XXXXXX)"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

REMOTE_REPO="$TEST_ROOT/remote.git"
SOURCE_REPO="$TEST_ROOT/source"
DRY_RUN_MIRROR="$TEST_ROOT/dry-run.git"
PUSH_MIRROR="$TEST_ROOT/push.git"
VERIFY_REPO="$TEST_ROOT/verify.git"
OLD_EMAIL="private@example.test"
NEW_EMAIL="12345+public@users.noreply.github.com"

git init --bare --quiet "$REMOTE_REPO"
git init --quiet "$SOURCE_REPO"
git -C "$SOURCE_REPO" config user.name "Private Identity"
git -C "$SOURCE_REPO" config user.email "$OLD_EMAIL"

printf 'first\n' > "$SOURCE_REPO/example.txt"
git -C "$SOURCE_REPO" add example.txt
git -C "$SOURCE_REPO" commit --quiet -m "Initial commit"
git -C "$SOURCE_REPO" branch -M main
git -C "$SOURCE_REPO" remote add origin "$REMOTE_REPO"
git -C "$SOURCE_REPO" push --quiet -u origin main

git -C "$SOURCE_REPO" switch --quiet -c feature
printf 'second\n' >> "$SOURCE_REPO/example.txt"
git -C "$SOURCE_REPO" commit --quiet -am "Feature commit"
git -C "$SOURCE_REPO" tag -a v1 -m "Version one"
git -C "$SOURCE_REPO" push --quiet -u origin feature --tags

"$SCRUBBER" \
  --source "$REMOTE_REPO" \
  --output "$DRY_RUN_MIRROR" \
  --old-email "$OLD_EMAIL" \
  --new-name "Public Identity" \
  --new-email "$NEW_EMAIL" >/dev/null

if git -C "$DRY_RUN_MIRROR" log --all --format='%ae%n%ce' | grep -Fqx "$OLD_EMAIL"; then
  echo "dry-run mirror still contains the old email" >&2
  exit 1
fi
git -C "$DRY_RUN_MIRROR" log --all --format='%ae%n%ce' | grep -Fqx "$NEW_EMAIL"
git -C "$REMOTE_REPO" log --all --format='%ae%n%ce' | grep -Fqx "$OLD_EMAIL"

"$SCRUBBER" \
  --source "$REMOTE_REPO" \
  --output "$PUSH_MIRROR" \
  --old-email "$OLD_EMAIL" \
  --new-name "Public Identity" \
  --new-email "$NEW_EMAIL" \
  --push \
  --yes >/dev/null

git clone --mirror --quiet --no-local "$REMOTE_REPO" "$VERIFY_REPO"
if git -C "$VERIFY_REPO" log --all --format='%ae%n%ce' | grep -Fqx "$OLD_EMAIL"; then
  echo "pushed remote still contains the old email" >&2
  exit 1
fi
git -C "$VERIFY_REPO" log --all --format='%ae%n%ce' | grep -Fqx "$NEW_EMAIL"
git -C "$VERIFY_REPO" for-each-ref refs/tags --format='%(taggeremail)' | grep -Fq "$NEW_EMAIL"
git -C "$VERIFY_REPO" fsck --full >/dev/null

echo "history scrubber test passed"
