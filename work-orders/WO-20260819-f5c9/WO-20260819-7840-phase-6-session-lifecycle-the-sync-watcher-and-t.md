---
{
  "id": "WO-20260819-7840",
  "slug": "phase-6-session-lifecycle-the-sync-watcher-and-t",
  "title": "Phase 6: session lifecycle, the sync watcher, and the Makefile handover",
  "type": "feature",
  "status": "in-progress",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-21",
  "created_at": "2026-08-19T19:33:00-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-6-session-lifecycle-the-sync-watcher-and-t",
  "pr": null,
  "merge_sha": null,
  "closed": null,
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


- [ ] `AC-H1` *(human)* drill-progress/ is added to .gitignore before the directory can exist, so a save file is never one git add -A away from being committed
- [ ] `AC-H2` *(human)* make scenario N=03 run twice converges to the same state rather than replaying, and the second run is not an error
- [ ] `AC-H3` *(human)* starting a second scenario while one is live is refused by name, with a message saying what is already running
- [ ] `AC-H4` *(human)* on kind: converge a session, tear the cluster down, bring it back, and make scenario N=03 restores to exactly where it left off
- [ ] `AC-H5` *(human)* exiting from the GUI tears the session down and leaves nothing billing or bound

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

## Outcome

_Written by `work-order close`. Empty until then._
