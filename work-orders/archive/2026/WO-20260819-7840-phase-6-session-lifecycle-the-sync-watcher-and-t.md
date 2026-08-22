---
{
  "id": "WO-20260819-7840",
  "slug": "phase-6-session-lifecycle-the-sync-watcher-and-t",
  "title": "Phase 6: session lifecycle, the sync watcher, and the Makefile handover",
  "type": "feature",
  "status": "done",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-21",
  "created_at": "2026-08-19T19:33:00-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-6-session-lifecycle-the-sync-watcher-and-t",
  "pr": 29,
  "merge_sha": "cb2c5c97f9eaf30e8f32e7c4e3a86695a3e30330",
  "closed": "2026-08-21",
  "approval": {
    "via": "lavish",
    "at": "2026-08-19"
  },
  "evidence": null,
  "surfaces": [],
  "depends_on": [
    "WO-20260819-98da",
    "WO-20260819-ca7c"
  ],
  "blocks": [
    "WO-20260819-0562",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-7840 - Phase 6: session lifecycle, the sync watcher, and the Makefile handover

## Problem

Progress dies with the cluster, and make scenario N=03 still just prints a card. A drill you cannot resume is a drill you only ever do once. This ticket makes curriculum progress a git bundle save file in the local repo that can rebuild a scenario from where you left off, makes make scenario N=03 converge a session rather than print one, and hands the user over to the GUI cleanly. Resume works by converging to a declared state, not by replaying actions, so it either works completely or it does not work at all. Implements Phase 6, Tasks 6.1 through 6.5 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- gitignored drill-progress/ on the laptop, as append-only sessions of git bundle save files
- the session ConfigMap and the sync watcher that keeps it current
- make scenario N=03 converging a session rather than printing a card
- the Makefile handover, including refusing a second scenario while one is live
- exit and tear down from the GUI

**Out - non-goals**

- any real AWS call
- porting scenarios other than 03
- supporting two scenarios at once - a concurrent start is refused by design, not queued
- a diary or event log of what the user did; the save file is a state snapshot, not a replay

## Acceptance criteria


- [x] `AC-H1` *(human)* drill-progress/ is added to .gitignore before the directory can exist, so a save file is never one git add -A away from being committed
  - observed `2026-08-21` MET. drill-progress/ was added to .gitignore in commit 831a7cf, the same commit that created scripts/progress.py, and the entry is Step 1 of Task 6.1 rather than Step 4 for exactly this reason. tests/test_progress.py additionally pins that nothing is created merely by importing or querying the module: 'every query against an empty store answers None' and 'querying created no files at all' both pass, so drill-progress/ cannot appear during 'make -f Makefile.test test' in a checkout where nobody is drilling. Verified with 'git check-ignore -v drill-progress/' resolving to the .gitignore line.
- [x] `AC-H2` *(human)* make scenario N=03 run twice converges to the same state rather than replaying, and the second run is not an error
  - observed `2026-08-21` MET. Asserted on the FILESYSTEM, not on the exit code, because an implementation that creates a second session and exits 0 would pass an exit-code test and fail this criterion. tests/test_scenario.py::test_AC_H2_converging_twice_produces_exactly_one_session: 'the first converge starts a session' PASS, 'the second converge does NOT start another' PASS, 'and it is the same session' PASS, 'exactly one session directory on disk' PASS, 'exactly one results row' PASS. Also exercised through real make: with the handover flag set for scenario 03, 'make scenario N=03' gets past its own guard (the lock is argument-scoped precisely so it can) and then refuses only because no cluster is reachable, printing 'scenario: no cluster is reachable, so there is nothing to converge. Bring one up: make up. Read the card meanwhile: cat scenarios/03-rolling-update-rollback.md'.
- [x] `AC-H3` *(human)* starting a second scenario while one is live is refused by name, with a message saying what is already running
  - observed `2026-08-21` MET, by name AND by title. Run through real make with drill-progress/.gui-owns-the-wheel naming scenario 03: 'make scenario N=05' printed 'make scenario: refused - scenario 03 is open in the drill GUI. one drill at a time - scenarios mutate the same app, so a second makes cluster state unattributable. Switch scenario from the GUI's pause menu - that is what it is for.' and exited 1. tests/test_scenario.py asserts the message contains both '03' and its title 'Rolling update + rollback', not merely that the exit code is 1 - 'another scenario is running' is a refusal the learner cannot act on. The GUI refuses too: POST /api/session/switch to an unported scenario returns 409 naming the id and the title.
- [x] `AC-H4` *(human)* on kind: converge a session, tear the cluster down, bring it back, and make scenario N=03 restores to exactly where it left off
  - observed `2026-08-21` MET on kind, with a real cluster destroyed and rebuilt. 'make -f Makefile.test drill-resume-test' - tests/drill-resume-kind.sh - reported 'AC-H4: 20 passed, 0 failed'. The cycle: seed cluster git, make a real commit the way the drill makes one (clone, edit values.yaml, commit, push), mirror a session into drill-state with tasks 1 and 2 passed, run the watcher, then 'kind delete cluster'. Verified the teardown was real rather than assumed - 'the API server is genuinely unreachable, not merely empty' PASS - and that the replacement cluster git had no history before the restore - 'the new cluster git has NO history - nothing up our sleeve' PASS. After restoring the bundle: 'THE LEARNER'S EDIT IS BACK, in a cluster that never saw it' PASS, and 'at the very same commit, not merely similar content' PASS, comparing rev-parse main before and after. The save file itself is verified with 'git bundle verify' before it is ever renamed into place.
- [x] `AC-H5` *(human)* exiting from the GUI tears the session down and leaves nothing billing or bound
  - observed `2026-08-21` MET for what the SCENARIO created, and the wording needs to be precise about the rest. QUIT ends the session, syncs a final time and clears the handover flag; the laptop watcher then deletes the Argo Application and the practice-app namespace, taking any LoadBalancer Service or PVC a scenario created with it. The drill pod, its PVC and the ALB deliberately stay up, so the learner lands on a game-over screen with the menu still reachable - nothing the GUI does may strand them outside the browser, which is the north star. The cluster itself is therefore still billing after QUIT, and the game-over screen says so in as many words and names 'make down'. Stopping the bill entirely is the second entry, SHUT IT DOWN, which the user explicitly approved at the Phase 6 kickoff as a narrow exception to CLAUDE.md hard rule 1 - amended in the same commit to carry it. Verified in the browser: the destroy button stays disabled until DESTROY is typed exactly, and the server re-checks it - server.test.ts drives five near-misses ({}, '', 'destroy', 'DESTROY ' with a trailing space, 'yes') and all five return 400, and only the exact literal reaches phase 'destroy-requested'. NOT verified end to end: the watcher branch that actually runs 'make down' was exercised only through its DRILL_ALLOW_DESTROY=0 disarm path, because running it for real would destroy an environment and needs the user driving it. That is Phase 7's step 6.

## Test plan

```sh
python3 tests/test_progress.py for the save-file mechanics, then a full converge, teardown, rebuild and restore cycle against the kind sandbox. No AWS. The Makefile refusal path is exercised by starting a second scenario and asserting the exit code and the message.
```

## Assumptions

1. Tasks 6.1 through 6.5 are specified at interface and intent level in the plan, deliberately. They must be expanded into full step-by-step tasks after the Phase 5 ticket's Task 5.3 review and before work starts here. Do not implement them as if they were fully specified.

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

- `2026-08-21` RETRO. The interface-level plan had one EXIT button behind POST /api/teardown. That was wrong in a way only visible once the GUI existed: EXIT is not one action. A learner done with 03 wants to restart it, or go to 06, or back to 02, or stop, or stop AND stop the bill - and one destructive verb cannot tell which. Collapsing them made restart and next reachable only by tearing the environment down and rebuilding it. The user's steer at kickoff was to make it a pause menu with video-game logic, and it cost a menu and four routes rather than a subsystem, because switching scenarios is the converge path with a different N. This is the argument FOR holding a phase at interface level: expanding Phase 6 early would have produced a detailed plan for the wrong thing. The design decision I would defend hardest is the two-ConfigMap contract. drill-state has exactly one writer (the server); drill-request has exactly one writer (the laptop). One object with two authors races on resourceVersion, and the write it loses is a task the learner just passed. Two objects cost one extra GET. The related one: the pod writes drill-state and mutates NOTHING else in the cluster - QUIT does not delete the Argo Application from inside the pod, it records a phase and the laptop acts. That keeps the blast radius of an unauthenticated cluster-admin web terminal at 'it can write its own status', and it is what makes the SHUT IT DOWN exception defensible instead of a hole. Where I was wrong twice, both caught by running things rather than reading them. First: the resume harness invented the container name 'git-daemon'. That is the binary; the container is 'git'. Every assertion downstream failed with one BadRequest that was invisible until I unmuted the output - 10 of 20 assertions red, all from one wrong string. Second, and worse because it was not mine: drill-gui-kind.sh had a latent ordering bug from Phase 5. A terraform plan lists resource_changes alphabetically, so drill_deployment came out before drill_namespace; kubectl apply processes in file order, does not stop at the first error, and the harness discarded the exit code. The Deployment failed with 'namespaces not found' while everything else was created - so the namespace then existed and a SECOND run passed. That is exactly how a harness reports 21 green while never having deployed the thing it tests. Fixed by sorting into dependency order and by making the apply's exit code an assertion of its own. The verification ladder earned its keep again at the top rung. Four defects reached a green 186-test suite and a clean typecheck and were found only by looking: the Esc note read as an eighth menu entry, the back button sat against the title because .grow is scoped to .panel and .statusbar, a one-line scenario card rendered visibly shorter than a two-line one, and the destroy dialog's heading was accent blue - the one screen in this product with consequences, toned identically to the theme picker. None of those is findable by a test that does not have eyes. What is NOT done, and is the honest gap: only 03 is ported, so the switch machinery is proven but the round trip it exists for - drill 03, switch to 06, drill 06, switch back and find 03 where you left it - has no fixture. It is the exit-condition test for whichever epic ports the second scenario, recorded in four places because Phase 4's AC-H3 nearly lapsed by being written down once. Also: the watcher's 'make down' branch was exercised only via its DRILL_ALLOW_DESTROY=0 disarm, because running it for real destroys an environment and is the user's to drive.

## Outcome

_Written by `work-order close`. Empty until then._
