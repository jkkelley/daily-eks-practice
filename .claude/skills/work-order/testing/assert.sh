# shellcheck shell=bash
#
# assert.sh - the assertion vocabulary every case uses.
#
# Assertions are on exit codes and file contents, never on whether some text
# appeared somewhere. A check that passes for the wrong reason is worse than no
# check, so every helper here names what it expected.

set -uo pipefail

: "${SKILL:=/skill}"
: "${WORK:=/work}"

TESTS_RUN=0
TESTS_FAILED=0
CASE_NAME="${CASE_NAME:-$(basename -- "${BASH_SOURCE[1]:-case}" .sh)}"

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '    ok   %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '    FAIL %s\n' "$1"
  shift
  local l
  for l in "$@"; do printf '         %s\n' "$l"; done
}

# run <expected-exit> <label> <command...>
run() {
  local want="$1" label="$2"
  shift 2
  local out
  out=$("$@" 2>&1)
  local got=$?
  if [[ $got == "$want" ]]; then
    _pass "$label (exit $got)"
  else
    _fail "$label" "wanted exit $want, got $got" "output: ${out:0:300}"
  fi
}

# capture <varname> <command...> - run and stash stdout, ignoring exit code
capture() {
  local __var="$1"
  shift
  local v
  v=$("$@" 2>/dev/null) || true
  printf -v "$__var" '%s' "$v"
}

assert_eq() {
  local want="$1" got="$2" label="$3"
  if [[ $want == "$got" ]]; then _pass "$label"; else _fail "$label" "wanted: $want" "got:    $got"; fi
}

assert_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    _pass "$label"
  else
    _fail "$label" "not found in $file: $needle"
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    _fail "$label" "unexpectedly found in $file: $needle"
  else
    _pass "$label"
  fi
}

assert_file() {
  local file="$1" label="$2"
  if [[ -f $file ]]; then _pass "$label"; else _fail "$label" "no such file: $file"; fi
}

assert_no_file() {
  local file="$1" label="$2"
  if [[ -e $file ]]; then _fail "$label" "file exists but should not: $file"; else _pass "$label"; fi
}

assert_same() {
  local a="$1" b="$2" label="$3"
  if cmp -s "$a" "$b"; then _pass "$label"; else _fail "$label" "$a and $b differ"; fi
}

assert_count() {
  local want="$1" got="$2" label="$3"
  if [[ $want == "$got" ]]; then _pass "$label"; else _fail "$label" "wanted $want, got $got"; fi
}

# A fresh project directory per test, so no case can depend on another's state.
new_project() {
  local d; d=$(mktemp -d "$WORK/proj.XXXXXX")
  printf '%s' "$d"
}

wo() { bash "$SKILL/scripts/work-order.sh" "$@"; }

# A project with one draft ticket, returned as "<dir> <id>".
drafted_project() {
  local d id; d=$(new_project)
  id=$(wo new --project "$d" --title "Empty cart state" --type feature --top-level \
        --problem "The cart shows nothing when empty" \
        --out "payment errors" --ac "npm test passes" 2>/dev/null | tail -1)
  printf '%s %s' "$d" "$id"
}

# --- figma fixtures ---------------------------------------------------------
# Shaped exactly like plan.py's output: build_order of prefix/screen/state/bp
# ids, plus the done_when and non_goals the brief carries through.
figma_dir() {
  local d="$1" prefix="${2:-wf}" project="${3:-shop}"
  mkdir -p "$d"
  cat >"$d/wireframe-brief.json" <<JSON
{"project":"$project","scope":"frontend","artifact":"screens","naming_prefix":"$prefix"}
JSON
  cat >"$d/build-plan.json" <<JSON
{"project":"$project","scope":"frontend","artifact":"screens","fidelity":"mid",
 "frames":[{"id":"$prefix/checkout-cart/empty/desktop","name":"$prefix/checkout-cart/empty",
            "state":"empty","breakpoint":"desktop","x":0,"y":0},
           {"id":"$prefix/checkout-cart/empty/mobile","name":"$prefix/checkout-cart/empty",
            "state":"empty","breakpoint":"mobile","x":900,"y":0},
           {"id":"$prefix/order-history/default/desktop","name":"$prefix/order-history/default",
            "state":"default","breakpoint":"desktop","x":0,"y":800}],
 "frame_count":3,
 "build_order":["$prefix/checkout-cart/empty/desktop","$prefix/checkout-cart/empty/mobile",
                "$prefix/order-history/default/desktop"],
 "done_when":"every frame renders at both breakpoints",
 "non_goals":["payment flow","logged-out variant"]}
JSON
  printf '%s' "$d"
}

# --- git / gh fixtures ------------------------------------------------------
# A real repo with a real bare origin. close does genuine branch deletes and
# pushes against this, so the destructive path is exercised, not simulated.
git_project() {
  local d bare; d=$(new_project); bare="${d}.git"
  git init --bare -q "$bare"
  git init -q "$d"
  git -C "$d" remote add origin "$bare"
  printf 'seed\n' >"$d/README.md"
  git -C "$d" add -A && git -C "$d" commit -qm "seed"
  git -C "$d" branch -M main
  git -C "$d" push -q -u origin main
  printf '%s' "$d"
}

# gh_stub <dir> <state> [sha] [project] [pr-create-fails] - put a fake gh on PATH
# reporting a fixed state. The close tests are about what work-order does with
# gh's answer, so gh's answer has to be the thing under our control.
#
# `pr list` answers "no open PR" by default, which is the state a first close run
# actually finds; a stub that claimed one would send every run down the reuse
# branch and leave the create path untested.
#
# `pr merge` really merges when <project> is given. close's phase 3 fetches and
# fast-forwards main immediately afterwards, so a stub that reported a merge
# without moving origin/main would test a world that cannot exist - and would
# quietly discard the close-out commit rather than failing.
#
# <pr-create-fails> makes `pr create` exit 1, which is the dead end the retry
# path exists for.
gh_stub() {
  local dir="$1" state="$2" sha="${3-abc123def456}"  # ${3-} not ${3:-}: "" must stay ""
  local proj="${4-}" create_fails="${5-}"
  mkdir -p "$dir"
  cat >"$dir/gh" <<STUB
#!/usr/bin/env bash
# canned gh: state=$state sha=$sha project=$proj create_fails=$create_fails
proj='$proj'
case "\$*" in
  *"pr list"*)            : ;;   # no open PR: real gh prints nothing through -q
  *"pr create"*)
    if [[ -n '$create_fails' ]]; then
      printf 'gh: could not create pull request\n' >&2
      exit 1
    fi
    printf '{}\n' ;;
  *"pr merge"*)
    if [[ -n \$proj ]]; then
      head=\$(git -C "\$proj" rev-parse --abbrev-ref HEAD)
      git -C "\$proj" push -q origin "HEAD:main" || exit 1
      git -C "\$proj" push -q origin --delete "\$head" >/dev/null 2>&1 || true
    fi
    printf '{}\n' ;;
  *"--json state"*)       printf '$state\n' ;;
  *"--json mergeCommit"*) printf '$sha\n' ;;
  *"--json number"*)      printf '{"number":7}\n' ;;
  *) printf '{}\n' ;;
esac
STUB
  chmod +x "$dir/gh"
  printf '%s' "$dir"
}

finish() {
  printf '  %s: %d checks, %d failed\n' "$CASE_NAME" "$TESTS_RUN" "$TESTS_FAILED"
  exit $((TESTS_FAILED > 0 ? 1 : 0))
}
