---
name: work-order
description: Deterministic ticketing for agent handoff. Creates and drives work-orders through a validated lifecycle, organises them as epics with children and a dependency graph, records progress notes, and binds acceptance criteria to Figma wireframe evidence when it exists. Use when the user asks for a ticket, a work-order, an epic, "cut me a ticket", "write this up as work", "what should I work on next", when handing a task to another agent, when adding a note or a dependency to existing work, or says "work-order with a side of figma" (run figma-wireframe first, then feed its output in). Not for prioritising a backlog - that is project-scaffold's BACKLOG.md.
version: 1.0.1
---

# Work Order

> **This copy is read-only.**
> Skills are vendored into a project as copies, and this may be one.
> Edit this skill upstream, bump its version, then re-pull it - never edit the copy where it landed.
> Upstream is `~/dotfiles/claude/skills/work-order/`, or https://github.com/jkkelley/dotfiles/tree/main/claude/skills/work-order if that checkout is not on this machine.
> `skill-update.sh` replaces the skill's directory rather than merging into it, so a local edit is destroyed by the next update with no conflict and no warning.
> The registry's content hash cannot catch it either, because a project's copy legitimately differs from upstream.

Tickets an agent can act on without asking a follow-up question. The determinism
comes from one rule: **the script writes the ticket, never the model.**

An agent hand-writing ticket markdown is the failure this skill removes. Every
field, every transition, every archive move goes through `scripts/work-order.sh`.

## Hard rule: never name a ticket without its title

Every reference to a work-order in a chat reply carries the ticket ID _and_ its full title, joined by a dash.

```text
WO-20260818-b1a7 - Login, 403 and error screens wireframed then built
```

A bare ID is a defect.
So is a pointer with no name attached: "the next ticket", "the blocked one", "the one this depends on".
The user cannot see what you are referring to, and will not go and look it up.

This holds on the first mention in a reply and on every mention after it.
When several tickets appear together - a list, a table, a dependency chain, a close-out message - each one carries its own ID and title.

Take the title from the ticket file itself.
The tree in `work-orders/INDEX.md` truncates long titles with an ellipsis, and a truncated title is not a title.

Scope is chat replies.
Commit messages, PR titles and bodies, and the ticket files themselves keep whatever format their own conventions call for.

## Requirements

- `bash` 4+, `jq`, `git`. `gh` for `submit` and `close`.
- `lavish-axi` to approve a ticket. Without it, `approve` refuses unless you pass
  `--no-lavish --reason "..."`, which records the exception in the ticket.

Why jq when `lib/common.sh` deliberately avoids it: common.sh only ever _emits_
JSON, which hand-rolled bash does safely. work-order _reads_ nested JSON out of
`build-plan.json`, and hand-rolled JSON parsing in bash is exactly the kind of
thing that stops being deterministic. jq reads; `ps_json_string` writes.

## How the directory is organised

Two rules, and the top level of `work-orders/` holds directories and nothing else:

1. **A ticket with no parent owns the directory named for it, and its own file lives inside.**
2. **A ticket with a parent is written into the parent's directory**, promoting that parent into one if it was still a loose leaf.

```
work-orders/
├── INDEX.md                                  generated router - read this first
├── WO-20260810-e21f/                          a top-level epic - the folder is the unit
│   ├── README.md                              generated, lists the children
│   ├── WO-20260810-e21f-dev001-pipeline.md    the epic's own ticket, inside its folder
│   ├── WO-20260810-a1d4-track-a1.md           a leaf: a plain file, no folder of its own
│   └── WO-20260810-33d1/                      a child that is itself an epic
│       ├── README.md
│       └── WO-20260810-33d1-track-c3.md
├── evidence/<ID>/                            wireframe snapshots
└── archive/YYYY/                              closed tickets
```

Everything has a home, and a ticket belonging to nothing cannot be expressed. The
older layout let a parentless ticket sit loose at the root, and unrelated tickets
piled up there with nothing tying them together - the pile is now structurally
impossible rather than something to be tidied periodically. `new` refuses a ticket
that names neither `--parent` nor `--top-level`, and `reindex --check` fails on any
`WO-*.md` found at the top level.

