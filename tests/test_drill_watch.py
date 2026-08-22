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



# ---------------------------------------------------------------------------
# The idle clock
# ---------------------------------------------------------------------------


def test_the_duration_parser_takes_the_units_a_human_would_type():
    for raw, expected in [
        ("90", 90), ("90s", 90), ("5m", 300), ("1h", 3600),
        ("30m", 1800), ("2h", 7200), (" 5M ", 300),
    ]:
        check(f"{raw!r} parses to {expected}s", dw.parse_duration(raw) == expected)

    check("330s renders back as 5m30s", dw.human_duration(330) == "5m30s")
    check("3600s renders back as 1h", dw.human_duration(3600) == "1h")
    check("45s renders back as 45s", dw.human_duration(45) == "45s")


def test_a_malformed_duration_is_fatal_and_never_defaulted_around():
    """The whole point. A typo that becomes some other number is the worst outcome
    available for a setting whose job is to destroy an environment: the user
    believes they set one thing, the machine believes another, and the
    disagreement only surfaces once the cluster is already gone."""
    for bad_value in ["", "   ", "0", "0s", "5x", "abc", "-5", "5 m", "m", "1.5h"]:
        try:
            got = dw.parse_duration(bad_value)
            bad(f"{bad_value!r} was accepted as {got}s - it must raise instead")
        except dw.IdleConfigError:
            ok(f"{bad_value!r} is refused rather than defaulted")

    try:
        dw.parse_duration("0")
        bad("zero was accepted")
    except dw.IdleConfigError as e:
        check(
            "and the zero refusal names the way to actually turn it off",
            "unset" in str(e).lower(),
        )


def test_unset_means_off_and_nothing_else_does():
    check("no DRILL_IDLE_TIMEOUT at all is off", dw.idle_policy_from_env({}) is None)
    check("an empty value is off", dw.idle_policy_from_env({"DRILL_IDLE_TIMEOUT": ""}) is None)
    check(
        "whitespace is off",
        dw.idle_policy_from_env({"DRILL_IDLE_TIMEOUT": "   "}) is None,
    )

    p = dw.idle_policy_from_env({"DRILL_IDLE_TIMEOUT": "5m"})
    check("a set value is on", p is not None and p.timeout == 300)
    check("and defaults to warn, not destroy", p.action == "warn")
    check("so it is NOT armed by default", not p.armed)
    check("with the 60s grace, not the 10s SHUT IT DOWN uses", p.grace == 60)

    armed = dw.idle_policy_from_env(
        {"DRILL_IDLE_TIMEOUT": "5m", "DRILL_IDLE_ACTION": "destroy"}
    )
    check("destroy arms it", armed.armed)

    try:
        dw.idle_policy_from_env({"DRILL_IDLE_TIMEOUT": "5m", "DRILL_IDLE_ACTION": "yes"})
        bad("a nonsense action was accepted")
    except dw.IdleConfigError:
        ok("a nonsense action is refused rather than treated as one of the two")


def test_the_warn_window_can_never_exceed_the_timeout():
    """Otherwise the banner is on screen from the first second of every drill,
    which teaches the learner to ignore the one thing they must not ignore."""
    p = dw.idle_policy_from_env({"DRILL_IDLE_TIMEOUT": "60s", "DRILL_IDLE_WARN": "10m"})
    check("a warn window longer than the timeout is clamped to it", p.warn == 60)


def test_the_verdict_counts_down_and_then_fires():
    p = dw.IdlePolicy(timeout=300, action="destroy", grace=60, warn=120)
    at = 1_000_000.0
    stamped = "2026-08-22T12:00:00+00:00"
    base = dw._iso_to_epoch(stamped)

    def verdict(elapsed):
        return dw.idle_verdict(p, stamped, base + elapsed, base + elapsed)

    check("fresh activity is active", verdict(10)[0] == "active")
    check("halfway is still active", verdict(150)[0] == "active")
    check("inside the warn window it warns", verdict(200)[0] == "warn")
    check("and the warn reports the seconds left", verdict(200)[1] == 100)
    check("at the deadline it fires", verdict(300)[0] == "fire")
    check("past the deadline it still fires", verdict(999)[0] == "fire")


