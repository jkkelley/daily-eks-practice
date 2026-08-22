#!/usr/bin/env python3
"""Unit tests for scripts/git-seed.py's pure helpers.

The kubectl exec itself needs a cluster and is covered by tests/cluster-git-argo.sh.
What is testable here is the part that silently does the wrong thing if it breaks:
the order the seeding steps run in, and the shape of the streaming command.

That second one is a regression guard for a measured bug, not a style preference.
Receiving the bundle with `kubectl exec -i ... /bin/sh -c 'cat > file'` truncates it
- 443833 bytes sent, 98662 landed, kubectl still exiting 0 - and the corruption only
surfaces later as "fatal: early EOF" from git. Exec'ing `tee` directly is intact.
"""
import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("git_seed", ROOT / "scripts" / "git-seed.py")
gs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gs)

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


def check(message, condition):
    """ok/bad, but with the condition passed in rather than branched at each site."""
    (ok if condition else bad)(message)


def test_unbundle_script_is_idempotent():
    """Re-seeding must overwrite refs rather than refuse or duplicate them."""
    script = gs.unbundle_script("/repos/repo.git")
    for needle in ("--force", "symbolic-ref HEAD", ".seeded"):
        if needle in script:
            ok(f"unbundle script contains {needle!r}")
        else:
            bad(f"unbundle script is missing {needle!r}")


def test_unbundle_script_writes_the_marker_last():
    """If .seeded is written before the refs land, the readiness probe passes too
    early and Argo clones a half-served repo - the exact failure the probe exists
    to stop. The marker must come after the fetch that publishes the refs."""
    script = gs.unbundle_script("/repos/repo.git")
    if script.index("fetch") < script.index(".seeded"):
        ok("the .seeded marker is written after the fetch that publishes refs")
    else:
        bad("the .seeded marker is written too early")


def test_unbundle_script_honours_the_repo_path_it_is_given():
    """The path comes from a terraform output. Hardcoding it here would let the
    Deployment's mountPath and the seeder drift apart silently."""
    script = gs.unbundle_script("/somewhere/else.git")
    if "/somewhere/else.git" in script:
        ok("the repo path argument reaches the script")
    else:
        bad("the repo path argument was ignored")
    if "/srv" not in script:
        ok("no hardcoded /srv (bitnami/git makes /srv a symlink - that trap is real)")
    else:
        bad("the script hardcodes /srv")


def test_unbundle_script_cleans_up_the_temp_bundle():
    script = gs.unbundle_script("/repos/repo.git")
    if "rm -f" in script and "seed.bundle" in script:
        ok("the temp bundle is removed inside the pod")
    else:
        bad("the temp bundle is left behind in the pod")


def test_stream_command_execs_the_receiver_directly():
    """The regression guard for the silent-truncation bug. A shell wrapper around
    the receiving end loses most of the stream and still exits 0."""
    argv = gs.stream_command("git", "git-server-abc", "git", "/tmp/seed.bundle")
    if "/bin/sh" not in argv and "sh" not in argv:
        ok("no shell wrapper on the receiving end")
    else:
        bad(f"a shell wrapper is back in the stream command: {argv}")
    if argv[-2:] == ["tee", "/tmp/seed.bundle"]:
        ok("the receiver is `tee <dest>`")
    else:
        bad(f"unexpected receiver: {argv[-2:]}")
    for needle in ("-n", "git", "exec", "-i", "-c"):
        if needle in argv:
            ok(f"stream command passes {needle!r}")
        else:
            bad(f"stream command is missing {needle!r}")


def test_the_drill_tree_holds_the_chart_and_nothing_else():
    """The load-bearing one: the learner's repo must not contain the answer key.

    Seeding `--all` handed them scenarios/answers/*.toml, docs/ (the plan, which
    explains every task), drill/ (the grader's own source) and work-orders/. The
    server strips accept rules from every response; none of that matters if `cat`
    reaches them in the workspace.
    """
    with tempfile.TemporaryDirectory() as tmp:
        out = gs.drill_tree(gs.DRILL_PATHS, Path(tmp) / "repo")
        tracked = subprocess.check_output(
            ["git", "-C", str(out), "ls-files"], text=True
        ).split()

    check("the chart is there", any(f.startswith("helm/practice-app/") for f in tracked))
    check(
        "values.yaml keeps its path, so Argo's `path: helm/practice-app` resolves",
        "helm/practice-app/values.yaml" in tracked,
    )
    for forbidden in (
        "scenarios/",
        "docs/",
        "drill/",
        "work-orders/",
        "scripts/",
        "terraform/",
        "CLAUDE.md",
        "COMPASS.md",
        "README.md",
        "PRACTICE_ANSWERS.html",
    ):
        check(
            f"{forbidden} is not in the learner's repository",
            not any(f == forbidden or f.startswith(forbidden) for f in tracked),
        )
    check(
        "and the answer key specifically is absent",
        not any("answers" in f for f in tracked),
    )


def test_the_drill_tree_is_a_real_repo_with_one_commit():
    with tempfile.TemporaryDirectory() as tmp:
        out = gs.drill_tree(gs.DRILL_PATHS, Path(tmp) / "repo")
        log = (
            subprocess.check_output(["git", "-C", str(out), "log", "--oneline"], text=True)
            .strip()
            .split("\n")
        )
        branch = subprocess.check_output(
            ["git", "-C", str(out), "rev-parse", "--abbrev-ref", "HEAD"], text=True
        ).strip()

    check("one baseline commit, not this project's history", len(log) == 1)
    check("on main, which is what the Application targets", branch == "main")


def main():
    for fn in (
        test_unbundle_script_is_idempotent,
        test_unbundle_script_writes_the_marker_last,
        test_unbundle_script_honours_the_repo_path_it_is_given,
        test_unbundle_script_cleans_up_the_temp_bundle,
        test_stream_command_execs_the_receiver_directly,
        test_the_drill_tree_holds_the_chart_and_nothing_else,
        test_the_drill_tree_is_a_real_repo_with_one_commit,
    ):
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"git-seed: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
