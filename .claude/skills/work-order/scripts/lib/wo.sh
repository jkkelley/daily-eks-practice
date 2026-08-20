# shellcheck shell=bash
#
# wo.sh - work-order specific helpers, layered on lib/common.sh.
#
# Split of responsibility with common.sh:
#   common.sh  emits JSON by hand and owns locking, atomic writes, exit codes.
#   wo.sh      reads JSON, and that is the one thing hand-rolled bash must not
#              do - hence jq. See wo_require_jq.
#
# work-order-version: 1

# `cancelled` is terminal like `done`, but it is the other terminal: nothing
# shipped. It is a separate status rather than a deleted file because a ticket
# that was abandoned is a decision, and a decision with no record is how the same
# idea gets cut again three weeks later.
readonly WO_STATUSES=(draft ready in-progress in-review done cancelled stale)
readonly WO_TYPES=(feature bug chore spike)
readonly WO_PRIORITIES=(p0 p1 p2 p3)

readonly WO_DIR_NAME="work-orders"
readonly WO_FROZEN_START="<!-- wo:frozen:start"
readonly WO_FROZEN_END="<!-- wo:frozen:end -->"

# ---------------------------------------------------------------------------
# Preflight. Every dependency is checked before anything is written, so a
# missing tool is a clean refusal rather than a half-mutated ticket.
# ---------------------------------------------------------------------------

wo_require_jq() {
  command -v jq >/dev/null 2>&1 || ps_die "$PS_IO" "jq_missing" \
    "jq is required (work-order reads build-plan.json). Install jq and retry."
}

# wo_require_git <dir> - the repo under test is the project directory, never the
# caller's cwd. Checking cwd passes or fails for reasons that have nothing to do
# with the ticket being operated on.
wo_require_git() {
  local dir="${1:-.}"
  command -v git >/dev/null 2>&1 || ps_die "$PS_IO" "git_missing" "git is required"
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || ps_die "$PS_IO" "not_a_repo" \
    "$dir is not inside a git repository"
}

wo_require_gh() {
  command -v gh >/dev/null 2>&1 || ps_die "$PS_IO" "gh_missing" \
    "gh is required to verify merge state. Install the GitHub CLI and retry."
}

# ---------------------------------------------------------------------------
# Identity.
#
# WO-YYYYMMDD-<hash> - date for human ordering, hash so two branches minting a
# ticket on the same day cannot collide the way a sequential counter would.
# The hash is derived from title+timestamp, so it is reproducible from inputs
# rather than random.
# ---------------------------------------------------------------------------

wo_mint_id() {
  local title="$1" stamp="$2" day short
  day="${stamp%%T*}"
  day="${day//-/}"
  short=$(printf '%s\n' "${title}|${stamp}" | cksum | awk '{printf "%04x", $1 % 65536}')
  printf 'WO-%s-%s' "$day" "$short"
}

# wo_slug <text> -> lowercase kebab, collapsed, trimmed, max 48 chars
wo_slug() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' \
    | cut -c1-48
}

wo_id_valid() {
  [[ $1 =~ ^WO-[0-9]{8}-[0-9a-f]{4}$ ]]
}

# ---------------------------------------------------------------------------
# Locating tickets. An ID resolves whether the ticket is active or archived,
# which is what keeps links working after `close` moves the file.
# ---------------------------------------------------------------------------

wo_root() { printf '%s/%s' "$1" "$WO_DIR_NAME"; }

# wo_find <project> <id> -> path, or dies
wo_find() {
  local project="$1" id="$2" root hit count
  root=$(wo_root "$project")
  [[ -d $root ]] || ps_die "$PS_NOTFOUND" "no_work_orders" \
    "no $WO_DIR_NAME/ directory in $project - run 'work-order new' first"

  # -print rather than a glob: archived tickets live under archive/YYYY/.
  count=$(find "$root" -type f -name "${id}-*.md" | wc -l)
  ((count != 0)) || ps_die "$PS_NOTFOUND" "id_not_found" "$id is not in $root"
  ((count == 1)) || ps_die "$PS_VALIDATION" "id_ambiguous" \
    "$id matches $count files in $root - resolve by hand before continuing"
  hit=$(find "$root" -type f -name "${id}-*.md")
  printf '%s' "$hit"
}

