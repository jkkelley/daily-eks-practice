---
{
  "id": "WO-20260819-844f",
  "slug": "phase-0-kind-sandbox-harness-and-its-documentati",
  "title": "Phase 0: kind sandbox harness and its documentation",
  "type": "chore",
  "status": "ready",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:30:53-05:00",
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
  "depends_on": [],
  "blocks": [
    "WO-20260819-98da",
    "WO-20260819-ca7c",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-844f - Phase 0: kind sandbox harness and its documentation

## Problem

.claude/skills/container-sandbox/SKILL.md line 12 points at a '## Kind Sandbox' section that does not exist in the file. Every later phase needs a throwaway cluster to prove cluster behaviour on, because ministack mocks AWS and never runs a pod, so without this harness the first place a pod-level assumption gets tested is real EKS at cost. This ticket writes the section and provides the harness it describes. Implements Phase 0, Task 0.1 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- scripts/kind-sandbox.sh with up, down, status and kubeconfig subcommands
- the '## Kind Sandbox' section of .claude/skills/container-sandbox/SKILL.md, placed after '## Terraform / Ministack Sandbox'
- kind-up, kind-down and kind-status targets in Makefile.test
- tests/kind-sandbox.sh
- .kubeconfig-kind-sandbox added to .gitignore

**Out - non-goals**

- any AWS call, of any kind
- replacing ministack - kind proves cluster behaviour, ministack proves Terraform plans, and neither substitutes for the other
- minikube support, even though minikube is installed
- installing anything into the sandbox cluster - each later ticket installs what it needs

## Acceptance criteria


- [ ] `AC-H1` *(human)* scripts/kind-sandbox.sh up run twice in a row is a no-op the second time and still rewrites the kubeconfig
- [ ] `AC-H2` *(human)* scripts/kind-sandbox.sh status exits 0 only when the cluster exists and every node reports Ready, non-zero otherwise
- [ ] `AC-H3` *(human)* scripts/kind-sandbox.sh down removes both the cluster and the kubeconfig file
- [ ] `AC-H4` *(human)* the pointer at SKILL.md line 12 resolves to a real section, and that section states plainly what kind cannot tell you
- [ ] `AC-H5` *(human)* the sandbox kubeconfig is repo-local and git-ignored, and the user's ~/.kube/config is never read or written

## Test plan

```sh
bash tests/kind-sandbox.sh, which exercises up, idempotent up, status, kubeconfig and down against real kind. Then make -f Makefile.test test to confirm nothing static broke.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
