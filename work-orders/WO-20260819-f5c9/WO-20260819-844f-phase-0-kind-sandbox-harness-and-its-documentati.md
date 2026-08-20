---
{
  "id": "WO-20260819-844f",
  "slug": "phase-0-kind-sandbox-harness-and-its-documentati",
  "title": "Phase 0: kind sandbox harness and its documentation",
  "type": "chore",
  "status": "done",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:30:53-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-0-kind-sandbox-harness-and-its-documentati",
  "pr": 11,
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


- [x] `AC-H1` *(human)* scripts/kind-sandbox.sh up run twice in a row is a no-op the second time and still rewrites the kubeconfig
  - observed `2026-08-19` Observed on kind cluster drill-ac2. Second 'up' printed "kind-sandbox: cluster 'drill-ac2' already exists - refreshing kubeconfig", created nothing (kind get clusters stayed at one entry, no 'creating cluster' line), and still rewrote the kubeconfig: mtime moved 1787188645 -> 1787188653 with byte-identical content.
- [x] `AC-H2` *(human)* scripts/kind-sandbox.sh status exits 0 only when the cluster exists and every node reports Ready, non-zero otherwise
  - observed `2026-08-19` Three branches observed. No cluster: 'no cluster daily-eks-drill-sandbox', exit 1 (make surfaces it as exit 2). Cluster up with all nodes Ready: 'cluster up, 1/1 nodes Ready', exit 0. Cluster exists but readiness unconfirmable (kubeconfig removed underneath it): '0/0 nodes Ready', exit 1.
- [x] `AC-H3` *(human)* scripts/kind-sandbox.sh down removes both the cluster and the kubeconfig file
  - observed `2026-08-19` make -f Makefile.test kind-down printed 'Deleted nodes: [daily-eks-drill-sandbox-control-plane]'. Afterwards kind get clusters returned empty, [ -f .kubeconfig-kind-sandbox ] was false, and kind-status exited non-zero.
- [x] `AC-H4` *(human)* the pointer at SKILL.md line 12 resolves to a real section, and that section states plainly what kind cannot tell you
  - observed `2026-08-19` The 'Cluster Tasks: Use the Kind Sandbox' pointer (now SKILL.md line 13 after the markdown formatter hook reflowed headings) resolves to '## Kind Sandbox' at line 162. That section contains '### What Kind cannot tell you' at line 203, which names IRSA token exchange, real IAM, the ALB controller provisioning an actual ALB, EBS volumes and RDS reachability, and states a green Kind run is necessary before spending money and never sufficient.
- [x] `AC-H5` *(human)* the sandbox kubeconfig is repo-local and git-ignored, and the user's ~/.kube/config is never read or written
  - observed `2026-08-19` Kubeconfig path is repo-local: /home/luna/projects/daily-eks-practice/.kubeconfig-kind-sandbox. git check-ignore -v resolves it to .gitignore:54, and git status --porcelain never lists it. The user's ~/.kube/config mtime was byte-stable at 1787188699 across a full up/up/status/down cycle, and no kind-drill-* context was left in it. This only holds because of the --kubeconfig fix; the plan's original harness was observed moving that mtime.

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

- `2026-08-19` Deviation 2 from the plan text, and a real defect it would have shipped. The plan's harness runs kind create cluster without --kubeconfig, so kind merges the new context into the user's ~/.kube/config. Observed directly: that file's mtime moved from 20:13:41 to 20:17:17 across a harness run. Added --kubeconfig "$KUBECONFIG_FILE" to both create and delete, and added a tenth test assertion that samples only the mtime of ~/.kube/config and fails if it moves. The plan's expected '9 assertions' is therefore 10.
- `2026-08-19` Deviation 1 from the plan text, required by AC-H5. The plan's tests/kind-sandbox.sh does KUBECONFIG="$KC" kubectl get nodes, and on a failing run KC is empty, so kubectl falls back to the user's ~/.kube/config and blocks on an unreachable endpoint. That both hung the mandatory step-3 failing run at 120s and read the file this repo must never read. Guarded the assertion on a non-empty KC and added --request-timeout=15s.
- `2026-08-19` Plan Task 0.1 Steps 1-7 done, strict TDD. Test written first and observed failing with 'bash: scripts/kind-sandbox.sh: No such file or directory', 3 passed / 6 failed, exit 1. After the harness landed the same test is 10 passed / 0 failed, exit 0. make -f Makefile.test test exits 0.

## Outcome

_Written by `work-order close`. Empty until then._
