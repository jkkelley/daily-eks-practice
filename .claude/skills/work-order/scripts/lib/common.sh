# shellcheck shell=bash
#
# common.sh - shared foundation for every project-scaffold tool.
#
# Sourced, never executed. Every function is prefixed ps_ so a project's own
# shell environment cannot collide with it.
#
# The invariants this file exists to guarantee:
#   - user input is written literally, never evaluated
#   - writes are atomic: build in a temp file, rename over the target
#   - concurrent writers serialise on a lock instead of racing for an ID
#   - every temp path is removed on exit, whether the run passed or failed
#   - stdout carries data only; every human word goes to stderr

# ---------------------------------------------------------------------------
# Exit codes. Agents branch on these numbers, never on message text.
# ---------------------------------------------------------------------------
readonly PS_OK=0
readonly PS_USAGE=2      # bad flag, missing required flag, empty required value
readonly PS_VALIDATION=3 # bad enum value, missing sentinel, malformed file
readonly PS_IO=4         # unreadable / unwritable path
readonly PS_LOCK=5       # another writer held the lock too long
readonly PS_NOTFOUND=6   # referenced ID does not exist

readonly PS_SCHEMA_VERSION=1
readonly PS_TOOL_VERSION=1

# Set by ps_parse_common; consulted by ps_emit_* .
PS_JSON=0
PS_PROJECT=""
PS_LOCK_TIMEOUT=10

# ---------------------------------------------------------------------------
# Output. Data on stdout, everything else on stderr.
# ---------------------------------------------------------------------------

ps_info() { printf '%s\n' "$*" >&2; }
ps_warn() { printf 'warning: %s\n' "$*" >&2; }

# ps_die <exit-code> <error-slug> <human message>
# In --json mode the slug is what an agent reads; the human message is for you.
ps_die() {
  local code="$1" slug="$2"
  shift 2
  if ((PS_JSON)); then
    printf '{"ok":false,"code":%d,"error":"%s","message":%s}\n' \
      "$code" "$slug" "$(ps_json_string "$*")"
  else
    printf 'error: %s\n' "$*" >&2
  fi
  exit "$code"
}

# ---------------------------------------------------------------------------
# JSON. Hand-rolled because the test image has no jq and we refuse to add a
# runtime dependency to a tool whose whole point is being always available.
# ---------------------------------------------------------------------------

# ps_json_string <text> -> a quoted, escaped JSON string
ps_json_string() {
  local s=${1-} out='' i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:i:1}
    case $ch in
      '"') out+='\"' ;;
      '\') out+='\\' ;;
      $'\n') out+='\n' ;;
      $'\r') out+='\r' ;;
      $'\t') out+='\t' ;;
      *)
        # Escape remaining C0 control characters as \u00XX; pass everything
        # else (including UTF-8) through untouched.
        if [[ $ch < $'\x20' ]]; then
          printf -v ch '\\u%04x' "'$ch"
        fi
        out+=$ch
        ;;
    esac
  done
  printf '"%s"' "$out"
}

# ---------------------------------------------------------------------------
# Time. Injectable so determinism is provable rather than asserted.
# ---------------------------------------------------------------------------

ps_now() {
  if [[ -n ${SCAFFOLD_NOW-} ]]; then
    printf '%s' "$SCAFFOLD_NOW"
  else
    date -Iseconds
  fi
}

ps_today() {
  if [[ -n ${SCAFFOLD_NOW-} ]]; then
    printf '%s' "${SCAFFOLD_NOW%%T*}"
  else
    date -I
  fi
}

# ---------------------------------------------------------------------------
# Scratch space. One temp dir per run, removed on every exit path.
# ---------------------------------------------------------------------------

PS_SCRATCH=""

ps_scratch_init() {
  # Guarded with if/fi rather than `[[ ... ]] && return 0`: under `set -e` a
  # trailing false test would take the whole script down.
  if [[ -n $PS_SCRATCH ]]; then return 0; fi
  PS_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/project-scaffold.XXXXXX") || {
    printf 'error: could not create a temporary directory\n' >&2
    exit "$PS_IO"
  }
  # INT and TERM re-raise after cleanup so the caller sees a real signal death.
  trap 'ps_cleanup' EXIT
  trap 'ps_cleanup; trap - INT; kill -INT $$' INT
  trap 'ps_cleanup; trap - TERM; kill -TERM $$' TERM
}

