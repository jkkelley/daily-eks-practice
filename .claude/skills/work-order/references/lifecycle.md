# Lifecycle

The complete status table.
Nothing here is left to interpretation: every status names its setter, its gate, its legal successors, what the transition writes, and what makes it refuse.

The status set is closed.
`work-order.sh` validates every transition and refuses an illegal one by name rather than silently allowing it.

## Statuses

### 1. `draft`

- **Set by** `new`
- **Gate** rendered in Lavish for review
- **Legal next** `ready`
- **Writes** the whole ticket, the evidence snapshot, `INDEX.md`
- **Refuses if** no `--out` was given; the slug collides with an existing ticket; `--from-figma` points somewhere without both JSON files; `--frames` matches nothing

An empty non-goals list is a validation error, not a default.
The `Out` list is what stops an agent wandering into adjacent work, so a ticket without one is not a ticket.

Everything that can refuse refuses **before** the first `mkdir`.
A rejected run leaves no trace, not even an empty `work-orders/` directory.

### 2. `ready`

- **Set by** `approve`
- **Gate** Lavish approval. Lavish is finished after this point
- **Legal next** `in-progress`, `stale`
- **Writes** `status`, `updated`, the approval record
- **Refuses if** any Open question is still unchecked; the ticket has no acceptance criteria; `lavish-axi` is absent and no `--no-lavish --reason` was given

Assumptions are recorded and proceed.
Open questions block.
That distinction is the whole reason they are separate sections.

`resolve --index N --answer "..."` is the only way to tick one off, and there is deliberately no flag that waives an unanswered question.
A question nobody answered is not a question that stopped mattering, and `--no-lavish` waives the Lavish gate alone.

`--no-lavish` writes `approval.via = "override"` along with the reason into the ticket.
The exception is auditable, never silent.

### 3. `in-progress`

- **Set by** `start`
- **Gate** creates and stamps the branch `feat/<slug>`
- **Legal next** `in-review`
- **Writes** `branch`, `updated`
- **Refuses if** status is not `ready`; the working tree is dirty; the branch already exists

Ticket state is checked before the environment.
Reporting "not a git repository" when the real problem is "this is still a draft" sends the reader down the wrong path.

`approve` rewrites the ticket, so the tree is dirty afterwards and `start` will refuse until that change is committed.
That is intended: the ticket's state belongs in history.

### 4. `in-review`

- **Set by** `submit`
- **Gate** the human review gate on the PR
- **Legal next** `done`
- **Writes** `pr`, `updated`
- **Refuses if** status is not `in-progress`; `gh` cannot see the PR number

### 5. `done`

- **Set by** `done`
- **Gate** the last commit on the feature branch, alongside the `context-compaction` update to `CONTEXT_STATE.md`
- **Legal next** archived by `close`; `in-progress` via `reopen`
- **Writes** `status`, `updated`
- **Refuses if** status is not `in-review`; acceptance criteria are still unchecked

`done` is written **before** the PR lands.
That is a deliberate decision and it has a known cost: a PR that is rejected leaves a ticket claiming done for work that never shipped.
`reopen --reason "..."` is the correction, and it records why in a `reopened` array rather than quietly rewinding.

### 6. `cancelled`

- **Set by** `cancel`
- **Gate** a stated `--reason`. Nothing shipped, so there is nothing to verify
- **Legal next** none. It is archived the moment it is set
- **Writes** `status`, `closed`, `updated`, `superseded_by`, the reason and any `--superseded-by` into `## Outcome`, and moves the file to `archive/YYYY/`
- **Refuses if** status is `done` - that one is finished, and `close` is its verb; the ticket is already archived or already cancelled; `--reason` is empty; `--superseded-by` names a ticket that does not exist

`cancelled` is the other terminal state, and the only one reached without shipping anything.
It exists because the alternative was inventing a branch, a PR and an observation for every acceptance criterion on work nobody intends to do - or deleting the file, which takes the reason with it.

