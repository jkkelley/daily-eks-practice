#!/usr/bin/env bash
# Rewrite one Git identity in a fresh mirror clone without touching this checkout.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/scrub-git-identity.sh \
    --old-email OLD_EMAIL \
    --new-name NEW_NAME \
    --new-email NEW_EMAIL \
    --output /path/to/sanitized.git \
    [--source REMOTE_OR_REPO] [--push] [--yes]

The default source is this repository's origin remote.
The output must not exist and must be outside this working repository.

Without --push, the script creates and verifies a sanitized mirror only.
With --push, it force-pushes every rewritten branch and tag after an explicit
confirmation. Use --yes only for intentional non-interactive execution.

History rewriting changes commit and annotated-tag IDs and invalidates their
signatures. Hosting-provider pull-request refs and caches may retain old objects,
so inspect and recreate affected pull requests before making a private repo public.
EOF
}

die() {
  printf 'scrub-git-identity: %s\n' "$*" >&2
  exit 1
}

need_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    die "$1 requires a value"
  fi
}

validate_single_line() {
  local label="$1"
  local value="$2"
  case "$value" in
    *$'\n'*|*$'\r'*) die "$label must be a single line" ;;
  esac
}

validate_email() {
  local label="$1"
  local value="$2"
  validate_single_line "$label" "$value"
  case "$value" in
    *' '*|*'<'*|*'>'*|''|@*|*@|*@.*|*.@*) die "$label is not a valid email address" ;;
    *@*.*) ;;
    *) die "$label is not a valid email address" ;;
  esac
}

snapshot_trees() {
  local repository="$1"
  local destination="$2"
  local ref
  local object_id

  : > "$destination"
  while IFS= read -r ref; do
    if object_id="$(git -C "$repository" rev-parse "${ref}^{tree}" 2>/dev/null)"; then
      printf '%s\ttree\t%s\n' "$ref" "$object_id" >> "$destination"
    elif object_id="$(git -C "$repository" rev-parse "${ref}^{blob}" 2>/dev/null)"; then
      printf '%s\tblob\t%s\n' "$ref" "$object_id" >> "$destination"
    else
      die "cannot snapshot the object behind $ref"
    fi
  done < <(git -C "$repository" for-each-ref --format='%(refname)' refs/heads refs/tags)
  LC_ALL=C sort -o "$destination" "$destination"
}

identity_count() {
  local repository="$1"
  local email="$2"
  {
    git -C "$repository" log --all --format='%ae%n%ce'
    git -C "$repository" for-each-ref refs/tags --format='%(taggeremail)'
  } | awk -v needle="$email" '
    $0 == needle || $0 == "<" needle ">" { count++ }
    END { print count + 0 }
  '
}

SOURCE_REPO=""
OUTPUT_DIR=""
OLD_EMAIL=""
NEW_NAME=""
NEW_EMAIL=""
PUSH_CHANGES=0
ASSUME_YES=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      need_value "$@"
      SOURCE_REPO="$2"
      shift 2
      ;;
    --output)
      need_value "$@"
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --old-email)
      need_value "$@"
      OLD_EMAIL="$2"
      shift 2
      ;;
    --new-name)
      need_value "$@"
      NEW_NAME="$2"
      shift 2
      ;;
    --new-email)
      need_value "$@"
      NEW_EMAIL="$2"
      shift 2
      ;;
    --push)
      PUSH_CHANGES=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git is not installed"
command -v git-filter-repo >/dev/null 2>&1 || die "git-filter-repo is not installed"

[ -n "$OLD_EMAIL" ] || die "--old-email is required"
[ -n "$NEW_NAME" ] || die "--new-name is required"
[ -n "$NEW_EMAIL" ] || die "--new-email is required"
[ -n "$OUTPUT_DIR" ] || die "--output is required"

validate_email "--old-email" "$OLD_EMAIL"
validate_email "--new-email" "$NEW_EMAIL"
validate_single_line "--new-name" "$NEW_NAME"
case "$NEW_NAME" in
  *'<'*|*'>'*|'') die "--new-name must be non-empty and cannot contain angle brackets" ;;
esac
[ "$OLD_EMAIL" != "$NEW_EMAIL" ] || die "old and new email addresses must differ"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ -z "$SOURCE_REPO" ]; then
  SOURCE_REPO="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)" \
    || die "cannot determine origin; pass --source"
fi

case "$SOURCE_REPO" in
  http://*:*@*|https://*:*@*)
    die "source URL contains credentials; use a credential helper instead"
    ;;
esac

OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"
case "${OUTPUT_DIR}/" in
  "${REPO_ROOT}/"*) die "--output must be outside this working repository" ;;
esac
[ ! -e "$OUTPUT_DIR" ] || die "output already exists: $OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"

SCRUB_TEMP_DIR="$(mktemp -d -t git-identity-scrub.XXXXXX)"
cleanup() {
  rm -rf "$SCRUB_TEMP_DIR"
}
trap cleanup EXIT

