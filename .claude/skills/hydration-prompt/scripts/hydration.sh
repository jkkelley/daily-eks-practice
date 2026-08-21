#!/usr/bin/env bash
# hydration.sh - deterministic HYDRATION.md maintenance and session-launch output.
#
# The point of this script is that none of it is the agent's judgement. Where an
# entry goes, how many are kept, which one is read, and the exact text of the
# command handed back are all mechanical. An agent that is asked to "remember to
# trim to ten" will eventually not, and will report that it did.
#
# Exit codes match the fleet convention: 0 ok, 2 usage, 3 validation, 4 io.
set -uo pipefail

readonly EX_OK=0 EX_USAGE=2 EX_VALIDATION=3 EX_IO=4

# The window. Adding an eleventh entry removes the oldest in the same write.
readonly KEEP=10

# A marker rather than a heading, because an entry body legitimately contains
# markdown headings and splitting on those would cut entries in half.
readonly MARK_PREFIX='<!-- hydration-entry:'

# The sections every entry carries, in this order. `check` enforces presence and
# refuses duplicates - the first draft of this file was copied from terminal
# output that had three of its sections pasted in twice, which is exactly the
# defect a human skims straight past.
readonly -a SECTIONS=(
  "Ticket"
  "What just landed"
  "What is NOT done"
  "Stale or false in the docs"
  "Your scope"
  "Before you start"
  "Read in this order"
  "Reuse, it is proven"
  "The verification ladder"
  "Traps, already paid for"
  "Workflow"
  "Conventions"
)

die() { local code=$1; shift; printf 'hydration: %s\n' "$*" >&2; exit "$code"; }
warn() { printf 'hydration: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
hydration.sh <command> [options]

  init     --project DIR
           Create HYDRATION.md if it is not there. Safe to re-run.

  add      --project DIR --title TITLE --body-file FILE [--id WO-ID]
           Prepend an entry and trim the oldest so exactly 10 remain.
           Refuses a body that fails `check`. Omit --id for work that is not
           a ticket; the entry and its command adapt.

  latest   --project DIR [--id-only | --title-only | --path]
           Print the newest entry. This is what an incoming agent reads.

  command  --project DIR [--id WO-ID] [--title TITLE]
           Print the claude -p block that starts the next session. With neither
           flag, both are read out of the newest entry, which is the form to
           prefer - it cannot disagree with the file it points at.

  check    --project DIR [--body-file FILE]
           Validate structure. With --body-file, validate that file instead of
           the newest entry.

  count    --project DIR
           Print how many entries are stored.

Common: --help. Exit codes: 0 ok, 2 usage, 3 validation, 4 io.
EOF
}

# ---------------------------------------------------------------------------
# helpers

hp_file() { printf '%s/HYDRATION.md' "$1"; }

# Sets HP_FILE rather than printing it. `f=$(hp_require_file ...)` would run die
# inside a command substitution, where `exit` kills only the subshell: the caller
# would carry on with an empty path and fail somewhere unrelated. Caught by the
# test that asserts a missing file exits 4.
HP_FILE=""
hp_require_file() {
  HP_FILE=$(hp_file "$1")
  [[ -f $HP_FILE ]] || die "$EX_IO" "no HYDRATION.md in $1 - run 'hydration.sh init --project $1' first"
}

# Everything above the first marker: the file's own preamble, never an entry.
hp_preamble() {
  awk -v m="$MARK_PREFIX" 'index($0, m) == 1 { exit } { print }' "$1"
}

# Entry N (1-based, newest first), marker line included.
hp_entry() {
  awk -v m="$MARK_PREFIX" -v want="$2" '
    index($0, m) == 1 { n++ }
    n == want { print }
    n > want { exit }
  ' "$1"
}