Owning a directory is monotone: a ticket keeps its folder even after its last
child leaves, so a path recorded anywhere stays valid. Grouping is by parent and
never by status, for the same reason - parent does not change over a ticket's life
and status changes five times, and a layout that moved a file on every transition
would rot every path anyone had written down.

The tree is the same shape one level at a time: an epic reads down to its
children and no further, so a grandchild appearing never rewrites anything above
it.

| Question                        | Answer                                                      |
| ------------------------------- | ----------------------------------------------------------- |
| What may I start right now?     | `work-order.sh next` - `ready` with every dependency `done` |
| What is the shape of this work? | `work-order.sh tree`, or the Tree section of `INDEX.md`     |
| Where does this ticket sit?     | `parent` in its frontmatter; the path follows from it       |
| What is it waiting on?          | `depends_on`, and the "waiting on" column in `INDEX.md`     |
| What happened while it ran?     | its `## Notes` section, appended by `work-order.sh note`    |

`depends_on` is the authoritative direction and `blocks` is its inverse. Both are
written when an edge is made, so a ticket read on its own is enough to tell an
agent whether it is allowed to start. Every edge that would close a cycle is
refused - a dependency loop makes `next` permanently empty, which reads exactly
like "there is no work" and is the worst failure this graph can have.

## Which document wins

| Situation          | Authority                                                                                                                                                            |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wireframes present | `build-plan.json` leads. Screens, states, `done_when` and `non_goals` come from it. The ticket is guidance layered on top and may never contradict the frozen block. |
| No wireframes      | The ticket leads. It is the sole source of truth, `evidence.source` is `human`, every criterion is `(human)`.                                                        |

A conflict between the two is a drift error, not something to merge by hand.

## Lifecycle

The status set is closed. Every transition is validated and an illegal one is
refused by name. Full table, including what each transition writes and what makes
it refuse, is in `references/lifecycle.md`.

| #   | Status        | Set by    | Gate                                 | Legal next               |
| --- | ------------- | --------- | ------------------------------------ | ------------------------ |
| 1   | `draft`       | `new`     | Rendered in Lavish for review        | `ready`                  |
| 2   | `ready`       | `approve` | Lavish approval. Lavish is done here | `in-progress`, `stale`   |
| 3   | `in-progress` | `start`   | Creates and stamps the branch        | `in-review`              |
| 4   | `in-review`   | `submit`  | Human review gate on the PR          | `done`                   |
| 5   | `done`        | `done`    | Last feature commit, at compaction   | _(archived by `close`)_  |
| -   | `cancelled`   | `cancel`  | A stated reason. Nothing shipped     | _(archived immediately)_ |
| —   | `stale`       | `verify`  | Frozen block drifted                 | `ready` via `resync`     |

`done` is written on the feature branch **before** the PR lands, alongside the
`context-compaction` update to `CONTEXT_STATE.md`. That is a deliberate choice: it
means a rejected PR leaves a ticket claiming done, which is what `reopen` exists
to correct.

`cancel` is the other terminal state, and the only one a ticket can reach without
shipping anything. It takes a required `--reason`, writes it into `## Outcome`,
archives the file exactly where `close` files one, and does no git and no `gh`
work at all - the move is left staged for you to commit. `--superseded-by` is
written to a `superseded_by` field as well as into the prose, so the graph can be
asked what replaced it. A `done` ticket is refused: that one is finished, and
`close` is its verb.

`link`, `note`, `resolve`, `next`, `tree`, `reindex`, `reflow` and `repair` sit
outside the status set: they change the graph, the record, the layout or the view, never the state. So
none of them can advance a ticket, and none of them is blocked by one.

Two verbs are deliberately not in that list. `evidence` requires `in-progress` or
`in-review`, because a criterion is an observation of work in flight and ticking
one on a draft would let `done` pass with nothing ever run. `amend` requires
`draft`, because a ticket whose scope can move after `approve` is not a contract;
it replaces the In, Out, Acceptance criteria or Test plan sections wholesale, and
leaves a wireframe-derived frozen block untouched.