It performs no git and no `gh` work at all: no branch, no PR, no merge.
The move is left staged in the working tree, to be committed with whatever change explains the cancellation.

The reason is prose, but `--superseded-by` is also written to a `superseded_by` field.
"What replaced this" is a fact the graph should be able to answer without anybody reading English.

A cancelled ticket is still a dependency, and it is still unsatisfied - only `done` satisfies one.
Anything waiting on it stays blocked until the edge is removed with `link --no-depends-on`, which is the honest order of events: somebody has to decide the dependent work can proceed without it.

### 7. `stale`

- **Set by** `verify`
- **Gate** the frozen block no longer matches the wireframe
- **Legal next** `ready` via `resync`
- **Writes** `status`, the drift report
- **Refuses if** the brief identity differs - that is a _replacement_, a hard error, not something to resync

`verify` distinguishes four outcomes:

| Result     | Meaning                                                              |
| ---------- | -------------------------------------------------------------------- |
| `ok`       | snapshot and source agree, or the ticket has no wireframe evidence   |
| `MISSING`  | the evidence snapshot is gone                                        |
| `TAMPERED` | the snapshot no longer matches the checksum recorded in the ticket   |
| `STALE`    | the wireframe was rebuilt; `resync` will regenerate the frozen block |
| `REPLACED` | the source path now holds a _different_ brief entirely               |

`REPLACED` exists because figma-wireframe writes fixed filenames into the working directory.
Wireframing a second feature in the same repo overwrites the first one's files, and that must not be mistaken for a rebuild of the same feature.

## Outside the status set

Seven commands change the graph, the record, or the view, and none of them touches status.
That separation is deliberate: nothing an agent does while working on a ticket should be able to advance it, and nothing about a ticket's state should block writing down what happened.

| Command   | Writes                                                   | Refuses if                                                                                                                                                                                         |
| --------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `link`    | `parent`, `depends_on`, `blocks`, and moves the file     | the target does not exist; the edge would close a cycle; the ticket would become its own ancestor; `--detach` is paired with `--depends-on`/`--blocks`, or the same edge is both added and removed |
| `note`    | one entry at the top of `## Notes`                       | `--text` is empty                                                                                                                                                                                  |
| `resolve` | one answer under one Open question, and ticks its box    | `--answer` is empty; no selector was given; the index is out of range; a `--match` is ambiguous or hits nothing; that question is already resolved                                                 |
| `next`    | nothing                                                  | never - an empty result is an answer, and it means nothing may be started                                                                                                                          |
| `tree`    | nothing                                                  | never                                                                                                                                                                                              |
| `reindex` | `INDEX.md`                                               | `--check` exits 3 when the index and the tickets on disk disagree                                                                                                                                  |
| `repair`  | the H1 of any ticket still holding a `%%…%%` placeholder | the frontmatter has no `id` or `title` to rebuild the heading from                                                                                                                                 |

`resolve` is outside the status set for the same reason `note` is, and for one more: it is what makes the `approve` gate survivable.
The gate is strict on purpose, and the answer to a strict gate is a verb that satisfies it honestly, never a flag that waives it.

`repair` is idempotent and `--dry-run` writes nothing.
It rewrites exactly one line per ticket and never the frontmatter, so it cannot be confused with an edit of the work.
It is separate from `reindex` because `reindex` runs implicitly at the end of nearly every other subcommand, and a ticket body that changed as a side effect of `note` would be an invisible mutation.

`link --parent` is the only command besides `close` that moves a file.
It moves the ticket's children directory with it, so re-homing an epic cannot orphan the tickets underneath it, and it uses `git mv` when the project is a repository so the move lands in history as a rename.

`link --no-depends-on` and `--no-blocks` remove an edge, and remove it from both tickets, because an edge written on both sides and cleared on one is worse than one never cleared at all.
Unlike an addition, a target that no longer exists is not refused: a dangling edge is the reason to run the flag, and refusing it would leave hand-editing the frontmatter as the only route.

