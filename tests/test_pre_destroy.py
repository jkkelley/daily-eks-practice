#!/usr/bin/env python3
"""Unit tests for scripts/pre-destroy.py's planning logic.

The kubectl calls need a cluster; what is testable here is the part that costs money
when it is wrong: whether the plan covers every billable object, whether it deletes
them before it starts waiting, and whether the wait is looking at the right load
balancers.

That last one is the expensive mistake. `describe-load-balancers` returns every load
balancer in the account, and the AWS Load Balancer Controller names them all
`k8s-<namespace>-<ingress>-<hash>` regardless of which cluster they belong to. Count
by name and a second EKS cluster in the same account either hangs `make down`
forever or - worse - never lets it reach zero. The controller tags what it creates
with `elbv2.k8s.aws/cluster`, so that is what the count is scoped by.

Run: python3 tests/test_pre_destroy.py
"""
import importlib.util
import os
import sys
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("pre_destroy", ROOT / "scripts" / "pre-destroy.py")
pd = importlib.util.module_from_spec(spec)
# Register before exec. @dataclass resolves its annotations through
# sys.modules[cls.__module__], and under `from __future__ import annotations` that
# lookup returns None for a module loaded this way - the decorator then dies with
# "'NoneType' object has no attribute '__dict__'" before a single test runs.
sys.modules[spec.name] = pd
spec.loader.exec_module(pd)

OURS = "daily-eks-practice-dev"
THEIRS = "somebody-elses-cluster"

PASS = 0
FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print(f"  PASS  {m}")


def bad(m):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {m}")


def fake_aws(lbs):
    """lbs: list of (arn, cluster_tag_or_None)."""

    def _aws(*args):
        if args[1] == "describe-load-balancers":
            return {"LoadBalancers": [{"LoadBalancerArn": a} for a, _ in lbs]}
        if args[1] == "describe-tags":
            wanted = set(args[args.index("--resource-arns") + 1:])
            out = []
            for arn, cluster in lbs:
                if arn not in wanted:
                    continue
                tags = [{"Key": "elbv2.k8s.aws/cluster", "Value": cluster}] if cluster else []
                out.append({"ResourceArn": arn, "Tags": tags})
            return {"TagDescriptions": out}
        return {}

    return _aws


def test_plan_covers_every_billable_kind():
    kinds = {step.kind for step in pd.plan()}
    for kind in ("ingress", "service", "persistentvolumeclaim"):
        if kind in kinds:
            ok(f"plan covers {kind}")
        else:
            bad(f"plan does NOT cover {kind} - it will orphan and keep billing")


def test_deletes_before_waiting():
    steps = pd.plan()
    last_delete = max(i for i, s in enumerate(steps) if s.action == "delete")
    first_wait = min(i for i, s in enumerate(steps) if s.action == "wait")
    if last_delete < first_wait:
        ok("every delete happens before the first wait")
    else:
        bad("a wait is scheduled before a delete, so it would time out on its own inaction")


def test_wait_has_a_timeout():
    waits = [s for s in pd.plan() if s.action == "wait"]
    if waits and all(s.timeout_seconds > 0 for s in waits):
        ok("every wait step has a positive timeout")
    else:
        bad("a wait step has no timeout - make down could hang forever")


def test_load_balancer_count_is_scoped_to_this_cluster():
    lbs = [("arn:aws:elasticloadbalancing:::lb/ours", OURS),
           ("arn:aws:elasticloadbalancing:::lb/theirs", THEIRS)]
    with mock.patch.object(pd, "aws_json", side_effect=fake_aws(lbs)):
        n = pd.remaining_load_balancers(OURS)
    if n == 1:
        ok("only this cluster's load balancers are counted")
    else:
        bad(f"counted {n} load balancers, expected 1 - another cluster's ALB would hang make down")


def test_other_clusters_alone_means_safe_to_destroy():
    lbs = [("arn:aws:elasticloadbalancing:::lb/theirs", THEIRS),
           ("arn:aws:elasticloadbalancing:::lb/untagged", None)]
    with mock.patch.object(pd, "aws_json", side_effect=fake_aws(lbs)):
        n = pd.remaining_load_balancers(OURS)
    if n == 0:
        ok("load balancers belonging to nothing of ours do not block the destroy")
    else:
        bad(f"counted {n}, expected 0 - make down would never reach zero")


def test_describe_tags_is_chunked():
    """describe-tags rejects more than 20 ARNs in one call."""
    lbs = [(f"arn:aws:elasticloadbalancing:::lb/{i}", OURS) for i in range(45)]
    seen = []

    def counting(*args):
        if args[1] == "describe-tags":
            seen.append(len(args) - args.index("--resource-arns") - 1)
        return fake_aws(lbs)(*args)

    with mock.patch.object(pd, "aws_json", side_effect=counting):
        n = pd.remaining_load_balancers(OURS)
    if not seen:
        bad("describe-tags was never called, so nothing is scoped by the cluster tag")
    elif max(seen) > 20:
        bad(f"describe-tags called with {max(seen)} ARNs - AWS rejects more than 20")
    elif n != 45:
        bad(f"chunking lost load balancers: counted {n} of 45")
    else:
        ok(f"describe-tags is chunked ({len(seen)} calls, max {max(seen)} ARNs) and counts all 45")


def test_no_load_balancers_at_all_is_zero():
    with mock.patch.object(pd, "aws_json", side_effect=fake_aws([])):
        n = pd.remaining_load_balancers(OURS)
    if n == 0:
        ok("an account with no load balancers counts zero without calling describe-tags")
    else:
        bad(f"counted {n} with no load balancers present")


def test_skip_bypasses_everything():
    with mock.patch.dict(os.environ, {"SKIP_PRE_DESTROY": "1"}), \
            mock.patch.object(pd, "api_reachable", side_effect=AssertionError("must not probe")):
        try:
            code = pd.main()
        except AssertionError:
            bad("SKIP_PRE_DESTROY still probed the cluster API")
            return
    if code == 0:
        ok("SKIP_PRE_DESTROY=1 short-circuits before touching the cluster")
    else:
        bad(f"SKIP_PRE_DESTROY exited {code}, so make down would stop")


def test_unreachable_api_continues_rather_than_blocking_destroy():
    """The cluster is already gone. Blocking here would strand the rest of the stack."""
    with mock.patch.dict(os.environ, {}, clear=True), \
            mock.patch.object(pd, "api_reachable", return_value=False), \
            mock.patch.object(pd, "delete_all", side_effect=AssertionError("must not delete")):
        try:
            code = pd.main()
        except AssertionError:
            bad("an unreachable API still tried to delete objects")
            return
    if code == 0:
        ok("an unreachable API lets the destroy proceed instead of blocking it")
    else:
        bad(f"an unreachable API exited {code}, blocking terraform destroy")


def main():
    tests = (
        test_plan_covers_every_billable_kind,
        test_deletes_before_waiting,
        test_wait_has_a_timeout,
        test_load_balancer_count_is_scoped_to_this_cluster,
        test_other_clusters_alone_means_safe_to_destroy,
        test_describe_tags_is_chunked,
        test_no_load_balancers_at_all_is_zero,
        test_skip_bypasses_everything,
        test_unreachable_api_continues_rather_than_blocking_destroy,
    )
    for fn in tests:
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"pre-destroy: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
