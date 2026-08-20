---
{
  "id": "WO-20260819-f5c9",
  "slug": "scenario-drill-sessions-make-scenario-n-03-conve",
  "title": "Scenario drill sessions: make scenario N=03 converges an in-cluster graded drill",
  "type": "feature",
  "status": "ready",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:30:25-05:00",
  "parent": null,
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
    "WO-20260819-844f",
    "WO-20260819-11df",
    "WO-20260819-a56c",
    "WO-20260819-98da",
    "WO-20260819-1fea",
    "WO-20260819-ca7c",
    "WO-20260819-7840",
    "WO-20260819-0562"
  ],
  "blocks": []
}
---

# WO-20260819-f5c9 - Scenario drill sessions: make scenario N=03 converges an in-cluster graded drill

## Problem

make scenario N=03 prints a Markdown card and stops. There is no grading, no completion gate, and no way to resume: the answer key sits in PRACTICE_ANSWERS.html where it is one glance away, the card and scenario_testing/check.sh agree only because somebody remembered to keep them in step, and tearing the cluster down loses everything. This epic turns scenario 03 into a converged drill session driven from a single long-lived in-cluster GUI pod that grades task by task from a sealed answers TOML and can restore you to where you left off. It is a vertical slice: scenario 03 only, with the other eleven ported one at a time afterwards. The full implementation plan is `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md` - 8 phases, 22 tasks - and it argues from the spec at `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`. Each of the eight children is one phase of that plan. The plan's `## Global Constraints` and `## The self-contained git rule` sections bind every child and are not restated per ticket. The plan and the spec agree; every contradiction between them was resolved and the spec amended on 2026-08-19.

## Scope

**In**

- Phase 0: a kind sandbox harness so every later phase has one documented way to get a throwaway cluster
- Phase 1: per-scenario answers TOML as the single source of truth, generating the 03 block of PRACTICE_ANSWERS.html
- Phase 2: a semantic grader in TypeScript, running in the pod, with alias expansion and hints
- Phase 3: a permanent in-cluster git server as the only source Argo CD ever reads
- Phase 4: one shared internet-facing ALB restricted to the operator's own IP, with a teardown that does not orphan it
- Phase 5: the mothership GUI - terminal, Monaco editor, answers panel, help panel - and its container image
- Phase 6: session lifecycle, the sync watcher, and the Makefile handover
- Phase 7: live verification on real EKS, approval-gated

**Out - non-goals**

- porting any scenario other than 03 - the other eleven come afterwards, one at a time
- real AWS anywhere except Phase 7, which is separately approval-gated
- Argo CD reading any repoURL outside the cluster, or any GitHub credential on the drill path
- creating a personal access token for any purpose
- any Terraform variable declared with a default value
- application-level auth on the GUI - deferred on 2026-08-19 with its triggers recorded in plan Task 4.1

## Acceptance criteria


- [ ] `AC-H1` *(human)* make scenario N=03 converges a drill session and the GUI serves a working terminal, editor, answers panel and help panel over one ALB
- [ ] `AC-H2` *(human)* all eight child tickets are done, each having passed its own acceptance criteria
- [ ] `AC-H3` *(human)* make -f Makefile.test test still passes, and a ministack plan was attempted and its result reported, for every ticket that touched Terraform
- [ ] `AC-H4` *(human)* scenario 03 is drilled end to end against real EKS with real verdicts, and progress restores to where it left off after a full teardown
- [ ] `AC-H5` *(human)* after make down, no ALB and no available EBS volume is left behind

## Test plan

```sh
Per-child: each ticket carries its own. Epic-level: make -f Makefile.test test for statics, make -f Makefile.test ministack for Terraform, scripts/kind-sandbox.sh plus kubectl for cluster behaviour, and the seven ordered steps of plan Phase 7 for the AWS-shaped half. Nothing in children 1 to 7 touches real AWS.
```

## Assumptions

1. The plan at docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md and the spec at docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md agree; every contradiction was resolved and the spec amended on 2026-08-19. Do not re-litigate either file.
1. Every ticket inherits the plan's ## Global Constraints section verbatim. It is not restated per ticket.
1. Local tooling is present: kind, kubectl, podman 4.9.3, node v20.20.2, python3 3.12.3, jq, tmux. helm is NOT on the host and runs in Podman via docker.io/alpine/helm:latest.

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
