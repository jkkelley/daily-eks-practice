"""bootstrap.py resolves the "auto" CIDR sentinel to the caller's public /32.

The drill ALB's allow list is the only control on an unauthenticated cluster-admin
terminal, so a stale entry is a lockout and a wrong entry is an exposure. These tests
pin the three behaviours that matter: literals are never touched, "auto" becomes a
/32, and a failed lookup is loud rather than silently wide open.
"""
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import bootstrap  # noqa: E402


class ResolveAutoCidrs(unittest.TestCase):
    def test_literal_cidrs_pass_through_untouched(self):
        cfg = {"drill_allowed_cidrs": ["203.0.113.10/32", "198.51.100.0/24"]}
        bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg["drill_allowed_cidrs"], ["203.0.113.10/32", "198.51.100.0/24"])

    def test_auto_becomes_the_public_slash_32(self):
        cfg = {"drill_allowed_cidrs": ["auto"]}
        with mock.patch.object(bootstrap, "public_ip", return_value="203.0.113.10"):
            bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg["drill_allowed_cidrs"], ["203.0.113.10/32"])

    def test_auto_mixed_with_literals_resolves_only_the_sentinel(self):
        cfg = {"drill_allowed_cidrs": ["auto", "198.51.100.0/24"]}
        with mock.patch.object(bootstrap, "public_ip", return_value="203.0.113.10"):
            bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg["drill_allowed_cidrs"], ["203.0.113.10/32", "198.51.100.0/24"])

    def test_lookup_failure_exits_instead_of_dropping_the_entry(self):
        cfg = {"drill_allowed_cidrs": ["auto"]}
        with mock.patch.object(bootstrap, "public_ip", return_value=None):
            with self.assertRaises(SystemExit):
                bootstrap.resolve_auto_cidrs(cfg)

    def test_key_absent_is_a_no_op(self):
        cfg = {"region": "us-east-2"}
        bootstrap.resolve_auto_cidrs(cfg)
        self.assertEqual(cfg, {"region": "us-east-2"})


class NeedsAutoCidrs(unittest.TestCase):
    """Which invocations may pay for the lookup, and which must not.

    Resolving the sentinel costs an HTTPS round trip with a 10s timeout, and
    bootstrap.py is invoked for far more than applies. `Makefile` runs two
    `--print` lookups through `$(shell ...)` on EVERY target, and `git-seed.py`
    reads terraform outputs. Resolving unconditionally makes `make help` do two
    network calls, and offline it stalls 20s or dies complaining about CIDRs
    while being asked for a profile name.
    """

    def test_print_of_an_unrelated_key_does_not_resolve(self):
        self.assertFalse(bootstrap.needs_auto_cidrs(["--print", "aws_profile"]))
        self.assertFalse(bootstrap.needs_auto_cidrs(["--print", "aws_region"]))

    def test_print_of_the_cidr_key_itself_does_resolve(self):
        self.assertTrue(bootstrap.needs_auto_cidrs(["--print", "drill_allowed_cidrs"]))

    def test_read_only_terraform_actions_do_not_resolve(self):
        for action in ("output", "show", "state", "version", "providers", "graph"):
            with self.subTest(action=action):
                self.assertFalse(bootstrap.needs_auto_cidrs([action, "-raw", "cluster_git_url"]))

    def test_actions_that_consume_the_tfvars_do_resolve(self):
        for action in ("init", "plan", "apply", "destroy", "refresh", "import"):
            with self.subTest(action=action):
                self.assertTrue(bootstrap.needs_auto_cidrs([action]))

    def test_writing_the_tfvars_with_no_terraform_action_resolves(self):
        self.assertTrue(bootstrap.needs_auto_cidrs([]))
        self.assertTrue(bootstrap.needs_auto_cidrs(["--generate-only"]))


if __name__ == "__main__":
    unittest.main()