## Usage

```bash
WO=.claude/skills/work-order/scripts/work-order.sh

# generic path - no design involved
bash $WO new --title "Retry failed webhook deliveries" --type bug --parent "$EPIC" \
  --problem "Deliveries that 500 are dropped silently" \
  --in "exponential backoff" --out "changing the payload schema" \
  --ac "a 500 is retried three times then dead-lettered" \
  --test-plan "podman run --rm -v \$PWD:/w -w /w node:22 npm test -- webhooks"

# figma path - "a work-order with a side of figma"
bash $WO new --title "Empty cart state" --type feature --problem "..." --parent "$EPIC" \
  --out "payment errors" --from-figma . --frames 'wf/checkout-cart/*'

bash $WO resolve --id WO-20260805-3f2a --index 1 --answer "v2 only"
bash $WO amend   --id WO-20260805-3f2a --ac "a 500 is retried three times" \
  --out "changing the payload schema"      # drafts only; replaces the section
bash $WO approve --id WO-20260805-3f2a     # after Lavish review
bash $WO start   --id WO-20260805-3f2a     # creates feat/<slug>
bash $WO submit  --id WO-20260805-3f2a --pr 42
bash $WO done    --id WO-20260805-3f2a     # last feature commit
bash $WO close   --id WO-20260805-3f2a --dry-run
bash $WO close   --id WO-20260805-3f2a     # post-merge only

# the other ending: work that is not going to happen
bash $WO cancel  --id WO-20260805-3f2a --reason "superseded by the queue rewrite" \
  --superseded-by WO-20260812-9a1c         # archives it; commit the move yourself
```

Every subcommand takes `--project DIR`, `--json`, `--help`. Exit codes match
`backlog.sh`: `0` ok, `2` usage, `3` validation or illegal transition, `4`
io/missing dependency, `5` lock timeout, `6` id not found.

### Cutting an epic and its children

An epic is a ticket whose closure depends on its children. Mint the parent first,
then each child with `--parent`, then wire the ordering with `--depends-on`:

```bash
# --top-level is required for a ticket with no parent: it opens a new directory
# at the root of work-orders/, which is a deliberate act rather than a default.
EPIC=$(bash $WO new --json --top-level --type feature --priority p1 \
  --title "Dev pipeline test end to end" --problem "..." --out "real money" \
  --ac "the run script exits 0 from a clean environment" | jq -r .id)

RUNNER=$(bash $WO new --json --parent "$EPIC" --type feature \
  --title "Contract test runner" --problem "..." --out "..." --ac "..." | jq -r .id)

# ordering the children, once every ID exists
bash $WO link --id "$CONSOLE" --depends-on "$RUNNER"

bash $WO next --json      # <- what an agent may pick up, and nothing else
bash $WO tree             # <- the shape, for a human
```

`link` is the only way to add an edge after the fact, which is the normal case:
siblings cannot reference each other at mint time. It moves the file when the
parent changes, with `git mv`, and carries any descendants along - a ticket that
owns a directory travels as that whole directory. `--detach` gives a ticket back
its own directory at the root rather than leaving it loose there.

### Notes: the progress record

```bash
bash $WO note --id WO-20260805-3f2a --text "namespace up, storefront pod pending"
```

Appended newest-first under `## Notes`, stamped, never rewritten - the same rule
as `ISSUES.md`. This is the **only** way a note reaches a ticket. An agent that
hand-edits the file instead defeats the format ownership the whole skill rests on,
and on a repository with a markdown formatter hook it corrupts the JSON
frontmatter outright.

Notes are for what happened. A decision that changes the work belongs in the
ticket's own fields, and a new idea belongs in `BACKLOG.md`.

### Answering an open question

`--question` writes an unchecked box, and `approve` refuses while any box in that
block is unchecked. `resolve` is the verb that records the answer and ticks it:

```bash
bash $WO resolve --id WO-20260805-3f2a --index 1 --answer "v2 only, v1 is retired"
bash $WO resolve --id WO-20260805-3f2a --match "DNS" --answer "platform team owns it"
```