def test_it_never_fires_on_information_it_does_not_have():
    """`unknown` and `stale` are separate from `active` on purpose, and neither may
    ever become `fire`. A server too old to stamp lastActivityAt, and an API that
    stopped answering, are both cases where nobody knows whether a human is
    working - and not knowing is never grounds to destroy an environment."""
    p = dw.IdlePolicy(timeout=300, action="destroy", grace=60, warn=120)
    now = 1_000_000.0

    check(
        "a state with no lastActivityAt is unknown, not idle",
        dw.idle_verdict(p, None, now, now)[0] == "unknown",
    )
    check(
        "an unparseable lastActivityAt is unknown, not idle",
        dw.idle_verdict(p, "yesterday afternoon", now, now)[0] == "unknown",
    )
    check(
        "a state that was never successfully read is stale, not idle",
        dw.idle_verdict(p, "2026-08-22T12:00:00+00:00", None, now)[0] == "stale",
    )

    # The one that matters: activity IS old enough to fire, but the reading of it
    # is old too - which is what an unreachable API looks like from here.
    stamped = "2026-08-22T12:00:00+00:00"
    base = dw._iso_to_epoch(stamped)
    verdict, _ = dw.idle_verdict(p, stamped, base, base + 10_000)
    check(
        "an old activity stamp behind a DEAD API is stale, not fire",
        verdict == "stale",
    )

    # ...and the same age, read a moment ago, genuinely is idle.
    verdict, _ = dw.idle_verdict(p, stamped, base + 10_000, base + 10_000)
    check("the same staleness with a LIVE read does fire", verdict == "fire")


def test_the_banner_quotes_the_users_own_number_back_at_them():
    armed = dw.IdlePolicy(timeout=300, action="destroy", grace=60, warn=120)
    text = dw.idle_banner(armed, 48, "03")
    check("it names the configured limit", "5m" in text)
    check("it names the time left", "48s" in text)
    check("it says self-terminate, in the armed voice", "SELF-TERMINATES" in text)
    check("it tells them how to come back", "make scenario N=03" in text)
    check("it says what resets the clock", "resets the clock" in text)
    check("and the pun landed", "Hasta la vista" in text)

    warn = dw.IdlePolicy(timeout=300, action="warn", grace=60, warn=120)
    wtext = dw.idle_banner(warn, 48, "03")
    check(
        "in warn mode it says WOULD, because saying WILL would be a lie",
        "WOULD self-terminate" in wtext and "SELF-TERMINATES" not in wtext,
    )
    check(
        "and it names the flag that arms it",
        "DRILL_IDLE_ACTION=destroy" in wtext,
    )



def test_the_monitor_stands_down_on_anything_that_is_not_a_live_drill():
    """The clock must not race a switch or a quit that is already under way, and
    must not act at all on state it does not have."""
    p = dw.IdlePolicy(timeout=300, action="destroy", grace=60, warn=120)
    fired = []
    m = dw.IdleMonitor(p, on_fire=lambda: fired.append(1))

    check("with nothing observed it does nothing", m.tick() == "nothing")

    for phase in ("switching", "ended", "destroy-requested"):
        m.observe({"phase": phase, "lastActivityAt": "2020-01-01T00:00:00+00:00"})
        check(f"phase {phase} stands the clock down", m.tick() == "not-active")

    m.observe({"phase": "active"})
    check("no lastActivityAt is 'unknown', never 'fire'", m.tick() == "unknown")
    check("and nothing was destroyed", not fired)


