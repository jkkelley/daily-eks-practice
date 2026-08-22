#!/usr/bin/env python3
"""Keep drill-progress/ in step with the running drill, and act on how it ends.

    python3 scripts/drill-watch.py            # foreground; `make scenario` starts one
    python3 scripts/drill-watch.py --once     # sync once and exit
    python3 scripts/drill-watch.py --status   # is one running?
    python3 scripts/drill-watch.py --stop     # stop the running one

Watches the `drill-state` ConfigMap with `kubectl --watch` rather than polling it.
The API server pushes, so there is no interval to tune and no lag on a task pass,
and it is the primitive every controller is built on - which keeps the tool that
teaches Kubernetes built out of Kubernetes.

(The drill server, on the other side of this contract, POLLS its own
`drill-request`. That asymmetry is deliberate; the reasoning is in
`drill/server/src/request.ts` and it is about which side of the network each
process is on.)

---- WHAT IT DOES WITH EACH PHASE ------------------------------------------

  active              sync state.json, re-bundle the workspace
  switching           sync and bundle FIRST, then restore the target, then
                      write drill-request so the pod converges
  ended               final sync, record the result, close the session, exit
  destroy-requested   everything `ended` does, then a countdown, then `make down`

**Sync-before-switch is the ordering that must not be got wrong.** A switch is the
one moment the previous scenario's work is about to be overwritten in cluster git,
so a bundle taken afterwards saves the NEXT scenario's baseline under the PREVIOUS
scenario's session id. That looks like it worked and loses the drill.

---- destroy-requested IS A SANCTIONED EXCEPTION TO A HARD RULE ------------

`CLAUDE.md` hard rule 1 says a destroy is always driven by hand. The GUI's
`SHUT IT DOWN` entry is the one exception, granted explicitly, and every gate
below is load-bearing:

  * the learner typed the literal string DESTROY, and the server re-checked it
  * the pod destroyed nothing - it wrote an intent, and THIS process, which the
    user started themselves in their own checkout, is what acts on it
  * the countdown below is abortable with ctrl-c, so the last gate is in the
    terminal the user is sitting at
  * DRILL_ALLOW_DESTROY=0 disarms the branch entirely
  * it runs `make down`, so pre-destroy.py runs first and refuses rather than
    orphaning a billing load balancer

Do not widen any of that without asking. The exception is narrow on purpose.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clustergit  # noqa: E402
import progress  # noqa: E402

REPO = Path(__file__).resolve().parent.parent

DRILL_NS = os.environ.get("DRILL_NAMESPACE", "practice-drill")
STATE_CM = "drill-state"
REQUEST_CM = "drill-request"
STATE_KEY = "state.json"
REQUEST_KEY = "request.json"

#: Seconds between the destroy intent arriving and `make down` running.
DESTROY_COUNTDOWN = 10


# ---------------------------------------------------------------------------
# Reading a `kubectl --watch -o json` stream
# ---------------------------------------------------------------------------


def json_stream(chunks) -> "list[dict]":
    """Decode a stream of CONCATENATED JSON objects into a list.

    `kubectl get --watch -o json` does not emit a JSON array and does not emit
    one object per line - it emits pretty-printed objects back to back, and
    nothing in the stdlib parses that shape directly.

    This is a generator-ish helper written as a pure function over an iterable of
    text chunks precisely so it can be unit tested. An implementation that only
    works when a chunk happens to end on an object boundary passes every naive
    test and then fails intermittently against a real socket, because TCP splits
    wherever it likes - mid-string, mid-escape, mid-number.
    """
    decoder = json.JSONDecoder()
    buf = ""
    out = []
    for chunk in chunks:
        buf += chunk
        while True:
            buf = buf.lstrip()
            if not buf:
                break
            try:
                obj, end = decoder.raw_decode(buf)
            except ValueError:
                break  # a partial object: wait for more bytes
            out.append(obj)
            buf = buf[end:]
    return out


def state_from_event(event: dict) -> dict | None:
    """Pull the SessionState out of a watch event, or None if there is not one.

    A ConfigMap with no `data` is a real state - the laptop creates the object
    before it has anything to put in it - and so is a half-written value. Both
    answer None, because the only sensible response to either is to wait.
    """
    if not isinstance(event, dict):
        return None
    data = event.get("data")
    if not isinstance(data, dict):
        return None
    raw = data.get(STATE_KEY)
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


# ---------------------------------------------------------------------------
# The PID file
# ---------------------------------------------------------------------------


def pid_path() -> Path:
    return progress.progress_root() / ".watcher.pid"


def process_start_time(pid: int) -> str | None:
    """A stable-ish identity for a running process, or None if it is not running.

    A BARE PID IS NOT ENOUGH. PIDs are reused, so a stale file naming a recycled
    PID reports a live watcher that is actually somebody's text editor - and
    converge then never restarts the real one, so the drill runs with nothing
    saving it and no error anywhere.

    `os.kill(pid, 0)` is also not enough on its own AND is POSIX-only, and
    Windows 11 is a supported target here. /proc gives an exact answer on Linux;
    everywhere else this falls back to existence, which is weaker but is the same
    answer the obvious implementation would have given.
    """
    stat = Path(f"/proc/{pid}/stat")
    if stat.exists():
        try:
            # Field 22 is starttime in clock ticks since boot. Parsed from after
            # the last ')' because a process name can contain spaces and
            # parentheses, which is a classic /proc parsing bug.
            text = stat.read_text()
            fields = text[text.rindex(")") + 1 :].split()
            return fields[19]
        except (OSError, ValueError, IndexError):
            return None

    if os.name == "nt":  # pragma: no cover - not exercised on Linux CI
        out = subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
            capture_output=True, text=True,
        )
        return "running" if str(pid) in out.stdout else None

    try:
        os.kill(pid, 0)
        return "running"
    except (OSError, ProcessLookupError):
        return None


def watcher_is_live() -> int | None:
    """The PID of a running watcher, or None. Both the PID and its start time must match."""
    raw = progress.read_json(pid_path(), None)
    if not isinstance(raw, dict):
        return None
    pid, started = raw.get("pid"), raw.get("started")
    if not isinstance(pid, int):
        return None
    now = process_start_time(pid)
    if now is None:
        return None
    if started is not None and now != "running" and str(started) != str(now):
        return None  # the PID was recycled: this is somebody else's process
    return pid


def claim_pid_file() -> None:
    progress.write_atomic(
        pid_path(),
        {
            "pid": os.getpid(),
            "started": process_start_time(os.getpid()),
            "since": datetime.now(timezone.utc).isoformat(),
        },
    )


def release_pid_file() -> None:
    pid_path().unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Syncing
# ---------------------------------------------------------------------------


def bundle_path(scenario: str, session_id: str) -> Path:
    return progress.session_dir(scenario, session_id) / "workspace.bundle"


def adopt_session(scenario: str, session_id: str) -> Path:
    """A session the SERVER invented needs somewhere on disk to live."""
    return progress.ensure_session(scenario, session_id)


def sync(cfg: dict, state: dict, *, bundle: bool = True) -> None:
    """Write state.json and re-bundle cluster git. Atomic, verified, both."""
    scenario = state.get("scenario")
    session_id = state.get("sessionId")
    if not scenario or not session_id:
        return

    adopt_session(scenario, session_id)
    progress.write_atomic(progress.session_dir(scenario, session_id) / "state.json", state)
    progress.record_result(
        scenario,
        session_id,
        passed=len(state.get("passed") or []),
        total=state.get("total") or len(state.get("passed") or []),
    )
    progress.set_live_scenario(scenario, session_id)

    if not bundle:
        return
    try:
        pod = clustergit.pod_name(cfg, timeout="30s")
        out = clustergit.pull_bundle(cfg, pod, bundle_path(scenario, session_id))
        if out is None:
            print("drill-watch: cluster git has nothing to bundle yet", flush=True)
    except (clustergit.ClusterGitError, subprocess.CalledProcessError) as e:
        # A failed bundle is loud but not fatal. state.json is already saved, the
        # drill is still running, and the next state change tries again.
        print(f"drill-watch: could not bundle cluster git - {e}", file=sys.stderr, flush=True)


def write_request(cfg: dict, scenario: str, session_id: str, restored_from: str | None) -> None:
    """Tell the pod which scenario to converge to. The laptop owns this object."""
    payload = {
        "scenario": scenario,
        "sessionId": session_id,
        "requestedAt": datetime.now(timezone.utc).isoformat(),
        **({"restoredFrom": restored_from} if restored_from else {}),
    }
    # `create --dry-run=client -o json | apply -f -` rather than `create`, because
    # a switch back to a scenario that already has a request must update the
    # object rather than fail with AlreadyExists.
    manifest = subprocess.run(
        ["kubectl", "-n", DRILL_NS, "create", "configmap", REQUEST_CM,
         f"--from-literal={REQUEST_KEY}={json.dumps(payload)}",
         "--dry-run=client", "-o", "json"],
        check=True, capture_output=True, text=True,
    ).stdout
    subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, text=True, check=True)


def restore(cfg: dict, scenario: str) -> tuple[str, str | None]:
    """Put the target scenario's saved work back into cluster git.

    Returns (session_id, restored_from). A scenario with no save file gets a NEW
    session restored from `baseline.bundle` - cluster git as `make git-seed` left
    it - because without that the next scenario inherits the last one's finished
    working tree and begins already solved.
    """
    saved = progress.latest_bundle(scenario)
    source = saved or (progress.baseline_bundle() if progress.baseline_bundle().is_file() else None)

    if saved:
        session_id = progress.current_session(scenario) or progress.sessions(scenario)[-1]
    else:
        session_id = progress.new_session(scenario).name

    if source is None:
        print(
            f"drill-watch: nothing to restore for scenario {scenario} and no baseline - "
            "cluster git is left as it is",
            file=sys.stderr, flush=True,
        )
        return session_id, None

    pod = clustergit.pod_name(cfg, timeout="60s")
    clustergit.push_bundle(cfg, pod, clustergit.bundle_from_file(source))
    print(f"drill-watch: restored scenario {scenario} from {source.name}", flush=True)
    return session_id, str(source)


# ---------------------------------------------------------------------------
# The terminal phases
# ---------------------------------------------------------------------------


def finish(state: dict) -> None:
    scenario, session_id = state.get("scenario"), state.get("sessionId")
    if scenario and session_id:
        progress.close_session(scenario, session_id)
    progress.clear_live_scenario()
    (progress.progress_root() / ".gui-owns-the-wheel").unlink(missing_ok=True)


def destroy(state: dict) -> int:
    """The SHUT IT DOWN branch. Read the module header before changing anything here."""
    if os.environ.get("DRILL_ALLOW_DESTROY") == "0":
        print(
            "drill-watch: the drill asked to tear the environment down, but "
            "DRILL_ALLOW_DESTROY=0 is set. Nothing was destroyed. Run `make down` yourself.",
            file=sys.stderr, flush=True,
        )
        return 0

    print("", flush=True)
    print("  " + "=" * 68, flush=True)
    print("  SHUT IT DOWN was confirmed in the drill GUI.", flush=True)
    print("", flush=True)
    print("  `make down` is about to run. It destroys THIS environment:", flush=True)
    print("    the EKS control plane, the nodes, the NAT gateway, the ALB,", flush=True)
    print("    the RDS instance and every volume the drill created.", flush=True)
    print("", flush=True)
    print(f"  Your progress is saved in {progress.progress_root().name}/ and survives this.", flush=True)
    print("", flush=True)
    print("  ctrl-c to abort.", flush=True)
    print("  " + "=" * 68, flush=True)
    try:
        for remaining in range(DESTROY_COUNTDOWN, 0, -1):
            print(f"  destroying in {remaining}... ", end="\r", flush=True)
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n  aborted. Nothing was destroyed. The cluster is still up and still billing.", flush=True)
        return 1

    print("\n  running `make down`", flush=True)
    return subprocess.run(["make", "down"], cwd=str(REPO)).returncode


# ---------------------------------------------------------------------------
# The loop
# ---------------------------------------------------------------------------


def handle(cfg: dict, state: dict) -> str:
    """Act on one state. Returns "continue" or "stop"."""
    phase = state.get("phase", "active")

    if phase == "switching":
        target = state.get("target")
        if not target:
            return "continue"
        # Bundle the CURRENT session before anything touches cluster git. Get this
        # ordering wrong and the next scenario's baseline is saved under this
        # session's id - which looks like it worked and loses the drill.
        sync(cfg, state)
        try:
            session_id, source = restore(cfg, target)
            write_request(cfg, target, session_id, source)
        except (clustergit.ClusterGitError, subprocess.CalledProcessError) as e:
            print(f"drill-watch: the switch to {target} failed - {e}", file=sys.stderr, flush=True)
        return "continue"

    sync(cfg, state)

    if phase == "ended":
        finish(state)
        print(
            f"drill-watch: scenario {state.get('scenario')} ended, "
            f"{len(state.get('passed') or [])} passed. Saved.",
            flush=True,
        )
        return "stop"

    if phase == "destroy-requested":
        finish(state)
        destroy(state)
        return "stop"

    return "continue"


def watch(cfg: dict) -> int:
    """Follow the ConfigMap until a terminal phase, or forever."""
    proc = subprocess.Popen(
        ["kubectl", "-n", DRILL_NS, "get", "configmap", STATE_CM,
         "--watch", "--ignore-not-found", "-o", "json"],
        stdout=subprocess.PIPE, text=True, bufsize=1,
    )
    assert proc.stdout is not None
    decoder = json.JSONDecoder()
    buf = ""
    try:
        for line in proc.stdout:
            buf += line
            while True:
                buf = buf.lstrip()
                if not buf:
                    break
                try:
                    event, end = decoder.raw_decode(buf)
                except ValueError:
                    break
                buf = buf[end:]
                state = state_from_event(event)
                if state and handle(cfg, state) == "stop":
                    return 0
    except KeyboardInterrupt:
        print("\ndrill-watch: stopped. Your progress is saved.", flush=True)
    finally:
        proc.terminate()
    return 0


def sync_once(cfg: dict) -> int:
    """Catch up on whatever happened while no watcher was running."""
    out = subprocess.run(
        ["kubectl", "-n", DRILL_NS, "get", "configmap", STATE_CM,
         "--ignore-not-found", "-o", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        return 0
    events = json_stream([out.stdout])
    state = state_from_event(events[0]) if events else None
    if state:
        handle(cfg, state)
    return 0


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else ""

    if mode == "--status":
        pid = watcher_is_live()
        print(f"drill-watch: running (pid {pid})" if pid else "drill-watch: not running")
        return 0 if pid else 1

    if mode == "--stop":
        pid = watcher_is_live()
        if not pid:
            print("drill-watch: not running")
            return 0
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError as e:
            print(f"drill-watch: could not stop pid {pid} - {e}", file=sys.stderr)
            return 1
        release_pid_file()
        print(f"drill-watch: stopped (pid {pid})")
        return 0

    live = watcher_is_live()
    if live and mode != "--once":
        print(f"drill-watch: already running (pid {live}) - nothing to do")
        return 0

    try:
        cfg = clustergit.settings()
    except clustergit.ClusterGitError as e:
        print(f"drill-watch: {e}", file=sys.stderr)
        return 1

    if mode == "--once":
        return sync_once(cfg)

    claim_pid_file()
    try:
        # Sync immediately, to catch up on anything missed while it was down.
        sync_once(cfg)
        return watch(cfg)
    finally:
        release_pid_file()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