`--index` is 1-based and counts every question whether resolved or not, so an
index never shifts as questions get answered. `--match` is a case-insensitive
substring and an ambiguous match is refused, never resolved by picking the first
hit - guessing which question was answered is the nondeterminism this skill
exists to remove.

`--answer` is mandatory and there is no flag that resolves without one. A question
closed with no recorded answer is indistinguishable from a deleted one and takes
the audit trail with it, so anything of that shape would be the gate removed
rather than satisfied. The question text is preserved and the answer is written
underneath it with the date.

### Evidencing an acceptance criterion

`--ac` writes an unchecked box, and `done` refuses while any box in that block is
unchecked. `evidence` is the verb that records what was seen and ticks it:

```bash
bash $WO evidence --id WO-20260805-3f2a --index 1 --observed "curl returned 200, body matched the fixture"
bash $WO evidence --id WO-20260805-3f2a --match "retry" --observed "three retries then dead-lettered, seen in the run log"
```

Selection works exactly as it does for `resolve`: `--index` is 1-based over every
criterion whether checked or not, `--match` is a case-insensitive substring, and
an ambiguous match is refused rather than guessed.

`--observed` is mandatory and there is no flag that ticks a criterion without it,
because a criterion checked with no recorded observation is a claim that somebody
verified it. Re-evidencing an already-checked criterion is refused too: two
observations under one criterion leave the ticket unable to say which run proved
it, and the second call is nearly always a repeated command rather than a second
proof.

A criterion nobody observed stays unchecked and the ticket stays in review. That
refusal is the gate working. The way past it is to observe the thing, or to split
the unobservable criterion into its own ticket - never to tick it.

### Repairing a heading

```bash
bash $WO repair --dry-run    # list what would change, write nothing
bash $WO repair              # rebuild each placeholder H1 from its own frontmatter
```

Tickets written before the heading placeholder was substituted carry
`# %%ID%% - %%TITLE%%` as their H1. `repair` rewrites that one line from the
ticket's own `id` and `title`, touches nothing else, and is idempotent. It is a
subcommand rather than a flag on `reindex` because `reindex` writes only generated
index files and runs implicitly after almost every other subcommand - a repair
that fired as a side effect of `note` would be exactly the invisible mutation this
skill forbids.

`new` now refuses with exit 3 and error `unsubstituted_placeholder` if any
`%%TOKEN%%` survives rendering, and writes nothing. That guard is the more
important half of the fix: the original defect was invisible for 27 tickets
precisely because a wrong heading breaks nothing downstream.

### The index as a gate

`INDEX.md` is generated and leads with what is startable, because the question an
agent arrives with is "what may I pick up". Wire the gate into the commit hook:

```bash
bash $WO reindex --check   # exit 3 when INDEX.md and the tickets disagree,
                           # or when any ticket sits loose at the top level
```

A stale index is not cosmetic. It is the router the next agent reads, and one that
disagrees with the tickets on disk sends work to the wrong place.

The same gate enforces the layout. When it reports a loose ticket, `reflow` is the
fix:

```bash
bash $WO reflow --dry-run   # what would move, and where
bash $WO reflow             # move every ticket to the home its own parent implies
```

`reflow` invents nothing: it touches no frontmatter and assigns no parent. It only
moves each file to where the ticket's own recorded `parent` already says it
belongs, so it is safe to run at any time and does nothing on a tree that is
already correct.

### Working with figma-wireframe

Run figma-wireframe to completion first, then point `--from-figma` at the
directory holding `wireframe-brief.json` and `build-plan.json`. work-order
**snapshots both files** into `work-orders/evidence/<ID>/`, because
figma-wireframe writes fixed filenames into the working directory - wireframing a
second feature would otherwise destroy the first ticket's evidence.

`build-plan.json` carries no Figma node IDs; those only exist after the build
step. Frames are therefore recorded by their deterministic `id` and `name`, which
an agent resolves with `get_metadata`.

Use `--frames` to cut one ticket per screen off a multi-screen brief.

## The close-out

