#!/usr/bin/env python3
"""Unit tests for scripts/drill-allow.py.

The AWS calls need a real security group and are first exercised in Phase 7. What is
testable here is everything that goes wrong without one, which is where the bugs are:

  * AC-H1: a failed public-IP lookup must be loud. Dropping the entry empties the
    allow list and locks the operator out of a billing cluster; substituting a
    wildcard opens an unauthenticated cluster-admin terminal to the internet. Both
    failure modes are silent, which is what makes them worth a test.
  * AC-H2: no IP address is ever printed. Terminal output is more exposed than the
    git-ignored files the value normally lives in - it lands in scrollback, in CI
    logs, and in whatever the user pastes into a chat window. The subprocess failure
    path is the sneaky one: echoing the failed command echoes `--cidr <your ip>`.
  * Stale rules are revoked, not merely added around. An allow list that accumulates
    every network you have ever drilled from is not an allow list.

Run: python3 tests/test_drill_allow.py
"""
import contextlib
import importlib.util
import io
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location("drill_allow", ROOT / "scripts" / "drill-allow.py")
da = importlib.util.module_from_spec(spec)
spec.loader.exec_module(da)

# Documentation range, never a real address. If this string appears in output, the
# real one would have too.
FAKE_IP = "203.0.113.77"
STALE = "198.51.100.4/32"
SG = "sg-0abc123"

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


def run_main(existing_cidrs, ip=FAKE_IP, sg=SG):
    """Run main() against a fake security group. Returns (exit_code, output, calls)."""
    calls = []

    def fake_aws(*args):
        calls.append(args)
        if args[1] == "describe-security-groups":
            return {"SecurityGroups": [{"IpPermissions": [
                {"FromPort": 80, "ToPort": 80, "IpProtocol": "tcp",
                 "IpRanges": [{"CidrIp": c} for c in existing_cidrs]},
            ]}]}
        return {}

    buf = io.StringIO()
    code = 0
    with mock.patch.object(da, "tf_output", return_value=sg), \
            mock.patch.object(da, "public_ip", return_value=ip), \
            mock.patch.object(da, "aws", side_effect=fake_aws), \
            contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try:
            code = da.main()
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
            if isinstance(e.code, str):
                buf.write(e.code)
    return code, buf.getvalue(), calls


def verbs(calls):
    return [c[1] for c in calls]


def test_no_security_group_is_a_clear_error():
    buf = io.StringIO()
    with mock.patch.object(da, "tf_output", return_value=""), \
            contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try:
            da.main()
            bad("main() returned normally with no security group in state")
            return
        except SystemExit as e:
            msg = str(e.code)
    if "cluster up" in msg:
        ok("no security group in state exits with an error naming the likely cause")
    else:
        bad(f"unhelpful message with no security group: {msg!r}")


def test_failed_ip_lookup_exits_rather_than_guessing():
    buf = io.StringIO()
    with mock.patch.object(da, "tf_output", return_value=SG), \
            mock.patch.object(da, "public_ip", return_value=None), \
            mock.patch.object(da, "aws", side_effect=AssertionError("must not call AWS")), \
            contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
        try:
            da.main()
            bad("AC-H1: a failed IP lookup returned normally - the allow list would be left stale")
            return
        except SystemExit as e:
            msg = str(e.code)
        except AssertionError:
            bad("AC-H1: a failed IP lookup still called AWS")
            return
    if "public IP" in msg and "0.0.0.0/0" not in msg:
        ok("AC-H1: a failed IP lookup exits with an error and never suggests a wildcard")
    else:
        bad(f"AC-H1: unhelpful or dangerous message on lookup failure: {msg!r}")


def test_never_prints_an_ip_address():
    for label, existing in (
        ("nothing to do", [f"{FAKE_IP}/32"]),
        ("adding a rule", []),
        ("revoking a stale rule", [STALE]),
    ):
        _, out, _ = run_main(existing)
        if FAKE_IP in out or STALE in out:
            bad(f"AC-H2: an IP address was printed while {label}")
        else:
            ok(f"AC-H2: no IP address printed while {label}")


def test_subprocess_failure_does_not_echo_the_cidr():
    """The sneaky one: reporting a failed command reports the --cidr argument with it."""
    failed = mock.Mock(returncode=1, stdout="", stderr="An error occurred (InvalidGroup.NotFound)")
    with mock.patch.object(da.subprocess, "run", return_value=failed):
        try:
            da.aws("ec2", "authorize-security-group-ingress", "--group-id", SG,
                   "--protocol", "tcp", "--port", "80", "--cidr", f"{FAKE_IP}/32")
            bad("AC-H2: a failing AWS call returned normally instead of exiting")
            return
        except SystemExit as e:
            msg = str(e.code)
    if FAKE_IP in msg:
        bad("AC-H2: the failed-command message echoed the CIDR, leaking the operator's IP")
    elif "authorize-security-group-ingress" in msg:
        ok("AC-H2: a failing AWS call names the operation without echoing the CIDR")
    else:
        bad(f"a failing AWS call gave no useful context: {msg!r}")


def test_stale_rules_are_revoked_not_just_added_around():
    code, _, calls = run_main([STALE])
    v = verbs(calls)
    if "revoke-security-group-ingress" not in v:
        bad("a stale rule was left in place - the allow list would accumulate every network")
    elif "authorize-security-group-ingress" not in v:
        bad("the current IP was never authorised, so the GUI stays unreachable")
    elif v.index("revoke-security-group-ingress") > v.index("authorize-security-group-ingress"):
        bad("revoked after authorising - a transient window with both rules present")
    else:
        ok("a stale rule is revoked before the current one is authorised")
    if code == 0:
        ok("a successful re-point exits 0")
    else:
        bad(f"a successful re-point exited {code}")


def test_already_correct_is_a_no_op():
    code, _, calls = run_main([f"{FAKE_IP}/32"])
    v = verbs(calls)
    if "revoke-security-group-ingress" in v or "authorize-security-group-ingress" in v:
        bad("an already-correct allow list was rewritten anyway")
    elif code != 0:
        bad(f"an already-correct allow list exited {code}")
    else:
        ok("an already-correct allow list is a no-op")


def main():
    tests = (
        test_no_security_group_is_a_clear_error,
        test_failed_ip_lookup_exits_rather_than_guessing,
        test_never_prints_an_ip_address,
        test_subprocess_failure_does_not_echo_the_cidr,
        test_stale_rules_are_revoked_not_just_added_around,
        test_already_correct_is_a_no_op,
    )
    for fn in tests:
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"drill-allow: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
