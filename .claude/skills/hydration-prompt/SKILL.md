---
name: hydration-prompt
description: Writes the prompt that starts the next session, and hands back the exact command to launch it. Maintains HYDRATION.md as a 10-entry sliding window, newest on top. Use at close-out, after CONTEXT_STATE.md is written and before the pull request is opened, or whenever the user asks for a hydration prompt, a handoff, or how to start the next ticket.
version: 2.0.2
---

# Hydration prompt

> **This copy is read-only.**
> Skills are vendored into a project as copies, and this may be one.
> Edit this skill upstream, bump its version, then re-pull it - never edit the copy where it landed.
> Upstream is `~/dotfiles/claude/skills/hydration-prompt/`, or https://github.com/jkkelley/dotfiles/tree/main/claude/skills/hydration-prompt if that checkout is not on this machine.
> `skill-update.sh` replaces the skill's directory rather than merging into it, so a local edit is destroyed by the next update with no conflict and no warning.
> The registry's content hash cannot catch it either, because a project's copy legitimately differs from upstream.

The last thing a session produces is the first thing the next one reads.

This skill turns that into an artifact rather than a message: an entry at the top
of `HYDRATION.md`, and a copy-paste command that launches the next session pointed
straight at it. The user should never have to explain the project again, and
should never have to assemble a command by hand.

## The one flow

`CONTEXT_STATE.md` -> hydration prompt -> **one** pull request -> merge -> cleanup -> the command.

```text
close-out
│
├─ ON THE WORK BRANCH ─── everything the ticket owns, nothing deferred
│  │
│  ├─ 1. CONTEXT_STATE.md        new checkpoint at the TOP, newest first
│  │
│  ├─ 2. THE TICKET REACHES done ← every part of it, in this order
│  │     ├─ evidence every AC      work-order.sh evidence --observed
│  │     ├─ interview-ready retro  work-order.sh note
│  │     └─ mark it done           work-order.sh done
│  │
│  └─ 3. HYDRATION.md            hydration.sh check, then add
│
├─ ONE PULL REQUEST
│  └─ 4. push once               code + ticket + state + prompt, one review
│
└─ AFTER THE MERGE
   ├─ 5. archive                 work-order.sh close, straight to main
   ├─ 6. cleanup                 ff main, delete the branch both sides
   └─ 7. hand back               the prompt AND its launch command, then hold
```

**Everything the ticket owns happens on the work branch, and the ticket reaches
`done` there.** We always roll forward: nothing is left as paperwork that follows
the PR, because paperwork that follows a merge is paperwork that gets skipped. A
branch carrying finished code and an unfinished ticket merges into a `main` where
the work exists and the record of it does not.

**There is exactly one pull request per ticket.** A second PR that carries only
state files doubles the review surface for one piece of work and leaves `main`
briefly describing a world that no longer exists.

## The script does the mechanical parts

Never hand-edit `HYDRATION.md`, and never assemble the launch command by typing
it. Both are scripted precisely because an agent asked to "remember to trim to
ten" will eventually not, and will report that it did.

```sh
HP=.claude/skills/hydration-prompt/scripts/hydration.sh

bash $HP init    --project .
bash $HP check   --project . --body-file /tmp/entry.md      # before writing
bash $HP add     --project . --id WO-... --title "..." --body-file /tmp/entry.md
bash $HP command --project . --id WO-... --title "..."      # the launch block
bash $HP latest  --project .                                # what the next agent reads
```

`add` refuses a body that fails `check`, so a malformed entry never reaches the
file.

## Which file governs

`CONTEXT_STATE.md` and `HYDRATION.md` are written in the same commit, by the same
close-out, describing the same moment. They are meant to be read together and an
agent should read both.

**When they disagree, the hydration prompt wins.** It is not a tie to be
reconciled and it is not a judgement call.

The reason is what each file is for. `CONTEXT_STATE.md` is a **state snapshot**:
where things stood, what was decided, what was learned. `HYDRATION.md` is an
**instruction written for this session**: what to do, what not to assume, what
must be settled first. State describes; the prompt directs. A snapshot that has
drifted is stale information, which is survivable. An instruction that is
overridden by stale information is how a session goes and does the wrong thing
confidently.

So the reading order is: `HYDRATION.md` top entry for what to do, then
`CONTEXT_STATE.md` top 10 for the background it assumes. If the background
contradicts the instruction, follow the instruction and **say so** - a
contradiction between two files written in the same commit is a defect worth
reporting, not worth silently resolving.

## The window

**Read the top entry only.** It is current and complete on its own. The nine
below it are history, kept so a question about how we got here can be answered,
not so they can be read at the start of a session. This differs from
`CONTEXT_STATE.md` and `ISSUES.md`, which are read ten deep - ten full hydration
prompts is roughly fifteen thousand words of superseded instructions.

**Newest on top, oldest falls off.** Adding an entry removes the tenth in the
same write and therefore the same commit. Entries are never numbered, never
renumbered and never edited in place. A correction is a new entry.

## What an entry contains

Twelve sections, in order, each exactly once. `references/entry.tmpl` is the
template and `check` enforces it:

`Ticket` &middot; `What just landed` &middot; `What is NOT done` &middot;
`Stale or false in the docs` &middot; `Your scope` &middot; `Before you start` &middot;
`Read in this order` &middot; `Reuse, it is proven` &middot;
`The verification ladder` &middot; `Traps, already paid for` &middot;
`Workflow` &middot; `Conventions`

Two of those carry most of the value.

**`What is NOT done`** is the section most often written dishonestly, because
every incentive at close-out points at sounding finished. If nothing reached a
real system, say that in those words and give the command whose empty output
proves it. Anything carried onto another ticket is named there by ID and full
title so it cannot be quietly dropped.