`close` is the only command that touches git history, and the only parameter it
accepts is `--id`. Everything else it discovers:

| Fact       | Source                            |
| ---------- | --------------------------------- |
| branch     | recorded in the ticket at `start` |
| PR number  | recorded at `submit`              |
| merged y/n | `gh pr view --json state`         |
| merge SHA  | `gh pr view --json mergeCommit`   |

**It never trusts a claim that a PR merged.** It asks `gh`, refuses anything but
`MERGED`, and refuses a `MERGED` with no merge commit. After checking out `main`
it re-reads the ticket, because the checkout swaps the file for main's copy.

**One pull request per ticket.** Cleanup, then the archive committed straight to
`main` and pushed. `close` used to open a second PR whose entire content was a
file move and a regenerated index; that doubled the review surface for one piece
of work and bought nothing, because `close` cannot run at all until the ticket's
own PR is `MERGED` and main's copy says `done`. The record follows the work.

The branch-and-PR route survives as a **fallback**, for a repository that
protects `main`. Nothing selects it - a rejected push does. It peels the commit
onto `close-out/<id>`, puts `main` back, opens a PR and merges it. Every step of
that path is repeatable, because the dead end it was written for is still
reachable there: an attempt that dies after the branch is cut must never leave a
ticket only a human can close.

You end on `main` when it succeeds, and back on the branch you started on when
anything fails - and a failed run is always safe to re-run, which is the only
repair that should ever be needed. `--dry-run` prints the whole plan and every
assertion result and executes nothing.

### Where the hydration prompt fits

`close` is step 6 of the one flow, not the end of it:

```text
CONTEXT_STATE.md -> hydration prompt -> ONE pull request -> merge -> close -> hand back the command
```

`context-compaction` and `hydration-prompt` both write on the feature branch,
alongside `done`, so all three ride the ticket's single PR. See the
`hydration-prompt` skill for the entry format and the launch command.

## Testing

`bash testing/run-tests.sh`. Podman, `--network=none`, skill mounted read-only,
per root CLAUDE.md Rule 14. The suite builds its own image because no stock slim
image carries both `jq` and `git`; the base is pinned by digest per Rule 15.

`gh` is never installed - each case stubs it, because the point of the close tests
is controlling what `gh` reports. Cases 070 and 090 run against a real bare
repository, so branch deletion and archiving are genuinely exercised.

Cases 110-130 cover the hierarchy, the dependency graph, notes, and the index
gate. The assertions that earn their keep are the refusals: an edge to a missing
ticket, a cycle in either direction, a re-home that would leave a grandchild
behind, and an index that drifted.

Case 140 covers `resolve`, and its load-bearing assertion is that `approve` is
still refused with exit 3 while one question of two remains unresolved - the point
of `resolve` was never to loosen the gate. Case 150 covers the heading: no `%%`
survives a render, an unwired template token refuses the write, and a repaired
ticket is byte-identical to a freshly minted one, which is how "it touches only
the H1" is proved rather than asserted.

Case 160 covers `evidence`, and mirrors 140's shape for the same reason: its
load-bearing assertion is that `done` is still refused with exit 3 while one
criterion of two is unobserved. It also asserts that the refusal names the verb
that fixes it, because an error that says what is wrong but not what to run is
how a hand edit gets invented.

## Bundled resources

- `references/lifecycle.md` — the full status table: setter, gate, legal successors, what it writes, what makes it refuse.
- `references/ticket.tmpl` — the body skeleton. `new` fills it; nobody edits a ticket by hand. A `%%TOKEN%%` added here without a matching case in `render_body` makes `new` refuse rather than ship the placeholder.
- `scripts/work-order.sh` — every subcommand.
- `scripts/lib/wo.sh` — identity, frontmatter, hierarchy, the graph, wireframe binding.
- `scripts/lib/common.sh` — vendored from project-scaffold so this skill is independently consumable.
- `settings.local.json.tmpl` — allowlists `work-order.sh` as a whole, so a new subcommand needs no permission change, and deliberately does **not** allowlist raw `git branch -D` / `git push --delete`, so hand-rolled cleanup is not an available path.
