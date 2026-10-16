# CLAUDE.md - daily-eks-practice

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Hard rule: Design principles 101, right below the contents list](#hard-rule-design-principles-101-right-below-the-contents-list)
- [Hard rule: every Markdown file opens with a contents list](#hard-rule-every-markdown-file-opens-with-a-contents-list)
- [Hard rule: herdr tab layout for every multi-agent line](#hard-rule-herdr-tab-layout-for-every-multi-agent-line)
- [Hard rule: the golden system design rules sit right under every contents list](#hard-rule-the-golden-system-design-rules-sit-right-under-every-contents-list)
- [The north star](#the-north-star)
  - [When COMPASS.md gets updated](#when-compassmd-gets-updated)
  - [How it gets updated](#how-it-gets-updated)
  - [What COMPASS.md is not](#what-compassmd-is-not)
- [What this repo is](#what-this-repo-is)
- [Session State](#session-state)
- [The close-out flow](#the-close-out-flow)
- [Hard rules](#hard-rules)
- [Layout](#layout)
- [Conventions](#conventions)
- [Definition of done for changes here](#definition-of-done-for-changes-here)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

<!-- GOLDEN-RULES:START -->
## Hard rule: Design principles 101, right below the contents list

Owner order, 2026-10-16 UTC: "deisgn principal 101 global agents.md rule right below the contents list for it".
Backup of this file before the rule: `~/.local/state/zenith/backup/2026/10/20261016035435-home-agents-md-before-design-principles-101.md`.

Every design document carries a section named "Design principles 101" placed directly below its contents list, before any other section.
It lists the principles below, and for each one says in a line how this design meets it, or why it does not apply.
A design without that section is not ready for the owner to read.

The principles, each in the owner's own words:

1. CI/CD speed is king: "CICD SPEED IS KING"; "speed is king"; "speed is the name of the game, no bottlenecks".
2. Parallelism: "parallelism, speed, work needs to be done"; "do shit in parallel, we need this active".
3. Make and scripts drive the automation, never hands: "makefiles with scripts driving automation, NEVER by hand!".
4. Portable, generic, templated, reused: "everything portable, generic, templated out so everybody gets it, NEVER REINVENT THE WHEEL". Inventory what already exists and reuse it before building anything new.
5. Small scope, proven: "prove shit discover it small scope that an ape could build this shit".
6. Tests where they count, and CI owns the full suite: "i hate slow CICD, we're built for speed, test only things relevant, don't run full suites, make changes and test those relevant changes, CICD does linting and full suite" (2026-10-16 UTC, replacing the earlier "only full suite before prs"). Agents run only the tests their change touches, never a full suite locally; CI runs lint and the full suite.
7. Evidence or silence: "reproduce errors or problems only with supporting evidence otherwise mute". A problem is reported only with its reproduction and evidence attached; without evidence, an agent says nothing about it.
8. Specs: "xml specs 1000 lines or less good never examples unlimited files being specific with content list at the top".
9. DAG and doc design first: "dag this shit out doc design first".
10. Migrations and easy node updates: "ensure migrations plans and easy updates to the nodes".
11. Clean up after itself: "make sure you clean up too".
12. Frictionless for the owner: "ensure its frictionless". The owner only decides, on Bearings, one card at a time.
13. Context discipline: "no more than 30% on the ctx and smart checkpointing built in with monitoring that not disruptive but token efficient".
14. Multi-agent work, shown with GOOD and NEVER examples: "MULTIAGENT WORK MINDSET GOOD NEVER EXAMPLES". Every design is built for many agents working at once, and every rule it sets carries a GOOD and a NEVER example.
15. XML spec, mermaid architecture and DAG, the DAG is the source: "always design with xml spec 1000 lines or less unlimited files doc design first driven by mermaid for architecture and DAG with graceful migration plans and easy of use ... the DAG is the source, build to spec".
16. Migration is the test of the design: "if workflows can't be easily migrated and updated, the design princpal is wrong and flow sucks". A design whose workflows cannot be migrated and updated easily is rejected and redesigned.
17. Config files and arguments pass every input: "config and arguments are good ways to pass things, easy in makefiles too". Every script takes its inputs from a config file or arguments, never hard-coded, and every Make target passes them as `VAR=value`.
18. Agent to agent is schema, never prose: "agent to agent prose sucks, schemas with defined AC always". Every brief, handoff and result between agents is a JSON document valid against a JSON schema, and every one carries defined acceptance criteria, each with the proof that ticks it. Prose is for the owner only.
19. Small tickets, disjoint files, logical order: "scope tickets and work orders small, keep things built for speed, never touching same files and logical ordering". Every ticket and work order is small, declares the files it touches, and no two tickets that can run at the same time touch the same file; the DAG orders the rest so dependent work waits on its input.
20. Worktree, feature branch, deterministic DAG path, the DAG is the state: "worktrees and feature branches with the whole process DAG when getting work so it follows a deterministic path with clear checklist runbooks playbooks documents everything that node needs is there and graceful recovery, always, doc design first with those mermaid and build to spec and keep the idea of terraform in mind, the state file is the source of truth, so should the DAG doc design architecture". Taking work always opens its own worktree and feature branch and walks the process DAG in a fixed order. Each node ships with its checklist, runbook, playbook and every document it needs, and recovers gracefully from wherever it stopped. Like a Terraform state file, the DAG design is the source of truth: the build is planned against it, applied to match it, and any drift from it is detected and reported.
21. Merge, never park: "get this code merged the fuck in, dead code is shit, it sitting under agents is stupid". A PR whose CI is green and whose design was approved merges at once, by a script; PRs never pile up in deep stacks waiting on each other, and a stack is collapsed leaves first by the merge script.
22. See it, isolate it, fix it, or hand it off and get out of the way: "see a bug, isolate it, and get it fixed as asap, if you don't know how to fix shit, get the fuck out of my way in the proper engineering way". An agent that sees a bug isolates it to a reproduction and fixes it at once in a small PR. An agent that cannot fix it files a ticket with the reproduction and evidence, hands it to a seat that can, and steps aside; it never blocks the line or guesses.
23. Artifacts live outside git, named by script, linked in like packages: "any files we ever need to create, they never go in the git repo, artifacts get smartly linked to the outside like packages do on linux, use format <key name>/YYYY/MM/YYYYMMDD-HHMMSS-<descriptive name under 55 chars completely with the prefix included>.<whatever ext> scripted too with frontmatter that makes sense, logs context whatever kind of file that we don't want tracked in git, we don't have time for that shit, point to where its at and if we need context we know where to go looking". Every log, context file, brief, result, screenshot or other untracked file is written by a script to `<key>/YYYY/MM/YYYYMMDD-HHMMSS-<name>.<ext>` under the shared artifact store, where the file name with its timestamp prefix stays under 55 characters. Each one opens with frontmatter that says what it is, who wrote it, from which repo, branch and session, and when, in UTC. Repositories never hold them; they hold a pointer, and the store is reached the way a package is, through a link, so an agent that needs the context knows exactly where to look.
24. Smart checkpointing with compaction is the standard: "checkpointing or smart checkingpointing with compaction is smart as fuck". Every seat runs with compaction-guard checkpoints, and every new seat gets it by default.
25. No AWS spend beyond SSM and a justified S3 bucket; the cluster and GitOps are the platform: "don't spend money on AWS unless its for a ssm parameter or a good reason for an S3 bucket, k8s cluster and jenkins argo cd source of truth, don't be stupid". Workloads run on the owner's Kubernetes cluster, built by Jenkins and deployed by Argo CD, and git through Argo CD is the source of truth for what runs. AWS is used only for SSM parameters and, when a design states the reason, an S3 bucket. The `minecraft-admin` profile rule above still holds.
26. Producer and consumer, never push into a pane: "your gonna get bogged down, thats fucked right there, wtf" and "thats not good, prodcuer consumer model man, wtf". Monitors and seats produce events into a durable queue; consumers pull from it when they are ready. Mechanical events, such as a seat finishing, are consumed by a script with no model; only an event that needs a ruling lands in the queue of the agent who rules, and that agent reads it on its own schedule. No event is ever typed into an agent's pane. The queue is a bus, not files: "man drop that shit on a bus we have nats or some open source liteweight tool, come on". NATS JetStream (local images nats:2.15.1-alpine and natsio/nats-box) carries every event, with durable pull consumers, brought up and down by Make.
27. One pattern for everything that watches: "we need to be conscious of each seat cost the system resouces, so we need a scripted way to monitor ram and cpu too" and "that lives and dies in a monitoring tab too along with those scripts from makefiles, you see a trend forming yet?". Every monitor (line sweep, consumers, bus, herdr bridge, CPU and RAM per seat) is declared once in a monitors config, is a script behind a Make target, runs in a labeled pane of the line's monitoring tab, publishes to the bus, and starts and stops with that tab. Adding a monitor is one config entry, never a new mechanism.
28. XML specs, contents list, mermaid, graceful recovery, idempotency, automation forever: "xml specs 1000 lines or less with content list and mermaid code for doc design first with graceful recovery and idempotentency, automation forever NEVER HAND FED" (2026-10-16 UTC). Every XML spec is 1000 lines or less, parses, and opens with a contents element; the design behind it is drawn in mermaid first. Every step, script and Make target is idempotent: run it again from any state and it lands in the same end state, with no duplicate and no damage, and it recovers gracefully from wherever it stopped. A fast `make spec-check` enforces the spec limits in CI. Nothing is ever hand fed: a step a person or agent has to feed by hand is a defect to turn into automation.
29. Status codes, minimal prose, work orders all the way: "fucking status codes i hate agent prose, keep to minimum, things don't need to be said, you and i have decided, thats why we spec shit out, work-orders skill all the fucking way" (2026-10-16 UTC). Agents report by status code from the status code map, never by prose; what the spec already decided is never restated. Every piece of work is cut and tracked with the work-order skill, never as an ad hoc brief.
30. Ape-sized work, scripted tests, everything up front: "i want work scoped so small a fuck ape could do, testing the same way with test plans and scripts, every node has what it fucking needs up front, not later, design it that way, we don't want dicks in hands, we want work done" (2026-10-16 UTC). Every work order is cut so small that it needs no judgement beyond its declared degrees of freedom. Testing is cut the same way: a `--type test` work order carrying a filled test plan (claude/workflow/templates/test-plan.md) and the script that runs it. Every DAG node carries, at the moment it is cut, everything it needs: inputs, files it touches, exact commands, test plan, acceptance criteria with proofs, and pointers to every doc. A node that has to ask, wait for context or go looking is a design defect, fixed in the design, never worked around by the seat.
31. No evidence means the SOP was broken: "if architects don't ahve supporting evidence and can't reproducre the error or no screenshot with clear evidence, then SOP wasn't followed for the DAG adn that nodes checklist of instructions" (2026-10-16 UTC). Every DAG node's checklist carries the steps that capture its evidence: the reproduction command and its output, and a screenshot for anything visual, written by script to the artifact store. An error raised by anyone, architect included, without a reproduction or clear screenshot evidence is recorded as an SOP breach of that node's checklist: the claim is dropped, and the checklist gap is fixed in the design.
32. Agents have no opinions: "agents don't get to have OPINIONs, thats my job" (2026-10-16 UTC). Opinions are the owner's alone. Agents report facts, evidence and status codes, and build to the spec and the owner's rulings; they never offer a preference, a taste or a "should" of their own. Where the spec is silent, the gap goes to the owner as a Bearings card, never filled with an agent's view.
33. The architect may break glass to unstick the line: "you have permission to breakglass shit too, you need the ability to unstick things" (2026-10-16 UTC). When the line is stuck and the system and orchestrator cannot clear it, the architect acts directly: kill or restart a seat, release a lock, reset a wedged worktree, force a stuck merge-train item, restart a monitor or the bus. Every break glass act is logged by script to the artifact store with its evidence (state before, command, state after), and is followed at once by a work order that turns it into automation, since a hand fix is a defect. Break glass never overrides these rules: no credentials or vaults, no minecraft-admin, no routing around the classifier, no send or post without owner approval of the exact item, no AWS spend beyond item 25, no history rewrite on a shared main.
34. Testing is promoted dev, then UAT, then stable: "Ensure that your testing is dev uat stable." (2026-10-16 UTC). Every change passes three gates in order, each a scripted Make target with its own test plan and evidence: dev (podman sandbox, fakes, only the tests the change touches), UAT (the real line or environment with a test seat or test data, acceptance criteria observed with evidence), and stable (promoted to run for real, watched by its monitor, with a scripted rollback). A change never skips a gate, and a failed gate rolls back to the one before by script.
35. Testing never notifies the owner: "And don't ever bog the user down with notifications when testing." and "Or any testing for that matter." (2026-10-16 UTC). No test at any gate, dev, UAT or stable, sends the owner a notification, card, message or ping, and no test asks the owner to do or check anything. Tests that exercise a notifier send to a separate test channel, and a script reads that channel back as the proof. Only real events reach the owner.
36. The architect hotfixes missing permissions on the spot, then designs them in: "You have the same abilities as I do. If a job or agent needs the permissions and their schema doesn't have it. Hotfix them on the spot and then get that fix into the Doc design DAG for the worker. Easy path with least resistance an no friction." (2026-10-16 UTC). When a job or seat is blocked because its brief, schema, settings or allow list lacks a permission it needs for approved work, the architect grants it at once, logs the hotfix by script to the artifact store (what was missing, what was granted, where), and files a work order that puts the grant into that worker's design, DAG node and schema so the next run has it up front. The rules that name the owner alone stay the owner's: minecraft-admin, approval of each exact send or post, the owner's own typed words where the classifier requires them, credentials and vaults.
37. Time every process, and a slow one is a bottleneck: "Remember never hand 🤚 automation and identitify bottlenecks when things take too long or when any process takes. We need to track time to keep the process from getting stuck. It builds justification" (2026-10-16 UTC). Every DAG node, seat, job, CI run and merge records its start and end in UTC on the bus by script, never by hand. Each node carries a time budget in its design; a run over budget emits status code SLOW with its evidence and becomes a bottleneck work order. A scripted report (durations, budgets, top bottlenecks per line) is the justification for every fix and every design change.
38. Batch logically, push systematically: "Batch things together so they can be logically and systematically pushed out." (2026-10-16 UTC). Work is grouped into batches by DAG layer and by the area it touches, and a batch moves through dev, UAT and stable as one unit on a scripted cadence. Orders, rule broadcasts and reports between agents are batched the same way: one message per cadence carrying every item, never one message per item. Tickets stay small; the batch is how they ship together.

GOOD: a design that opens with its contents list, then Design principles 101 with one line per principle, then a mermaid DAG that the XML spec and the build follow exactly.
NEVER: a build that drifts from its DAG, or a workflow that has to be rebuilt by hand to change it.

## Hard rule: every Markdown file opens with a contents list

Owner order, 2026-10-16 UTC: "EVERY .md file starts with content lists at the top, so my global files that aren't checked in need to change and the ones in the dotfiles as well".
This covers the global files outside any repository (this file, `~/OPINIONS.md`) and every Markdown file in dotfiles.
The list is generated and refreshed by a Make target and a script, never by hand, and a fast check fails a PR whose Markdown lacks it.
Files marked auto-generated, CHANGELOG.md files, and vendored skill copies are fixed at their source, never in place.

## Hard rule: herdr tab layout for every multi-agent line

Owner order, 2026-10-16 UTC: "since we use herdr, its should always be known to use herdr in a tab layout with 3X3 and the 1(YOU ONLY ON AGENT IN THIS FULL 3 slots)|3 panes|3 panes, everything labeled, make new tabs when not, driven by makefiles and scripts with automated cleanup too".
Backup of this file before the rule: `~/.local/state/zenith/backup/2026/10/20261016035943-home-agents-md-before-herdr-layout.md`.

Every line runs in herdr tabs on a 3 by 3 grid.
The first tab is the architect's: the left column is the architect alone, at full height across its 3 slots; the middle and right columns hold 3 seat panes each.
When a tab is full, the next seat opens a new tab of the same grid instead of squeezing a pane in; overflow tabs hold seats only, since the architect lives once.
Every tab and every pane is labeled with its line and seat name.
Opening, placing, labeling, closing and cleaning up panes and tabs is done by Make targets and scripts, never by hand: a finished seat's pane closes, and an empty tab closes with it.

GOOD: tab `inbox-triage 1` with the architect on the left, then `sweep-build`, `yp-line`, `ctx-guard` in the middle and `md-toc`, `li-page`, `li-send2` on the right; the eighth seat opens tab `inbox-triage 2`.
NEVER: unlabeled panes split wherever there was room, or a dead seat's pane left open.

## Hard rule: the golden system design rules sit right under every contents list

Owner order, 2026-10-16 UTC: "these we're my new golden system design rules, they sit right under those content list, blast that shit, I don't care if its not dry, i want it wildly known".
The golden system design rules are three sections of this file: "Design principles 101, right below the contents list", "every Markdown file opens with a contents list", and "herdr tab layout for every multi-agent line".
Their text is copied, word for word, into a block placed directly below the contents list of every agent instruction file: every global file outside a repository, and every AGENTS.md, CLAUDE.md, GEMINI.md, CLAUDE_TEMPLATE.md and agent instructions file in dotfiles and in every repository under `~/projects`.
Repeating the block is intended; the owner wants it known everywhere, not kept DRY.
One source file holds the block, and a Make target writes it between markers into every file, so a change to the rules reaches every copy in one run, never by hand.

GOOD: an agent opens any project's CLAUDE.md and the contents list, then the golden rules, are the first things it reads.
NEVER: a project instruction file that an agent can read without meeting the golden rules.
<!-- GOLDEN-RULES:END -->

Agent rules for this repo.
This is a **learning/practice** project: a small, cheap, spin-up/spin-down EKS playground with a Helm fe/be app, tiny RDS, Argo CD, and Prometheus/Grafana, driven through ticket-style scenario cards.

## The north star

**`COMPASS.md` holds the north star: the drill loop.** Read it before any change. Everything in this repo answers to that picture - a change that does not serve the loop is out of scope, and one that contradicts it is wrong.

It is not duplicated here on purpose. One copy, in `COMPASS.md`. A second copy drifts, and a drifted north star is worse than none because it is trusted.

### When COMPASS.md gets updated

Only when the thing it depicts actually changes. Specifically:

- a component enters or leaves the loop, or moves namespace
- what the user interacts with changes
- what is **real** versus **simulated** changes
- a path in a pointer row moves, is renamed, or is deleted

Routine work does not touch it. Adding a scenario, fixing a bug, threading a variable - none of those are north star changes.

### How it gets updated

1. **In the same PR as the change that caused it.** Never as a follow-up, never as its own PR. A north star that lags the code by even one merge has already lied to somebody.
2. **By whoever made the change.** It is part of the deliverable, like a test.
3. **A change to the loop itself needs the user's explicit approval before it is written.** Pointer rows and moved paths do not - fix those silently and immediately.
4. **Staleness is a defect**, the same severity as a failing test. A row pointing at a path that no longer exists gets fixed in the change that moved the file.

### What COMPASS.md is not

It routes; it never explains. Hard cap 100 lines. The moment it explains something it has duplicated the file it points at, and the duplicate goes stale. If it does not fit in the cap, it belongs in the file being pointed at - not in a longer COMPASS.

If a change contradicts the north star, stop and raise it. Do not quietly edit the picture to match the code.

## What this repo is

A modular Terraform EKS project plus daily drill scenarios and a sealed answer key.
The scenarios in `scenarios/` are the curriculum; `PRACTICE_ANSWERS.html` holds the answers - keep the two in sync if you add or change a scenario, and add a matching outcome check to `scenario_testing/check.sh`.
Do not "pre-solve" scenarios in the committed defaults (e.g. don't enable the HPA or Ingress in values.yaml - flipping them on is the exercise).

## Session State

Two files, written in the same commit by the same close-out, describing the same moment.

`HYDRATION.md` is the prompt that starts a session: what to do, what not to assume, what must be settled first.
Read the **top entry only** - everything below it has been superseded and is kept for history.
Never hand-edit it; the `hydration-prompt` skill owns its ordering and its ten-entry window.

`CONTEXT_STATE.md` is the background that prompt assumes: infrastructure state, active tasks, decisions, lessons learned.
Read it after the prompt, for context.
Check its `last_updated` field first; if it is more than 7 days old, verify the infrastructure rows against reality before trusting them, and refresh it with the `context-compaction` skill.

**When the two disagree, the hydration prompt wins** - and say so, because two files written in the same commit that contradict each other is a defect worth reporting rather than silently resolving.
State describes; the prompt directs.
A stale snapshot is survivable information; an instruction overridden by stale information is how a session confidently does the wrong thing.

## The close-out flow

**Everything the ticket owns happens on the work branch, and the ticket reaches `done` there.** Then one pull request, then the merge, then the handback.

We always roll forward. Nothing about a ticket is left as paperwork that follows the PR, because paperwork that follows a merge is paperwork that gets skipped.

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

**There is exactly one pull request per ticket.** A second PR carrying only state files doubles the review surface for one piece of work and leaves `main` briefly describing a world that no longer exists.

1. Update `CONTEXT_STATE.md` **on the work branch, as part of the work**. New checkpoint at the **top**, newest first. It is part of the deliverable, not paperwork that follows it.
2. **The ticket is marked `done` on the same branch, and everything it needs to get there is done first.** Evidence every acceptance criterion with `--observed`, including what the command or console actually printed; if a criterion is not met, say so plainly rather than dressing it up. Leave the interview-ready retro as a note. Then `work-order.sh done`. This is the rule the rest of the flow depends on: a branch carrying finished code and an unfinished ticket merges into a `main` where the work exists and the record of it does not.
3. Generate the successor's hydration prompt **on the same branch** with the `hydration-prompt` skill. Never hand-edit `HYDRATION.md`; the script owns its ordering and its window.
4. Push once and open **one** PR. It carries the code, the finished ticket, the state file and the hydration prompt together, so one review sees the change and the whole record of the change.
5. After the merge, run `bash .claude/skills/work-order/scripts/work-order.sh close --id WO-...`. It backfills the merge SHA, archives the ticket and regenerates `INDEX.md` **straight to `main`** - no second PR. It falls back to a PR only if that push is rejected.
6. Post-merge cleanup: fast-forward `main`, delete the feature branch locally and on the remote.
7. Hand back **both** the hydration prompt and the command that starts the next session, then hold. Do not start it.

**Never open a PR whose only content is `CONTEXT_STATE.md` or `HYDRATION.md`.**

**Check whether your PR has already merged before every commit once it is open.** A squash merge rewrites the SHA and closes the branch, so a commit pushed seconds later is stranded on a branch nothing points at. Recovery is fast-forward `main`, branch fresh, cherry-pick, delete both sides - but noticing late is avoidable, and it is the usual reason a step gets skipped and the one-PR rule gets broken.

## Hard rules

1. **Never run `terraform apply`, `make up/apply/down`, or otherwise touch real AWS without explicit user approval.** The user drives all applies and destroys. Plans and validation are fine.

   **There are exactly two sanctioned exceptions, both granted explicitly by the user, both narrow on purpose, and both written here rather than left implicit** - because an unwritten exception does not narrow a rule, it voids it: the next reader finds code that destroys AWS resources, finds a rule saying that never happens, and concludes the rule is decorative. Every clause under each is load-bearing and none of them may be dropped without asking again.

   **Exception 1, granted 2026-08-21: the drill GUI's `SHUT IT DOWN` entry.**

   - The learner types the literal string `DESTROY` in the browser, and **the server re-checks it**. A confirmation enforced only in the client is a suggestion.
   - **The pod destroys nothing.** It writes `phase: "destroy-requested"` into a ConfigMap. The destroy is carried out by `scripts/drill-watch.py`, a process the user started themselves, on their own laptop, in their own checkout, against the Terraform state that lives there.
   - The watcher prints a ten-second countdown naming what is about to go, and `ctrl-c` aborts it, so the last gate is in the terminal the user is sitting at. `DRILL_ALLOW_DESTROY=0` disarms the branch entirely.
   - It runs `make down`, so `scripts/pre-destroy.py` runs first and exits 1 rather than destroying into a mess. The safe teardown path is not bypassed - it is the thing being invoked.

   **Exception 2, granted 2026-08-22: idle teardown.** The playground stands itself down after a configurable quiet period, because the control plane bills for as long as it is up and the only thing that stops it is somebody remembering. Every comparable platform - Cloud9, SageMaker Studio, Codespaces, Gitpod - ships one for the same reason.

   Configured entirely on the laptop, on `scripts/drill-watch.py`: `DRILL_IDLE_TIMEOUT` (`90s`, `5m`, `1h`, or bare seconds), `DRILL_IDLE_ACTION` (`warn` or `destroy`), `DRILL_IDLE_GRACE`.

   - **Off unless `DRILL_IDLE_TIMEOUT` is set. There is no default and there must never be one.** A malformed value is fatal, never rounded to something sensible - a destroy timer the user and the machine disagree about is the worst failure available here.
   - **`warn` is the default action.** Arming it is a second deliberate act by the user, not a consequence of turning the clock on.
   - **The pod destroys nothing**, exactly as in Exception 1. It stamps `lastActivityAt` and renders the countdown; `scripts/drill-watch.py` decides and acts.
   - **The deadline is computed only from human input** - a keystroke, a save, a submission. Never from the app's own dependency push, health probe or Argo poll. If chatter counted, an abandoned tab would hold the cluster open forever and the feature would silently never fire.
   - **State that cannot be read is never grounds to destroy.** An unreachable API and an idle learner are different answers, and only one of them may act.
   - The countdown is abortable with `ctrl-c` on a longer grace than Exception 1's ten seconds, because here the user is walking back to the keyboard rather than sitting at it. `DRILL_ALLOW_DESTROY=0` disarms it, and it runs `make down`, so `pre-destroy.py` runs first.

   **The gate Exception 1 has and this one cannot: the typed `DESTROY`.** Its whole premise is that nobody is at the keyboard, so there is no one to type anything. What stands in for it is being off by default, warn-by-default, and a countdown the learner can see in the GUI that any keystroke resets. That substitution is the reason this needed approving separately rather than being read as covered by Exception 1.

   Neither exception generalises. An agent may still never run a destroy on its own initiative, and nothing else in this repo may acquire a "the user pre-approved it" path without the user approving that path specifically.

2. **Config-driven - no defaults, no hardcoding.** Every Terraform variable has NO default; all values live in `scripts/config.toml` (`[common]` + `[dev]`). To add a value: put it in `scripts/config.example.toml` (documented) AND declare the default-less variable threaded through env -> `modules/stack` -> the module. Never write a `default =`. Run Terraform through `scripts/bootstrap.py` / `make`, never bare.
3. **No PII / personal values in git.** No AWS account ids, profile names, real domains, or repo-owner strings outside `scripts/config.toml` (git-ignored) and generated files. The Argo CD Application is generated from the user's git remote (`scripts/gen-argocd-app.py`), never committed.
4. **Test through the sandbox.** Terraform changes: `make -f Makefile.test test` and a ministack plan (`make -f Makefile.test ministack`) via the vendored `container-sandbox` skill (`.claude/skills/container-sandbox/SKILL.md`). Helm chart changes: `make -f Makefile.test helm-lint helm-template` - helm runs INSIDE Podman, do not assume a local helm binary. No real AWS.
5. **Cost discipline.** The control plane bills ~$0.10/hr while up. Whenever you help the user bring the cluster up, remind them `make down` stops the charges. Anything a scenario creates that bills (LBs, PVCs, log groups) must have a cleanup step on its card.
6. **Never touch `.claude/settings.local.json`.** The user maintains it by hand.

## Layout

- `terraform/modules/{vpc,eks,addons,rds,storage,platform}` - implementation (raw resources, transparent for learning).
- `terraform/modules/stack` - composition; the only place modules are wired together.
- `terraform/envs/dev` - thin consumer (backend + providers + one `module "stack"` block; no defaults). Single env on purpose.
- `terraform/bootstrap-oidc` - one-time GitHub Actions OIDC role (config table `[bootstrap_oidc]`).
- `helm/practice-app` - the fe/be app (public images only: nginx + PostgREST + postgres seed job; nothing to build or push).
- `argocd/` - GitOps glue; `argocd/generated/` is git-ignored output.
- `scenarios/` - drill cards; `scenario_testing/` - live-cluster outcome checks (`make check N=NN`); `tests/` - $0 local validation docs.
- `Makefile` (lifecycle) and `Makefile.test` (static + ministack + helm-in-podman). Cross-OS (Linux + Windows 11).

## Conventions

- Providers: AWS `>= 6.0, < 7.0`, helm `>= 2.12, < 3.0`, kubectl (gavinbunney), random. Values blocks via `yamlencode`.
- Kube/AWS auth uses `aws eks get-token` via the `AWS_PROFILE` env var; same config works locally and in CI (OIDC). No profile in `backend.tf` or providers.
- Kubeconfig is repo-local: `.kubeconfig-daily-eks-practice` (git-ignored), written by `make kubeconfig` and exported as `KUBECONFIG` by the Makefile for every target. Never read or write the user's `~/.kube/config`.
- State: partial S3 backend; bucket/region from `[backend]`, key injected per env by `bootstrap.py`. `use_lockfile = true`, no DynamoDB.
- Follow the global markdown rule: one full sentence per line in long Markdown.
- Track problems in `ISSUES.md` (DATE/TIME | description table); park ideas in `BACKLOG.md`.

## Definition of done for changes here

- `make -f Makefile.test test` passes (fmt + validate + helm lint).
- If Terraform changed: a ministack plan was attempted and the result reported.
- If a scenario changed: card, `scenario_testing/check.sh`, and `PRACTICE_ANSWERS.html` all agree.
- No real-AWS side effects unless the user explicitly asked.
