#!/usr/bin/env python3
"""Unit tests for scripts/drill-watch.py's pure parts.

The `kubectl --watch` itself needs a cluster and is covered by the kind harness.
What is testable here is the part that silently does the wrong thing if it breaks,
and both of those turned out to be things the interface-level plan did not
anticipate - they were found by writing the thing:

1. `kubectl get --watch -o json` emits CONCATENATED JSON objects, not an array and
   not one per line. Nothing in the stdlib parses that. A reader that only works
   when a chunk happens to end on an object boundary passes every naive test and
   then fails intermittently against a real socket, because TCP splits wherever it
   likes.

2. PID liveness cannot be `os.kill(pid, 0)`. That is POSIX-only and Windows 11 is
   a supported target here - and worse, a bare PID is ambiguous on every platform,
   because PIDs get recycled. A stale file naming a recycled PID reports a live
   watcher that is actually somebody's text editor, so converge never restarts the
   real one and the drill runs with nothing saving it.
"""
import importlib.util
import json
import os
import subprocess
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
dw = _load("drill_watch", "drill-watch.py")

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
        self._tmp = tempfile.TemporaryDirectory(prefix="drill-watch-test-")
        self._prev = os.environ.get("DRILL_PROGRESS_DIR")
        os.environ["DRILL_PROGRESS_DIR"] = self._tmp.name
        return Path(self._tmp.name)

    def __exit__(self, *exc):
        if self._prev is None:
            os.environ.pop("DRILL_PROGRESS_DIR", None)
        else:
            os.environ["DRILL_PROGRESS_DIR"] = self._prev
        self._tmp.cleanup()


def chunked(text: str, size: int) -> list[str]:
    return [text[i : i + size] for i in range(0, len(text), size)]


# ---------------------------------------------------------------------------


def test_the_watch_stream_reader_survives_any_chunk_boundary():
    a = {"kind": "ConfigMap", "data": {"state.json": '{"scenario":"03"}'}}
    b = {"kind": "ConfigMap", "data": {"state.json": '{"scenario":"06"}'}}
    # Pretty-printed and concatenated: exactly what kubectl emits.
    stream = json.dumps(a, indent=2) + "\n" + json.dumps(b, indent=2) + "\n"

    check("whole stream in one chunk", dw.json_stream([stream]) == [a, b])
    check("one byte at a time", dw.json_stream(list(stream)) == [a, b])

    # Every possible split point, which is the only honest way to test this: the
    # interesting boundaries are mid-string and mid-escape, and picking a few by
    # hand is how you miss the one that matters.
    every = all(
        dw.json_stream([stream[:i], stream[i:]]) == [a, b] for i in range(len(stream))
    )
    check("split at every one of the %d byte offsets" % len(stream), every)

    for size in (3, 7, 13, 64):
        check(f"chunked at {size} bytes", dw.json_stream(chunked(stream, size)) == [a, b])

    check("a trailing partial object is held, not mis-parsed", dw.json_stream(['{"a":1}{"b"']) == [{"a": 1}])
    check("nothing at all yields nothing", dw.json_stream([]) == [])


def test_a_configmap_without_usable_state_answers_none():
    check("no data at all", dw.state_from_event({"kind": "ConfigMap"}) is None)
    check("data with no state key", dw.state_from_event({"data": {}}) is None)
    check("an empty value", dw.state_from_event({"data": {"state.json": ""}}) is None)
    check(
        "a half-written value must not take the watcher down",
        dw.state_from_event({"data": {"state.json": "{ torn"}}) is None,
    )
    check(
        "a JSON scalar is not a session",
        dw.state_from_event({"data": {"state.json": "42"}}) is None,
    )
    check(
        "a real one comes through",
        dw.state_from_event({"data": {"state.json": '{"scenario":"03","phase":"active"}'}})
        == {"scenario": "03", "phase": "active"},
    )


