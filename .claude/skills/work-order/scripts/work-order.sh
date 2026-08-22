#!/usr/bin/env bash
#
# work-order.sh - deterministic ticketing for agent handoff.
#
# Every mutation refuses rather than guesses. The agent supplies an identifier;
# this script establishes the facts. That is the whole design: `close` calls gh
# to find out whether a PR merged instead of believing what it was told.
#
# work-order-version: 1

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/wo.sh
source "$SCRIPT_DIR/lib/wo.sh"

readonly TEMPLATE="$SKILL_DIR/references/ticket.tmpl"

usage() {
  cat <<'EOF'
work-order.sh - deterministic tickets for agent handoff

Usage:
  work-order.sh new     [--project DIR] --title T --type T --problem T --out T...
                        [--in T...] [--ac T...] [--test-plan T] [--surface T...]
                        [--priority p0|p1|p2|p3] [--assume T...] [--question T...]
                        (--parent WO-... | --top-level)
                        [--depends-on WO-...] [--blocks WO-...]
                        [--from-figma DIR] [--frames GLOB] [--json]
  work-order.sh amend   [--project DIR] --id WO-... [--title T] [--problem T]
                        [--in T...] [--out T...] [--ac T...] [--test-plan T] [--json]
  work-order.sh link    [--project DIR] --id WO-... [--parent WO-... | --detach]
                        [--depends-on WO-...] [--blocks WO-...]
                        [--no-depends-on WO-...] [--no-blocks WO-...] [--json]
  work-order.sh note    [--project DIR] --id WO-... --text T [--json]
  work-order.sh resolve [--project DIR] --id WO-... (--index N | --match TEXT)
                        --answer T [--json]
  work-order.sh evidence [--project DIR] --id WO-... (--index N | --match TEXT)
                        --observed T [--json]
  work-order.sh next    [--project DIR] [--json]
  work-order.sh tree    [--project DIR] [--json]
  work-order.sh reindex [--project DIR] [--check] [--json]
  work-order.sh reflow  [--project DIR] [--dry-run] [--json]
  work-order.sh repair  [--project DIR] [--dry-run] [--json]
  work-order.sh approve [--project DIR] --id WO-... [--no-lavish --reason T] [--json]
  work-order.sh start   [--project DIR] --id WO-... [--json]
  work-order.sh submit  [--project DIR] --id WO-... --pr N [--json]
  work-order.sh done    [--project DIR] --id WO-... [--json]
  work-order.sh close   [--project DIR] --id WO-... [--dry-run] [--json]
  work-order.sh cancel  [--project DIR] --id WO-... --reason T
                        [--superseded-by WO-...] [--json]
  work-order.sh reopen  [--project DIR] --id WO-... --reason T [--json]
  work-order.sh verify  [--project DIR] [--id WO-...] [--json]
  work-order.sh resync  [--project DIR] --id WO-... [--json]
  work-order.sh show    [--project DIR] --id WO-... [--json]
  work-order.sh list    [--project DIR] [--status S] [--json]

Lifecycle:
  draft --approve--> ready --start--> in-progress --submit--> in-review
        --done--> done --close--> done (archived, merge SHA recorded)
  Any of draft/ready/in-progress/in-review may become `cancelled` via cancel,
  which archives the ticket with nothing shipped. It is the other terminal state.
  Any of ready/in-progress/in-review may become `stale` via verify; resync returns it.

Authority:
  With wireframe evidence, build-plan.json leads and the frozen block is
  derived from it. Without, the ticket itself is the source of truth.

new:
  --title      one line
  --type       feature | bug | chore | spike
  --problem    what is broken or missing, and for whom
  --out        a non-goal. REQUIRED and repeatable - an empty Out list is what
               lets an agent wander, so it is a validation error, not a default.
  --in         an in-scope item, repeatable
  --ac         a human acceptance criterion, repeatable, phrased as a check
  --from-figma DIR containing wireframe-brief.json and build-plan.json. Both are
               snapshotted into work-orders/evidence/<ID>/ so a later wireframe
               run cannot destroy this ticket's evidence.
  --frames     glob over build_order, e.g. 'wf/checkout-cart/*'. Default: all.
  --parent     an existing WO this one belongs to. The file is written into that
               parent's directory, so the tree mirrors the work.
  --depends-on an existing WO that must reach `done` first. Repeatable. The
               inverse `blocks` edge is written on the other ticket too.

amend:
  Corrects a `draft` before it is approved, and only a draft: an approved ticket
  is amended by `reopen` or by cutting a new one. That refusal is the point - a
  ticket whose scope can move after approval is not a contract.
  Every repeatable flag REPLACES its whole section rather than adding to it, so
  what you pass is what the section says afterwards. Predictable beats clever.
  --title      rewrites the H1 and the frontmatter title. The slug and the file
               name are minted once by `new` and are left alone.
  --out        replaces the non-goals. As in `new`, an empty Out list is refused.
  --ac         replaces the human criteria. A wireframe-derived frozen block is
               preserved untouched - it is derived from build-plan.json, not
               from the caller.

link:
  Edges after the fact, for children cut before every ID existed.
  --parent     re-home the ticket under a parent; the file is moved with git mv.
  --detach     back to the root of work-orders/. It removes the parent and only
               the parent, so it is refused alongside --depends-on/--blocks.
  --no-depends-on  removes a dependency edge, and the inverse `blocks` edge on
               the other ticket with it. Repeatable. A target that no longer
               exists is still removed from this ticket - a dangling edge is the
               reason to run this, not a reason to refuse.
  --no-blocks  the same, in the other direction.
  Both --parent and --depends-on refuse a cycle and refuse an unknown ID.

note:
  --text       one line, appended newest-first under `## Notes`. This is the only
               way a progress note reaches a ticket - nothing here is hand-edited.

resolve:
  Records the answer to one Open question and checks its box. `approve` refuses
  while any question is unchecked, so this is the only way a ticket minted with
  --question ever reaches `ready`. It is not a way to dismiss a question:
  --answer is required, and there is no flag that resolves without one.
  --index      1-based, counting every question in the block whether it is
               resolved or not, so an index never shifts as questions are answered.
  --match      substring of the question, case-insensitive. An ambiguous match is
               refused rather than guessed.
  --answer     what was decided. Written under the question with today's date;
               the question text itself is preserved, never overwritten.

evidence:
  Records what was observed for one acceptance criterion and checks its box.
  Requires status `in-progress` or `in-review`: a criterion can only be observed
  while the work is being done, and ticking one on a draft would let a ticket
  reach `done` with nothing ever run.
  `done` refuses while any criterion is unchecked, so this is the only way a
  ticket reaches `done`. It is not a way to wave a criterion through: --observed
  is required, and there is no flag that ticks one without it. A criterion that
  was not observed stays unchecked, and the ticket stays in review - that
  refusal is the gate working, not a fault to route around.
  --index      1-based, counting every criterion in the block whether it is
               checked or not, so an index never shifts as criteria are met.
  --match      substring of the criterion, case-insensitive. An ambiguous match
               is refused rather than guessed.
  --observed   what was actually seen: the input, the result, and how a reader
               confirms it. Written under the criterion with today's date; the
               criterion text itself is preserved, never overwritten.

next:
  Prints the tickets that are `ready` with every dependency `done`. This is the
  handoff list: an empty result means nothing may be started, not "pick anything".

reindex:
  --check      exit 3 when INDEX.md does not match the tickets on disk, and print
               nothing but the reason. For a commit gate.

repair:
  Rewrites the H1 of any ticket still carrying the `%%ID%% - %%TITLE%%` template
  placeholder, from that ticket's own frontmatter. Idempotent. It touches that one
  line and nothing else - never the frontmatter, never the body.
  --dry-run    list what would change and write nothing.

close:
  Three phases: clean up the feature branch, land a close-out PR that archives the
  ticket, clean up the close-out branch. The close-out PR is opened and merged
  without asking, because close has already proved with `gh` that the ticket's own
  PR is MERGED - what is left is bookkeeping behind a merge a human approved.
  The caller ends on `main` when it succeeds, and back on the branch they started
  on when anything fails. A failed run is always safe to re-run: close reuses and
  resets the close-out branch, reuses a PR already open on it, and skips work a
  previous attempt already landed. Nothing here has to be finished by hand.
  --dry-run    print the phase plan and every assertion result, execute nothing.

cancel:
  Terminates a `draft`, `ready`, `in-progress` or `in-review` ticket that is not
  going to be built. It archives the file exactly where `close` would, and does no
  git and no gh work at all: no branch, no PR, no merge. The move is left staged in
  your working tree - commit it yourself, in whatever change explains it.
  A `done` ticket is refused: that one is finished, and `close` is its verb.
  --reason     REQUIRED. A cancellation with no stated reason is how the same idea
               gets cut again a month later. It is written into `## Outcome`.
  --superseded-by  the WO that replaced this one. Validated like any other edge
               target, written to the `superseded_by` field so the graph can be
               asked, and repeated in `## Outcome` beside the reason.

Common:
  --project DIR   project directory (default: .)
  --json          machine-readable output on stdout
  --lock-timeout SECONDS
  --help

Exit codes: 0 ok, 2 usage, 3 validation/illegal-transition, 4 io/missing-dep,
            5 lock timeout, 6 id not found

`new` exits 3 with error `unsubstituted_placeholder` when a %%TOKEN%% survives
rendering, and writes nothing. A ticket carrying a raw placeholder is a defect in
the template pass, and shipping it silently is how it stayed unnoticed once.
EOF
}

(($#)) || { usage; exit "$PS_USAGE"; }
case ${1-} in --help | -h) usage; exit "$PS_OK" ;; esac

command="$1"; shift

title=""; type=""; problem=""; test_plan=""; priority="p2"
id=""; pr=""; reason=""; status_filter=""; from_figma=""; frames_glob="*"
parent=""; text=""; answer=""; observed=""; index=""; match=""; superseded_by=""
no_lavish=0; dry_run=0; detach=0; check=0; top_level=0
declare -a in_items=() out_items=() ac_items=() surfaces=() assumptions=() questions=()
declare -a dep_items=() block_items=() no_dep_items=() no_block_items=()

while (($#)); do
  case $1 in
    --project) PS_PROJECT="${2-}"; shift 2 ;;
    --json) PS_JSON=1; shift ;;
    --lock-timeout) PS_LOCK_TIMEOUT="${2-}"; shift 2 ;;
    --title) title="${2-}"; shift 2 ;;
    --type) type="${2-}"; shift 2 ;;
    --problem) problem="${2-}"; shift 2 ;;
    --priority) priority="${2-}"; shift 2 ;;
    --test-plan) test_plan="${2-}"; shift 2 ;;
    --in) in_items+=("${2-}"); shift 2 ;;
    --out) out_items+=("${2-}"); shift 2 ;;
    --ac) ac_items+=("${2-}"); shift 2 ;;
    --surface) surfaces+=("${2-}"); shift 2 ;;
    --assume) assumptions+=("${2-}"); shift 2 ;;
    --question) questions+=("${2-}"); shift 2 ;;
    --from-figma) from_figma="${2-}"; shift 2 ;;
    --frames) frames_glob="${2-}"; shift 2 ;;
    --parent) parent="${2-}"; shift 2 ;;
    --depends-on) dep_items+=("${2-}"); shift 2 ;;
    --blocks) block_items+=("${2-}"); shift 2 ;;
    --no-depends-on) no_dep_items+=("${2-}"); shift 2 ;;
    --no-blocks) no_block_items+=("${2-}"); shift 2 ;;
    --superseded-by) superseded_by="${2-}"; shift 2 ;;
    --text) text="${2-}"; shift 2 ;;
    --answer) answer="${2-}"; shift 2 ;;
    --observed) observed="${2-}"; shift 2 ;;
    --index) index="${2-}"; shift 2 ;;
    --match) match="${2-}"; shift 2 ;;
    --detach) detach=1; shift ;;
    --top-level) top_level=1; shift ;;
    --check) check=1; shift ;;
    --id) id="${2-}"; shift 2 ;;
    --pr) pr="${2-}"; shift 2 ;;
    --reason) reason="${2-}"; shift 2 ;;
    --status) status_filter="${2-}"; shift 2 ;;
    --no-lavish) no_lavish=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    --help | -h) usage; exit "$PS_OK" ;;
    *) PS_JSON=0; ps_die "$PS_USAGE" "unknown_flag" "unknown flag: $1 (try --help)" ;;
  esac
done

[[ $PS_LOCK_TIMEOUT =~ ^[0-9]+$ ]] || \
  ps_die "$PS_USAGE" "bad_lock_timeout" "--lock-timeout must be a whole number of seconds"

project=$(ps_resolve_project "${PS_PROJECT:-.}")
root=$(wo_root "$project")

require_id() {
  ps_require_value id "$id"
  wo_id_valid "$id" || ps_die "$PS_USAGE" "bad_id_format" \
    "--id must look like WO-20260805-3f2a (got: $id)"
}

# ---------------------------------------------------------------------------
# Rendering. The template owns the section skeleton; the script fills the
# lists. An agent hand-writing ticket markdown is the failure this removes.
# ---------------------------------------------------------------------------