def test_the_monitor_fires_only_when_armed():
    """Same elapsed time, same everything, one flag apart. warn must report and
    NOT call on_fire; destroy must."""
    stamped = "2026-08-22T12:00:00+00:00"
    base = dw._iso_to_epoch(stamped)
    state = {"phase": "active", "scenario": "03", "lastActivityAt": stamped}

    warn_fired = []
    warn = dw.IdleMonitor(
        dw.IdlePolicy(timeout=60, action="warn", grace=60, warn=30),
        on_fire=lambda: warn_fired.append(1),
    )
    warn.observe(state)
    warn._last_read_at = base + 100
    check("warn mode reports rather than fires", warn.tick(now=base + 100) == "warned-only")
    check("warn mode called on_fire ZERO times", not warn_fired)
    check("and warn mode never sets .fired", not warn.fired)

    armed_fired = []
    armed = dw.IdleMonitor(
        dw.IdlePolicy(timeout=60, action="destroy", grace=60, warn=30),
        on_fire=lambda: armed_fired.append(1),
    )
    armed.observe(state)
    armed._last_read_at = base + 100
    check("armed mode fires", armed.tick(now=base + 100) == "fired")
    check("and calls on_fire exactly once", len(armed_fired) == 1)
    check("and records it", armed.fired)


def test_the_monitor_counts_down_and_resets_on_activity():
    stamped = "2026-08-22T12:00:00+00:00"
    base = dw._iso_to_epoch(stamped)
    m = dw.IdleMonitor(
        dw.IdlePolicy(timeout=300, action="destroy", grace=60, warn=120),
        on_fire=lambda: None,
    )
    m.observe({"phase": "active", "scenario": "03", "lastActivityAt": stamped})
    m._last_read_at = base

    check("early on it is simply active", m.tick(now=base + 10) == "active")
    m._last_read_at = base + 200
    check("inside the window it warns", m.tick(now=base + 200) == "warn")

    # The learner comes back and types. The stamp moves, and the clock restarts -
    # this is the whole contract from the watcher's side.
    later = "2026-08-22T12:04:00+00:00"
    m.observe({"phase": "active", "scenario": "03", "lastActivityAt": later})
    check(
        "a fresh keystroke puts it back to active",
        m.tick(now=dw._iso_to_epoch(later) + 5) == "active",
    )


def test_publishing_the_idle_policy_never_clobbers_the_scenario():
    """drill-request carries BOTH the scenario and the idle policy, and they are
    written by different call sites. A publish that replaced the object would drop
    the session id, and the pod would converge onto nothing."""
    calls = []
    real_read, real_apply = dw.read_request, dw.apply_request
    try:
        dw.read_request = lambda cfg: {"scenario": "03", "sessionId": "s-1"}
        dw.apply_request = lambda payload: calls.append(payload)

        dw.publish_idle_policy({}, dw.IdlePolicy(timeout=300, action="warn", grace=60, warn=120))
        check("it wrote once", len(calls) == 1)
        check("the scenario survived", calls[0].get("scenario") == "03")
        check("the session id survived", calls[0].get("sessionId") == "s-1")
        check("and the policy landed", calls[0].get("idleTimeoutSeconds") == 300)
        check("with the action", calls[0].get("idleAction") == "warn")

        # Turning the feature off must REMOVE the keys, not leave them behind -
        # a stale policy has the GUI counting down to a teardown no watcher will do.
        calls.clear()
        dw.read_request = lambda cfg: {
            "scenario": "03", "sessionId": "s-1",
            "idleTimeoutSeconds": 300, "idleAction": "warn", "idleWarnSeconds": 120,
        }
        dw.publish_idle_policy({}, None)
        check("turning it off rewrites the object", len(calls) == 1)
        check("the idle keys are gone", "idleTimeoutSeconds" not in calls[0])
        check("and the scenario is still there", calls[0].get("scenario") == "03")

        # Nothing changed: no write at all. A write per tick would churn the object.
        calls.clear()
        dw.read_request = lambda cfg: {
            "scenario": "03", "sessionId": "s-1",
            "idleTimeoutSeconds": 300, "idleAction": "warn", "idleWarnSeconds": 120,
        }
        dw.publish_idle_policy({}, dw.IdlePolicy(timeout=300, action="warn", grace=60, warn=120))
        check("an unchanged policy writes nothing at all", not calls)
    finally:
        dw.read_request, dw.apply_request = real_read, real_apply


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