def test_liveness_needs_the_pid_AND_its_start_time():
    with _Sandbox():
        dw.claim_pid_file()
        check("our own watcher reads as live", dw.watcher_is_live() == os.getpid())

        # A PID that is real but is NOT the process the file was written for.
        # This is the recycled-PID case, and the naive `os.kill(pid, 0)` check
        # reports it as a live watcher.
        record = pg.read_json(dw.pid_path())
        record["started"] = "0"  # a start time no live process can have
        pg.write_atomic(dw.pid_path(), record)
        check(
            "a recycled PID is NOT mistaken for a live watcher",
            dw.watcher_is_live() is None,
        )

        # A PID that is simply not running at all.
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        pg.write_atomic(dw.pid_path(), {"pid": dead.pid, "started": "0"})
        check("a dead PID reads as not running", dw.watcher_is_live() is None)

        dw.release_pid_file()
        check("no pid file at all reads as not running", dw.watcher_is_live() is None)

        pg.write_atomic(dw.pid_path(), {"nonsense": True})
        check("a corrupt pid file reads as not running", dw.watcher_is_live() is None)


def test_the_bundle_path_lands_inside_the_session_that_owns_it():
    with _Sandbox() as root:
        p = dw.bundle_path("03", "2026-08-21T19-00-00Z")
        check(
            "the bundle is under the scenario AND the session",
            p == root / "03" / "sessions" / "2026-08-21T19-00-00Z" / "workspace.bundle",
        )
        check("no colon anywhere in the path", ":" not in str(p.relative_to(root)))


def test_adopting_a_server_minted_session_is_idempotent():
    """RESTART and SWITCH mint a session id inside the POD, so the first the
    laptop hears of a session is a state mirroring one. Without adoption those
    sessions have nowhere to live and are simply never saved."""
    with _Sandbox():
        sid = "2026-08-21T19-30-00Z"
        d = dw.adopt_session("03", sid)
        (d / "state.json").write_text('{"marker":"first"}')

        again = dw.adopt_session("03", sid)
        check("adopting twice is the same directory", again == d)
        check(
            "and does not clobber what is already in it",
            (d / "state.json").read_text() == '{"marker":"first"}',
        )
        check("it becomes the current session", pg.current_session("03") == sid)
        check(
            "exactly one results row, not one per adoption",
            len([r for r in pg.results("03") if r["session"] == sid]) == 1,
        )


def test_the_countdown_is_long_enough_to_abort_and_the_kill_switch_exists():
    """The destroy branch is a sanctioned exception to CLAUDE.md hard rule 1 and
    every gate on it is load-bearing. This asserts the two that live in this file."""
    check("there is a countdown at all", dw.DESTROY_COUNTDOWN >= 5)

    prev = os.environ.get("DRILL_ALLOW_DESTROY")
    os.environ["DRILL_ALLOW_DESTROY"] = "0"
    try:
        rc = dw.destroy({"scenario": "03"})
        check("DRILL_ALLOW_DESTROY=0 disarms the branch entirely", rc == 0)
    finally:
        if prev is None:
            os.environ.pop("DRILL_ALLOW_DESTROY", None)
        else:
            os.environ["DRILL_ALLOW_DESTROY"] = prev


def test_finish_closes_the_session_without_deleting_the_save_file():
    with _Sandbox() as root:
        d = pg.new_session("03")
        (d / "workspace.bundle").write_bytes(b"a real save file")
        pg.set_live_scenario("03", d.name)
        (root / ".gui-owns-the-wheel").write_text("{}")

        dw.finish({"scenario": "03", "sessionId": d.name, "passed": ["t1"]})

        check("the session is closed", pg.current_session("03") is None)
        check("nothing is live", pg.live_scenario() is None)
        check("the Makefile gets its wheel back", not (root / ".gui-owns-the-wheel").exists())
        check(
            "the save file is still there - close means over, not discardable",
            (d / "workspace.bundle").read_bytes() == b"a real save file",
        )


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    print(f"tests/test_drill_watch.py - {len(tests)} groups")
    for t in tests:
        print(f"\n{t.__name__}")
        t()
    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