# grep -c prints 0 AND exits 1 when there is no match, so a naive
# `grep -c ... || printf 0` prints it twice and every arithmetic test downstream
# blows up on "0\n0".
hp_count() {
  local n
  n=$(grep -c -- "^$MARK_PREFIX" "$1" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# check - the guard that makes "deterministic" true rather than aspirational.

hp_check_body() {
  local body=$1 problems=0 s count

  for s in "${SECTIONS[@]}"; do
    count=$(grep -c "^### ${s}\$" "$body" 2>/dev/null) || count=0
    if (( count == 0 )); then
      warn "missing section: ### $s"; problems=$((problems+1))
    elif (( count > 1 )); then
      warn "duplicated section (appears $count times): ### $s"; problems=$((problems+1))
    fi
  done

  # Any ### heading that is not one of ours is a typo or a stray paste.
  local unknown
  unknown=$(grep '^### ' "$body" 2>/dev/null | sed 's/^### //' | while read -r h; do
    local hit=0 s2
    for s2 in "${SECTIONS[@]}"; do [[ $h == "$s2" ]] && hit=1 && break; done
    (( hit )) || printf '%s\n' "$h"
  done)
  if [[ -n $unknown ]]; then
    while IFS= read -r h; do warn "unknown section: ### $h"; done <<<"$unknown"
    problems=$((problems+1))
  fi

  # "Before you start" carries prerequisites. Empty is a defect, because an
  # agent cannot tell "nothing to settle" from "the author forgot". Write the
  # word None.
  local before
  before=$(awk '/^### Before you start$/{f=1;next} /^### /{f=0} f' "$body" | tr -d '[:space:]')
  if [[ -z $before ]]; then
    warn "### Before you start is empty - write 'None.' if there is genuinely nothing"
    problems=$((problems+1))
  fi

  return $(( problems > 0 ? 1 : 0 ))
}

# ---------------------------------------------------------------------------
# commands

cmd_init() {
  local project=$1 f
  f=$(hp_file "$project")
  if [[ -f $f ]]; then printf '%s\n' "$f"; return "$EX_OK"; fi
  [[ -d $project ]] || die "$EX_IO" "no such directory: $project"
  cat > "$f" <<EOF
# HYDRATION.md

The prompt that starts the next session, and the $KEEP before it.

**Read the top entry only.** It is the current one and it is complete on its own.
Everything below it has been superseded and is kept for history, not for reading.

**Newest on top.** Adding an entry removes the oldest in the same commit, so this
file holds exactly $KEEP once it has filled up. Entries are never renumbered and
never edited in place - a correction is a new entry.

Written by \`hydration.sh add\`. Do not hand-edit.
EOF
  printf '%s\n' "$f"
}

cmd_add() {
  local project=$1 id=$2 title=$3 body=$4
  [[ -f $body ]] || die "$EX_IO" "no such body file: $body"
  hp_check_body "$body" || die "$EX_VALIDATION" "body failed check - fix the problems above, nothing was written"

  hp_require_file "$project"; local f=$HP_FILE
  local today; today=$(date +%F)
  local tmp; tmp=$(mktemp) || die "$EX_IO" "cannot create a temp file"

  {
    hp_preamble "$f"
    printf '%s %s -->\n' "$MARK_PREFIX" "${id:-none}"
    if [[ -n $id ]]; then printf '## %s - %s\n' "$id" "$title"
    else                  printf '## %s\n' "$title"; fi
    printf '_Generated %s by hydration.sh. Newest entry._\n\n' "$today"
    cat "$body"
    printf '\n'
    # Keep the first KEEP-1 existing entries; the rest fall off the bottom.
    local n total; total=$(hp_count "$f")
    for (( n=1; n<KEEP && n<=total; n++ )); do hp_entry "$f" "$n"; done
  } > "$tmp" || { rm -f "$tmp"; die "$EX_IO" "failed while writing $f"; }

  mv -- "$tmp" "$f" || die "$EX_IO" "cannot replace $f"
  printf 'added %s, %s entries retained\n' "$id" "$(hp_count "$f")"
}

cmd_latest() {
  local project=$1 mode=$2
  hp_require_file "$project"; local f=$HP_FILE
  (( $(hp_count "$f") > 0 )) || die "$EX_VALIDATION" "HYDRATION.md has no entries yet"
  local entry mark_id head_line
  entry=$(hp_entry "$f" 1)
  mark_id=$(printf '%s' "$entry" | sed -n "1s|^$MARK_PREFIX *\\(.*\\) -->$|\\1|p")
  [[ $mark_id == none ]] && mark_id=""
  head_line=$(printf '%s' "$entry" | sed -n '2p'); head_line=${head_line#\#\# }
  case $mode in
    id-only)    printf '%s\n' "$mark_id" ;;
    title-only) if [[ -n $mark_id ]]; then printf '%s\n' "${head_line#"$mark_id" - }"
                else printf '%s\n' "$head_line"; fi ;;
    path)       printf '%s\n' "$(cd "$project" && pwd)/HYDRATION.md" ;;
    *)          printf '%s\n' "$entry" ;;
  esac
}

# The template, verbatim and not negotiable. Everything variable in it is
# derived here rather than typed, so the command that comes back is always
# runnable and always points at a file that exists.
cmd_command() {
  local project=$1 id=$2 title=$3 full
  full="$(cd "$project" 2>/dev/null && pwd)/HYDRATION.md" \
    || die "$EX_IO" "no such directory: $project"
  [[ -f $full ]] || die "$EX_IO" "no HYDRATION.md at $full"

  # Derive from the file when not told. Typing them again is a chance to type
  # them differently, and a command whose title disagrees with the entry it
  # points at is worse than no command.
  [[ -n $id && -n $title ]] || {
    id=${id:-$(cmd_latest "$project" id-only)}
    title=${title:-$(cmd_latest "$project" title-only)}
  }
  if [[ -n $id ]]; then
    cat <<EOF
claude -p "Read Hydration Prompt located at $full, Process work order $id per its acceptance criteria after you've read it." \\
  --permission-mode bypassPermissions \\
  -n "Session: $id - $title"
EOF
  else
    # No work order. Two deliberate differences from the shape above, and
    # neither is an oversight.
    #
    # The acceptance-criteria clause is dropped, because there are none to
    # process and pointing it at nothing is worse than leaving it out.
    #
    # The session name is left EMPTY on purpose. Work outside a ticket has no
    # name until the person starting it decides what this session is - a design
    # pass, a spike, an investigation - so the slot is left open to be typed at
    # the moment of pasting. Do not "helpfully" fill it from the entry title.
    cat <<EOF
claude -p "Read Hydration Prompt located at $full" \\
  -n "Session: "
EOF
  fi
}

cmd_check() {
  local project=$1 body=${2:-}
  if [[ -n $body ]]; then
    hp_check_body "$body" || die "$EX_VALIDATION" "$body failed check"
    printf 'ok: %s\n' "$body"; return "$EX_OK"
  fi
  local tmp; hp_require_file "$project"; local f=$HP_FILE
  local n; n=$(hp_count "$f")
  (( n > 0 )) || die "$EX_VALIDATION" "HYDRATION.md has no entries"
  (( n <= KEEP )) || die "$EX_VALIDATION" "HYDRATION.md holds $n entries, the window is $KEEP"
  tmp=$(mktemp); hp_entry "$f" 1 | tail -n +3 > "$tmp"
  hp_check_body "$tmp" || { rm -f "$tmp"; die "$EX_VALIDATION" "newest entry failed check"; }
  rm -f "$tmp"
  printf 'ok: %s entries, newest is well-formed\n' "$n"
}

cmd_count() { hp_require_file "$1"; hp_count "$HP_FILE"; printf '\n'; }

# ---------------------------------------------------------------------------

main() {
  local cmd=${1:-}; [[ -n $cmd ]] || { usage; exit "$EX_USAGE"; }
  case $cmd in -h|--help|help) usage; exit "$EX_OK" ;; esac
  shift

  local project="" id="" title="" body="" mode="full"
  while (( $# )); do
    case $1 in
      --project)    project=${2:-}; shift 2 ;;
      --id)         id=${2:-}; shift 2 ;;
      --title)      title=${2:-}; shift 2 ;;
      --body-file)  body=${2:-}; shift 2 ;;
      --id-only)    mode="id-only"; shift ;;
      --title-only) mode="title-only"; shift ;;
      --path)       mode="path"; shift ;;
      -h|--help)    usage; exit "$EX_OK" ;;
      *)            die "$EX_USAGE" "unknown option: $1" ;;
    esac
  done
  [[ -n $project ]] || die "$EX_USAGE" "--project is required"

  case $cmd in
    init)    cmd_init "$project" ;;
    add)     [[ -n $title && -n $body ]] \
               || die "$EX_USAGE" "add needs --title and --body-file (--id is optional: omit it for work outside a ticket)"
             cmd_add "$project" "$id" "$title" "$body" ;;
    latest)  cmd_latest "$project" "$mode" ;;
    command) cmd_command "$project" "$id" "$title" ;;
    check)   cmd_check "$project" "$body" ;;
    count)   cmd_count "$project" ;;
    *)       die "$EX_USAGE" "unknown command: $cmd" ;;
  esac
}

main "$@"