ps_cleanup() {
  if [[ -n $PS_SCRATCH && -d $PS_SCRATCH ]]; then
    rm -rf -- "$PS_SCRATCH"
  fi
  PS_SCRATCH=""
}

ps_tempfile() {
  ps_scratch_init
  mktemp "$PS_SCRATCH/tmp.XXXXXX"
}

# ---------------------------------------------------------------------------
# Input sanitising.
#
# Values reach the markdown verbatim - no shell ever evaluates them. The only
# transformation is defensive: a literal comment terminator inside a value
# would end the metadata block early and corrupt every downstream parse.
# ---------------------------------------------------------------------------

# The replacements are held in variables and expanded quoted. Bash 5.2 treats a
# bare `&` in a substitution replacement as "whatever the pattern matched", so
# an inline --&gt; would silently produce ---->gt;.
readonly PS_GT_ESCAPE='--&gt;'
readonly PS_LT_ESCAPE='&lt;!--'

# ps_sanitize_line <text> -> single line, comment-terminator neutralised
ps_sanitize_line() {
  local s=${1-}
  s=${s//$'\r'/}
  s=${s//$'\n'/ }
  s=${s//$'\t'/ }
  s=${s//-->/"$PS_GT_ESCAPE"}
  s=${s//<!--/"$PS_LT_ESCAPE"}
  # collapse runs of spaces, then trim
  while [[ $s == *"  "* ]]; do s=${s//  / }; done
  s=${s# }
  s=${s% }
  printf '%s' "$s"
}

# ps_sanitize_body <text> -> newlines preserved, terminator neutralised
ps_sanitize_body() {
  local s=${1-}
  s=${s//$'\r'/}
  s=${s//-->/"$PS_GT_ESCAPE"}
  s=${s//<!--/"$PS_LT_ESCAPE"}
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Locking. Every mutation of a managed file happens inside this.
# ---------------------------------------------------------------------------

# ps_with_lock <lockfile> <command...>
ps_with_lock() {
  local lockfile="$1"
  shift
  local lockdir
  lockdir=$(dirname -- "$lockfile")
  [[ -d $lockdir ]] || ps_die "$PS_IO" "lock_dir_missing" "lock directory does not exist: $lockdir"

  exec 9>"$lockfile" || ps_die "$PS_IO" "lock_open_failed" "cannot open lock file: $lockfile"
  if ! flock -w "$PS_LOCK_TIMEOUT" 9; then
    ps_die "$PS_LOCK" "lock_timeout" \
      "another writer held $lockfile for more than ${PS_LOCK_TIMEOUT}s"
  fi
  "$@"
  local rc=$?
  exec 9>&-
  return $rc
}

# ---------------------------------------------------------------------------
# Atomic write. Never leaves a half-written managed file behind.
# ---------------------------------------------------------------------------

# ps_atomic_install <source-temp-file> <destination>
ps_atomic_install() {
  local src="$1" dst="$2"
  local dstdir
  dstdir=$(dirname -- "$dst")
  [[ -w $dstdir ]] || ps_die "$PS_IO" "dir_not_writable" "directory is not writable: $dstdir"

  # Stage inside the destination directory so the rename cannot cross a
  # filesystem boundary and silently degrade into a copy.
  local staged
  staged=$(mktemp "$dstdir/.project-scaffold.XXXXXX") || \
    ps_die "$PS_IO" "stage_failed" "cannot stage a write in $dstdir"

  if [[ -e $dst ]]; then
    # Preserve the mode of the file being replaced.
    chmod --reference="$dst" "$staged" 2>/dev/null || true
  else
    chmod 0644 "$staged" 2>/dev/null || true
  fi

  cat -- "$src" >"$staged" || { rm -f -- "$staged"; ps_die "$PS_IO" "write_failed" "cannot write to $dstdir"; }
  mv -f -- "$staged" "$dst" || { rm -f -- "$staged"; ps_die "$PS_IO" "rename_failed" "cannot replace $dst"; }
}

# ---------------------------------------------------------------------------
# File helpers.
# ---------------------------------------------------------------------------

# ps_normalize_newlines <file> - strip CR so sentinel matching survives a file
# that has been touched on Windows. Operates on a temp copy, not the original.
ps_strip_cr() {
  local src="$1" out
  out=$(ps_tempfile)
  tr -d '\r' <"$src" >"$out"
  printf '%s' "$out"
}

# ps_has_sentinel <file> <sentinel-text>
ps_has_sentinel() {
  local file="$1" sentinel="$2"
  [[ -f $file ]] || return 1
  grep -qF -- "$sentinel" "$file"
}

# ps_ends_with_newline <file> - false for an empty file too, which is correct:
# appending to it must not assume a leading blank line exists.
ps_ends_with_newline() {
  local file="$1"
  [[ -s $file ]] || return 1
  [[ $(tail -c 1 -- "$file" | od -An -c | tr -d ' ') == '\n' ]]
}

# ---------------------------------------------------------------------------
# ID allocation. Scans existing IDs and returns the successor, zero-padded.
# Refuses to wrap, because silent ID reuse is unrecoverable.
# ---------------------------------------------------------------------------

# ps_next_id <file> <prefix>   e.g. ps_next_id ISSUES.md ISS  ->  ISS-0043
ps_next_id() {
  local file="$1" prefix="$2"
  local max=0 n
  if [[ -f $file ]]; then
    while IFS= read -r n; do
      # 10# forces base-10 so a value like 0042 is not read as octal.
      n=$((10#$n))
      if ((n > max)); then max=$n; fi
    done < <(grep -oE "^[[:space:]]*id: ${prefix}-[0-9]{4}" "$file" 2>/dev/null | grep -oE '[0-9]{4}$' || true)
  fi
  local next=$((max + 1))
  if ((next > 9999)); then
    ps_die "$PS_VALIDATION" "id_space_exhausted" \
      "${prefix} IDs are exhausted at 9999 - widen the ID format before logging more"
  fi
  printf '%s-%04d' "$prefix" "$next"
}

# ps_id_exists <file> <id>
ps_id_exists() {
  local file="$1" id="$2"
  [[ -f $file ]] || return 1
  grep -qE "^[[:space:]]*id: ${id}\$" "$file"
}

# ps_id_count <file> <id> - used to refuse ambiguous files rather than guess
ps_id_count() {
  local file="$1" id="$2"
  [[ -f $file ]] || { printf '0'; return 0; }
  grep -cE "^[[:space:]]*id: ${id}\$" "$file" || true
}

# ---------------------------------------------------------------------------
# Project resolution and common flags.
# ---------------------------------------------------------------------------

ps_resolve_project() {
  local p="${1:-.}"
  [[ -d $p ]] || ps_die "$PS_IO" "project_missing" "no such directory: $p"
  (cd -- "$p" && pwd) || ps_die "$PS_IO" "project_unreadable" "cannot enter directory: $p"
}

# ps_require_value <flag-name> <value>
ps_require_value() {
  local name="$1" value="${2-}"
  [[ -n $value ]] || ps_die "$PS_USAGE" "required_empty" "--${name} is required and must not be empty"
}

# ps_require_enum <flag-name> <value> <allowed...>
ps_require_enum() {
  local name="$1" value="$2"
  shift 2
  local allowed=("$@") a
  for a in "${allowed[@]}"; do
    if [[ $value == "$a" ]]; then return 0; fi
  done
  ps_die "$PS_VALIDATION" "invalid_enum" \
    "--${name} must be one of: ${allowed[*]} (got: ${value})"
}

ps_is_tty() { [[ -t 0 && -t 1 ]]; }

# ps_prompt <label> <varname> - interactive fallback, only ever reached on a TTY
ps_prompt() {
  local label="$1" __var="$2" reply=""
  printf '%s: ' "$label" >&2
  IFS= read -r reply || reply=""
  printf -v "$__var" '%s' "$reply"
}