A dependency is satisfied only by status `done`.
A dependency that no longer exists is reported as missing and treated as unsatisfied - never assumed cleared, because an ID that resolves to nothing is a broken ticket, not a finished one.

## Status-gated record verbs

Two verbs write the record rather than the state, and are still refused on the wrong status.
Both restrictions are gates, not conveniences.

`evidence` requires `in-progress` or `in-review`.
It ticks an acceptance criterion, and `done` refuses while any criterion is unchecked - so without this gate every criterion could be ticked on a draft and `done` would then pass with nothing ever observed during the work.
A gate is only as good as the moment it may be satisfied.

`amend` requires `draft`.
It replaces the In, Out, Acceptance criteria or Test plan sections of a ticket that has not been approved yet, which is what a review of a draft needs and what previously had to land as a note contradicting the section above it.
An approved ticket is amended by `reopen`, or by a new ticket that says why: a ticket whose scope can move after approval is not a contract.
Each repeatable flag replaces its whole section, an empty `Out` list is refused exactly as in `new`, and a wireframe-derived frozen block is carried through untouched because it is derived from `build-plan.json` rather than from the caller.

## The frozen block

Wireframe-derived criteria live between `<!-- wo:frozen:start checksum=... -->` and `<!-- wo:frozen:end -->`.

The checksum covers `build_order`, `done_when` and `non_goals` - the semantic contract.
Canvas `x`/`y` is deliberately excluded, so nudging a frame twenty pixels does not falsely mark a ticket stale.

## close

`close` is the only command that touches git history, and it takes exactly one parameter: `--id`.

| Phase     | What happens                                                                                                   |
| --------- | -------------------------------------------------------------------------------------------------------------- |
| preflight | status is `done`, not already archived, PR recorded                                                            |
| verify    | `gh pr view` reports `MERGED` **and** a non-null merge commit                                                  |
| 1         | fetch/prune, checkout `main`, `merge --ff-only`, delete the feature branch local and remote                    |
| re-check  | re-read the ticket - the checkout swapped it for main's copy - and require `done` again                        |
| 2         | branch `close-out/<ID>` from main, backfill `merge_sha` and `closed`, archive to `archive/YYYY/`, commit, push |
| 2b        | `gh pr create --base main`, then `gh pr merge --squash --delete-branch`, with no prompt                        |
| 3         | the same cleanup for the close-out branch                                                                      |

The re-check between phase 1 and phase 2 is not defensive padding.
Checking out `main` replaces the ticket on disk with main's version of it, so the status verified moments earlier says nothing about the file now being held.
A `gh` that reports `MERGED` for a branch whose ticket never reached `done` on main means the two disagree, and stamping a merge SHA onto that is how a ticket ends up lying.

Phase 2b merges without asking anybody, and that is a decision rather than an oversight.
`close` has already established with `gh` that the ticket's own PR is `MERGED`, so everything on the close-out branch is bookkeeping behind a merge a human already approved: a file moved into `archive/`, a merge SHA backfilled, a regenerated index.
It never merges the work, only the record of it, and it cannot run at all until the work is in `main`.

The caller ends on `main` when close succeeds, because that is the correct place to be once the archive has landed.
On **any** failure they are returned to the branch they started on - or to `main` with a warning when that branch was the feature branch phase 1 deleted.

**A failed close is always safe to re-run, and re-running it is the only repair anybody should need.**
The first version of phase 2 was not repeatable: an attempt that died after the branch was cut left it behind, `checkout -b` then refused to create a branch that already existed, and the ticket became permanently unclosable by the tool - a workaround invented by hand for exactly the problem this command exists to remove.
So phase 2 reuses and resets the close-out branch with `checkout -B`, skips a move a previous attempt already made, pushes with `--force-with-lease` over a branch it left on the remote, and reuses an open PR on that branch instead of failing to open a second one.
When `main` already carries the archive, there is nothing to commit and nothing to merge, and the run says so and drops through to the cleanup that was all that remained.

`--dry-run` prints the phase plan and every assertion result and executes nothing.