MAILMAP_FILE="$SCRUB_TEMP_DIR/identity.mailmap"
TREES_BEFORE="$SCRUB_TEMP_DIR/trees.before"
TREES_AFTER="$SCRUB_TEMP_DIR/trees.after"
REMOTE_REFS_BEFORE="$SCRUB_TEMP_DIR/remote-refs.before"
REMOTE_REFS_CURRENT="$SCRUB_TEMP_DIR/remote-refs.current"

printf 'Cloning a fresh mirror from %s\n' "$SOURCE_REPO"
git clone --mirror --no-local "$SOURCE_REPO" "$OUTPUT_DIR"
REMOTE_URL="$(git -C "$OUTPUT_DIR" remote get-url origin)"
git ls-remote --heads --tags "$REMOTE_URL" | LC_ALL=C sort > "$REMOTE_REFS_BEFORE"

snapshot_trees "$OUTPUT_DIR" "$TREES_BEFORE"
COMMITS_BEFORE="$(git -C "$OUTPUT_DIR" rev-list --all --count)"
OLD_IDENTITIES="$(identity_count "$OUTPUT_DIR" "$OLD_EMAIL")"
[ "$OLD_IDENTITIES" -gt 0 ] || die "the old email does not occur in reachable commit or tag metadata"

printf '%s <%s> <%s>\n' "$NEW_NAME" "$NEW_EMAIL" "$OLD_EMAIL" > "$MAILMAP_FILE"
git -C "$OUTPUT_DIR" filter-repo --mailmap "$MAILMAP_FILE"

if git -C "$OUTPUT_DIR" remote get-url origin >/dev/null 2>&1; then
  git -C "$OUTPUT_DIR" remote set-url origin "$REMOTE_URL"
else
  git -C "$OUTPUT_DIR" remote add origin "$REMOTE_URL"
fi

snapshot_trees "$OUTPUT_DIR" "$TREES_AFTER"
cmp -s "$TREES_BEFORE" "$TREES_AFTER" \
  || die "branch or tag trees changed unexpectedly; do not push this mirror"

COMMITS_AFTER="$(git -C "$OUTPUT_DIR" rev-list --all --count)"
[ "$COMMITS_BEFORE" -eq "$COMMITS_AFTER" ] \
  || die "reachable commit count changed unexpectedly; do not push this mirror"

REMAINING_OLD_IDENTITIES="$(identity_count "$OUTPUT_DIR" "$OLD_EMAIL")"
[ "$REMAINING_OLD_IDENTITIES" -eq 0 ] \
  || die "old identity remains in reachable commit or tag metadata"

NEW_IDENTITIES="$(identity_count "$OUTPUT_DIR" "$NEW_EMAIL")"
[ "$NEW_IDENTITIES" -ge "$OLD_IDENTITIES" ] \
  || die "not every old identity was rewritten to the new email"

git -C "$OUTPUT_DIR" fsck --full >/dev/null

printf '\nVerified sanitized mirror: %s\n' "$OUTPUT_DIR"
printf '  reachable commits: %s\n' "$COMMITS_AFTER"
printf '  rewritten identity fields: %s\n' "$OLD_IDENTITIES"
printf '  branch and tag trees: unchanged\n'
printf '  git fsck: passed\n'

if [ "$PUSH_CHANGES" -eq 0 ]; then
  printf '\nNo remote refs were changed. Inspect the mirror, then rerun with --push when ready.\n'
  exit 0
fi

git ls-remote --heads --tags "$REMOTE_URL" | LC_ALL=C sort > "$REMOTE_REFS_CURRENT"
cmp -s "$REMOTE_REFS_BEFORE" "$REMOTE_REFS_CURRENT" \
  || die "the remote changed after cloning; create a new mirror and retry"

if [ "$ASSUME_YES" -eq 0 ]; then
  [ -t 0 ] || die "--push requires an interactive terminal or an explicit --yes"
  printf '\nThis will force-push every rewritten branch and tag to:\n  %s\n' "$REMOTE_URL"
  printf 'Type force-push to continue: '
  read -r CONFIRMATION
  [ "$CONFIRMATION" = "force-push" ] || die "push cancelled"
fi

git -C "$OUTPUT_DIR" push --force origin 'refs/heads/*:refs/heads/*'
if git -C "$OUTPUT_DIR" show-ref --tags --quiet; then
  git -C "$OUTPUT_DIR" push --force origin 'refs/tags/*:refs/tags/*'
fi

VERIFY_MIRROR="$SCRUB_TEMP_DIR/verify.git"
git clone --mirror --no-local "$REMOTE_URL" "$VERIFY_MIRROR" >/dev/null
[ "$(identity_count "$VERIFY_MIRROR" "$OLD_EMAIL")" -eq 0 ] \
  || die "remote verification found the old identity in reachable refs"
git -C "$VERIFY_MIRROR" fsck --full >/dev/null

printf '\nForce-push and remote verification completed.\n'
printf 'Review hosting-provider pull-request refs and caches before changing visibility.\n'