bullets() {
  local prefix="$1"; shift
  if (($# == 0)); then printf '%s\n' "_none_"; return; fi
  local x
  for x in "$@"; do printf '%s%s\n' "$prefix" "$(ps_sanitize_line "$x")"; done
}

render_body() {
  local criteria="$1" outcome="$2"
  local line token safe_title
  safe_title=$(ps_sanitize_line "$title")
  while IFS= read -r line; do
    case $line in
      '%%'*'%%')
        token="${line//%/}"
        case $token in
          ID) printf '%s\n' "$id" ;;
          TITLE) printf '%s\n' "$safe_title" ;;
          PROBLEM) printf '%s\n' "$(ps_sanitize_line "$problem")" ;;
          IN) bullets "- " "${in_items[@]+"${in_items[@]}"}" ;;
          OUT) bullets "- " "${out_items[@]+"${out_items[@]}"}" ;;
          CRITERIA) printf '%s\n' "$criteria" ;;
          TEST_PLAN)
            if [[ -n $test_plan ]]; then
              printf '```sh\n%s\n```\n' "$(ps_sanitize_line "$test_plan")"
            else
              printf '%s\n' "_none recorded - Rule 14 says this runs in a container_"
            fi ;;
          ASSUMPTIONS) bullets "1. " "${assumptions[@]+"${assumptions[@]}"}" ;;
          OPEN_QUESTIONS) bullets "- [ ] " "${questions[@]+"${questions[@]}"}" ;;
          OUTCOME) printf '%s\n' "$outcome" ;;
          *) printf '%s\n' "$line" ;;
        esac ;;
      # Inline placeholders. The H1 is `# %%ID%% - %%TITLE%%`, which is not a
      # whole-line token, so the cases above never saw it and every ticket this
      # skill ever wrote carried the raw placeholder as its heading. The
      # frontmatter held the right values, so nothing downstream broke and the
      # defect stayed invisible - which is exactly why render_guard now exists.
      *) line=${line//'%%ID%%'/"$id"}
         line=${line//'%%TITLE%%'/"$safe_title"}
         printf '%s\n' "$line" ;;
    esac
  done <"$TEMPLATE"
}

# render_guard <rendered-file> - refuse to write a ticket that still carries a
# template placeholder. A token the substitution pass does not know about is a
# defect in this script, and a ticket is read by agents for weeks: failing here
# costs one run, shipping it costs every ticket minted until somebody notices.
#
# The pattern is the placeholder shape, not a bare `%%`, so a legitimate title
# like "cap CPU at 100%% in the worker" is not mistaken for an unfilled token.
render_guard() {
  local hits
  hits=$(grep -oE '%%[A-Z][A-Z0-9_]*%%' "$1" | sort -u | tr '\n' ' ') || true
  if [[ -n $hits ]]; then
    ps_die "$PS_VALIDATION" "unsubstituted_placeholder" \
      "template placeholders survived rendering: ${hits% } - refusing to write the ticket"
  fi
}

# ---------------------------------------------------------------------------
# Graph edges.
#
# depends_on is the authoritative direction; blocks is its inverse and is
# written onto the other ticket at the same time. Both files therefore describe
# the edge, so reading either one alone is enough - which is the only way an
# agent handed a single ticket can tell whether it is allowed to start.
# ---------------------------------------------------------------------------

require_edge_target() {
  local kind="$1" target="$2"
  wo_id_valid "$target" || ps_die "$PS_USAGE" "bad_id_format" \
    "--$kind must look like WO-20260805-3f2a (got: $target)"
  wo_exists "$project" "$target" || ps_die "$PS_NOTFOUND" "edge_target_missing" \
    "--$kind $target does not exist - create it before linking to it"
}

# add_edge <target-id> <field> <value-id> - idempotent, so re-running a link
# script cannot double an edge.
add_edge() {
  local tf field="$2"
  tf=$(wo_find "$project" "$1")
  wo_fm_set "$tf" \
    "if ((.${field} // []) | index(\$v)) then . else .${field} = ((.${field} // []) + [\$v]) end
     | .updated = \$d" \
    --arg v "$3" --arg d "$(ps_today)"
}

# del_edge <target-id> <field> <value-id> - the inverse of add_edge. Subtraction
# rather than a search, so removing an edge that was never there is a no-op and a
# half-applied removal can be finished by re-running the same command.
del_edge() {
  local tf field="$2"
  tf=$(wo_find "$project" "$1")
  wo_fm_set "$tf" \
    ".${field} = ((.${field} // []) - [\$v]) | .updated = \$d" \
    --arg v "$3" --arg d "$(ps_today)"
}

# ---------------------------------------------------------------------------
# new
# ---------------------------------------------------------------------------

cmd_new() {
  wo_require_jq
  ps_require_value title "$title"
  ps_require_value type "$type"
  ps_require_enum type "$type" "${WO_TYPES[@]}"
  ps_require_enum priority "$priority" "${WO_PRIORITIES[@]}"
  ps_require_value problem "$problem"
  ((${#out_items[@]})) || ps_die "$PS_VALIDATION" "no_non_goals" \
    "at least one --out is required: a work-order with no non-goals lets an agent wander"

  [[ -w $project ]] || ps_die "$PS_IO" "dir_not_writable" "not writable: $project"

  local stamp today slug
  stamp=$(ps_now); today=$(ps_today)
  id=$(wo_mint_id "$title" "$stamp")
  slug=$(wo_slug "$title")
  [[ -n $slug ]] || ps_die "$PS_VALIDATION" "empty_slug" "--title produced an empty slug"

  # Everything that can refuse must refuse before the first mkdir. A rejected run
  # leaves no trace - not even an empty work-orders/ directory.
  local e
  # Every ticket has a home. A ticket with no parent becomes a directory at the
  # top of work-orders/, and that is a deliberate act rather than the default -
  # otherwise unrelated tickets accumulate at the root with nothing tying them
  # together, which is exactly the pile this rule exists to prevent.
  if [[ -z $parent ]] && ((top_level == 0)); then
    ps_die "$PS_VALIDATION" "no_home" \
      "a ticket needs a home: pass --parent WO-... to file it under existing work, or --top-level to open a new epic at the root of $WO_DIR_NAME/"
  fi
  if [[ -n $parent ]]; then require_edge_target parent "$parent"; fi
  for e in "${dep_items[@]+"${dep_items[@]}"}"; do require_edge_target depends-on "$e"; done
  for e in "${block_items[@]+"${block_items[@]}"}"; do require_edge_target blocks "$e"; done

  local ev_source="human" ev_json='null' criteria="" frozen_frames=""
  local brief="" plan=""
  if [[ -n $from_figma ]]; then
    brief="$from_figma/wireframe-brief.json"; plan="$from_figma/build-plan.json"
    [[ -r $brief ]] || ps_die "$PS_IO" "brief_missing" "no wireframe-brief.json in $from_figma"
    [[ -r $plan ]] || ps_die "$PS_IO" "plan_missing" "no build-plan.json in $from_figma"
    jq -e . "$plan" >/dev/null 2>&1 || ps_die "$PS_VALIDATION" "plan_invalid" "build-plan.json is not valid JSON"

    frozen_frames=$(wo_plan_frames "$plan" "$frames_glob")
    [[ -n $frozen_frames ]] || ps_die "$PS_VALIDATION" "no_frames_matched" \
      "--frames '$frames_glob' matched nothing in build_order"
  fi

  mkdir -p "$root" || ps_die "$PS_IO" "mkdir_failed" "cannot create $root"
  local home
  if [[ -n $parent ]]; then
    home=$(child_home "$parent")
  else
    home=$(wo_home_dir "$project" "" "$id")
  fi
  mkdir -p "$home" || ps_die "$PS_IO" "mkdir_failed" "cannot create $home"
  local file="$home/${id}-${slug}.md"
  [[ -e $file ]] && ps_die "$PS_VALIDATION" "id_collision" "$file already exists"

  # --- evidence -----------------------------------------------------------
  if [[ -n $from_figma ]]; then
    # Snapshot, so a later wireframe run cannot destroy this ticket's evidence.
    local evdir="$root/evidence/$id"
    mkdir -p "$evdir" || ps_die "$PS_IO" "mkdir_failed" "cannot create $evdir"
    cp -- "$brief" "$evdir/wireframe-brief.json"
    cp -- "$plan" "$evdir/build-plan.json"

    ev_source="wireframe"
    local checksum identity
    checksum=$(wo_plan_checksum "$evdir/build-plan.json" "$frames_glob")
    identity=$(wo_plan_identity "$evdir/build-plan.json")
    ev_json=$(jq -n \
      --arg src "$from_figma" --arg ck "$checksum" --arg idn "$identity" \
      --arg glob "$frames_glob" \
      --argjson frames "$(printf '%s\n' "$frozen_frames" | jq -R . | jq -s .)" \
      --argjson dw "$(jq '.done_when // null' "$evdir/build-plan.json")" \
      --argjson ng "$(jq '.non_goals // []' "$evdir/build-plan.json")" \
      '{source:"wireframe", origin:$src, snapshot:("evidence/" + "'"$id"'"),
        frame_checksum:$ck, identity:$idn, frames_glob:$glob, frames:$frames,
        done_when:$dw, non_goals:$ng}')

    # Frozen block: wireframe-derived criteria, checksummed. Nothing between the
    # markers may be edited by hand - verify recomputes it.
    criteria=$(
      printf '%s %s -->\n' "$WO_FROZEN_START" "checksum=$checksum"
      local f n=0
      while IFS= read -r f; do
        n=$((n + 1))
        printf -- '- [ ] `AC-%d` *(wireframe)* frame `%s` renders as planned\n' "$n" "$f"
      done <<<"$frozen_frames"
      local dw
      dw=$(jq -r '.done_when // empty' "$evdir/build-plan.json")
      if [[ -n $dw ]]; then
        n=$((n + 1))
        printf -- '- [ ] `AC-%d` *(wireframe)* %s\n' "$n" "$dw"
      fi
      printf '%s\n' "$WO_FROZEN_END"
    )
    # Wireframe non_goals are authoritative, so they join the Out list.
    local ng
    while IFS= read -r ng; do [[ -n $ng ]] && out_items+=("$ng"); done < <(
      jq -r '.non_goals[]? // empty' "$evdir/build-plan.json")
  fi

  local hn=0 a
  for a in "${ac_items[@]+"${ac_items[@]}"}"; do
    hn=$((hn + 1))
    criteria+=$'\n'"- [ ] \`AC-H${hn}\` *(human)* $(ps_sanitize_line "$a")"
  done
  [[ -n $criteria ]] || criteria="_none - approve will refuse until at least one exists_"

  # --- assemble -----------------------------------------------------------
  local fm tmp
  fm=$(jq -n \
    --arg id "$id" --arg slug "$slug" --arg title "$title" --arg type "$type" \
    --arg pri "$priority" --arg now "$stamp" --arg today "$today" \
    --argjson ev "$ev_json" \
    --arg parent "$parent" \
    --argjson surfaces "$(printf '%s\n' "${surfaces[@]+"${surfaces[@]}"}" | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson deps "$(printf '%s\n' "${dep_items[@]+"${dep_items[@]}"}" | grep -v '^$' | jq -R . | jq -s .)" \
    --argjson blocks "$(printf '%s\n' "${block_items[@]+"${block_items[@]}"}" | grep -v '^$' | jq -R . | jq -s .)" \
    '{id:$id, slug:$slug, title:$title, type:$type, status:"draft", priority:$pri,
      created:$today, updated:$today, created_at:$now,
      parent:(if $parent == "" then null else $parent end),
      branch:null, pr:null, merge_sha:null, closed:null,
      approval:null, evidence:$ev, surfaces:$surfaces,
      depends_on:$deps, blocks:$blocks}')

  tmp=$(ps_tempfile)
  {
    printf -- '---\n%s\n---\n\n' "$fm"
    render_body "$criteria" "_Written by \`work-order close\`. Empty until then._"
  } >"$tmp"
  render_guard "$tmp"
  ps_atomic_install "$tmp" "$file"

  # Inverse edges last: the ticket exists by now, so a failure here leaves a
  # findable ticket with one missing edge rather than an orphaned half-write.
  for e in "${dep_items[@]+"${dep_items[@]}"}"; do add_edge "$e" blocks "$id"; done
  for e in "${block_items[@]+"${block_items[@]}"}"; do add_edge "$e" depends_on "$id"; done
  reindex

  if ((PS_JSON)); then
    printf '{"ok":true,"id":"%s","file":%s,"status":"draft","evidence":"%s"}\n' \
      "$id" "$(ps_json_string "$file")" "$ev_source"
  else
    ps_info "created $file (status: draft, evidence: $ev_source)"
    printf '%s\n' "$id"
  fi
}

# ---------------------------------------------------------------------------
# amend - the review fix for a draft, and only for a draft.
#
# `new` is the only thing that ever wrote In, Out, Acceptance criteria or the
# test plan, so a review that found the scope wrong had nowhere to land: the
# choice was a binding note contradicting the section above it, or a hand edit of
# a file this skill owns. Both leave the ticket saying two things at once.
#
# The status gate is the whole point rather than a convenience. A ticket that can
# be rewritten after `approve` is not a contract, and the ability to move the
# goalposts on work already approved is worth more to a confused agent than every
# other refusal in this script is worth to us. An approved ticket changes through
# `reopen`, or by cutting a new one that says why.
#
# Each repeatable flag replaces its section wholesale. Merge semantics would need
# a rule for ordering and de-duplication, and "what you passed is what it says"
# needs no rule at all.
# ---------------------------------------------------------------------------

# section_file <text> -> a temp file holding it verbatim, for awk to read back.
# Passing a section body through `awk -v` runs it through awk's escape
# processing, so a criterion containing a backslash would be silently altered on
# the way in. A file is read byte for byte.
section_file() {
  local f; f=$(ps_tempfile)
  printf '%s\n' "$1" >"$f"
  printf '%s' "$f"
}

cmd_amend() {
  wo_require_jq; require_id
  local file; file=$(wo_find "$project" "$id")
  wo_require_status "$file" draft

  ((${#in_items[@]})) || ((${#out_items[@]})) || ((${#ac_items[@]})) \
    || [[ -n $title || -n $problem || -n $test_plan ]] \
    || ps_die "$PS_USAGE" "nothing_to_do" \
      "amend needs one of --title, --problem, --in, --out, --ac, --test-plan"

  # The Out list may be replaced but never emptied, for the same reason `new`
  # requires one: a ticket with no non-goals is a ticket an agent may wander out
  # of, and an amend is exactly when somebody is tempted to drop them.
  local o kept=0
  for o in "${out_items[@]+"${out_items[@]}"}"; do
    [[ -n $(ps_sanitize_line "$o") ]] && kept=$((kept + 1))
  done
  if ((${#out_items[@]})) && ((kept == 0)); then
    ps_die "$PS_VALIDATION" "no_non_goals" \
      "--out was passed with nothing in it: an amend may replace the non-goals, never empty them"
  fi

  local body; body=$(wo_body "$file")
  # A section that is not there cannot be replaced, and a silent no-op reported as
  # ok is the failure mode this whole script is written against.
  if ((${#in_items[@]})) && ! printf '%s\n' "$body" | grep -q '^\*\*In\*\*[[:space:]]*$'; then
    ps_die "$PS_VALIDATION" "section_missing" "$id has no **In** block to replace"
  fi
  if ((${#out_items[@]})) && ! printf '%s\n' "$body" | grep -q '^\*\*Out - non-goals\*\*[[:space:]]*$'; then
    ps_die "$PS_VALIDATION" "section_missing" "$id has no **Out - non-goals** block to replace"
  fi
  if ((${#ac_items[@]})) && ! printf '%s\n' "$body" | grep -q '^## Acceptance criteria[[:space:]]*$'; then
    ps_die "$PS_VALIDATION" "section_missing" "$id has no ## Acceptance criteria section to replace"
  fi
  if [[ -n $problem ]] && ! printf '%s\n' "$body" | grep -q '^## Problem[[:space:]]*$'; then
    ps_die "$PS_VALIDATION" "section_missing" "$id has no ## Problem section to replace"
  fi
  if [[ -n $test_plan ]] && ! printf '%s\n' "$body" | grep -q '^## Test plan[[:space:]]*$'; then
    ps_die "$PS_VALIDATION" "section_missing" "$id has no ## Test plan section to replace"
  fi

  # Every section is built by the same helpers `new` uses, so an amended ticket
  # and a freshly minted one are the same bytes for the same inputs.
  local f_title="" f_problem="" f_in="" f_out="" f_ac="" f_test=""
  local safe_title=""
  if [[ -n $title ]]; then
    safe_title=$(ps_sanitize_line "$title")
    [[ -n $safe_title ]] || ps_die "$PS_USAGE" "required_empty" "--title is required and must not be empty"
    f_title="# $id - $safe_title"
  fi
  [[ -n $problem ]] && f_problem=$(section_file "$(ps_sanitize_line "$problem")")
  ((${#in_items[@]})) && f_in=$(section_file "$(bullets "- " "${in_items[@]}")")
  ((${#out_items[@]})) && f_out=$(section_file "$(bullets "- " "${out_items[@]}")")
  [[ -n $test_plan ]] && f_test=$(section_file "$(printf '```sh\n%s\n```' "$(ps_sanitize_line "$test_plan")")")

  if ((${#ac_items[@]})); then
    # A wireframe-derived frozen block is carried through untouched: it is
    # derived from build-plan.json and checksummed against it, so it is not the
    # caller's to replace. --ac replaces the human criteria beneath it.
    local criteria hn=0 a
    criteria=$(printf '%s\n' "$body" | awk -v s="$WO_FROZEN_START" -v e="$WO_FROZEN_END" '
      index($0, s) == 1 { f = 1 }
      f { print }
      index($0, e) == 1 { f = 0 }')
    for a in "${ac_items[@]}"; do
      hn=$((hn + 1))
      [[ -n $criteria ]] && criteria+=$'\n'
      criteria+="- [ ] \`AC-H${hn}\` *(human)* $(ps_sanitize_line "$a")"
    done
    f_ac=$(section_file "$criteria")
  fi

  local tmp; tmp=$(ps_tempfile)
  {
    printf -- '---\n'
    wo_fm "$file"
    printf -- '---\n'
    printf '%s\n' "$body" | awk \
      -v h1="$f_title" -v problem="$f_problem" -v inb="$f_in" -v outb="$f_out" \
      -v ac="$f_ac" -v testp="$f_test" '
      function emit(f,   line) { while ((getline line < f) > 0) print line; close(f) }
      {
        # A replaced section runs to the next heading. **In** and **Out** are
        # sub-blocks of one heading, so they end at the next bold line too.
        if (skip) {
          if ($0 ~ /^## / || (stopsub && $0 ~ /^\*\*/)) { skip = 0; stopsub = 0 }
          else next
        }
        if (h1 != "" && !titled && /^#[[:space:]]/) { print h1; titled = 1; next }
        if (problem != "" && /^## Problem[[:space:]]*$/) {
          print; print ""; emit(problem); print ""; skip = 1; next }
        if (ac != "" && /^## Acceptance criteria[[:space:]]*$/) {
          print; print ""; emit(ac); print ""; skip = 1; next }
        if (testp != "" && /^## Test plan[[:space:]]*$/) {
          print; print ""; emit(testp); print ""; skip = 1; next }
        if (inb != "" && /^\*\*In\*\*[[:space:]]*$/) {
          print; print ""; emit(inb); print ""; skip = 1; stopsub = 1; next }
        if (outb != "" && /^\*\*Out - non-goals\*\*[[:space:]]*$/) {
          print; print ""; emit(outb); print ""; skip = 1; stopsub = 1; next }
        print
      }'
  } >"$tmp"
  render_guard "$tmp"
  ps_atomic_install "$tmp" "$file"

  # The title lives in three places - the H1, the frontmatter and INDEX.md - and
  # the slug in a fourth. The first three are rewritten here; the slug and the
  # file name are minted once by `new` and left alone, because renaming a file an
  # agent may already have been handed is a worse trade than a slug that reads a
  # little old.
  if [[ -n $safe_title ]]; then
    wo_fm_set "$file" '.title=$t | .updated=$d' --arg t "$safe_title" --arg d "$(ps_today)"
  else
    wo_fm_set "$file" '.updated=$d' --arg d "$(ps_today)"
  fi
  reindex
  emit_ok "$id" draft "$file"
}

# ---------------------------------------------------------------------------
# transitions
# ---------------------------------------------------------------------------

cmd_approve() {
  wo_require_jq; require_id
  local file; file=$(wo_find "$project" "$id")
  wo_require_status "$file" draft

  local body; body=$(wo_body "$file")
  if printf '%s' "$body" | grep -q '^- \[ \] '; then
    if printf '%s' "$body" | awk '/^## Open questions/{f=1;next} /^## /{f=0} f' | grep -q '^- \[ \] '; then
      ps_die "$PS_VALIDATION" "open_questions" \
        "unchecked Open questions block approval - resolve them or delete them"
    fi
  fi
  printf '%s' "$body" | grep -q '`AC-' || ps_die "$PS_VALIDATION" "no_criteria" \
    "ticket has no acceptance criteria"

  local approval
  if ((no_lavish)); then
    ps_require_value reason "$reason"
    approval=$(jq -n --arg r "$reason" --arg d "$(ps_today)" \
      '{via:"override", reason:$r, at:$d}')
    ps_warn "approved without Lavish review: $reason"
  else
    command -v lavish-axi >/dev/null 2>&1 || ps_die "$PS_IO" "lavish_missing" \
      "lavish-axi not found. Review in Lavish, or pass --no-lavish --reason '...' to record the exception."
    approval=$(jq -n --arg d "$(ps_today)" '{via:"lavish", at:$d}')
  fi

  wo_fm_set "$file" \
    '.status="ready" | .updated=$d | .approval=$a' \
    --arg d "$(ps_today)" --argjson a "$approval"
  reindex
  emit_ok "$id" ready "$file"
}

cmd_start() {
  wo_require_jq; require_id
  local file; file=$(wo_find "$project" "$id")
  # Ticket state before environment: telling someone "not a git repo" when the
  # real problem is "this is still a draft" sends them down the wrong path.
  wo_require_status "$file" ready
  wo_require_git "$project"

  git -C "$project" diff --quiet && git -C "$project" diff --cached --quiet \
    || ps_die "$PS_VALIDATION" "dirty_tree" "working tree is dirty - commit or stash first"

  local slug branch; slug=$(wo_field "$file" '.slug')
  branch="feat/${slug}"
  git -C "$project" rev-parse --verify "$branch" >/dev/null 2>&1 \
    && ps_die "$PS_VALIDATION" "branch_exists" "branch $branch already exists"

  git -C "$project" checkout -b "$branch" >/dev/null 2>&1 \
    || ps_die "$PS_IO" "checkout_failed" "could not create branch $branch"

  wo_fm_set "$file" '.status="in-progress" | .branch=$b | .updated=$d' \
    --arg b "$branch" --arg d "$(ps_today)"
  reindex
  emit_ok "$id" in-progress "$file"
}

cmd_submit() {
  wo_require_jq; wo_require_gh; require_id
  ps_require_value pr "$pr"
  [[ $pr =~ ^[0-9]+$ ]] || ps_die "$PS_USAGE" "bad_pr" "--pr must be a number (got: $pr)"
  local file; file=$(wo_find "$project" "$id")
  wo_require_status "$file" in-progress

  gh pr view "$pr" --json number >/dev/null 2>&1 \
    || ps_die "$PS_NOTFOUND" "pr_not_found" "gh cannot see PR #$pr"

  wo_fm_set "$file" '.status="in-review" | .pr=($p|tonumber) | .updated=$d' \
    --arg p "$pr" --arg d "$(ps_today)"
  reindex
  emit_ok "$id" in-review "$file"
}

# `done` is written on the feature branch at context-compaction time, before the
# PR lands. That is a deliberate call: it means a rejected PR leaves a ticket
# claiming done, which is what `reopen` exists to correct.
cmd_done() {
  wo_require_jq; require_id
  local file; file=$(wo_find "$project" "$id")
  wo_require_status "$file" in-review

  local body; body=$(wo_body "$file")
  printf '%s' "$body" | awk '/^## Acceptance criteria/{f=1;next} /^## /{f=0} f' \
    | grep -q '^- \[ \] ' && ps_die "$PS_VALIDATION" "unchecked_criteria" \
    "acceptance criteria still unchecked - record each one with:
  work-order.sh evidence --id $id --index N --observed 'what was seen'
A criterion that was not observed is not met, and this refusal is the point."

  wo_fm_set "$file" '.status="done" | .updated=$d' --arg d "$(ps_today)"
  reindex
  ps_info "status: done. CONTEXT_STATE.md should be updated in this same commit."
  emit_ok "$id" done "$file"
}

cmd_reopen() {
  wo_require_jq; require_id
  ps_require_value reason "$reason"
  local file; file=$(wo_find "$project" "$id")
  wo_require_status "$file" done
  wo_is_archived "$file" && ps_die "$PS_VALIDATION" "already_archived" \
    "$id is archived; reopening a closed-out ticket is a new work-order"

  wo_fm_set "$file" \
    '.status="in-progress" | .merge_sha=null | .closed=null | .updated=$d
     | .reopened=((.reopened // []) + [{at:$d, reason:$r}])' \
    --arg d "$(ps_today)" --arg r "$reason"
  reindex
  emit_ok "$id" in-progress "$file"
}

# ---------------------------------------------------------------------------
# close - the only command that touches git history. Every fact is discovered,
# never accepted from the caller.
# ---------------------------------------------------------------------------

# The branch the caller stood on when close started, and the trap that puts them
# back. close checks out main and then cuts close-out/<id>, so every refusal
# after that point used to end with the caller somewhere they never asked to be -
# which is how a failed close turns into a lost afternoon rather than a retry.
WO_CLOSE_RETURN=""

# close_restore_branch - EXIT/INT/TERM hook. Only acts on a failure: finishing on
# main is the correct end state once the archive has landed, so a clean run is
# left exactly where it stopped.
close_restore_branch() {
  local rc=$? cur back
  ((rc == 0)) && return 0
  [[ -n $WO_CLOSE_RETURN ]] || return 0
  cur=$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null) || cur=""
  back="$WO_CLOSE_RETURN"
  # Phase 1 deletes the feature branch deliberately, and close is normally run
  # from it. Recreating it here would undo the one thing phase 1 got right, so
  # when the branch the caller started on is the branch that just went, main is
  # the honest answer: it is where their work lives now.
  if ! git -C "$project" rev-parse --verify --quiet "$back" >/dev/null 2>&1; then
    back=main
    ps_warn "$WO_CLOSE_RETURN was deleted by phase 1 - leaving you on main instead"
  fi
  [[ $cur == "$back" ]] && return 0
  # --force is safe here and nowhere else: close refuses a dirty tree before it
  # touches anything, so the only uncommitted work at this point is close's own
  # half-finished archive move, and carrying that back onto the caller's branch
  # would be worse than dropping it.
  git -C "$project" checkout --force "$back" >/dev/null 2>&1 \
    || ps_warn "could not return you to $back - you are on ${cur:-a detached HEAD}"
  return 0
}

# gh_in_project - gh infers the repository from the working directory, and every
# other fact in this command is read from $project. A write aimed at whatever
# repository the caller happened to be standing in is not a risk worth taking.
gh_in_project() { (cd -- "$project" && gh "$@"); }

cmd_close() {
  wo_require_jq; wo_require_git "$project"; wo_require_gh; require_id
  local file; file=$(wo_find "$project" "$id")
  wo_require_status "$file" done
  wo_is_archived "$file" && ps_die "$PS_VALIDATION" "already_archived" "$id is already archived"

  local branch pr_num state sha
  branch=$(wo_field "$file" '.branch')
  pr_num=$(wo_field "$file" '.pr')
  [[ -n $pr_num ]] || ps_die "$PS_VALIDATION" "no_pr" "$id has no PR recorded - run submit first"

  state=$(gh_in_project pr view "$pr_num" --json state -q .state 2>/dev/null) \
    || ps_die "$PS_IO" "gh_failed" "gh could not read PR #$pr_num"
  sha=$(gh_in_project pr view "$pr_num" --json mergeCommit -q '.mergeCommit.oid // ""' 2>/dev/null)

  # The whole point of this command.
  [[ $state == MERGED ]] || ps_die "$PS_VALIDATION" "pr_not_merged" \
    "PR #$pr_num reports state=$state, not MERGED - refusing to delete anything"
  [[ -n $sha ]] || ps_die "$PS_VALIDATION" "no_merge_commit" \
    "PR #$pr_num is MERGED but has no merge commit - refusing"

  local year archive_dir dest
  year=$(ps_today); year="${year%%-*}"
  archive_dir="$root/archive/$year"
  dest="$archive_dir/$(basename -- "$file")"

  if ((dry_run)); then
    cat <<EOF
DRY RUN - nothing will be executed

  ticket    $id  ($file)
  branch    ${branch:-<none recorded>}
  PR        #$pr_num
  gh state  $state          <- must be MERGED
  merge sha $sha

  phase 1   git fetch --prune; checkout main; merge --ff-only origin/main
            git branch -D ${branch:-<none>}; git push origin --delete ${branch:-<none>}
  phase 2   on main: backfill merge_sha + closed; archive to ${archive_dir#"$project"/}/
            regenerate INDEX.md; commit; push origin main
            ONE pull request per ticket - this is bookkeeping after #$pr_num merged
  fallback  only if that push is rejected (protected main, or origin moved):
            peel onto close-out/$id, reset main, PR it, merge, clean up

  assertions passed: status=done, not archived, PR MERGED, merge commit present
EOF
    exit "$PS_OK"
  fi

  git -C "$project" diff --quiet && git -C "$project" diff --cached --quiet \
    || ps_die "$PS_VALIDATION" "dirty_tree" "working tree is dirty - refusing"

  # Remember where the caller stood, and arm the trap before the first checkout.
  # ps_scratch_init is called first on purpose: it installs the cleanup traps
  # lazily on the first temp file, and doing that after this point would silently
  # replace the handler below with one that no longer restores the branch.
  ps_scratch_init
  WO_CLOSE_RETURN=$(git -C "$project" symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || WO_CLOSE_RETURN=""
  trap 'close_restore_branch; ps_cleanup' EXIT
  trap 'close_restore_branch; ps_cleanup; trap - INT; kill -INT $$' INT
  trap 'close_restore_branch; ps_cleanup; trap - TERM; kill -TERM $$' TERM

  # phase 1
  git -C "$project" fetch origin --prune >/dev/null 2>&1
  git -C "$project" checkout main >/dev/null 2>&1 \
    || ps_die "$PS_IO" "checkout_failed" "cannot check out main"
  git -C "$project" merge --ff-only origin/main >/dev/null 2>&1 \
    || ps_die "$PS_VALIDATION" "main_diverged" "main cannot fast-forward to origin/main"

  # Checking out main swapped the ticket for main's copy of it. The status
  # verified before the checkout says nothing about the file we now hold, and a
  # PR that gh calls MERGED whose ticket never reached done on main means the
  # two disagree. Refuse rather than stamp a merge SHA onto the wrong state.
  # The refusal names the actual cause rather than the raw status. A caller who
  # just watched the ticket say `done` on the feature branch reads
  # "status is 'in-review'" as the script being wrong, and goes looking in the
  # wrong place; what it means is that the commit carrying the transition has
  # not reached main.
  file=$(wo_find "$project" "$id")
  local main_status; main_status=$(wo_field "$file" '.status')
  [[ $main_status == done ]] || ps_die "$PS_VALIDATION" "done_not_merged" \
    "$id reached done on the feature branch, but main's copy still says '$main_status': the PR carrying that transition has not merged to main yet. Merge it first, then run close again."
  if [[ -n $branch ]]; then
    git -C "$project" branch -D "$branch" >/dev/null 2>&1 || true
    git -C "$project" push origin --delete "$branch" >/dev/null 2>&1 || true
  fi

  # phase 2 - the bookkeeping, committed straight to main.
  #
  # This used to cut a close-out/<id> branch, open a PR for it and merge that
  # PR. It produced a second pull request for every ticket whose entire content
  # was a file move and a regenerated index, which doubles the review surface
  # for one piece of work and buys nothing: close cannot run at all until the
  # ticket's own PR is MERGED and main's copy says done, both asserted above.
  # So the record follows the work directly onto main.
  #
  # The branch-and-PR route survives as a fallback for a repository that
  # protects main. It is a fallback, not a mode: nothing chooses it, a rejected
  # push does.
  mkdir -p "$archive_dir"
  # Assigning the same SHA and date twice is a no-op, so this needs no guard.
  # Moving a file onto itself is not, so the move does: a previous attempt may
  # already have landed the archive on main.
  wo_fm_set "$file" '.merge_sha=$s | .closed=$d | .updated=$d' \
    --arg s "$sha" --arg d "$(ps_today)"
  if [[ $file != "$dest" ]]; then
    [[ -e $dest ]] && ps_die "$PS_VALIDATION" "path_collision" \
      "$dest already exists and is not this ticket's file - resolve it by hand"
    git -C "$project" mv "$file" "$dest" >/dev/null 2>&1 || mv -- "$file" "$dest"
  fi
  # An epic archived after its last child leaves would otherwise hold an empty
  # directory open with nothing but its own generated README inside it.
  prune_dir "$(dirname -- "$file")"
  reindex
  archive_readmes
  git -C "$project" add -A "$root" >/dev/null 2>&1

  if git -C "$project" diff --cached --quiet; then
    # Nothing staged means main already carries this exact archive - an earlier
    # attempt landed it and died afterwards. Nothing to commit, nothing to push.
    ps_warn "$id is already archived on main - nothing left to commit"
  else
    git -C "$project" commit -m "chore($id): close out and archive" >/dev/null 2>&1 \
      || ps_die "$PS_IO" "commit_failed" "nothing to commit for $id"

    if git -C "$project" push origin main >/dev/null 2>&1; then
      : # done - one pull request for this ticket, which is the whole point
    else
      # Either main is protected or origin moved under us. Peel the commit onto
      # a branch, put main back where it was, and go round through a PR.
      ps_warn "cannot push to main directly - falling back to a close-out PR"
      local cob="close-out/$id"
      # -B, not -b: reuse and reset a branch an earlier attempt abandoned.
      git -C "$project" branch -f "$cob" HEAD >/dev/null 2>&1 \
        || ps_die "$PS_IO" "branch_failed" "cannot create $cob"
      git -C "$project" reset --hard origin/main >/dev/null 2>&1 \
        || ps_die "$PS_IO" "reset_failed" "cannot restore main after a rejected push"
      git -C "$project" checkout "$cob" >/dev/null 2>&1 \
        || ps_die "$PS_IO" "checkout_failed" "cannot check out $cob"
      git -C "$project" push -u --force-with-lease origin "$cob" >/dev/null 2>&1 \
        || ps_die "$PS_IO" "push_failed" \
          "cannot push $cob - origin moved since the fetch in phase 1. Run close again."

      # An earlier attempt may have opened the PR and then failed to merge it,
      # and gh refuses a second PR for the same branch. Ask first.
      local co_pr
      co_pr=$(gh_in_project pr list --head "$cob" --state open --json number \
        -q '.[0].number // ""' 2>/dev/null) || co_pr=""
      if [[ -n $co_pr ]]; then
        ps_info "reusing close-out PR #$co_pr, left open by an earlier attempt"
      else
        gh_in_project pr create --base main --head "$cob" \
          --title "chore($id): close out and archive" \
          --body "Archives $id after PR #$pr_num merged as $sha. Generated by work-order.sh close, because a direct push to main was rejected." \
          >/dev/null 2>&1 \
          || ps_die "$PS_IO" "pr_create_failed" \
            "could not open the close-out PR for $cob. Nothing is lost: the branch is pushed and close is safe to re-run."
      fi
      gh_in_project pr merge "$cob" --squash --delete-branch >/dev/null 2>&1 \
        || ps_die "$PS_IO" "pr_merge_failed" \
          "the close-out PR for $cob is open but would not merge. Clear whatever is blocking it and run close again."

      git -C "$project" fetch origin --prune >/dev/null 2>&1 || true
      git -C "$project" checkout main >/dev/null 2>&1 \
        || ps_die "$PS_IO" "checkout_failed" "cannot check out main after merging $cob"
      git -C "$project" merge --ff-only origin/main >/dev/null 2>&1 \
        || ps_die "$PS_VALIDATION" "main_diverged" \
          "$cob merged, but main cannot fast-forward - reconcile main by hand"
      git -C "$project" branch -D "$cob" >/dev/null 2>&1 || true
    fi
  fi

  emit_ok "$id" done "$dest"
}

# ---------------------------------------------------------------------------
# cancel - the other terminal state.
#
# Before this verb, a ticket that was never going to be built could only leave
# the active tree through `close`, which demands a branch, a merged PR and an
# observation against every acceptance criterion. Nobody produces that for work
# that was abandoned, so the ticket sat in the index forever or was deleted by
# hand - and a deleted ticket takes the reason with it.
#
# It touches no git history at all: no branch, no PR, no merge. It moves the file
# and reindexes, and leaves the result staged for the caller to commit inside
# whatever change explains the cancellation. That asymmetry with `close` is
# deliberate: close has to prove something about main, cancel has nothing to
# prove, and a verb that opens a PR to record "we are not doing this" would be
# ceremony charged for nothing.
# ---------------------------------------------------------------------------

cmd_cancel() {
  wo_require_jq; require_id
  ps_require_value reason "$reason"
  local file; file=$(wo_find "$project" "$id")

  if wo_is_archived "$file"; then
    ps_die "$PS_VALIDATION" "already_archived" \
      "$id is archived - a ticket that already left the active tree is not cancelled again"
  fi
  local cur; cur=$(wo_field "$file" '.status')
  if [[ $cur == cancelled ]]; then
    ps_die "$PS_VALIDATION" "already_cancelled" "$id was already cancelled"
  fi
  if [[ $cur == done ]]; then
    ps_die "$PS_VALIDATION" "done_not_cancellable" \
      "$id is done - work that finished is closed out with 'close', never cancelled. Use 'reopen' first if it turns out it was not finished."
  fi
  wo_require_status "$file" draft ready in-progress in-review

  if [[ -n $superseded_by ]]; then
    require_edge_target superseded-by "$superseded_by"
    [[ $superseded_by == "$id" ]] && ps_die "$PS_VALIDATION" "self_edge" \
      "$id cannot supersede itself"
  fi

  # The Outcome block is where a reader lands when they follow a stale pointer to
  # this ticket, so it has to answer "why is there nothing here" on its own.
  local stamp block tmp
  stamp=$(ps_today)
  block=$(
    printf 'Cancelled `%s` - nothing shipped.\n\n' "$stamp"
    printf -- '- reason: %s\n' "$(ps_sanitize_line "$reason")"
    if [[ -n $superseded_by ]]; then
      printf -- '- superseded by: `%s`\n' "$superseded_by"
    fi
    printf '\nNo branch, no PR and no merge commit exist for this work order.\n'
  )

  tmp=$(ps_tempfile)
  {
    printf -- '---\n'
    wo_fm "$file"
    printf -- '---\n'
    wo_body "$file" | awk -v block="$block" '
      BEGIN { placed = 0; skip = 0 }
      skip && /^## / { skip = 0 }
      skip { next }
      /^## Outcome[[:space:]]*$/ {
        print; print ""; print block; print ""
        placed = 1; skip = 1; next
      }
      { print }
      END { if (!placed) { print ""; print "## Outcome"; print ""; print block } }
    '
  } >"$tmp"
  ps_atomic_install "$tmp" "$file"

  # The reason is prose in `## Outcome`, but "what replaced this" is a fact the
  # graph should be able to answer without reading English, so it is a field too.
  wo_fm_set "$file" \
    '.status="cancelled" | .closed=$d | .updated=$d
     | .superseded_by=(if $s == "" then null else $s end)' \
    --arg d "$stamp" --arg s "$superseded_by"

  # Archived exactly where close files a ticket, because the question a reader
  # asks later is "where did this ticket go", and one answer is easier to hold
  # than two.
  local year archive_dir dest
  year="${stamp%%-*}"
  archive_dir="$root/archive/$year"
  mkdir -p "$archive_dir" || ps_die "$PS_IO" "mkdir_failed" "cannot create $archive_dir"
  dest="$archive_dir/$(basename -- "$file")"
  [[ -e $dest ]] && ps_die "$PS_VALIDATION" "path_collision" "$dest already exists"
  wo_git_mv "$file" "$dest"
  prune_dir "$(dirname -- "$file")"
  reindex
  archive_readmes

  ps_info "nothing was committed - 'git add' the move and commit it with the change that explains it"
  emit_ok "$id" cancelled "$dest"
}

# ---------------------------------------------------------------------------
# link - edges after the fact, because a set of sibling tickets cannot all
# reference each other at mint time. Refuses every cycle it can detect.
# ---------------------------------------------------------------------------

# dep_reaches <from-id> <target-id> - 0 when target is reachable from `from` by
# following depends_on. Used to refuse an edge that would close a loop.
dep_reaches() {
  local target="$2" cur f d
  local -a queue=("$1")
  local -A seen=()
  while ((${#queue[@]})); do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    if [[ -n ${seen[$cur]:-} ]]; then continue; fi
    seen[$cur]=1
    if [[ $cur == "$target" ]]; then return 0; fi
    if ! wo_exists "$project" "$cur"; then continue; fi
    f=$(wo_find "$project" "$cur")
    while IFS= read -r d; do
      if [[ -n $d ]]; then queue+=("$d"); fi
    done < <(wo_fm "$f" | jq -r '(.depends_on // [])[]')
  done
  return 1
}

# ---------------------------------------------------------------------------
# Layout. A parentless ticket lives inside the directory named for it, and a
# child lives in its parent's directory. Promotion is what keeps the second rule
# true for a ticket minted as a leaf that later grows children.
# ---------------------------------------------------------------------------

# wo_git_mv <src> <dest> - git mv when the path is tracked, plain mv otherwise,
# so the layout can be repaired in a working tree that is not yet a repository.
wo_git_mv() {
  git -C "$project" mv "$1" "$2" >/dev/null 2>&1 || mv -- "$1" "$2" \
    || ps_die "$PS_IO" "move_failed" "cannot move $1 to $2"
}

# prune_dir <dir> - drop a directory that holds nothing but its own generated
# README, which would otherwise hold an empty folder open forever.
prune_dir() {
  local d="$1"
  [[ -d $d && $d != "$root" ]] || return 0
  if [[ -f $d/README.md ]] \
    && [[ -z $(find "$d" -mindepth 1 -maxdepth 1 ! -name README.md -print -quit) ]]; then
    git -C "$project" rm -q -f "$d/README.md" >/dev/null 2>&1 || rm -f -- "$d/README.md"
  fi
  rmdir -p --ignore-fail-on-non-empty "$d" 2>/dev/null || true
}

# promote <file> -> the directory this ticket owns, after moving its own file
# inside it. Idempotent: a ticket already sitting in its own directory is
# returned untouched, so every caller may promote without checking first.
promote() {
  local f="$1" own fname
  own=$(wo_own_dir "$f")
  mkdir -p "$own" || ps_die "$PS_IO" "mkdir_failed" "cannot create $own"
  if wo_owns_dir "$f"; then printf '%s' "$own"; return 0; fi
  fname=$(basename -- "$f")
  [[ -e $own/$fname ]] && ps_die "$PS_VALIDATION" "path_collision" "$own/$fname already exists"
  wo_git_mv "$f" "$own/$fname"
  printf '%s' "$own"
}

# child_home <parent-id> -> the directory a child of that ticket belongs in.
# Promotes the parent first, so a leaf gaining its first child becomes an epic
# with a folder rather than leaving the child stranded beside it.
child_home() { promote "$(wo_find "$project" "$1")"; }

# desired_dir <id> -> the directory this ticket's own file belongs in.
#
# A ticket owns the directory named for it in exactly two cases: it has children,
# or it has no parent and so must be a directory at the top level. Everything
# else is a leaf - a plain file in its parent's directory, with no folder and no
# generated README of its own.
#
# Derived rather than remembered: a ticket that gains its first child is promoted
# into a folder, and one that loses its last is demoted back out. Ownership that
# persisted after the last child left would leave a folder holding one file and a
# README listing nothing, which is the clutter this layout exists to avoid.
#
# Requires a loaded graph.
desired_dir() {
  local gid="$1" base
  if [[ -z ${G_PARENT[$gid]} ]]; then
    base="$root"
  else
    base=$(desired_dir "${G_PARENT[$gid]}")
  fi
  if [[ -z ${G_PARENT[$gid]} || -n $(g_kids "$gid") ]]; then
    printf '%s/%s' "$base" "$gid"
  else
    printf '%s' "$base"
  fi
}

# owns_dir_by_graph <id> - 0 when the ticket is entitled to its own directory.
owns_dir_by_graph() {
  [[ -z ${G_PARENT[$1]} || -n $(g_kids "$1") ]]
}

# place_all -> "<before>\t<after>" for every ticket the layout rule moved.
#
# Shallowest first, so a parent's directory exists before its children move into
# it and an emptied directory is pruned only once the last child has left. Every
# ticket is moved as a single file rather than as a folder: the folder is not the
# unit of the move, it is a consequence of having children, and moving files one
# at a time means a demotion and a promotion in the same pass cannot fight.
#
# Requires a loaded graph.
place_all() {
  local gid depth f cur want dest
  local -a plan=()
  for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
    g_archived "$gid" && continue
    depth=$(wo_ancestors "$project" "$gid" | wc -l)
    plan+=("$(printf '%04d\t%s' "$depth" "$gid")")
  done
  ((${#plan[@]})) || return 0

  while IFS=$'\t' read -r depth gid; do
    [[ -n $gid ]] || continue
    f=$(wo_find "$project" "$gid")
    cur=$(dirname -- "$f")
    want=$(desired_dir "$gid")
    [[ $cur == "$want" ]] && continue
    dest="$want/$(basename -- "$f")"
    [[ -e $dest ]] && ps_die "$PS_VALIDATION" "path_collision" "$dest already exists"
    mkdir -p "$want" || ps_die "$PS_IO" "mkdir_failed" "cannot create $want"
    wo_git_mv "$f" "$dest"
    prune_dir "$cur"
    printf '%s\t%s\n' "${f#"$project"/}" "${dest#"$project"/}"
  done < <(printf '%s\n' "${plan[@]}" | sort -n)
}

cmd_link() {
  wo_require_jq; require_id
  local file; file=$(wo_find "$project" "$id")
  ((detach)) && [[ -n $parent ]] && ps_die "$PS_USAGE" "conflicting_flags" \
    "--parent and --detach are opposites - pass one"
  ((detach)) || [[ -n $parent ]] || ((${#dep_items[@]})) || ((${#block_items[@]})) \
    || ((${#no_dep_items[@]})) || ((${#no_block_items[@]})) \
    || ps_die "$PS_USAGE" "nothing_to_do" \
      "link needs one of --parent, --detach, --depends-on, --blocks, --no-depends-on, --no-blocks"

  # --detach removes the parent edge and nothing else, but it reads like a
  # modifier - and `link --detach --depends-on B` used to detach the parent while
  # quietly ADDING the dependency the caller was trying to drop. Removal now has
  # its own flags, so the ambiguous pairing is refused rather than guessed at.
  if ((detach)) && { ((${#dep_items[@]})) || ((${#block_items[@]})); }; then
    ps_die "$PS_USAGE" "conflicting_flags" \
      "--detach removes the parent only; alongside --depends-on/--blocks it would add the very edge you meant to drop. Use --no-depends-on/--no-blocks to remove one, or run the two links separately."
  fi

  # Adding and removing the same edge in one run is refused rather than resolved
  # by ordering: whichever way the loops happened to run would be the answer, and
  # that is a coin toss with a permanent result.
  local a b
  for a in "${dep_items[@]+"${dep_items[@]}"}"; do
    for b in "${no_dep_items[@]+"${no_dep_items[@]}"}"; do
      [[ $a == "$b" ]] && ps_die "$PS_USAGE" "conflicting_flags" \
        "--depends-on $a and --no-depends-on $a in the same run - pass one"
    done
  done
  for a in "${block_items[@]+"${block_items[@]}"}"; do
    for b in "${no_block_items[@]+"${no_block_items[@]}"}"; do
      [[ $a == "$b" ]] && ps_die "$PS_USAGE" "conflicting_flags" \
        "--blocks $a and --no-blocks $a in the same run - pass one"
    done
  done

  local e
  for e in "${dep_items[@]+"${dep_items[@]}"}"; do
    require_edge_target depends-on "$e"
    [[ $e == "$id" ]] && ps_die "$PS_VALIDATION" "self_edge" "$id cannot depend on itself"
    dep_reaches "$e" "$id" && ps_die "$PS_VALIDATION" "dependency_cycle" \
      "$id already blocks $e, so depending on it would close a loop"
    add_edge "$id" depends_on "$e"
    add_edge "$e" blocks "$id"
  done
  for e in "${block_items[@]+"${block_items[@]}"}"; do
    require_edge_target blocks "$e"
    [[ $e == "$id" ]] && ps_die "$PS_VALIDATION" "self_edge" "$id cannot block itself"
    dep_reaches "$id" "$e" && ps_die "$PS_VALIDATION" "dependency_cycle" \
      "$id already depends on $e, so blocking it would close a loop"
    add_edge "$id" blocks "$e"
    add_edge "$e" depends_on "$id"
  done

  # Removals. An edge is written on both tickets, so it is removed from both -
  # a half-removed edge still blocks `next` from one side and is invisible from
  # the other, which is worse than never having removed it.
  #
  # Unlike an addition, a missing target is not refused. g_waiting already
  # reports a dependency whose ticket has gone as `missing`, and that dangling
  # edge is precisely what somebody would run this flag to clear; refusing it
  # would leave hand-editing the frontmatter as the only route, which is the one
  # thing this skill exists to prevent.
  for e in "${no_dep_items[@]+"${no_dep_items[@]}"}"; do
    wo_id_valid "$e" || ps_die "$PS_USAGE" "bad_id_format" \
      "--no-depends-on must look like WO-20260805-3f2a (got: $e)"
    del_edge "$id" depends_on "$e"
    if wo_exists "$project" "$e"; then del_edge "$e" blocks "$id"; fi
  done
  for e in "${no_block_items[@]+"${no_block_items[@]}"}"; do
    wo_id_valid "$e" || ps_die "$PS_USAGE" "bad_id_format" \
      "--no-blocks must look like WO-20260805-3f2a (got: $e)"
    del_edge "$id" blocks "$e"
    if wo_exists "$project" "$e"; then del_edge "$e" depends_on "$id"; fi
  done

  # Parent last: it is the one that moves the file, so every frontmatter write
  # above has already landed at a stable path.
  if ((detach)) || [[ -n $parent ]]; then
    local newp=""
    if [[ -n $parent ]]; then
      require_edge_target parent "$parent"
      [[ $parent == "$id" ]] && ps_die "$PS_VALIDATION" "self_edge" "$id cannot be its own parent"
      local a
      while IFS= read -r a; do
        [[ $a == "$id" ]] && ps_die "$PS_VALIDATION" "parent_cycle" \
          "$parent is already a descendant of $id"
      done < <(wo_ancestors "$project" "$parent")
      newp="$parent"
    fi
    wo_fm_set "$file" '.parent=(if $p == "" then null else $p end) | .updated=$d' \
      --arg p "$newp" --arg d "$(ps_today)"
    # Re-parenting can promote the new parent and demote the old one, so the
    # whole tree is re-placed rather than just this ticket. Every move is
    # derived from the parents on disk, so it converges in one pass.
    load_graph
    place_all >/dev/null
    file=$(wo_find "$project" "$id")
  fi

  reindex
  emit_ok "$id" "$(wo_field "$file" '.status')" "$file"
}

# ---------------------------------------------------------------------------
# note - the only way a progress note reaches a ticket. Append-only, newest
# first, same as ISSUES.md: an entry is never rewritten, so the record of what
# an agent believed at each point survives being wrong.
# ---------------------------------------------------------------------------

cmd_note() {
  wo_require_jq; require_id
  ps_require_value text "$text"
  local file; file=$(wo_find "$project" "$id")

  local entry tmp
  entry="- \`$(ps_today)\` $(ps_sanitize_line "$text")"
  tmp=$(ps_tempfile)
  {
    printf -- '---\n'
    wo_fm "$file"
    printf -- '---\n'
    wo_body "$file" | awk -v entry="$entry" '
      BEGIN { placed = 0; pending = 0 }
      # Existing Notes section. The entry lands above the previous newest one,
      # but below the heading and its explanatory line.
      !placed && /^## Notes[[:space:]]*$/ { print; pending = 1; next }
      pending {
        if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^_.*_[[:space:]]*$/) { print; next }
        print entry
        if ($0 ~ /^## /) { print "" }
        pending = 0; placed = 1
        print; next
      }
      # No Notes section yet: open one immediately above Outcome, so the
      # close-out summary stays the last thing in the file.
      !placed && /^## Outcome[[:space:]]*$/ {
        print "## Notes"; print ""; print entry; print ""; placed = 1
      }
      { print }
      END {
        if (pending) { print entry; placed = 1 }
        if (!placed) { print ""; print "## Notes"; print ""; print entry }
      }
    '
  } >"$tmp"
  ps_atomic_install "$tmp" "$file"
  wo_fm_set "$file" '.updated=$d' --arg d "$(ps_today)"

  if ((PS_JSON)); then
    printf '{"ok":true,"id":"%s","note":%s,"file":%s}\n' \
      "$id" "$(ps_json_string "$text")" "$(ps_json_string "$file")"
  else
    ps_info "$id note recorded"
  fi
}

# ---------------------------------------------------------------------------
# resolve - the verb that records a question's answer.
#
# `new --question` writes an unchecked box and `approve` refuses while any box in
# the Open questions block is unchecked. That gate is right: an unanswered
# question genuinely must not reach `ready`. What was missing was a verb that
# could record the answer, so a ticket minted with a question could only ever be
# freed by hand-editing the file - the one thing this skill exists to prevent.
#
# resolve is not a way to dismiss a question. `--answer` is mandatory and there is
# deliberately no --force, --skip or --all: a question closed with no recorded
# answer is indistinguishable from a deleted one, and it takes the audit trail
# with it. Anything that resolved without an answer would be the gate removed.
#
# It sits outside the status set, like `link` and `note`: it changes the record,
# never the state. So it cannot advance a ticket and no status blocks it.
# ---------------------------------------------------------------------------

# questions_of <file> -> "<open|resolved>\t<text>" per question, in file order.
#
# Resolved questions are numbered too. Numbering only the unresolved ones would
# renumber every later question each time one was answered, so a script that
# resolved 1 and then 2 would answer something nobody asked about.
questions_of() {
  wo_body "$1" | awk '
    /^## Open questions[[:space:]]*$/ { inq = 1; next }
    /^## / { inq = 0 }
    inq && /^- \[[ xX]\] / {
      printf "%s\t%s\n", (substr($0, 4, 1) == " " ? "open" : "resolved"), substr($0, 7)
    }'
}

cmd_resolve() {
  wo_require_jq; require_id
  ps_require_value answer "$answer"
  if [[ -z $index && -z $match ]]; then
    ps_die "$PS_USAGE" "no_selector" \
      "resolve needs --index N or --match TEXT to say which question was answered"
  fi
  if [[ -n $index && -n $match ]]; then
    ps_die "$PS_USAGE" "conflicting_flags" \
      "--index and --match are two ways to name the same question - pass one"
  fi

  local file; file=$(wo_find "$project" "$id")

  local -a states=() texts=()
  local st tx
  while IFS=$'\t' read -r st tx; do
    states+=("$st"); texts+=("$tx")
  done < <(questions_of "$file")

  local n=${#states[@]}
  ((n)) || ps_die "$PS_VALIDATION" "no_questions" \
    "$id has no Open questions - there is nothing to resolve"

  local pick=0
  if [[ -n $index ]]; then
    [[ $index =~ ^[0-9]+$ ]] || ps_die "$PS_USAGE" "bad_index" \
      "--index must be a whole number (got: $index)"
    ((index >= 1 && index <= n)) || ps_die "$PS_VALIDATION" "index_out_of_range" \
      "--index $index is out of range: $id has $n question(s)"
    pick=$index
  else
    # Ambiguity is refused, never resolved by picking the first hit. Guessing
    # which question was answered is precisely the nondeterminism this tool exists
    # to remove, and the wrong answer recorded under the wrong question is worse
    # than a refusal because it reads as though somebody decided it.
    local i needle hits=0
    needle="${match,,}"
    for ((i = 0; i < n; i++)); do
      if [[ ${texts[i],,} == *"$needle"* ]]; then hits=$((hits + 1)); pick=$((i + 1)); fi
    done
    ((hits)) || ps_die "$PS_VALIDATION" "match_no_hit" \
      "--match '$match' matches none of the $n question(s) on $id"
    ((hits == 1)) || ps_die "$PS_VALIDATION" "match_ambiguous" \
      "--match '$match' matches $hits questions on $id - name one with --index"
  fi

  [[ ${states[pick - 1]} == open ]] || ps_die "$PS_VALIDATION" "already_resolved" \
    "question $pick on $id is already resolved: ${texts[pick - 1]}"

  # The question text is copied through untouched and the answer is added beneath
  # it, so the ticket still says what was asked as well as what was decided.
  local stamp entry tmp
  stamp=$(ps_today)
  entry="  - answer \`$stamp\` $(ps_sanitize_line "$answer")"
  tmp=$(ps_tempfile)
  {
    printf -- '---\n'
    wo_fm "$file"
    printf -- '---\n'
    wo_body "$file" | awk -v pick="$pick" -v entry="$entry" '
      BEGIN { inq = 0; seen = 0 }
      /^## Open questions[[:space:]]*$/ { inq = 1; print; next }
      /^## / { inq = 0 }
      inq && /^- \[[ xX]\] / {
        seen++
        if (seen == pick) { print "- [x] " substr($0, 7); print entry; next }
      }
      { print }
    '
  } >"$tmp"
  ps_atomic_install "$tmp" "$file"
  wo_fm_set "$file" '.updated=$d' --arg d "$stamp"

  if ((PS_JSON)); then
    printf '{"ok":true,"id":"%s","question":%s,"index":%d,"answer":%s,"at":"%s","file":%s}\n' \
      "$id" "$(ps_json_string "${texts[pick - 1]}")" "$pick" \
      "$(ps_json_string "$answer")" "$stamp" "$(ps_json_string "$file")"
  else
    ps_info "$id question $pick resolved: ${texts[pick - 1]}"
  fi
}

criteria_of() {
  wo_body "$1" | awk '
    /^## Acceptance criteria[[:space:]]*$/ { inc = 1; next }
    /^## / { inc = 0 }
    inc && /^- \[[ xX]\] / {
      printf "%s\t%s\n", (substr($0, 4, 1) == " " ? "unmet" : "met"), substr($0, 7)
    }'
}

# The selector logic below is a deliberate mirror of cmd_resolve rather than a
# shared helper: every refusal names the thing it refused, and "criterion" and
# "question" are different nouns to the human reading the error. Factoring them
# together would trade a legible message for six saved lines.
cmd_evidence() {
  wo_require_jq; require_id
  ps_require_value observed "$observed"
  if [[ -z $index && -z $match ]]; then
    ps_die "$PS_USAGE" "no_selector" \
      "evidence needs --index N or --match TEXT to say which criterion was observed"
  fi
  if [[ -n $index && -n $match ]]; then
    ps_die "$PS_USAGE" "conflicting_flags" \
      "--index and --match are two ways to name the same criterion - pass one"
  fi

  local file; file=$(wo_find "$project" "$id")
  # Evidence is an observation of work in flight, so it is the one record verb
  # that a status does block. Without this, every criterion on a draft could be
  # ticked before a line was written and `done` would then pass with nothing ever
  # observed - the gate `done` relies on is only as good as when it may be met.
  wo_require_status "$file" in-progress in-review

  local -a states=() texts=()
  local st tx
  while IFS=$'\t' read -r st tx; do
    states+=("$st"); texts+=("$tx")
  done < <(criteria_of "$file")

  local n=${#states[@]}
  ((n)) || ps_die "$PS_VALIDATION" "no_criteria" \
    "$id has no Acceptance criteria - there is nothing to evidence"

  local pick=0
  if [[ -n $index ]]; then
    [[ $index =~ ^[0-9]+$ ]] || ps_die "$PS_USAGE" "bad_index" \
      "--index must be a whole number (got: $index)"
    ((index >= 1 && index <= n)) || ps_die "$PS_VALIDATION" "index_out_of_range" \
      "--index $index is out of range: $id has $n criterion(s)"
    pick=$index
  else
    local i needle hits=0
    needle="${match,,}"
    for ((i = 0; i < n; i++)); do
      if [[ ${texts[i],,} == *"$needle"* ]]; then hits=$((hits + 1)); pick=$((i + 1)); fi
    done
    ((hits)) || ps_die "$PS_VALIDATION" "match_no_hit" \
      "--match '$match' matches none of the $n criterion(s) on $id"
    ((hits == 1)) || ps_die "$PS_VALIDATION" "match_ambiguous" \
      "--match '$match' matches $hits criteria on $id - name one with --index"
  fi

  # Re-evidencing is refused rather than appended. Two observations under one
  # criterion is a ticket that cannot say which run proved it, and the second
  # one is nearly always a repeat of the command rather than a second proof.
  [[ ${states[pick - 1]} == unmet ]] || ps_die "$PS_VALIDATION" "already_evidenced" \
    "criterion $pick on $id is already evidenced: ${texts[pick - 1]}"

  local stamp entry tmp
  stamp=$(ps_today)
  entry="  - observed \`$stamp\` $(ps_sanitize_line "$observed")"
  tmp=$(ps_tempfile)
  {
    printf -- '---\n'
    wo_fm "$file"
    printf -- '---\n'
    wo_body "$file" | awk -v pick="$pick" -v entry="$entry" '
      BEGIN { inc = 0; seen = 0 }
      /^## Acceptance criteria[[:space:]]*$/ { inc = 1; print; next }
      /^## / { inc = 0 }
      inc && /^- \[[ xX]\] / {
        seen++
        if (seen == pick) { print "- [x] " substr($0, 7); print entry; next }
      }
      { print }
    '
  } >"$tmp"
  ps_atomic_install "$tmp" "$file"
  wo_fm_set "$file" '.updated=$d' --arg d "$stamp"

  if ((PS_JSON)); then
    printf '{"ok":true,"id":"%s","criterion":%s,"index":%d,"observed":%s,"at":"%s","file":%s}\n' \
      "$id" "$(ps_json_string "${texts[pick - 1]}")" "$pick" \
      "$(ps_json_string "$observed")" "$stamp" "$(ps_json_string "$file")"
  else
    ps_info "$id criterion $pick evidenced: ${texts[pick - 1]}"
  fi
}

# ---------------------------------------------------------------------------
# The graph, loaded once. Every read-only view below is a projection of it.
# ---------------------------------------------------------------------------

load_graph() {
  [[ -d $root ]] || ps_die "$PS_NOTFOUND" "no_work_orders" "no $WO_DIR_NAME/ in $project"
  unset G_STATUS G_TYPE G_PRI G_PARENT G_DEPS G_PATH G_TITLE G_IDS
  declare -gA G_STATUS G_TYPE G_PRI G_PARENT G_DEPS G_PATH G_TITLE
  declare -ga G_IDS=()
  local gid st ty pri par deps path title
  while IFS=$'\t' read -r gid st ty pri par deps path title; do
    [[ -n $gid ]] || continue
    [[ $par == "$WO_NONE" ]] && par=""
    [[ $deps == "$WO_NONE" ]] && deps=""
    G_IDS+=("$gid")
    G_STATUS[$gid]=$st; G_TYPE[$gid]=$ty; G_PRI[$gid]=$pri; G_PARENT[$gid]=$par
    G_DEPS[$gid]=$deps; G_PATH[$gid]=$path; G_TITLE[$gid]=$title
  done < <(wo_records "$root")
}

g_archived() { [[ ${G_PATH[$1]} == archive/* ]]; }

# g_waiting <id> - the dependencies that are not done yet, space separated.
# A dependency that no longer exists is reported, never assumed satisfied.
g_waiting() {
  local d out=""
  local -a ds=()
  [[ -n ${G_DEPS[$1]} ]] || return 0
  IFS=',' read -ra ds <<<"${G_DEPS[$1]}"
  for d in "${ds[@]}"; do
    [[ -n $d ]] || continue
    if [[ -z ${G_STATUS[$d]:-} ]]; then out+=" $d(missing)"
    elif [[ ${G_STATUS[$d]} != done ]]; then out+=" $d"
    fi
  done
  printf '%s' "${out# }"
}

# g_startable <id> - ready, and nothing is being waited on.
g_startable() {
  [[ ${G_STATUS[$1]} == ready ]] || return 1
  [[ -z $(g_waiting "$1") ]]
}

# g_kids <parent-id-or-empty> - child ids, p0 first then by title, one per line.
# Deterministic ordering matters: the index is committed, so an unstable sort
# would show up as a diff on every unrelated run.
g_kids() {
  local par="$1" kid
  local -a sortable=()
  for kid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
    [[ ${G_PARENT[$kid]} == "$par" ]] || continue
    g_archived "$kid" && continue
    sortable+=("${G_PRI[$kid]}|${G_TITLE[$kid]}|$kid")
  done
  ((${#sortable[@]})) || return 0
  printf '%s\n' "${sortable[@]}" | sort | sed 's/.*|//'
}

trunc() { local s="$1" n="$2"; if ((${#s} > n)); then printf '%s...' "${s:0:n-3}"; else printf '%s' "$s"; fi; }

# render_branch <parent-id-or-empty> <prefix> <depth>
render_branch() {
  local par="$1" pre="$2" depth="$3" kid conn nextpre i=0 n
  local -a kids=()
  while IFS= read -r kid; do kids+=("$kid"); done < <(g_kids "$par")
  n=${#kids[@]}
  for kid in "${kids[@]+"${kids[@]}"}"; do
    i=$((i + 1))
    if ((depth == 0)); then
      conn=""; nextpre=""
    elif ((i == n)); then
      conn='`-- '; nextpre="$pre    "
    else
      conn='|-- '; nextpre="$pre|   "
    fi
    printf '%s%s%-17s %-11s %-2s %s\n' \
      "$pre" "$conn" "$kid" "${G_STATUS[$kid]}" "${G_PRI[$kid]}" "$(trunc "${G_TITLE[$kid]}" 62)"
    render_branch "$kid" "$nextpre" $((depth + 1))
  done
}

cmd_tree() {
  wo_require_jq
  load_graph
  if ((PS_JSON)); then
    local gid first=1
    printf '['
    for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
      ((first)) || printf ','
      first=0
      jq -nc --arg id "$gid" --arg st "${G_STATUS[$gid]}" --arg pr "${G_PRI[$gid]}" \
        --arg par "${G_PARENT[$gid]}" --arg t "${G_TITLE[$gid]}" --arg p "${G_PATH[$gid]}" \
        --arg w "$(g_waiting "$gid")" \
        '{id:$id, status:$st, priority:$pr, parent:(if $par=="" then null else $par end),
          title:$t, path:$p, waiting_on:($w | if .=="" then [] else split(" ") end)}'
    done
    printf ']\n'
  else
    render_branch "" "" 0
  fi
}

cmd_next() {
  wo_require_jq
  load_graph
  local gid
  local -a picks=()
  for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
    g_archived "$gid" && continue
    g_startable "$gid" && picks+=("${G_PRI[$gid]}|$gid")
  done

  if ((PS_JSON)); then
    printf '['
    local first=1 line
    if ((${#picks[@]})); then
      while IFS= read -r line; do
        gid="${line##*|}"
        ((first)) || printf ','
        first=0
        jq -nc --arg id "$gid" --arg pr "${G_PRI[$gid]}" --arg t "${G_TITLE[$gid]}" \
          --arg p "${G_PATH[$gid]}" '{id:$id, priority:$pr, title:$t, path:$p}'
      done < <(printf '%s\n' "${picks[@]}" | sort)
    fi
    printf ']\n'
  else
    if ((${#picks[@]} == 0)); then
      ps_info "nothing is startable: no ticket is 'ready' with all dependencies done"
      return 0
    fi
    local line
    while IFS= read -r line; do
      gid="${line##*|}"
      printf '%-17s %-2s %s\n' "$gid" "${G_PRI[$gid]}" "${G_TITLE[$gid]}"
    done < <(printf '%s\n' "${picks[@]}" | sort)
  fi
}

# ---------------------------------------------------------------------------
# verify / resync
# ---------------------------------------------------------------------------

verify_one() {
  local file="$1" src ck idn snap cur_ck cur_idn glob
  src=$(wo_field "$file" '.evidence.source')
  [[ $src == wireframe ]] || { printf 'ok       %s (no wireframe evidence)\n' "$(basename "$file")"; return 0; }

  ck=$(wo_field "$file" '.evidence.frame_checksum')
  idn=$(wo_field "$file" '.evidence.identity')
  glob=$(wo_field "$file" '.evidence.frames_glob')
  snap="$root/$(wo_field "$file" '.evidence.snapshot')/build-plan.json"
  [[ -r $snap ]] || { printf 'MISSING  %s (snapshot gone: %s)\n' "$(basename "$file")" "$snap"; return 1; }

  cur_ck=$(wo_plan_checksum "$snap" "$glob")
  [[ $cur_ck == "$ck" ]] || { printf 'TAMPERED %s (snapshot no longer matches recorded checksum)\n' "$(basename "$file")"; return 1; }

  # Compare against the live brief only if it is still the same feature.
  local origin; origin=$(wo_field "$file" '.evidence.origin')
  local live="$origin/build-plan.json"
  if [[ -r $live ]]; then
    cur_idn=$(wo_plan_identity "$live")
    if [[ $cur_idn != "$idn" ]]; then
      printf 'REPLACED %s (%s now holds a different brief: %s)\n' "$(basename "$file")" "$origin" "$cur_idn"
      return 2
    fi
    if [[ "$(wo_plan_checksum "$live" "$glob")" != "$ck" ]]; then
      printf 'STALE    %s (wireframe rebuilt)\n' "$(basename "$file")"
      return 3
    fi
  fi
  printf 'ok       %s\n' "$(basename "$file")"
}

cmd_verify() {
  wo_require_jq
  [[ -d $root ]] || ps_die "$PS_NOTFOUND" "no_work_orders" "no $WO_DIR_NAME/ in $project"
  local rc=0 f
  if [[ -n $id ]]; then
    require_id
    f=$(wo_find "$project" "$id")
    verify_one "$f" || rc=$?
    if ((rc == 3)); then
      wo_fm_set "$f" '.status="stale" | .updated=$d' --arg d "$(ps_today)"
      reindex
    fi
    exit $((rc ? PS_VALIDATION : PS_OK))
  fi
  while IFS= read -r f; do
    verify_one "$f" || rc=$PS_VALIDATION
  done < <(find "$root" -type f -name 'WO-*.md' | sort)
  exit "$rc"
}

cmd_resync() {
  wo_require_jq; require_id
  local file; file=$(wo_find "$project" "$id")
  wo_require_status "$file" stale

  local origin glob snap idn
  origin=$(wo_field "$file" '.evidence.origin')
  glob=$(wo_field "$file" '.evidence.frames_glob')
  idn=$(wo_field "$file" '.evidence.identity')
  local live="$origin/build-plan.json"
  [[ -r $live ]] || ps_die "$PS_IO" "plan_missing" "cannot re-read $live"
  [[ "$(wo_plan_identity "$live")" == "$idn" ]] || ps_die "$PS_VALIDATION" "identity_changed" \
    "$origin now holds a different brief - that is a replacement, not a resync"

  snap="$root/$(wo_field "$file" '.evidence.snapshot')"
  cp -- "$live" "$snap/build-plan.json"
  [[ -r "$origin/wireframe-brief.json" ]] && cp -- "$origin/wireframe-brief.json" "$snap/wireframe-brief.json"

  local ck; ck=$(wo_plan_checksum "$snap/build-plan.json" "$glob")
  wo_fm_set "$file" \
    '.status="ready" | .updated=$d | .evidence.frame_checksum=$c
     | .evidence.frames=($f|split("\n")|map(select(length>0)))' \
    --arg d "$(ps_today)" --arg c "$ck" --arg f "$(wo_plan_frames "$snap/build-plan.json" "$glob")"
  reindex
  ps_warn "frozen block regenerated - re-read the acceptance criteria before working"
  emit_ok "$id" ready "$file"
}

# ---------------------------------------------------------------------------
# read-only
# ---------------------------------------------------------------------------

cmd_show() {
  wo_require_jq; require_id
  local file; file=$(wo_find "$project" "$id")
  if ((PS_JSON)); then wo_fm "$file"; else cat -- "$file"; fi
}

cmd_list() {
  wo_require_jq
  [[ -d $root ]] || ps_die "$PS_NOTFOUND" "no_work_orders" "no $WO_DIR_NAME/ in $project"
  [[ -n $status_filter ]] && ps_require_enum status "$status_filter" "${WO_STATUSES[@]}"
  local f rows=()
  while IFS= read -r f; do
    local s; s=$(wo_field "$f" '.status')
    [[ -n $status_filter && $s != "$status_filter" ]] && continue
    rows+=("$f")
  done < <(find "$root" -type f -name 'WO-*.md' | sort)

  if ((PS_JSON)); then
    printf '['
    local first=1
    for f in "${rows[@]+"${rows[@]}"}"; do
      ((first)) || printf ','
      first=0
      wo_fm "$f" | jq -c '{id,title,status,type,priority,pr,merge_sha}'
    done
    printf ']\n'
  else
    for f in "${rows[@]+"${rows[@]}"}"; do
      printf '%-24s %-12s %s\n' "$(wo_field "$f" '.id')" "$(wo_field "$f" '.status')" "$(wo_field "$f" '.title')"
    done
  fi
}

# INDEX.md is generated, never edited. It is what keeps an archived ticket
# findable after close moves it out of the active directory.
#
# It leads with what is startable rather than with a full list, because the
# question an agent arrives with is "what may I pick up", and a flat table of
# every ticket sorted by a hash answers a question nobody asked.
build_index() {
  local gid n_active=0 n_ready=0 n_blocked=0 n_arch=0 n_draft=0 w
  for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
    if g_archived "$gid"; then n_arch=$((n_arch + 1)); continue; fi
    n_active=$((n_active + 1))
    [[ ${G_STATUS[$gid]} == draft ]] && n_draft=$((n_draft + 1))
    if g_startable "$gid"; then
      n_ready=$((n_ready + 1))
    elif [[ -n $(g_waiting "$gid") ]]; then
      n_blocked=$((n_blocked + 1))
    fi
  done

  printf '# Work orders\n\n'
  printf 'Generated by `work-order.sh`. Never edit by hand - run `work-order.sh reindex`.\n\n'
  printf '| active | startable now | waiting on a dependency | still draft | archived |\n'
  printf '|---|---|---|---|---|\n'
  printf '| %s | %s | %s | %s | %s |\n\n' "$n_active" "$n_ready" "$n_blocked" "$n_draft" "$n_arch"

  printf '## Start now\n\n'
  printf 'Status `ready` with every dependency `done`. Hand one of these straight to an agent.\n\n'
  if ((n_ready == 0)); then
    printf '_none - approve a draft, or clear a dependency below._\n\n'
  else
    printf '| ID | pri | title | path |\n|---|---|---|---|\n'
    local line
    local -a picks=()
    for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
      g_archived "$gid" && continue
      g_startable "$gid" && picks+=("${G_PRI[$gid]}|${G_TITLE[$gid]}|$gid")
    done
    while IFS= read -r line; do
      gid="${line##*|}"
      printf '| `%s` | %s | %s | [%s](%s) |\n' \
        "$gid" "${G_PRI[$gid]}" "${G_TITLE[$gid]}" "${G_PATH[$gid]##*/}" "${G_PATH[$gid]}"
    done < <(printf '%s\n' "${picks[@]}" | sort)
    printf '\n'
  fi

  printf '## Tree\n\n'
  printf 'A ticket with children owns the directory named for it and sits inside it, so\n'
  printf 'this shape is the directory layout. Nothing sits loose at the top level.\n'
  printf 'Archived tickets drop out of it and into the table below.\n\n'
  printf '```text\n'
  if ((n_active == 0)); then printf '(no active work orders)\n'; else render_branch "" "" 0; fi
  printf '```\n\n'

  printf '## Active\n\n'
  if ((n_active == 0)); then
    printf '_none._\n\n'
  else
    printf '| ID | status | pri | type | parent | waiting on | title |\n'
    printf '|---|---|---|---|---|---|---|\n'
    for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
      g_archived "$gid" && continue
      w=$(g_waiting "$gid")
      printf '| `%s` | %s | %s | %s | %s | %s | [%s](%s) |\n' \
        "$gid" "${G_STATUS[$gid]}" "${G_PRI[$gid]}" "${G_TYPE[$gid]}" \
        "${G_PARENT[$gid]:--}" "${w:--}" "${G_TITLE[$gid]}" "${G_PATH[$gid]}"
    done
    printf '\n'
  fi

  printf '## Archived\n\n'
  if ((n_arch == 0)); then
    printf '_none._\n'
  else
    printf '| ID | status | title | path |\n|---|---|---|---|\n'
    for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
      g_archived "$gid" || continue
      printf '| `%s` | %s | %s | [%s](%s) |\n' \
        "$gid" "${G_STATUS[$gid]}" "${G_TITLE[$gid]}" "${G_PATH[$gid]##*/}" "${G_PATH[$gid]}"
    done
  fi
}

# Every epic directory carries its own generated explainer, so a reader who lands
# one level down is never looking at a bare pile of ticket files, and a repository
# that requires a .md at every level of the tree gets one without anybody hand
# writing it into a directory the script owns.
child_dir_of() {
  local gid="$1"
  desired_dir "$gid"
}

build_child_readme() {
  local gid="$1" kid w n=0
  printf '# %s and its children\n\n' "$gid"
  printf 'Generated by `work-order.sh`. Never edit by hand - run `work-order.sh reindex`.\n\n'
  printf 'This ticket: [%s](%s)\n\n' "${G_TITLE[$gid]}" "${G_PATH[$gid]##*/}"
  printf 'One level down only. A child of a child is listed in its own directory, not here.\n\n'
  n=$(g_kids "$gid" | grep -c . || true)
  if ((n == 0)); then
    printf '_No children yet. This ticket sits at the top level, so it holds the directory\n'
    printf 'on its own until work is filed underneath it._\n'
    return 0
  fi
  printf '| ID | status | pri | waiting on | title |\n|---|---|---|---|---|\n'
  while IFS= read -r kid; do
    w=$(g_waiting "$kid")
    printf '| `%s` | %s | %s | %s | [%s](%s) |\n' \
      "$kid" "${G_STATUS[$kid]}" "${G_PRI[$kid]}" "${w:--}" \
      "${G_TITLE[$kid]}" "$(readme_link "$gid" "$kid")"
  done < <(g_kids "$gid")
}

# readme_link <epic-id> <child-id> -> the child's path relative to the epic's
# directory. A child that owns a directory of its own sits one level below the
# README that lists it, so a bare filename would be a broken pointer.
readme_link() {
  local kid="$2" f
  f="${G_PATH[$kid]##*/}"
  if owns_dir_by_graph "$kid"; then printf '%s/%s' "$kid" "$f"; else printf '%s' "$f"; fi
}

# ---------------------------------------------------------------------------
# The archive's own explainers.
#
# reindex walks active tickets only - each_child_dir skips anything archived by
# construction - so no generated README has ever reached archive/ or archive/
# <year>/. The two that exist there were written by hand after `rolodex.sh check`
# failed on them, which means rolling into a new year reproduces that failure
# exactly. close and cancel are the only things that create those directories, so
# they are the only things that can write the explainer at the same moment.
#
# Written only when missing. The hand-written pair say more about the archive
# than a generator can, and regenerating over them every close would trade a good
# document for a consistent one.
# ---------------------------------------------------------------------------

build_archive_readme() {
  printf '# Work-order archive\n\n'
  printf 'Written by `work-order.sh` the first time a ticket is archived into a year that had no\n'
  printf 'explainer yet. One level down only: what is inside each year is that year'"'"'s own README.\n\n'
  printf 'A ticket arrives here two ways, and only these two:\n\n'
  printf -- '- `work-order.sh close` - the work shipped. It refuses unless `gh` reports the pull\n'
  printf '  request `MERGED` and it can read a merge commit, so every file it files here carries a\n'
  printf '  `merge_sha` that exists in `main`.\n'
  printf -- '- `work-order.sh cancel` - the work was abandoned. No branch, no PR, no merge commit;\n'
  printf '  the `Outcome` block says why and what superseded it, if anything did.\n\n'
  printf 'Nothing here is edited, ever. A closed ticket that turns out to be wrong is reopened with\n'
  printf '`work-order.sh reopen`, or it becomes a new ticket.\n\n'
  printf '| Year | Archived in |\n|---|---|\n'
  local d y
  while IFS= read -r d; do
    y=$(basename -- "$d")
    [[ $y =~ ^[0-9]{4}$ ]] || continue
    printf '| [%s](%s/README.md) | Tickets archived during %s |\n' "$y" "$y" "$y"
  done < <(find "$root/archive" -mindepth 1 -maxdepth 1 -type d | sort)
  printf '\nActive tickets, and the lifecycle a ticket passes through to get here, are one level up in\n'
  printf '[../README.md](../README.md).\n'
}

build_archive_year_readme() {
  local year="$1"
  printf '# Archived in %s\n\n' "$year"
  printf 'Written by `work-order.sh`. Tickets that left the active tree during %s, one file each,\n' "$year"
  printf 'named exactly as they were while active.\n\n'
  printf 'Read one to see what was asked for, which acceptance criteria were observed and what was\n'
  printf 'observed for each, and either the merge SHA that landed it or the reason it was cancelled.\n'
  printf 'The `Outcome` block at the bottom is the only part added after the work stopped.\n\n'
  printf 'Filed here by `close` and `cancel`, never by hand. What the archive is and why it is\n'
  printf 'immutable is one level up in [../README.md](../README.md).\n'
}

# archive_readmes - create any absent explainer under archive/, never touch one
# that exists. Every year directory is checked rather than only the one being
# written to, because the table above links to all of them and a pointer to a
# directory with no README is the defect this whole function exists to stop.
archive_readmes() {
  local adir="$root/archive" tmp d y
  [[ -d $adir ]] || return 0
  if [[ ! -e $adir/README.md ]]; then
    tmp=$(ps_tempfile)
    build_archive_readme >"$tmp"
    ps_atomic_install "$tmp" "$adir/README.md"
  fi
  while IFS= read -r d; do
    y=$(basename -- "$d")
    [[ $y =~ ^[0-9]{4}$ ]] || continue
    [[ -e $d/README.md ]] && continue
    tmp=$(ps_tempfile)
    build_archive_year_readme "$y" >"$tmp"
    ps_atomic_install "$tmp" "$d/README.md"
  done < <(find "$adir" -mindepth 1 -maxdepth 1 -type d | sort)
}

# each_child_dir -> "<id>\t<abs-dir>" for every ticket that owns a directory.
# That is every epic and every top-level ticket - and it is exactly the set of
# directories that exist, so each one gets the explainer the repository requires
# without anybody hand-writing a README into a directory the script owns.
# Tab separated because IFS here excludes the space, and a project directory is
# perfectly entitled to contain one.
each_child_dir() {
  local gid
  for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
    g_archived "$gid" && continue
    owns_dir_by_graph "$gid" || continue
    printf '%s\t%s\n' "$gid" "$(child_dir_of "$gid")"
  done
}

reindex() {
  [[ -d $root ]] || return 0
  load_graph
  local tmp gid dir
  tmp=$(ps_tempfile)
  build_index >"$tmp"
  ps_atomic_install "$tmp" "$root/INDEX.md"
  while IFS=$'\t' read -r gid dir; do
    [[ -d $dir ]] || continue
    tmp=$(ps_tempfile)
    build_child_readme "$gid" >"$tmp"
    ps_atomic_install "$tmp" "$dir/README.md"
  done < <(each_child_dir)
}

# reindex --check is the commit gate: a stale index means the tickets on disk and
# the router disagree, and the router is what the next agent reads.
cmd_reindex() {
  wo_require_jq
  [[ -d $root ]] || ps_die "$PS_NOTFOUND" "no_work_orders" "no $WO_DIR_NAME/ in $project"
  if ((check)); then
    # The layout gate. A ticket loose at the top of work-orders/ belongs to
    # nothing, and one of them is all it takes for the pile to start again -
    # so this fails the commit rather than waiting for anyone to notice.
    local loose names
    loose=$(wo_loose_at_root "$root")
    if [[ -n $loose ]]; then
      names=$(printf '%s\n' "$loose" | while IFS= read -r p; do basename -- "$p"; done | paste -sd' ' -)
      ps_die "$PS_VALIDATION" "loose_ticket" \
        "these tickets sit loose at the top of $WO_DIR_NAME/ instead of inside a directory: $names - run 'work-order.sh reflow'"
    fi

    load_graph
    local tmp gid dir
    tmp=$(ps_tempfile)
    build_index >"$tmp"
    cmp -s "$tmp" "$root/INDEX.md" || ps_die "$PS_VALIDATION" "index_stale" \
      "INDEX.md does not match the tickets on disk - run 'work-order.sh reindex'"
    while IFS=$'\t' read -r gid dir; do
      tmp=$(ps_tempfile)
      build_child_readme "$gid" >"$tmp"
      cmp -s "$tmp" "$dir/README.md" || ps_die "$PS_VALIDATION" "readme_stale" \
        "${dir#"$project"/}/README.md does not match its children - run 'work-order.sh reindex'"
    done < <(each_child_dir)
    if ((PS_JSON)); then printf '{"ok":true,"index":"current"}\n'; else ps_info "INDEX.md and every child README are current"; fi
    return 0
  fi
  reindex
  if ((PS_JSON)); then
    printf '{"ok":true,"index":%s}\n' "$(ps_json_string "$root/INDEX.md")"
  else
    ps_info "rebuilt $root/INDEX.md and every child README"
  fi
}

# ---------------------------------------------------------------------------
# reflow - move every ticket to the home the layout rule gives it.
#
# It is the repair for a tree written under the older rule, where a parentless
# ticket sat loose at the root and an epic's own file sat outside its children's
# directory. It is also the fix the gate names when anything drifts back.
#
# Nothing about the ticket changes: no frontmatter is touched and no parent is
# invented. The only thing that moves is the file, to where its own recorded
# parent already says it belongs.
# ---------------------------------------------------------------------------

cmd_reflow() {
  wo_require_jq
  [[ -d $root ]] || ps_die "$PS_NOTFOUND" "no_work_orders" "no $WO_DIR_NAME/ in $project"
  load_graph

  local gid f cur want
  local -a moved=()

  if ((dry_run)); then
    # A dry run may not move a byte, so it compares each ticket's current
    # directory against the one the rule gives it and reports the difference.
    for gid in "${G_IDS[@]+"${G_IDS[@]}"}"; do
      g_archived "$gid" && continue
      f=$(wo_find "$project" "$gid")
      cur=$(dirname -- "$f")
      want=$(desired_dir "$gid")
      [[ $cur == "$want" ]] \
        || moved+=("${f#"$project"/} -> ${want#"$project"/}/$(basename -- "$f")")
    done
    if ((PS_JSON)); then
      printf '{"ok":true,"dry_run":true,"out_of_place":%d}\n' "${#moved[@]}"
    else
      ps_info "DRY RUN - ${#moved[@]} ticket(s) are not in the home the layout rule gives them"
      ((${#moved[@]})) && printf '  %s\n' "${moved[@]}" >&2
    fi
    return 0
  fi

  local before after
  while IFS=$'\t' read -r before after; do
    [[ -n $before ]] && moved+=("$before -> $after")
  done < <(place_all)

  reindex
  if ((PS_JSON)); then
    printf '{"ok":true,"moved":%d}\n' "${#moved[@]}"
  else
    ps_info "reflowed ${#moved[@]} ticket(s)"
    ((${#moved[@]})) && printf '  %s\n' "${moved[@]}" >&2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# repair - heal tickets minted before the H1 placeholder was substituted.
#
# Every ticket written before that fix carries `# %%ID%% - %%TITLE%%` as its
# heading. The facts were always correct in the frontmatter, so nothing
# downstream broke; the repair is therefore a pure re-derivation from the
# ticket's own id and title, inventing nothing.
#
# It is a subcommand rather than a flag on reindex on purpose. reindex writes only
# generated index files and never a ticket body, and it runs implicitly at the end
# of almost every other subcommand - a repair that fired as a side effect of
# `note` would be the invisible mutation this skill forbids. It is a script rather
# than a manual pass because hand-editing a ticket corrupts the JSON frontmatter
# on any repository with a markdown formatter hook.
# ---------------------------------------------------------------------------

# repair_h1 <file> -> the ticket's H1 line, which is the first `# ` line of the
# body. Nothing below it is ever considered.
repair_h1() {
  wo_body "$1" | awk '/^#[[:space:]]/ { print; exit }'
}

cmd_repair() {
  wo_require_jq
  [[ -d $root ]] || ps_die "$PS_NOTFOUND" "no_work_orders" "no $WO_DIR_NAME/ in $project"

  local f h1 tid ttitle want tmp scanned=0
  local -a changed=()
  while IFS= read -r f; do
    scanned=$((scanned + 1))
    h1=$(repair_h1 "$f")
    case $h1 in *'%%'*) ;; *) continue ;; esac

    tid=$(wo_field "$f" '.id')
    ttitle=$(ps_sanitize_line "$(wo_field "$f" '.title')")
    [[ -n $tid && -n $ttitle ]] || ps_die "$PS_VALIDATION" "incomplete_frontmatter" \
      "${f#"$project"/} has a placeholder heading and no id/title to rebuild it from"
    want="# $tid - $ttitle"
    changed+=("${f#"$project"/}")
    ((dry_run)) && continue

    # Exactly one line changes: the first heading that still holds a placeholder.
    # The frontmatter is copied through byte for byte and no other body line is
    # even examined, so a repair can never be mistaken for an edit of the work.
    tmp=$(ps_tempfile)
    {
      printf -- '---\n'
      wo_fm "$f"
      printf -- '---\n'
      wo_body "$f" | awk -v want="$want" '
        BEGIN { fixed = 0 }
        !fixed && /^#[[:space:]].*%%/ { print want; fixed = 1; next }
        { print }
      '
    } >"$tmp"
    ps_atomic_install "$tmp" "$f"
  done < <(find "$root" -type f -name 'WO-*.md' | sort)

  local n=${#changed[@]} dr="false" p
  ((dry_run)) && dr="true"
  if ((PS_JSON)); then
    printf '{"ok":true,"dry_run":%s,"scanned":%d,"repaired":%d,"files":%s}\n' \
      "$dr" "$scanned" "$n" \
      "$(printf '%s\n' "${changed[@]+"${changed[@]}"}" | grep -v '^$' | jq -R . | jq -sc .)"
  else
    for p in "${changed[@]+"${changed[@]}"}"; do
      if ((dry_run)); then printf 'would repair %s\n' "$p"; else printf 'repaired %s\n' "$p"; fi
    done
    if ((dry_run)); then
      ps_info "$n of $scanned ticket(s) carry a placeholder heading - nothing was written"
    else
      ps_info "repaired $n of $scanned ticket(s)"
    fi
  fi
}

emit_ok() {
  if ((PS_JSON)); then
    printf '{"ok":true,"id":"%s","status":"%s","file":%s}\n' "$1" "$2" "$(ps_json_string "$3")"
  else
    ps_info "$1 -> $2"
  fi
}

case $command in
  new) cmd_new ;;
  amend) cmd_amend ;;
  link) cmd_link ;;
  note) cmd_note ;;
  resolve) cmd_resolve ;;
  evidence) cmd_evidence ;;
  next) cmd_next ;;
  tree) cmd_tree ;;
  reindex) cmd_reindex ;;
  reflow) cmd_reflow ;;
  repair) cmd_repair ;;
  approve) cmd_approve ;;
  start) cmd_start ;;
  submit) cmd_submit ;;
  done) cmd_done ;;
  close) cmd_close ;;
  cancel) cmd_cancel ;;
  reopen) cmd_reopen ;;
  verify) cmd_verify ;;
  resync) cmd_resync ;;
  show) cmd_show ;;
  list) cmd_list ;;
  # Every verb the case above dispatches appears here, because this string is the
  # only listing an agent that guessed wrong ever sees. `evidence` and `reflow`
  # were missing from it for as long as they have existed.
  *) ps_die "$PS_USAGE" "unknown_command" \
       "unknown command: $command (new|amend|link|note|resolve|evidence|approve|start|submit|done|close|cancel|reopen|verify|resync|show|list|next|tree|reindex|reflow|repair)" ;;
esac
