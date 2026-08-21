---
{
  "id": "WO-20260819-1fea",
  "slug": "phase-4-terraform-the-shared-alb-the-source-ip-s",
  "title": "Phase 4: Terraform - the shared ALB, the source-IP security group, and non-orphaning teardown",
  "type": "feature",
  "status": "in-progress",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-20",
  "created_at": "2026-08-19T19:32:20-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-4-terraform-the-shared-alb-the-source-ip-s",
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
    "WO-20260819-98da"
  ],
  "blocks": [
    "WO-20260819-0562",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-1fea - Phase 4: Terraform - the shared ALB, the source-IP security group, and non-orphaning teardown

## Problem

Three ops UIs - the drill GUI, Argo CD and Grafana - would each provision their own ALB. Worse, the AWS Load Balancer Controller creates the ALB so Terraform cannot sequence its deletion, and destroying the cluster first leaves a load balancer billing about $16 a month that nothing in the account points at, plus security groups that make VPC deletion hang. This ticket gives them one shared ALB, restricts it to the operator's own address, and makes teardown delete things in the order that leaves nothing behind. Implements Phase 4, Tasks 4.1 and 4.2 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- one internet-facing ALB shared via the alb.ingress.kubernetes.io/group.name annotation
- a source-IP security group driven by drill_allowed_cidrs
- the 'auto' sentinel in drill_allowed_cidrs, resolved by scripts/bootstrap.py to this machine's current public /32 at plan time, because a residential address is DHCP and a pinned literal goes stale on a lease change and locks the operator out with no error
- make drill-allow as the mid-drill recovery path - it revokes stale rules rather than only adding, and never prints the address
- scripts/pre-destroy.py, run first by make down, deleting Ingresses and the drill PVC and confirming the ALB is gone before terraform destroy

**Out - non-goals**

- application-level auth on the GUI - deferred on 2026-08-19; the triggers that reverse that decision are recorded in plan Task 4.1 and must be carried into the ticket, not dropped
- ACM, TLS, or a DNS zone - enable_external_dns is false and there is no domain
- any real AWS call
- asking the user for a literal IP address, or writing one into any committed file

## Acceptance criteria


- [ ] `AC-H1` *(human)* when the public IP lookup fails, bootstrap.py exits with an error naming the fix rather than dropping the entry or substituting a wildcard - dropping it empties the allow list and locks the operator out, a wildcard opens the terminal to the internet
- [ ] `AC-H2` *(human)* no IP address is printed by make drill-allow, written into a committed file, or echoed by bootstrap.py - only the fact that resolution happened
- [ ] `AC-H3` *(human)* a ministack plan shows one ALB serving all three Ingresses through the shared group name, not three
- [ ] `AC-H4` *(human)* make down deletes the Ingresses and the drill PVC and confirms the ALB is gone before terraform destroy runs, and says so in its output
- [ ] `AC-H5` *(human)* terraform fmt -check and validate pass, and a ministack plan was attempted and its result reported

## Test plan

```sh
python3 tests/test_resolve_auto_cidrs.py for the sentinel resolver, including the lookup-failure case; python3 tests/test_pre_destroy.py for the teardown ordering; make -f Makefile.test test and make -f Makefile.test ministack for the Terraform. The AWS calls inside scripts/drill-allow.py can only reach their guard without a real security group - they are first genuinely exercised in the Phase 7 ticket, and that gap is stated rather than hidden.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
