---
{
  "id": "WO-20260819-1fea",
  "slug": "phase-4-terraform-the-shared-alb-the-source-ip-s",
  "title": "Phase 4: Terraform - the shared ALB, the source-IP security group, and non-orphaning teardown",
  "type": "feature",
  "status": "done",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-20",
  "created_at": "2026-08-19T19:32:20-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-4-terraform-the-shared-alb-the-source-ip-s",
  "pr": 25,
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


- [x] `AC-H1` *(human)* when the public IP lookup fails, bootstrap.py exits with an error naming the fix rather than dropping the entry or substituting a wildcard - dropping it empties the allow list and locks the operator out, a wildcard opens the terminal to the internet
  - observed `2026-08-20` Phase 3's scripts/bootstrap.py:128-132 exits on a failed lookup with 'drill_allowed_cidrs is ["auto"] but your public IP could not be determined (no network?). Set a literal CIDR in scripts/config.toml, or retry.' It names the fix, drops nothing, and never substitutes a wildcard. Pinned by tests/test_resolve_auto_cidrs.py::test_lookup_failure_exits_instead_of_dropping_the_entry, which passes. The same rule now holds in scripts/drill-allow.py, whose own lookup-failure path exits with 'The allow list was left untouched' - covered by tests/test_drill_allow.py::test_failed_ip_lookup_exits_rather_than_guessing, which also asserts AWS is never called and that no wildcard is suggested.
- [x] `AC-H2` *(human)* no IP address is printed by make drill-allow, written into a committed file, or echoed by bootstrap.py - only the fact that resolution happened
  - observed `2026-08-20` Nine assertions in tests/test_drill_allow.py, all passing. Three of them run main() end to end with a fake address and assert it never appears in stdout or stderr - while adding a rule, while revoking a stale one, and on the no-op path. A fourth covers the case the plan got wrong: the plan's aws() reported failures as sys.exit(f"...{' '.join(cmd)} failed..."), and revoke/authorize carry --cidr <the operator's ip>/32, so every AWS failure printed the address. It now names the operation only. I verified the assertion catches it by temporarily restoring the plan's line - it goes red with 'the failed-command message echoed the CIDR, leaking the operator's IP', then green after. Live run: 'make drill-allow' with no cluster printed only 'no drill ALB security group in state - is the cluster up?'. No CIDR is in any committed file; the SG reads var.drill_allowed_cidrs, which lives in the git-ignored scripts/config.toml.
- [x] `AC-H3` *(human)* a ministack plan shows one ALB serving all three Ingresses through the shared group name, not three
  - observed `2026-08-20` PARTIAL, and the gap is in the criterion rather than the work. No Ingress exists yet: plan Task 4.1 states the Ingress resources ship in Phase 5 with the GUI so the ALB is never created before something needs it, so 'one ALB serving three Ingresses' cannot be observed until Phase 5. What the ministack plan does show (61 to add, 0 to change): aws_security_group.drill_alb[0], aws_vpc_security_group_ingress_rule.drill_alb_http["203.0.113.10/32"] keyed per CIDR, aws_vpc_security_group_egress_rule.drill_alb_all[0], terraform_data.drill_cidr_guard[0], and outputs drill_alb_security_group_id (known after apply) plus drill_ingress_group_name = "daily-eks-practice-ops". The single shared group name is exported once and consumed by every ops Ingress, which is the mechanism that makes it one ALB; the count itself is first observable at Phase 5 and first real at Phase 7.
- [x] `AC-H4` *(human)* make down deletes the Ingresses and the drill PVC and confirms the ALB is gone before terraform destroy runs, and says so in its output
  - observed `2026-08-20` 'make -n down' prints, in order: the guard-env case statement, 'python3 scripts/pre-destroy.py', 'python3 scripts/bootstrap.py dev init -input=false', 'python3 scripts/bootstrap.py dev destroy -auto-approve'. pre-destroy runs first and its plan() deletes every Ingress, every LoadBalancer Service and every PVC (the drill PVC and the cluster git PVC included) before any wait, then polls up to 300s for this cluster's load balancers and exits 1 with 'load balancers are STILL present after the timeout' rather than destroying into a mess. Eleven tests in tests/test_pre_destroy.py pass, including one that every delete precedes every wait. Live: a real run against the destroyed cluster printed 'cluster API is unreachable - nothing to clean up, continuing' and exited 0; SKIP_PRE_DESTROY=1 printed 'skipped' and exited 0. It says what it removed - each delete prints its own line, and failures print a WARNING naming what will be orphaned. No terraform destroy was run.
- [x] `AC-H5` *(human)* terraform fmt -check and validate pass, and a ministack plan was attempted and its result reported
  - observed `2026-08-20` 'make -f Makefile.test test' exits 0 (fmt-check, validate for envs/dev and bootstrap-oidc, helm-lint, history-scrubber, answers-check, script-tests). 'make -f Makefile.test fmt-check validate' passes on its own: 'Success! The configuration is valid.' for both. Ministack was attempted and succeeded: 'Plan: 61 to add, 0 to change, 0 to destroy', plan saved to terraform/envs/dev/test/ministack.tfplan. Both guards were also proven to fire rather than merely written - TF_VAR_drill_allowed_cidrs='["0.0.0.0/0"]' fails with 'Error: Resource precondition failed' quoting the drill_allowed_cidrs message, and '[]' fails with the empty-list message; make exits 1 in both cases. Phase 3's kind acceptance test still passes: 'make -f Makefile.test cluster-git-test' reports 13 passed, 0 failed.

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

- `2026-08-20` Four plan defects found by execution, all invisible on reading. (1) Task 4.1 Step 5 says to test the CIDR guard by editing scripts/config.toml, the user's git-ignored file that CLAUDE.md says not to touch without asking; TF_VAR_drill_allowed_cidrs proves the same thing and touches nothing. (2) drill-allow.py's error path breaks its own AC-H2 by echoing the full command line, which carries --cidr <the operator's ip>/32. (3) Task 4.2's own test cannot import Task 4.2's own script: @dataclass under 'from __future__ import annotations' resolves annotations through sys.modules[cls.__module__], which is None for an importlib-loaded module, so it dies before any assertion runs. (4) remaining_load_balancers() fetches the cluster name and discards it, counting every k8s- named load balancer in the account, so a second EKS cluster would make make down wait out its full timeout and refuse every time; the interface section said 'tagged with this cluster' and the code never did it. Also: Task 4.2 Step 6 proposes renaming answers-check to py-tests, which is stale now that Phase 3 added script-tests.
- `2026-08-20` AC-H3 cannot be fully observed in this phase and that is a defect in the criterion, not in the work. It asks for a ministack plan showing one ALB serving all three Ingresses, but plan Task 4.1 deliberately ships no Ingress - they arrive in Phase 5 with the GUI, so that the ALB is never created before something needs it. The shared group name is exported as an output and is the mechanism that makes it one ALB; the count is first observable at Phase 5 and first real at Phase 7. Carry it into Phase 5's acceptance rather than letting it lapse.

## Outcome

_Written by `work-order close`. Empty until then._