wo_is_archived() { [[ $1 == */archive/* ]]; }

# wo_exists <project> <id> - quiet lookup, for validating an edge target.
wo_exists() {
  local root
  root=$(wo_root "$1")
  [[ -d $root ]] || return 1
  [[ -n $(find "$root" -type f -name "${2}-*.md" -print -quit) ]]
}

# ---------------------------------------------------------------------------
# Hierarchy and layout.
#
# The top level of work-orders/ holds directories and nothing else. Two rules
# produce that, and both are enforced rather than remembered:
#
#   1. A ticket with no parent owns the directory named for it, and its own file
#      lives inside that directory.
#   2. A ticket with a parent is written into the parent's directory, promoting
#      the parent into one first if it was still a loose leaf.
#
#   work-orders/WO-…-e21f/WO-…-e21f-dev001-pipeline-test.md   the epic itself
#   work-orders/WO-…-e21f/WO-…-a1d4-track-a1.md               a leaf beneath it
#   work-orders/WO-…-e21f/WO-…-234b/WO-…-234b-skeleton.md     a child that is
#                                                             itself an epic
#
# A loose ticket file at the root was the old shape, and it is what let ten
# unrelated tickets pile up with nothing tying them together. Placing every
# parentless ticket in its own directory makes that pile impossible rather than
# merely tidied.
#
# Owning a directory is monotone: a ticket that has one keeps it even after its
# last child leaves. A path recorded anywhere therefore stays valid, which is
# the same reason grouping is by parent and never by status.
# ---------------------------------------------------------------------------

# wo_owns_dir <file> - 0 when the ticket's file already sits inside the
# directory named for its own id.
wo_owns_dir() {
  local f="$1" id
  id=$(wo_field "$f" '.id')
  [[ $(basename -- "$(dirname -- "$f")") == "$id" ]]
}

# wo_own_dir <file> -> the directory this ticket owns, whether or not it exists
# on disk yet. For a ticket that already owns one, that is the directory its own
# file sits in.
wo_own_dir() {
  local f="$1" id
  if wo_owns_dir "$f"; then printf '%s' "$(dirname -- "$f")"; return 0; fi
  id=$(wo_field "$f" '.id')
  printf '%s/%s' "$(dirname -- "$f")" "$id"
}

# wo_child_dir <parent-file> -> the directory this ticket's children live in.
# The same directory the ticket owns: an epic sits beside its children rather
# than one level above them, so the folder is the whole unit of work.
wo_child_dir() { wo_own_dir "$1"; }

# wo_home_dir <project> <parent-id-or-empty> <id> -> where this ticket's own
# file belongs. The id is required for a parentless ticket because that ticket
# is placed in the directory named for itself, never at the root.
wo_home_dir() {
  local project="$1" parent="${2:-}" id="${3:-}"
  if [[ -z $parent ]]; then
    [[ -n $id ]] || ps_die "$PS_USAGE" "missing_id" \
      "wo_home_dir needs the ticket id to place a ticket that has no parent"
    printf '%s/%s' "$(wo_root "$project")" "$id"
    return 0
  fi
  wo_child_dir "$(wo_find "$project" "$parent")"
}

# wo_loose_at_root <root> -> every ticket file sitting directly in work-orders/,
# one per line. This is what the layout gate reads: a single hit means the rule
# above has been broken and the pile is starting again.
wo_loose_at_root() {
  find "$1" -maxdepth 1 -type f -name 'WO-*.md' | sort
}

# wo_ancestors <project> <id> - the parent chain, nearest first, on stdout.
# Depth-capped: a cycle already on disk must be reported, never looped on.
wo_ancestors() {
  local project="$1" cur="$2" depth=0 f p
  while ((depth < 32)); do
    wo_exists "$project" "$cur" || return 0
    f=$(wo_find "$project" "$cur")
    p=$(wo_field "$f" '.parent')
    [[ -n $p ]] || return 0
    printf '%s\n' "$p"
    cur="$p"
    depth=$((depth + 1))
  done
  ps_die "$PS_VALIDATION" "parent_cycle" \
    "the parent chain above $2 is more than 32 deep - it contains a cycle"
}

# ---------------------------------------------------------------------------
# Records. One jq per ticket, emitting every field the index and the graph
# need. Reading each field with its own jq call is what made reindex slow
# enough that an agent would be tempted to skip it.
# ---------------------------------------------------------------------------

# wo_records <root> -> TSV: id status type priority parent deps relpath title
#
# An absent parent and an empty dependency list are emitted as WO_NONE rather
# than as an empty field. Tab is an IFS whitespace character, so `read` collapses
# two adjacent tabs into one delimiter and every later column shifts left - a
# ticket with no parent would silently read its own path as its parent. The
# sentinel keeps all eight fields non-empty; the caller maps it back.
readonly WO_NONE="-"

wo_records() {
  local root="$1" f
  while IFS= read -r f; do
    wo_fm "$f" | jq -r --arg p "${f#"$root"/}" --arg none "$WO_NONE" '
      def blank_as_none: if . == "" then $none else . end;
      [ .id, .status, .type, (.priority // "p2"),
        ((.parent // "") | blank_as_none),
        (((.depends_on // []) | join(",")) | blank_as_none),
        $p, .title ] | @tsv'
  done < <(find "$root" -type f -name 'WO-*.md' | sort)
}

# ---------------------------------------------------------------------------
# Frontmatter. The ticket is one file: a JSON object between the first pair of
# --- fences, then markdown. Keeping both in one file is what stops the machine
# layer and the human layer from drifting apart.
# ---------------------------------------------------------------------------

# wo_fm <file> -> the frontmatter JSON on stdout
wo_fm() {
  local file="$1" fm
  [[ -r $file ]] || ps_die "$PS_IO" "unreadable" "cannot read $file"
  fm=$(awk 'NR==1 && $0!="---" {exit 1} NR==1 {next} /^---$/ {exit} {print}' "$file") \
    || ps_die "$PS_VALIDATION" "no_frontmatter" "$file does not start with a --- frontmatter fence"
  printf '%s\n' "$fm" | jq -e . >/dev/null 2>&1 \
    || ps_die "$PS_VALIDATION" "bad_frontmatter" "frontmatter in $file is not valid JSON"
  printf '%s\n' "$fm"
}

# wo_field <file> <jq-path> -> raw value ("" when null/absent)
wo_field() {
  local file="$1" path="$2"
  wo_fm "$file" | jq -r "${path} // \"\""
}

# wo_body <file> -> everything after the closing frontmatter fence
wo_body() {
  awk 'NR==1 && $0=="---" {infm=1; next} infm && /^---$/ {infm=0; body=1; next} body {print}' "$1"
}

# wo_fm_set <file> <jq-filter> [jq-args...] - rewrite frontmatter atomically.
# The body is never touched, so a bad filter cannot eat the human layer.
wo_fm_set() {
  local file="$1" filter="$2"
  shift 2
  local fm new tmp
  fm=$(wo_fm "$file")
  new=$(printf '%s\n' "$fm" | jq "$@" "$filter") \
    || ps_die "$PS_VALIDATION" "jq_failed" "could not apply update to $file"
  tmp=$(ps_tempfile)
  {
    printf -- '---\n'
    printf '%s\n' "$new"
    printf -- '---\n'
    wo_body "$file"
  } >"$tmp"
  ps_atomic_install "$tmp" "$file"
}

# ---------------------------------------------------------------------------
# Status transitions. A closed set with an explicit table - an illegal move is
# refused by name rather than silently allowed.
# ---------------------------------------------------------------------------

# wo_require_status <file> <allowed...>
wo_require_status() {
  local file="$1"
  shift
  local cur s
  cur=$(wo_field "$file" '.status')
  for s in "$@"; do
    if [[ $cur == "$s" ]]; then return 0; fi
  done
  # IFS is $'\n\t' script-wide, so an unqualified "$*" would list the allowed
  # statuses one per line inside a single-line error. The list is read by a human
  # deciding what to run next, so it is joined by hand.
  local allowed=""
  for s in "$@"; do allowed+="${allowed:+, }$s"; done
  ps_die "$PS_VALIDATION" "illegal_transition" \
    "status is '$cur'; this command requires one of: $allowed"
}

# ---------------------------------------------------------------------------
# Wireframe binding.
#
# The checksum covers build_order, done_when and non_goals - the semantic
# contract. Canvas x/y is deliberately excluded so nudging a frame does not
# falsely mark a ticket stale.
# ---------------------------------------------------------------------------

# wo_plan_checksum <build-plan.json> [frames-glob]
wo_plan_checksum() {
  local plan="$1" glob="${2:-*}"
  jq -S --arg g "$glob" '{
      build_order: [.build_order[] | select(test("^" + ($g | gsub("\\*"; ".*")) + "$"))],
      done_when:   (.done_when // null),
      non_goals:   (.non_goals // [])
    }' "$plan" | cksum | awk '{printf "cksum:%s-%s", $1, $2}'
}

# wo_plan_identity <build-plan.json> -> project|naming-prefix, used to tell
# "the wireframe was rebuilt" apart from "that file is a different feature now".
wo_plan_identity() {
  jq -r '[(.project // "?"), ((.frames[0].id // "wf/x") | split("/")[0])] | join("|")' "$1"
}

wo_plan_frames() {
  local plan="$1" glob="${2:-*}"
  jq -r --arg g "$glob" \
    '.build_order[] | select(test("^" + ($g | gsub("\\*"; ".*")) + "$"))' "$plan"
}
