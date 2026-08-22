#!/usr/bin/env python3
"""Unit tests for scripts/handover.py AND for the Makefile's own wiring.

The second half is the one that will actually catch something.

A test that only exercises `handover.py` proves the policy object is correct while
the Makefile forgets to consult it - which is precisely the edit a future change
makes: somebody adds a target, copies the recipe above it, and does not notice the
guard prerequisite is what they left out. The consequence in the other direction
is worse. A guard accidentally added to `down` locks the learner out of stopping
their own bill, and they find out while it is running.
"""
import importlib.util
import os
import re
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
ho = _load("handover", "handover.py")

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


class _Drilling:
    """A sandbox where the GUI holds the wheel on `scenario`."""

    def __init__(self, scenario="03"):
        self.scenario = scenario

    def __enter__(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="drill-handover-test-")
        self._prev = os.environ.get("DRILL_PROGRESS_DIR")
        self._force = os.environ.pop("FORCE", None)
        os.environ["DRILL_PROGRESS_DIR"] = self._tmp.name
        pg.write_atomic(
            ho.flag_path(), {"scenario": self.scenario, "sessionId": "2026-08-21T19-00-00Z"}
        )
        return Path(self._tmp.name)

    def __exit__(self, *exc):
        if self._prev is None:
            os.environ.pop("DRILL_PROGRESS_DIR", None)
        else:
            os.environ["DRILL_PROGRESS_DIR"] = self._prev
        if self._force is not None:
            os.environ["FORCE"] = self._force
        self._tmp.cleanup()


# ---------------------------------------------------------------------------
# The policy
# ---------------------------------------------------------------------------


def test_every_locked_target_refuses_while_the_gui_is_up():
    with _Drilling():
        for target in ho.LOCKED:
            arg = "05" if target == "scenario" else None
            allowed, _ = ho.allowed(target, arg)
            check(f"{target} refuses", not allowed)


def test_every_locked_target_runs_when_no_drill_is_running():
    with _Drilling() as root:
        ho.flag_path().unlink()
        for target in ho.LOCKED:
            allowed, _ = ho.allowed(target)
            check(f"{target} runs with no drill up", allowed)


def test_the_never_locked_list_is_exactly_the_bootstrap_and_teardown_path():
    # Asserted, not merely written down. `down` is the one that matters: it is how
    # the learner stops paying, and locking it would strand them mid-bill with the
    # only way out being a flag they do not know exists.
    check(
        "the never-locked set is exactly up/plan/apply/down/kubeconfig/config",
        ho.NEVER_LOCKED == frozenset({"up", "plan", "apply", "down", "kubeconfig", "config"}),
    )
    check("and none of them is also in LOCKED", not (ho.NEVER_LOCKED & set(ho.LOCKED)))

    with _Drilling():
        for target in sorted(ho.NEVER_LOCKED):
            allowed, _ = ho.allowed(target)
            check(f"{target} is never refused, even mid-drill", allowed)


def test_force_overrides_every_lock():
    with _Drilling():
        os.environ["FORCE"] = "1"
        try:
            every = all(ho.allowed(t, "05")[0] for t in ho.LOCKED)
            check("FORCE=1 lifts every lock there is", every)
        finally:
            os.environ.pop("FORCE", None)


def test_a_refusal_names_a_consequence_not_just_the_rule():
    """'the GUI owns this now' is a refusal you cannot act on."""
    generic = ("owns", "locked", "not allowed", "refused")
    with _Drilling():
        for target in ho.LOCKED:
            arg = "05" if target == "scenario" else None
            _, why = ho.allowed(target, arg)
            body = ho.LOCKED[target]
            check(
                f"{target}'s refusal explains what would go wrong",
                len(body) > 40 and not body.lower().startswith(generic),
            )
            check(f"{target}'s message carries that explanation", body in why)


def test_the_scenario_lock_is_scoped_to_the_argument_so_AC_H2_can_hold():
    """AC-H2 requires `make scenario N=03` twice, the second not an error. The
    first run sets this very flag, so a flat lock makes it unsatisfiable."""
    with _Drilling(scenario="03"):
        check("converging the SAME scenario is allowed - that is idempotency", ho.allowed("scenario", "03")[0])
        check("no argument at all is allowed", ho.allowed("scenario", None)[0])

        allowed, why = ho.allowed("scenario", "05")
        check("a DIFFERENT scenario is refused", not allowed)
        check("and the refusal names what is already open", "03" in why)
        check("and points at where switching now lives", "pause menu" in why)


# ---------------------------------------------------------------------------
# The Makefile's own wiring
# ---------------------------------------------------------------------------

MAKEFILE = (ROOT / "Makefile").read_text(encoding="utf-8")


def target_prereqs(name: str) -> list[str] | None:
    m = re.search(rf"^{re.escape(name)}:([^\n=]*?)(?:##.*)?$", MAKEFILE, re.MULTILINE)
    return m.group(1).split() if m else None


def test_the_makefile_actually_consults_the_guard():
    for target in ho.LOCKED:
        prereqs = target_prereqs(target)
        check(f"{target} exists in the Makefile", prereqs is not None)
        if prereqs is None:
            continue
        guard = f"check-handover-{target}"
        check(f"{target} carries {guard}", guard in prereqs)
        # FIRST, not merely present. `app-deploy` depends on `git-seed`, and a
        # guard after it means the seed has already run before the refusal.
        check(f"...and carries it FIRST", prereqs and prereqs[0] == guard)


def test_the_makefile_never_guards_the_recovery_path():
    for target in sorted(ho.NEVER_LOCKED):
        prereqs = target_prereqs(target)
        if prereqs is None:
            continue
        check(
            f"{target} has no handover guard - it is the way out",
            not any(p.startswith("check-handover") for p in prereqs),
        )


def test_the_makefile_is_serial_so_first_prerequisite_means_first():
    # Without .NOTPARALLEL, `make -j2 app-deploy` may run git-seed and the guard
    # concurrently, and the guard stops being a guard.
    check(".NOTPARALLEL is set", re.search(r"^\.NOTPARALLEL:", MAKEFILE, re.MULTILINE) is not None)


def test_scenario_clean_is_reachable_and_unguarded():
    # It is part of the way OUT of a drill. Locking it behind the flag it clears
    # would be a deadlock with a very confusing error message.
    check("scenario-clean exists", target_prereqs("scenario-clean") is not None)
    check(
        "scenario-clean is not guarded",
        not any(p.startswith("check-handover") for p in (target_prereqs("scenario-clean") or [])),
    )


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    print(f"tests/test_handover.py - {len(tests)} groups")
    for t in tests:
        print(f"\n{t.__name__}")
        t()
    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
