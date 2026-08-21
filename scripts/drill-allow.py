#!/usr/bin/env python3
"""Re-point the drill ALB security group at this machine's current public IP.

Residential addresses are DHCP-assigned. When the lease rotates mid-drill the GUI
simply stops answering - no error, the browser just hangs - and the fix would
otherwise be a full `terraform apply` on a cluster that is billing by the hour, to
change one firewall rule. This does only the rule.

Terraform stays the source of truth: the next `make plan` re-reads config.toml,
re-resolves "auto", and converges to the same place. This is the fast path, not a
second owner of the resource.

Two deliberate choices, both load-bearing enough to have tests in
tests/test_drill_allow.py:

  * It never prints an address, matching Task 3.1's reasoning that terminal output is
    more exposed than the git-ignored files the value normally lives in. That
    includes the subprocess failure path, which is why aws() reports the operation
    rather than the whole command line - the command line carries `--cidr <your ip>`.
  * It revokes stale rules rather than only adding, because an allow list that
    accumulates every network you have ever drilled from is not an allow list.

    make drill-allow
"""
import json
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from bootstrap import public_ip  # noqa: E402  - single definition, shared


def tf_output(name: str) -> str:
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "output", "-raw", name],
        capture_output=True,
        text=True,
    )
    return out.stdout.strip() if out.returncode == 0 else ""


def aws(*args: str) -> dict:
    """Run an AWS CLI call. On failure, name the operation but never the arguments.

    `' '.join(cmd)` would be the natural thing to put in the error and is exactly
    what AC-H2 forbids: a revoke or authorize call carries `--cidr <your ip>/32`, so
    echoing the command leaks the operator's address into the terminal on every
    failure. The operation name is the part that helps anyway.
    """
    cmd = ["aws", *args, "--output", "json"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        operation = " ".join(a for a in args[:2] if not a.startswith("-"))
        sys.exit(f"drill-allow: aws {operation} failed:\n{out.stderr.strip()}")
    return json.loads(out.stdout) if out.stdout.strip() else {}


def main() -> int:
    sg = tf_output("drill_alb_security_group_id")
    if not sg:
        sys.exit("drill-allow: no drill ALB security group in state - is the cluster up?")

    ip = public_ip()
    if ip is None:
        # Never fall back to a wildcard and never leave the list as it is. The first
        # opens an unauthenticated cluster-admin terminal to the internet; the second
        # leaves the operator locked out of a cluster that is still billing, with the
        # browser hanging and nothing to read.
        sys.exit("drill-allow: could not determine your public IP (no network?). "
                 "The allow list was left untouched - fix connectivity and re-run.")
    want = f"{ip}/32"

    desc = aws("ec2", "describe-security-groups", "--group-ids", sg)
    perms = desc["SecurityGroups"][0]["IpPermissions"]
    have = {
        r["CidrIp"]
        for p in perms
        if p.get("FromPort") == 80
        for r in p.get("IpRanges", [])
    }

    if have == {want}:
        print(f"drill-allow: already correct, nothing to do ({len(have)} rule)")
        return 0

    # Revoke first. Authorising first would leave a window where both the stale
    # network and the current one can reach the terminal.
    for stale in sorted(have - {want}):
        aws("ec2", "revoke-security-group-ingress", "--group-id", sg,
            "--protocol", "tcp", "--port", "80", "--cidr", stale)
        print("drill-allow: revoked a stale rule")

    if want not in have:
        aws("ec2", "authorize-security-group-ingress", "--group-id", sg,
            "--protocol", "tcp", "--port", "80", "--cidr", want)
        print("drill-allow: authorised your current public /32")

    print("drill-allow: done. Terraform will converge to the same state on the next plan.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
