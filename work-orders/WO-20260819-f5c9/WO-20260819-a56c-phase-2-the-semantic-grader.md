---
{
  "id": "WO-20260819-a56c",
  "slug": "phase-2-the-semantic-grader",
  "title": "Phase 2: the semantic grader",
  "type": "feature",
  "status": "ready",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:31:40-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": null,
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
    "WO-20260819-11df"
  ],
  "blocks": [
    "WO-20260819-ca7c",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-a56c - Phase 2: the semantic grader

## Problem

Nothing decides whether an answer is right. String equality is the wrong instrument: 'k get po -n practice' and 'kubectl get pods --namespace practice' are the same command, and a drill that marks one wrong teaches typing rather than Kubernetes. This ticket builds the grader as pure functions over strings and files - no cluster, no AWS, no network - so it is testable before anything can call it. Implements Phase 2, Tasks 2.1 through 2.4 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- the drill/ TypeScript workspace: package.json, tsconfig.base.json, drill/shared and drill/server, all installed and tested inside Podman
- alias expansion (k -> kubectl, po -> pods, and the rest of the table)
- semantic command parsing producing ParsedCommand, so flag order and short or long form do not change the verdict
- grading and hints across the three grader kinds: command, file and prose
- the shared types Verdict, SessionState, Attempt and DependencyStatus in @drill/shared, defined once here and consumed unchanged by Phase 5
- running Phase 1's invalid-TOML fixtures through drill/server/src/grader/answers.ts, so the two validators cannot drift
- drill-install, drill-test and drill-build targets in Makefile.test

**Out - non-goals**

- any UI - the GUI is the Phase 5 ticket
- the PTY, the websocket, or anything that talks to a cluster or the network
- grading in Python - the grader runs inside the pod's Node process and shipping a Python runtime in the image would buy nothing
- running npm install on the host - it runs in Podman, always

## Acceptance criteria


- [ ] `AC-H1` *(human)* 'k get po -n x' and 'kubectl get pods --namespace x' produce the same verdict
- [ ] `AC-H2` *(human)* reordering flags, or swapping a short flag for its long form, does not change the verdict
- [ ] `AC-H3` *(human)* every invalid fixture from the Phase 1 ticket is rejected by the TypeScript validator with the same failure the Python validator gives
- [ ] `AC-H4` *(human)* a wrong answer returns a hint that names what was actually wrong, not a generic failure
- [ ] `AC-H5` *(human)* npm install and the whole test run happen inside Podman, and no node_modules directory appears on the host

## Test plan

```sh
make -f Makefile.test drill-install drill-test, which runs the workspace test suite inside Podman. The grader has no fixtures outside the repo and needs no cluster, so this is the complete proof for this ticket.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
