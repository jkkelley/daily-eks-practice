---
{
  "id": "WO-20260822-ec89",
  "slug": "idle-teardown-the-playground-stands-itself-down-",
  "title": "Idle teardown: the playground stands itself down after a configurable quiet period",
  "type": "feature",
  "status": "in-progress",
  "priority": "p1",
  "created": "2026-08-22",
  "updated": "2026-08-22",
  "created_at": "2026-08-22T09:35:13-05:00",
  "parent": null,
  "branch": "feat/idle-teardown-the-playground-stands-itself-down-",
  "pr": null,
  "merge_sha": null,
  "closed": null,
  "approval": {
    "via": "lavish",
    "at": "2026-08-22"
  },
  "evidence": null,
  "surfaces": [],
  "depends_on": [],
  "blocks": []
}
---

# WO-20260822-ec89 - Idle teardown: the playground stands itself down after a configurable quiet period

## Problem

The control plane bills about $0.10/hr for as long as it is up, and the only thing that stops it is a human remembering to run make down. A drill left open over lunch, or a browser tab abandoned on a Friday, bills all weekend with nobody watching. Every comparable platform - Cloud9, SageMaker Studio, Codespaces, Gitpod - ships an idle timeout for exactly this reason, and a playground whose stated premise is cheap spin-up spin-down arguably should have had one from the start. This adds a second path by which this repo destroys AWS resources without a human in the loop, so CLAUDE.md hard rule 1 is amended in the same commit to carry it - an unwritten exception does not narrow a rule, it voids it.

## Scope

**In**

- DRILL_IDLE_TIMEOUT on scripts/drill-watch.py, accepting 90s / 5m / 1h / a bare integer of seconds
- DRILL_IDLE_ACTION=warn|destroy, defaulting to warn, so the clock can be proven before it has teeth
- DRILL_IDLE_GRACE, the abortable countdown before make down, defaulting to 60s
- lastActivityAt on SessionState, stamped ONLY by human input, riding the drill-state mirror that already exists
- a GUI warning that quotes the configured value back to the learner and names how to come back
- amending CLAUDE.md hard rule 1 and the drill-watch.py header to carry the second sanctioned path

**Out - non-goals**

- changing or widening the existing SHUT IT DOWN path
- any default timeout - unset means the feature is off, and that is not negotiable
- the pod destroying anything, or gaining any cluster mutation beyond the drill-state it already writes
- billing alarms, budget alerts or cost reporting - a different feature that shares a motivation
- arming destroy mode by default; flipping DRILL_IDLE_ACTION is a deliberate act by the user

## Acceptance criteria


- [ ] `AC-H1` *(human)* with DRILL_IDLE_TIMEOUT unset the watcher computes no deadline at all and behaves exactly as it does today
- [ ] `AC-H2` *(human)* DRILL_IDLE_TIMEOUT parses 90s, 5m, 1h and a bare integer as seconds, and refuses anything else loudly rather than falling back to a default
- [ ] `AC-H3` *(human)* app chatter does not reset the clock: a session with a connected browser and no human input goes idle despite the 10s dependency push, the health probe and Argo polling
- [ ] `AC-H4` *(human)* a terminal keystroke, an editor save and a submission each reset the clock
- [ ] `AC-H5` *(human)* in warn mode the deadline passes, the GUI and the watcher both say so quoting the configured value, and nothing is destroyed
- [ ] `AC-H6` *(human)* in destroy mode the watcher runs make down so pre-destroy.py runs first, after a DRILL_IDLE_GRACE countdown that ctrl-c aborts
- [ ] `AC-H7` *(human)* DRILL_ALLOW_DESTROY=0 disarms the idle branch exactly as it disarms the SHUT IT DOWN branch
- [ ] `AC-H8` *(human)* the watcher never destroys on state it could not read - an unreachable API says so loudly and does nothing
- [ ] `AC-H9` *(human)* CLAUDE.md hard rule 1 carries the second path, in the same commit, with every gate named

## Test plan

```sh
Unit tests for the duration parser and the deadline computation in tests/test_drill_watch.py, joined to make -f Makefile.test script-tests. Drill-side tests for the lastActivityAt stamping under Podman, asserting that a dependency push does NOT stamp it - that is the assertion the whole feature rests on. A kind harness extending tests/drill-resume-kind.sh proving the clock fires and resets, at a few seconds rather than minutes. Then the real smoke test on EKS at DRILL_IDLE_TIMEOUT=5m in warn mode, then armed.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
