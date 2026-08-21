#!/usr/bin/env python3
"""Remove everything Terraform cannot sequence, before `terraform destroy`.

Two classes of object outlive a destroy and keep billing:

  * ALBs and NLBs, because the AWS Load Balancer Controller created them from an
    Ingress or a Service, not from a Terraform resource. Destroy the cluster first
    and the controller is gone before it can clean up. The load balancer bills about
    $16/month with nothing in the account pointing at what made it, and its security
    groups keep the VPC deletion hanging.
  * EBS volumes behind PVCs, for the same reason via the EBS CSI driver.

So: delete the Kubernetes objects, let the controllers do their own cleanup, and
only then hand over to Terraform. Ordering is the whole point.

    make down                      # runs this first
    SKIP_PRE_DESTROY=1 make down   # skip it (cluster already gone / API unreachable)

The load balancer count is scoped by the `elbv2.k8s.aws/cluster` tag, not by name.
`describe-load-balancers` returns the whole account and the controller names every
load balancer it creates `k8s-<namespace>-<ingress>-<hash>`, so a name match cannot
tell this cluster's ALB from another EKS cluster's. Counting by name means a second
cluster in the account makes `make down` wait out its full timeout and then refuse,
every single time, with nothing actually wrong.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

WAIT_SECONDS = 300
POLL_SECONDS = 10
CLUSTER_TAG = "elbv2.k8s.aws/cluster"
# describe-tags rejects more than 20 resource ARNs in a single call.
TAG_CHUNK = 20


@dataclass(frozen=True)
class Step:
    action: str          # "delete" | "wait"
    kind: str
    description: str
    timeout_seconds: int = 0


def plan() -> list[Step]:
    """What pre-destroy does, in order. Deletes first, then one wait for all of it."""
    return [
        Step("delete", "ingress", "every Ingress in every namespace (releases the shared ALB)"),
        Step("delete", "service", "every LoadBalancer Service (releases any NLB)"),
        Step("delete", "persistentvolumeclaim", "every PVC (releases the EBS volumes behind them)"),
        Step("wait", "loadbalancer", "poll until no load balancer remains for this cluster", WAIT_SECONDS),
    ]


def kubectl(*args: str, check: bool = False) -> subprocess.CompletedProcess:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True, check=check)


def api_reachable() -> bool:
    return kubectl("version", "--request-timeout=10s").returncode == 0


def delete_all(kind: str) -> None:
    """Delete every object of a kind, and say so when it does not work.

    A failed delete is the whole failure mode this script exists to prevent, so it is
    reported rather than swallowed. A PVC still mounted by a running pod is the common
    case: it sits in Terminating behind its finalizer, the delete times out, and if
    that is silent the EBS volume is orphaned by the destroy that follows.
    """
    if kind == "service":
        # There is no field selector for spec.type, so list and filter.
        out = kubectl("get", "svc", "-A", "-o",
                      "jsonpath={range .items[?(@.spec.type==\"LoadBalancer\")]}{.metadata.namespace} {.metadata.name}{\"\\n\"}{end}")
        for line in out.stdout.splitlines():
            if not line.strip():
                continue
            ns, name = line.split()
            print(f"  deleting LoadBalancer service {ns}/{name}")
            r = kubectl("-n", ns, "delete", "svc", name, "--ignore-not-found", "--timeout=120s")
            if r.returncode != 0:
                print(f"  WARNING: could not delete svc {ns}/{name}: {r.stderr.strip()}", file=sys.stderr)
        return

    print(f"  deleting all {kind}")
    r = kubectl("delete", kind, "--all-namespaces", "--all", "--ignore-not-found", "--timeout=120s")
    if r.returncode != 0:
        print(f"  WARNING: could not delete every {kind}: {r.stderr.strip()}", file=sys.stderr)
        print(f"  anything left will be orphaned by the destroy and keep billing.", file=sys.stderr)


def aws_json(*args: str) -> dict:
    out = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if out.returncode != 0 or not out.stdout.strip():
        return {}
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {}


def cluster_name() -> str:
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "output", "-raw", "cluster_name"],
        capture_output=True, text=True,
    )
    return out.stdout.strip() if out.returncode == 0 else ""


def remaining_load_balancers(cluster: str) -> int:
    """Ask AWS, not Kubernetes - the Ingress can be gone while the ALB still exists.

    Scoped by the controller's own cluster tag. See the module docstring for why a
    name match is not good enough.
    """
    lbs = aws_json("elbv2", "describe-load-balancers").get("LoadBalancers", [])
    arns = [lb["LoadBalancerArn"] for lb in lbs if lb.get("LoadBalancerArn")]
    if not arns:
        return 0

    count = 0
    for i in range(0, len(arns), TAG_CHUNK):
        chunk = arns[i:i + TAG_CHUNK]
        described = aws_json("elbv2", "describe-tags", "--resource-arns", *chunk)
        for desc in described.get("TagDescriptions", []):
            if any(t.get("Key") == CLUSTER_TAG and t.get("Value") == cluster
                   for t in desc.get("Tags", [])):
                count += 1
    return count


def main() -> int:
    if os.environ.get("SKIP_PRE_DESTROY"):
        print("pre-destroy: skipped (SKIP_PRE_DESTROY is set)")
        return 0
    if not api_reachable():
        print("pre-destroy: cluster API is unreachable - nothing to clean up, continuing")
        return 0

    print("pre-destroy: removing everything the controllers own before terraform destroy")
    for step in plan():
        if step.action == "delete":
            print(f"- {step.description}")
            delete_all(step.kind)

    cluster = cluster_name()
    if not cluster:
        print("pre-destroy: no cluster_name in terraform state - cannot identify this "
              "cluster's load balancers, so not waiting on them.", file=sys.stderr)
        print("If a load balancer survives, delete it by hand or it bills about "
              "$16/month.", file=sys.stderr)
        return 0

    print(f"- waiting up to {WAIT_SECONDS}s for load balancers to disappear")
    deadline = time.time() + WAIT_SECONDS
    while True:
        n = remaining_load_balancers(cluster)
        if n == 0:
            print("pre-destroy: no load balancers remain - safe to destroy")
            return 0
        if time.time() >= deadline:
            break
        print(f"  {n} load balancer(s) still present, waiting...")
        time.sleep(POLL_SECONDS)

    print("pre-destroy: load balancers are STILL present after the timeout.", file=sys.stderr)
    print("Destroying now would orphan them (about $16/month each) and probably hang on VPC deletion.", file=sys.stderr)
    print("Check the AWS console, delete them by hand, then re-run `make down`.", file=sys.stderr)
    print("To destroy anyway: SKIP_PRE_DESTROY=1 make down", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
