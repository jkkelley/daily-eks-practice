#!/usr/bin/env python3
"""Unit tests for scripts/progress.py - the append-only drill save files.

Nothing here touches a cluster. What is worth testing is the part that fails
quietly and expensively: a session directory that cannot be created on Windows,
a second session that overwrites the first, a results row that vanishes, and a
half-written save file left behind by an interrupted write.

The last one is the reason this module exists at all. Losing one task is
annoying; a truncated bundle or a half-written state.json is losing the whole
run, and it surfaces at the resume, which is the moment the learner most
believed their progress was safe.
"""
import importlib.util
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("progress", ROOT / "scripts" / "progress.py")
pg = importlib.util.module_from_spec(spec)
# Registered before exec_module because @dataclass under `from __future__ import
# annotations` resolves its annotations through sys.modules[cls.__module__] and
# dies with 'NoneType' object has no attribute '__dict__' if it is not there.
sys.modules[spec.name] = pg
spec.loader.exec_module(pg)

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
    """A throwaway drill-progress/ pointed at by DRILL_PROGRESS_DIR."""

    def __enter__(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="drill-progress-test-")
        self._prev = os.environ.get("DRILL_PROGRESS_DIR")
        os.environ["DRILL_PROGRESS_DIR"] = self._tmp.name
        return Path(self._tmp.name)

    def __exit__(self, *exc):
        if self._prev is None:
            os.environ.pop("DRILL_PROGRESS_DIR", None)
        else:
            os.environ["DRILL_PROGRESS_DIR"] = self._prev
        self._tmp.cleanup()


# ---------------------------------------------------------------------------
# Session ids have to be legal directory names on Windows 11, which is a
# supported target for this repo. A colon is the one an ISO timestamp actually
# trips, but the assertion covers the whole illegal set so that a LATER change
# to the id format - adding the scenario, adding a counter - cannot introduce a
# name that works here and makes the directory uncreatable there. That failure
# lands inside mkdir on somebody else's machine, which is not a thing to learn
# about from a bug report.
WINDOWS_ILLEGAL = set('<>:"/\\|?*') | {chr(c) for c in range(32)}


def test_session_ids_are_legal_on_windows():
    stamp = pg.session_stamp(datetime(2026, 8, 19, 14, 3, 11, tzinfo=timezone.utc))

    check("the session id carries no colon", ":" not in stamp)
    check(
        "the session id carries no character Windows forbids",
        not (set(stamp) & WINDOWS_ILLEGAL),
    )
    check(
        "the session id does not end in a dot or a space, which Windows also strips",
        stamp[-1] not in ". ",
    )
    check(
        "the session id is still a readable timestamp",
        stamp.startswith("2026-08-19T14-03-11"),
    )


def test_a_second_session_in_the_same_second_does_not_replace_the_first():
    """The collision is real: restart a drill twice inside one second and both
    sessions want the same stamp. Driven with a fixed clock, because that is the
    only way to make it deterministic."""
    clock = datetime(2026, 8, 19, 14, 3, 11, tzinfo=timezone.utc)
    with _Sandbox():
        first = pg.new_session("03", started_at=clock)
        (first / "marker").write_text("the first session's work")

        second = pg.new_session("03", started_at=clock)

        check("a same-second restart gets its own directory", first != second)
        check("both session directories exist", first.is_dir() and second.is_dir())
        check(
            "the first session's contents were not clobbered",
            (first / "marker").read_text() == "the first session's work",
        )
        check(
            "the disambiguated id is still Windows-legal",
            not (set(second.name) & WINDOWS_ILLEGAL),
        )


def test_index_accumulates_a_row_per_session_and_never_loses_one():
    with _Sandbox():
        a = pg.new_session("03", started_at=datetime(2026, 8, 19, 9, 0, 0, tzinfo=timezone.utc))
        pg.record_result("03", a.name, passed=2, total=6)

        b = pg.new_session("03", started_at=datetime(2026, 8, 20, 9, 0, 0, tzinfo=timezone.utc))
        pg.record_result("03", b.name, passed=5, total=6)

        rows = pg.results("03")
        check("one row per session", len(rows) == 2)
        check(
            "the earlier session's row survived the later one",
            any(r["session"] == a.name and r["passed"] == 2 for r in rows),
        )

        # Re-recording the SAME session updates its row rather than appending a
        # duplicate. Every submit calls this, so an appending implementation
        # produces one row per keystroke and an index nobody can read.
        pg.record_result("03", b.name, passed=6, total=6)
        rows = pg.results("03")
        check("re-recording a session updates rather than appends", len(rows) == 2)
        check(
            "the updated row carries the new score",
            any(r["session"] == b.name and r["passed"] == 6 for r in rows),
        )
        check(
            "and the older row is still untouched",
            any(r["session"] == a.name and r["passed"] == 2 for r in rows),
        )