**`Before you start`** is what makes a prerequisite a gate rather than a
discovery. Anything unsettled goes here, and an agent that finds an unanswered
question asks the user rather than choosing an answer and building on it. Write
`None.` when there is genuinely nothing - an empty section cannot be told apart
from a forgotten one.

### Duplicated sections are a defect, not a formatting quibble

`check` fails on a repeated heading. This exists because the first entry ever
written was assembled from terminal output that had three of its sections pasted
in twice, and every human who looked at it skimmed straight past. A reader who
hits the same heading a second time cannot tell which copy is current.

## The launch command

`command` emits this, with every variable derived rather than typed, laid out
**one argument per line** and folded at 68 columns:

```sh
claude --permission-mode bypassPermissions \
-n "Session: WO-20260819-ca7c - Phase 5: the mothership GUI, its \
container image, and the first visual" \
"Read Hydration Prompt located at \
/home/luna/projects/example/HYDRATION.md, Process work order \
WO-20260819-ca7c per its acceptance criteria after you've read it."
```

### The prompt is positional. It must never go back to `-p`

This used to be `claude -p "<prompt>"`, which was wrong in the way that looks
right.

`-p` is `--print`: _"print response and exit."_ The command ran the hydration
prompt headless, printed a reply, and quit. Nobody ever landed in a session,
which is the one thing this whole skill exists to arrange. It survived as long as
it did because the failure produces plausible output rather than an error - you
get a sensible-looking answer in your terminal and no session.

`claude [options] [prompt]` takes the prompt as a **positional argument**, and
without `-p` that starts an interactive session with the prompt already
delivered. One command, no paste step, and the session is actually a session.

The prompt goes **last**, after the options, so adding a flag never has to step
over it. There is a test asserting `-p` and `--print` appear nowhere.

### Why it is folded at all

**A single line is not safe.** Every surface this command travels through - a
chat transcript, a terminal, a markdown pane - soft-wraps it at _its own_ width,
and a copy taken out of that surface can carry the break with it. The break lands
wherever that renderer decided, usually the middle of a quoted string.

The failure mode is the bad kind: the first fragment is normally a syntactically
**valid** command that does something other than intended, so the shell runs it
rather than complaining, and the user finds out afterwards.

So the breaks are ours, folded narrow enough that nothing else wants to re-wrap.

### Why one argument per line, rather than a greedy fill

A greedy fill is correct and unreadable, and it is fragile in a way that only
shows up later. It produced this:

````text
you've read it." --permission-mode bypassPermissions -n "Session: ```

An argument ends mid-line and two more begin behind it. Add a flag and it lands
wherever the fill happens to put it.

One argument per line means **a new flag is a new line and nothing else moves**.
The layout is also the same at every width, because the fold is structural rather
than width-driven - a two-argument command is two lines even at a width that
would fit it on one. Newlines are free; a command nobody can read is not.

### Why the join is exact

A backslash-newline is removed by the shell **inside double quotes as well as
outside**.

Between arguments the line ends `text \` so the space survives and the arguments
stay separate. Inside an argument, a break at a space keeps that space *before*
the backslash; a token longer than the width breaks mid-token and rejoins with no
space invented, which is why a long path may split anywhere.

**Continuations start at column 0.** An indent wastes width, and a copy that
loses the indent is indistinguishable from one that did not.

Never single-quote anything that goes through the folder. Inside single quotes a
backslash is literal and the continuation would become part of the string.

`--width N` changes the column, `--oneline` disables folding for scripting.

### Verified against the shell, not against itself

Checking the folder with its own inverse would only prove the two agree with each
other. `testing/wrap-roundtrip.sh` puts a stub `claude` on `PATH` that prints its
argv, runs **both** the folded and the unfolded form through a real bash at six
widths across three command shapes, and compares what each actually delivered.

**128 checks.** They cover argv equality, that no line exceeds the width, that
every line but the last carries a real continuation and the last does not, that
continuations are flush left, that no argument ends and another begins on one
line, and the apostrophe in `you've`, which is where a mis-placed fold surfaces.

### When there is no work order

Not every session is a ticket. A spike, an investigation, a piece of maintenance -
`--id` is optional, and both the entry and the command adapt:

```sh
claude -n "Session: "
````

One argument on one line. Three deliberate differences from the shape above,
none of them an oversight.

**There is no prompt at all.** Not a shortened one, not the bare located-at
clause - none. Work outside a ticket has no instruction until the person starting
it writes one, and a guessed prompt aims a session at the wrong thing with full
confidence. A test asserts no prompt leaks onto this path.

**`--permission-mode bypassPermissions` is not carried over.** A ticket has a
reviewed scope and acceptance criteria behind it; an ad-hoc session has neither,
so it answers for itself.

**The session name is left empty on purpose.** Work outside a ticket has no name
until the person starting it decides what this session is - a design pass, a
spike, an investigation - so the slot stays open to be typed at the moment of
pasting. Do not fill it from the entry title. That looks like helpfulness and is
actually a guess, and a test asserts it stays empty.

The `Ticket` section of the entry still exists on this path - it names what the
session is and why, instead of an ID.

## Pointer

Every project using this skill carries a line in `CLAUDE.md` pointing at
`HYDRATION.md` and stating the read-the-top-entry-only rule.

`project-scaffold` writes that pointer; it does **not** create the file. Running
`hydration.sh init --project .` does, and this script owns the file from then on.
The split is the same one `context-compaction` has with `CONTEXT_STATE.md`: the
scaffold points at it, the owning skill writes it.

## Testing

```sh
bash testing/run-tests.sh
```

Runs in a container per the `container-sandbox` skill. Covers rotation at the
window boundary, refusal of a duplicated section, refusal of an empty
`Before you start`, and that the emitted command matches the template byte for
byte.
