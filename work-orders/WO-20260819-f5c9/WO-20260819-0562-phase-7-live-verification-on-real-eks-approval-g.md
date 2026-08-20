---
{
  "id": "WO-20260819-0562",
  "slug": "phase-7-live-verification-on-real-eks-approval-g",
  "title": "Phase 7: live verification on real EKS - APPROVAL GATED, about $6.50 per 30-hour cycle",
  "type": "chore",
  "status": "ready",
  "priority": "p2",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:33:01-05:00",
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
    "WO-20260819-1fea",
    "WO-20260819-7840"
  ],
  "blocks": [
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-0562 - Phase 7: live verification on real EKS - APPROVAL GATED, about $6.50 per 30-hour cycle

## Problem

Everything up to here is proven on kind, ministack and Podman. What none of them can prove is the AWS-shaped half: IRSA, the AWS Load Balancer Controller actually provisioning an ALB, the source-IP security group actually restricting it, real EBS volumes behind the PVCs, and the teardown ordering that keeps them from orphaning. This is the only ticket in the epic that touches real AWS and the only one that costs money. Its first step is to ask, with the number, and wait. Implements Phase 7, Steps 1 through 7 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- presenting the cost and waiting for an explicit yes before anything runs
- make up, kubeconfig, git-seed, app-deploy and argo-sync
- verifying the four AWS-shaped things kind could not: one shared ALB, the source-IP restriction, a real EBS volume behind the PVC, and Argo reading cluster git rather than GitHub
- exercising scripts/drill-allow.py against a real security group for the first time, twice, to prove it does not churn the rule
- drilling scenario 03 end to end in the GUI with real answers and real verdicts
- verifying progress survives a full teardown and restores
- verifying teardown orphans nothing, and reporting honestly what passed, what did not, and what was skipped

**Out - non-goals**

- running any step before the user has approved the cost - this is the gate, and it is the whole reason this is a separate ticket
- porting scenarios other than 03
- fixing anything discovered during the drill inside this ticket - findings go to ISSUES.md, ideas go to BACKLOG.md
- leaving the cluster up after verification finishes

## Acceptance criteria


- [ ] `AC-H1` *(human)* approval was asked for with the figure - about $6.50 for a 30-hour cycle, of which the drill platform's own share is roughly $1.05 - and recorded before make up ran
- [ ] `AC-H2` *(human)* exactly one ALB exists, not three, confirming the shared IngressGroup
- [ ] `AC-H3` *(human)* the GUI is reachable from the configured address and refused from anywhere else, confirming the security group
- [ ] `AC-H4` *(human)* make drill-allow run a second time reports 'already correct, nothing to do' - a second run that changes something means the comparison logic churns the rule on every invocation
- [ ] `AC-H5` *(human)* scenario 03 is drilled through all six tasks with real verdicts, and task 5 shows Argo putting the bad version back after a rollout undo
- [ ] `AC-H6` *(human)* after a teardown and rebuild, make scenario N=03 restores to exactly where the drill left off
- [ ] `AC-H7` *(human)* after make down, both the ALB query and the available-volumes query return empty
- [ ] `AC-H8` *(human)* the outcome is reported honestly, naming what passed, what did not, and what was skipped

## Test plan

```sh
The seven ordered steps of plan Phase 7. Step 1 is the approval gate and nothing runs before it. Step 6 is the teardown check: make down, then aws elbv2 describe-load-balancers filtered on k8s- and aws ec2 describe-volumes filtered on status available, both of which must come back empty. A kind pass is necessary before spending money and never sufficient.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
