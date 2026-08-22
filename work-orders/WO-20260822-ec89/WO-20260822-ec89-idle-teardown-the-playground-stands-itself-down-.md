---
{
  "id": "WO-20260822-ec89",
  "slug": "idle-teardown-the-playground-stands-itself-down-",
  "title": "Idle teardown: the playground stands itself down after a configurable quiet period",
  "type": "feature",
  "status": "in-review",
  "priority": "p1",
  "created": "2026-08-22",
  "updated": "2026-08-22",
  "created_at": "2026-08-22T09:35:13-05:00",
  "parent": null,
  "branch": "feat/idle-teardown-the-playground-stands-itself-down-",
  "pr": 34,
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


- [x] `AC-H1` *(human)* with DRILL_IDLE_TIMEOUT unset the watcher computes no deadline at all and behaves exactly as it does today
  - observed `2026-08-22` idle_policy_from_env({}) returns None, as do an empty value and whitespace - tests/test_drill_watch.py test_unset_means_off_and_nothing_else_does, 3 assertions. watch() takes policy=None and constructs no IdleMonitor at all, so the code path is absent rather than merely inert.
- [x] `AC-H2` *(human)* DRILL_IDLE_TIMEOUT parses 90s, 5m, 1h and a bare integer as seconds, and refuses anything else loudly rather than falling back to a default
  - observed `2026-08-22` Observed: '90'->90s, '90s'->90s, '5m'->300s, '1h'->3600s, '30m'->1800s, '2h'->7200s, ' 5M '->300s. Refused with IdleConfigError, not defaulted: '', ' ', '0', '0s', '5x', 'abc', '-5', '5 m', 'm', '1.5h'. The zero refusal names the fix - 'unset DRILL_IDLE_TIMEOUT rather than setting it to zero'. main() exits 2 on a bad value before anything else runs.
- [x] `AC-H3` *(human)* app chatter does not reset the clock: a session with a connected browser and no human input goes idle despite the 10s dependency push, the health probe and Argo polling
  - observed `2026-08-22` drill/server/src/ws.test.ts 'the idle clock is stamped by human input and by NOTHING else': after connect + a dependency frame arriving, marks stayed at 1 (the startup stamp). A term:resize also left it at 1. VERIFIED AGAINST THE BROKEN VERSION: patching pushDeps to call activity.mark() turned it red with 'connecting and receiving a dependency push must NOT count as activity', then reverted to green.
- [x] `AC-H4` *(human)* a terminal keystroke, an editor save and a submission each reset the clock
  - observed `2026-08-22` Same ws test: a term:input keystroke took marks 1->2, a file:save (acknowledged by file:saved) took it 2->3, and POST /api/submit took it 3->4. Each asserted individually, so a single over-eager mark cannot satisfy all three.
- [x] `AC-H5` *(human)* in warn mode the deadline passes, the GUI and the watcher both say so quoting the configured value, and nothing is destroyed
  - observed `2026-08-22` Watcher side: IdleMonitor.tick() in warn mode at 100s past a 60s limit returned 'warned-only', called on_fire ZERO times and left .fired False - test_the_monitor_fires_only_when_armed. VERIFIED AGAINST THE BROKEN VERSION: replacing 'if not self.policy.armed' with 'if False' turned three assertions red, then reverted. Banner: idle_banner() in warn mode says 'WOULD self-terminate', never 'SELF-TERMINATES', and names DRILL_IDLE_ACTION=destroy as the way to arm it. GUI side: idleView() carries action through and IdleBanner.tsx renders the WOULD copy. Both quote the configured value back - the banner asserts '5m' and '48s' appear.
- [ ] `AC-H6` *(human)* in destroy mode the watcher runs make down so pre-destroy.py runs first, after a DRILL_IDLE_GRACE countdown that ctrl-c aborts
- [x] `AC-H7` *(human)* DRILL_ALLOW_DESTROY=0 disarms the idle branch exactly as it disarms the SHUT IT DOWN branch
  - observed `2026-08-22` idle_destroy() checks DRILL_ALLOW_DESTROY=0 first, before printing anything and before the countdown, and returns 0 having run nothing - the same position and the same check the SHUT IT DOWN destroy() uses. Read side by side in scripts/drill-watch.py; both branches are the first statement of their function.
- [x] `AC-H8` *(human)* the watcher never destroys on state it could not read - an unreachable API says so loudly and does nothing
  - observed `2026-08-22` idle_verdict returns 'unknown' for a missing lastActivityAt and for an unparseable one, and 'stale' when the last successful read is older than timeout+IDLE_STALE_MARGIN. The assertion that matters: an activity stamp old enough to fire, read 10000s ago, returns 'stale' NOT 'fire' - while the same staleness with a live read does fire. VERIFIED AGAINST THE BROKEN VERSION: deleting the staleness guard turned two assertions red ('a state that was never successfully read is stale, not idle' and 'an old activity stamp behind a DEAD API is stale, not fire'), then reverted to 82 passed / 0 failed. IdleMonitor.tick() also returns 'unknown'/'stale' rather than acting, and complains once rather than per second.
- [x] `AC-H9` *(human)* CLAUDE.md hard rule 1 carries the second path, in the same commit, with every gate named
  - observed `2026-08-22` CLAUDE.md hard rule 1 now reads 'exactly two sanctioned exceptions', with Exception 2 carrying all six gates named individually plus an explicit paragraph on the gate it CANNOT have - the typed DESTROY - and what substitutes for it. Shipped in the same commit as the code (c81f40c). scripts/drill-watch.py's module header carries the same exception in full, beside the existing one. COMPASS.md's drill-watch.py row updated and a row added for drill/server/src/activity.ts; COMPASS is 96 lines, inside its 100 cap.

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

- `2026-08-22` RETRO. The design question that mattered was not how to time something out, it was what counts as somebody being there. The obvious answer - any request - would have shipped a feature that passed every test and never once fired, because this app pushes a dependency frame every ten seconds and an abandoned browser tab therefore looks identical to a busy learner. That is the same vacuous-pass family as the AC-H5 assertion that went green against a pod which did not exist, and it is why the load-bearing test asserts a NEGATIVE: the deps push must NOT stamp. Three separate guards were each verified by breaking the implementation and watching the specific assertion go red, then reverting - the deps push, the staleness guard and the armed check. Two real defects surfaced while wiring it up rather than from any test: drill/package.json's test script never built @drill/shared, which was harmless while shared was types-only and became an ordering trap the moment it carried runtime code; and 'ctrl-c to abort' was describing a gate that does not exist on the default path, because make scenario starts the watcher detached with stdin on /dev/null. The second is the more interesting one - a safeguard nobody can reach is worse than an absent one, because it still gets counted as a safeguard by the next person reading the file. It now says so instead. The honest weak point of the whole feature is that the gate the SHUT IT DOWN path gets from a typed confirmation cannot exist here by construction, so what stands in for it is three weaker things stacked: off by default, warn by default, and a countdown any keystroke resets.
- `2026-08-22` AC-H6 is DELIBERATELY LEFT UNOBSERVED and the ticket therefore cannot reach done yet. It asks for the watcher actually running make down after an abortable DRILL_IDLE_GRACE countdown, and there is no way to observe that without destroying a real environment - the same shape as the AC-H3 lesson from Phase 4, where a criterion was untestable in the phase that owned it. Everything AROUND it is observed: the DRILL_ALLOW_DESTROY=0 disarm returns before the countdown, the countdown is a plain range() over policy.grace guarded by KeyboardInterrupt, and the last statement is subprocess.run(['make','down']) - which is the same call the SHUT IT DOWN path makes, so pre-destroy.py runs first by construction rather than by a second implementation. What is NOT proven is that it does that against a live cluster. The place that proves it is WO-20260819-0562 - Phase 7: live verification on real EKS - APPROVAL GATED, about 6.50 USD per 30-hour cycle, whose smoke test brings a real cluster up anyway. Recommended sequencing: merge this code first so the drill image carries the lastActivityAt stamping, run the 5-minute smoke test in warn mode, then armed, then evidence AC-H6 and close this ticket. Merging first is what makes the smoke test possible at all, because without the stamping in the image there is nothing for the clock to read.

## Outcome

_Written by `work-order close`. Empty until then._
