#!/usr/bin/env python3
"""Unit tests for scripts/scenario.py's converge logic.

The kubectl and bundle halves need a cluster and are covered by the kind harness.
What is testable here is the session bookkeeping, and each of the three
acceptance-criteria assertions is written so that a WRONG implementation cannot
pass it:

  AC-H2 idempotency is asserted on the FILESYSTEM, not on the exit code. An
        implementation that creates a second session and exits 0 passes an
        exit-code test and fails the criterion.

  AC-H3 the refusal must name the open scenario AND its title. "Another scenario
        is running" is a refusal the learner cannot act on.

  clean  with nothing open must exit 0 and change nothing. A cleanup that errors
         when there is nothing to clean is a cleanup nobody runs twice, and this
         one is in the teardown path.
"""
import importlib.util
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


pg = _load("progress", "progress.py")
sc = _load("scenario", "scenario.py")

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
    (ok if condition else bad)(message)


class _Sandbox:
    def __enter__(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="drill-scenario-test-")
        self._prev = os.environ.get("DRILL_PROGRESS_DIR")
        os.environ["DRILL_PROGRESS_DIR"] = self._tmp.name
        return Path(self._tmp.name)

    def __exit__(self, *exc):
        if self._prev is None:
            os.environ.pop("DRILL_PROGRESS_DIR", None)
        else:
            os.environ["DRILL_PROGRESS_DIR"] = self._prev
        self._tmp.cleanup()


def tree(root: Path) -> set[str]:
    return {str(p.relative_to(root)) for p in root.rglob("*")}


# ---------------------------------------------------------------------------


def test_the_curriculum_is_read_from_the_cards_not_hardcoded():
    check("03 has a card", sc.card_path("03") is not None)
    check("03 is ported", sc.is_ported("03"))
    check("07 has a card", sc.card_path("07") is not None)
    check("07 is not ported", not sc.is_ported("07"))
    check("99 does not exist", sc.card_path("99") is None)
    check(
        "the title comes from the card's own H1",
        sc.title("03") == "Rolling update + rollback",
    )
    check("an unknown scenario titles as itself rather than crashing", sc.title("99") == "99")


def test_AC_H2_converging_twice_produces_exactly_one_session():
    with _Sandbox():
        first, new_first = sc.open_session("03")
        check("the first converge starts a session", new_first)

        second, new_second = sc.open_session("03")
        check("the second converge does NOT start another", not new_second)
        check("and it is the same session", first == second)

        # Asserted on the filesystem, because that is what the criterion is about.
        check(
            "exactly one session directory on disk",
            len(pg.sessions("03")) == 1,
        )
        check(
            "exactly one results row",
            len([r for r in pg.results("03") if r["session"] == first]) == 1,
        )


def test_a_closed_session_reopens_as_a_NEW_attempt_not_a_resume():
    with _Sandbox():
        first, _ = sc.open_session("03")
        pg.close_session("03", first)

        second, is_new = sc.open_session("03")
        check("re-running after finishing starts a fresh attempt", is_new)
        check("with a different session id", second != first)
        check("and the old attempt is still on record", len(pg.sessions("03")) == 2)


def test_AC_H3_a_second_scenario_is_refused_by_name():
    with _Sandbox():
        d = pg.new_session("03")
        pg.set_live_scenario("03", d.name)

        check("the same scenario is NOT a conflict - that is AC-H2", sc.conflict("03") is None)

        live = sc.conflict("05")
        check("a different scenario IS a conflict", live is not None)

        msg = sc.refusal(live)
        check("the refusal names the open scenario", "03" in msg)
        check(
            "the refusal names its TITLE, so it is actionable",
            "Rolling update + rollback" in msg,
        )
        check("it says why two at once is not allowed", "unattributable" in msg)
        check("it offers the GUI's pause menu", "pause menu" in msg)
        check("and it offers the laptop way out", "make scenario-clean N=03" in msg)


def test_nothing_is_live_means_nothing_conflicts():
    with _Sandbox():
        check("no live scenario, no conflict", sc.conflict("05") is None)


def test_clean_with_nothing_open_is_a_no_op_that_exits_zero():
    with _Sandbox() as root:
        # Force the cluster branch off: this test is about the laptop half.
        real = sc.cluster_reachable
        sc.cluster_reachable = lambda: False
        try:
            before = tree(root)
            rc = sc.clean("03")
            check("it exits 0 with nothing to clean", rc == 0)
            check("and changed nothing on disk", tree(root) == before)
        finally:
            sc.cluster_reachable = real


def test_clean_closes_the_session_but_never_deletes_a_save_file():
    with _Sandbox() as root:
        d = pg.new_session("03")
        (d / "workspace.bundle").write_bytes(b"the learner's work")
        pg.set_live_scenario("03", d.name)
        pg.write_atomic(root / sc.HANDOVER_FLAG, {"scenario": "03"})

        real = sc.cluster_reachable
        sc.cluster_reachable = lambda: False
        try:
            rc = sc.clean("03")
        finally:
            sc.cluster_reachable = real

        check("it exits 0", rc == 0)
        check("the session is closed", pg.current_session("03") is None)
        check("nothing is live", pg.live_scenario() is None)
        check("the Makefile has its wheel back", not (root / sc.HANDOVER_FLAG).exists())
        check(
            "the save file survives - clean is not delete",
            (d / "workspace.bundle").read_bytes() == b"the learner's work",
        )


def test_a_fresh_session_starts_from_the_baseline_not_from_your_last_attempt():
    """A new attempt at a scenario you have drilled before must NOT restore the
    newest bundle - that would hand you your own finished tree and the drill would
    open already solved, which looks exactly like it working."""
    with _Sandbox() as root:
        old = pg.new_session("03")
        (old / "workspace.bundle").write_bytes(b"my finished 03")
        pg.baseline_bundle().write_bytes(b"the clean start")

        captured = {}

        def fake_pod(cfg, timeout="60s"):
            return "git-server-abc"

        def fake_push(cfg, pod, chunks, **kw):
            captured["bytes"] = b"".join(chunks)
            return len(captured["bytes"])

        real_pod, real_push = sc.clustergit.pod_name, sc.clustergit.push_bundle
        sc.clustergit.pod_name, sc.clustergit.push_bundle = fake_pod, fake_push
        try:
            sc.restore_into_cluster_git({}, "03", fresh=True)
            check("a fresh session restores the BASELINE", captured.get("bytes") == b"the clean start")

            captured.clear()
            sc.restore_into_cluster_git({}, "03", fresh=False)
            check("a resume restores the SAVE FILE", captured.get("bytes") == b"my finished 03")
        finally:
            sc.clustergit.pod_name, sc.clustergit.push_bundle = real_pod, real_push


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    print(f"tests/test_scenario.py - {len(tests)} groups")
    for t in tests:
        print(f"\n{t.__name__}")
        t()
    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