def test_current_session_returns_the_newest_and_can_be_closed():
    with _Sandbox():
        a = pg.new_session("03", started_at=datetime(2026, 8, 19, 9, 0, 0, tzinfo=timezone.utc))
        check("a fresh session becomes the current one", pg.current_session("03") == a.name)

        b = pg.new_session("03", started_at=datetime(2026, 8, 20, 9, 0, 0, tzinfo=timezone.utc))
        check("the newest session is the current one", pg.current_session("03") == b.name)

        pg.close_session("03", b.name)
        check("closing clears the pointer", pg.current_session("03") is None)
        check(
            "closing does NOT delete the session - it is a save file, not a cache",
            (pg.session_dir("03", b.name)).is_dir(),
        )
        check(
            "and the closed session still has its results row",
            any(r["session"] == b.name for r in pg.results("03")),
        )


class _Unserialisable:
    """Raises during encoding, AFTER json has already emitted the opening bytes."""


def test_write_atomic_leaves_the_previous_file_intact_when_the_write_raises():
    """Testing this by writing successfully proves nothing - every
    implementation passes that, including the one that truncates the target
    first and then dies."""
    with _Sandbox() as root:
        target = root / "state.json"
        pg.write_atomic(target, {"passed": ["t1", "t2"], "phase": "active"})
        before = target.read_bytes()

        raised = False
        try:
            pg.write_atomic(target, {"padding": "x" * 4096, "boom": _Unserialisable()})
        except TypeError:
            raised = True

        check("an unserialisable payload raises rather than being swallowed", raised)
        check("the previous file is byte-identical", target.read_bytes() == before)
        check(
            "no half-written temp file is left behind",
            [p.name for p in root.iterdir() if p.name != "state.json"] == [],
        )


def test_write_atomic_keeps_its_temp_file_on_the_same_filesystem():
    """os.replace is only atomic WITHIN a filesystem. A temp file in the system
    temp dir - frequently a different mount on Linux - turns the atomic rename
    back into a copy that can be interrupted, which is the exact failure this
    function exists to prevent."""
    with _Sandbox() as root:
        target = root / "nested" / "state.json"
        seen = []
        real_replace = os.replace

        def spy(src, dst):
            seen.append((Path(src).parent, Path(dst).parent))
            return real_replace(src, dst)

        os.replace = spy
        try:
            pg.write_atomic(target, {"ok": True})
        finally:
            os.replace = real_replace

        check("write_atomic creates the parent directory", target.is_file())
        check("it renamed exactly once", len(seen) == 1)
        check(
            "the temp file was a sibling of the target, not in the system temp dir",
            seen and seen[0][0] == seen[0][1] == target.parent,
        )


def test_the_live_scenario_pointer_is_json_and_not_a_symlink():
    """A symlink would be the obvious way to point at the current session and it
    is wrong twice over: it needs a privilege or developer mode on Windows, and
    `git add -A` on a repo where drill-progress/ was somehow unignored follows
    it. JSON is boring and works everywhere."""
    with _Sandbox() as root:
        s = pg.new_session("03", started_at=datetime(2026, 8, 19, 9, 0, 0, tzinfo=timezone.utc))
        pg.set_live_scenario("03", s.name)

        live = root / "current.json"
        check("the live pointer is a regular file", live.is_file() and not live.is_symlink())
        check(
            "it names the scenario and the session",
            json.loads(live.read_text())["scenario"] == "03",
        )
        check("live_scenario reads it back", pg.live_scenario()["scenario"] == "03")

        pg.clear_live_scenario()
        check("clearing it leaves nothing live", pg.live_scenario() is None)


def test_nothing_is_created_until_a_session_is_started():
    """AC-H1's other half. The .gitignore entry lands first, but a module that
    creates drill-progress/ at import time would also have it appear during
    `make -f Makefile.test test`, in a checkout where nobody is drilling."""
    with _Sandbox() as root:
        # Read every query path there is, against an empty root.
        answers = [
            pg.current_session("03"),
            pg.live_scenario(),
            pg.latest_bundle("03"),
        ]
        check("every query against an empty store answers None", answers == [None, None, None])
        check("querying created no files at all", list(root.iterdir()) == [])
        check("sessions() on an unknown scenario is empty, not an error", pg.sessions("07") == [])


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    print(f"tests/test_progress.py - {len(tests)} groups")
    for t in tests:
        print(f"\n{t.__name__}")
        t()
    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
