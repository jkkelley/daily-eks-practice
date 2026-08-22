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

---- IDLE TEARDOWN IS THE SECOND SANCTIONED PATH ---------------------------

Granted 2026-08-22, and written here because an unwritten exception does not
narrow a rule, it voids it. The motivation is money: the control plane bills for
as long as it is up, and the only thing that stops it is somebody remembering.

  DRILL_IDLE_TIMEOUT   unset = OFF. "90s", "5m", "1h", or a bare count of
                       seconds. There is no default and there never will be.
  DRILL_IDLE_ACTION    "warn" (default) or "destroy". warn proves the clock
                       with nothing at stake; destroy arms it.
  DRILL_IDLE_GRACE     the abortable countdown before `make down`. Default 60s,
                       not the 10s above, because you are walking BACK to the
                       keyboard rather than already sitting at it.

**One gate of the SHUT IT DOWN path cannot exist here and its absence is the
whole design problem.** There is no typed DESTROY, because the entire premise is
that nobody is at the keyboard. What stands in for it:

  * OFF unless DRILL_IDLE_TIMEOUT is set. Nobody's cluster vanishes because of a
    feature they did not know shipped.
  * warn is the default action, so arming it is a second deliberate act.
  * the deadline is computed from `lastActivityAt`, which the server stamps ONLY
    on human input - never on its own dependency push, its health probe or its
    Argo poll. If app chatter counted, an open browser tab would hold the cluster
    open forever and this would silently never fire.
  * a state that cannot be read is never grounds to destroy. "I cannot see" and
    "nothing is happening" are different answers, and only one of them is here.
  * DRILL_ALLOW_DESTROY=0 and `make down` behave exactly as they do above.

Every clause is load-bearing. Read CLAUDE.md hard rule 1 before touching it.
"""
from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
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

#: Default abortable countdown for the IDLE path. Longer than DESTROY_COUNTDOWN
#: on purpose: SHUT IT DOWN is confirmed by somebody sitting at the keyboard,
#: and this one has to be caught by somebody walking back to it.
IDLE_GRACE_DEFAULT = 60

#: How long before the deadline the learner starts being told. Also how long the
#: countdown is visible in the GUI.
IDLE_WARN_DEFAULT = 120

#: A state older than this is not evidence of anything. If the last successful
#: read of `drill-state` is staler than the idle timeout plus this margin, the
#: monitor refuses to act - it cannot tell an idle learner from a dead API.
IDLE_STALE_MARGIN = 60


# ---------------------------------------------------------------------------
# The idle clock
# ---------------------------------------------------------------------------


class IdleConfigError(ValueError):
    """A malformed DRILL_IDLE_* value. Always fatal - never defaulted around."""


def parse_duration(raw: str) -> int:
    """Seconds from "90s" / "5m" / "1h" / "90", or raise IdleConfigError.

    Deliberately strict, and deliberately fatal rather than falling back to a
    default. A typo'd timeout that quietly becomes some other number is the worst
    available outcome for a setting whose job is to destroy an environment: the
    user believes they set one thing, the machine believes another, and the
    disagreement only surfaces when the cluster is already gone.

    Zero is refused for the same reason. `DRILL_IDLE_TIMEOUT=0` reads as "off" to
    a human and computes as "immediately" to a machine, and off is spelled by not
    setting the variable at all.
    """
    text = (raw or "").strip().lower()
    if not text:
        raise IdleConfigError("empty duration - unset the variable to turn the feature off")

    units = {"s": 1, "m": 60, "h": 3600}
    unit = 1
    if text[-1] in units:
        unit = units[text[-1]]
        text = text[:-1]

    if not text.isdigit():
        raise IdleConfigError(
            f"{raw!r} is not a duration - use 90s, 5m, 1h, or a bare number of seconds"
        )

    seconds = int(text) * unit
    if seconds <= 0:
        raise IdleConfigError(
            f"{raw!r} is not a usable idle timeout - to turn the feature off, "
            "unset DRILL_IDLE_TIMEOUT rather than setting it to zero"
        )
    return seconds


def human_duration(seconds: int) -> str:
    """`330` -> `5m30s`. Used in messages, so the learner sees their own units back."""
    if seconds <= 0:
        return "0s"
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    out = f"{h}h" if h else ""
    out += f"{m}m" if m else ""
    out += f"{s}s" if s or not out else ""
    return out


class IdlePolicy:
    """What the user asked for, or None-ish if they asked for nothing."""

    def __init__(self, timeout: int, action: str, grace: int, warn: int) -> None:
        self.timeout = timeout
        self.action = action
        self.grace = grace
        self.warn = warn

    @property
    def armed(self) -> bool:
        return self.action == "destroy"

    def as_request_fields(self) -> dict:
        """The half the pod needs, so the GUI can render the same countdown."""
        return {
            "idleTimeoutSeconds": self.timeout,
            "idleAction": self.action,
            "idleWarnSeconds": self.warn,
        }


def idle_policy_from_env(env: dict | None = None) -> IdlePolicy | None:
    """Read DRILL_IDLE_*, or None when the feature is off.

    Off is the absence of DRILL_IDLE_TIMEOUT and nothing else. Every other
    malformed value raises rather than degrading into a default.
    """
    e = os.environ if env is None else env
    raw = e.get("DRILL_IDLE_TIMEOUT")
    if raw is None or not raw.strip():
        return None

    timeout = parse_duration(raw)

    action = (e.get("DRILL_IDLE_ACTION") or "warn").strip().lower()
    if action not in ("warn", "destroy"):
        raise IdleConfigError(
            f"DRILL_IDLE_ACTION={action!r} is not valid - use 'warn' or 'destroy'"
        )

    grace = parse_duration(e["DRILL_IDLE_GRACE"]) if e.get("DRILL_IDLE_GRACE") else IDLE_GRACE_DEFAULT
    warn = parse_duration(e["DRILL_IDLE_WARN"]) if e.get("DRILL_IDLE_WARN") else IDLE_WARN_DEFAULT
    # A warn window longer than the timeout would put the banner on screen from
    # the first second of every drill, which trains the learner to ignore it.
    warn = min(warn, timeout)

    return IdlePolicy(timeout=timeout, action=action, grace=grace, warn=warn)


def idle_verdict(
    policy: IdlePolicy,
    last_activity: str | None,
    last_read_at: float | None,
    now: float,
    parse_iso=None,
) -> tuple[str, int]:
    """Decide what the idle clock should do. Pure, so it can be tested at any offset.

    Returns one of ("off"|"unknown"|"stale"|"active"|"warn"|"fire", seconds_left).

    `unknown` and `stale` are separate from `active` on purpose, and neither ever
    becomes `fire`. A server too old to stamp `lastActivityAt`, and an API that
    stopped answering, are both cases where we do not know whether anybody is
    working - and not knowing is never grounds to destroy an environment.
    """
    to_epoch = parse_iso or _iso_to_epoch

    if last_activity is None:
        return "unknown", 0

    stamped = to_epoch(last_activity)
    if stamped is None:
        return "unknown", 0

    # The state we are reasoning from must itself be fresh. Without this the
    # monitor happily counts down against a `lastActivityAt` frozen by an
    # unreachable API and tears the environment down on the strength of it.
    if last_read_at is None or (now - last_read_at) > policy.timeout + IDLE_STALE_MARGIN:
        return "stale", 0

    left = int(round(policy.timeout - (now - stamped)))
    if left <= 0:
        return "fire", 0
    if left <= policy.warn:
        return "warn", left
    return "active", left


def _iso_to_epoch(text: str) -> float | None:
    try:
        parsed = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def idle_banner(policy: IdlePolicy, left: int, scenario: str | None) -> str:
    """The warning, quoting the user's own configured value back at them.

    The joke is deliberate and it is also true, which is the only kind worth
    shipping: the cluster really does self-terminate, and `I'll be back` really is
    what happens next - the save file outlives the cluster it came from, which is
    the thing AC-H4 exists to prove.
    """
    resume = f"make scenario N={scenario}" if scenario else "make scenario N=NN"
    lines = [
        "",
        "  " + "=" * 68,
        f"  No human input for {human_duration(policy.timeout - left)} "
        f"of your {human_duration(policy.timeout)} idle limit.",
        "",
    ]
    if policy.armed:
        lines += [
            f"  This cluster SELF-TERMINATES in {human_duration(left)}.",
            "",
            '      "Hasta la vista, baby."',
            "",
            f"  Your progress is saved in {progress.progress_root().name}/ and outlives",
            f"  the cluster. I'll be back:   {resume}",
        ]
    else:
        lines += [
            f"  This cluster WOULD self-terminate in {human_duration(left)} -",
            "  but DRILL_IDLE_ACTION=warn, so nothing is going to happen.",
            "",
            '      "I\'ll be back." ...eventually. Not today.',
            "",
            "  Set DRILL_IDLE_ACTION=destroy to give this teeth.",
        ]
    lines += [
        "",
        "  Any keystroke, save or submit in the drill resets the clock.",
        "  " + "=" * 68,
    ]
    return "\n".join(lines)


class IdleMonitor(threading.Thread):
    """The clock that ticks when nothing is happening.

    It has to be a thread. `watch()` blocks on `proc.stdout`, and an idle drill
    produces no events by definition - the server stops flushing `lastActivityAt`
    the moment the learner stops typing. So the one loop that could notice is the
    one guaranteed to be asleep. A `select` with a timeout would do on POSIX and
    does not work on Windows pipes, and Windows 11 is a supported target here.

    The thread decides; it does not destroy. When the deadline passes in destroy
    mode it sets `fired` and unblocks the watch loop, and the countdown and the
    `make down` run on the MAIN thread - so ctrl-c reaches them, which is the last
    gate and the only one a person can still use once the machine has decided.
    """

    def __init__(self, policy: IdlePolicy, on_fire) -> None:
        super().__init__(name="drill-idle", daemon=True)
        self.policy = policy
        self._on_fire = on_fire
        self._lock = threading.Lock()
        self._state: dict | None = None
        self._last_read_at: float | None = None
        self._stop = threading.Event()
        self._warned = False
        self._complained = ""
        self.fired = False

    def observe(self, state: dict) -> None:
        """Called from the watch loop every time a state is successfully read."""
        with self._lock:
            self._state = state
            self._last_read_at = time.time()

    def stop(self) -> None:
        self._stop.set()

    def _snapshot(self) -> tuple[dict | None, float | None]:
        with self._lock:
            return self._state, self._last_read_at

    def _complain_once(self, key: str, message: str) -> None:
        """Say it, but say it once. A per-second reason is noise, not a warning."""
        if self._complained != key:
            self._complained = key
            print(message, file=sys.stderr, flush=True)

    def run(self) -> None:  # pragma: no cover - the loop is the thread
        while not self._stop.wait(1.0):
            state, read_at = self._snapshot()
            if state is None:
                continue
            # A terminal phase has its own path; the idle clock stands down so it
            # cannot race a switch or a quit that is already under way.
            if state.get("phase") not in (None, "active"):
                continue

            verdict, left = idle_verdict(
                self.policy, state.get("lastActivityAt"), read_at, time.time()
            )

            if verdict == "unknown":
                self._complain_once(
                    "unknown",
                    "drill-watch: the idle timeout is set, but this drill server does not "
                    "report lastActivityAt - the clock is not running. Nothing will be "
                    "destroyed on a timer.",
                )
                continue
            if verdict == "stale":
                self._complain_once(
                    "stale",
                    "drill-watch: cannot read the drill state, so the idle clock is "
                    "standing down. An unreachable API is not the same as an idle "
                    "learner, and only one of those is a reason to destroy anything.",
                )
                continue

            self._complained = ""

            if verdict == "active":
                self._warned = False
                continue

            if verdict == "warn":
                if not self._warned:
                    self._warned = True
                    print(idle_banner(self.policy, left, state.get("scenario")), flush=True)
                print(f"  idle: {human_duration(left)} left... ", end="\r", flush=True)
                continue

            # fire
            if not self.policy.armed:
                self._complain_once(
                    "warned-only",
                    "\ndrill-watch: the idle limit passed. DRILL_IDLE_ACTION=warn, so "
                    "nothing was destroyed and the cluster is still billing.",
                )
                continue

            self.fired = True
            self._on_fire()
            return


def idle_destroy(policy: IdlePolicy, state: dict) -> int:
    """The idle half of the destroy path. Runs on the MAIN thread so ctrl-c works."""
    if os.environ.get("DRILL_ALLOW_DESTROY") == "0":
        print(
            "drill-watch: the idle limit passed, but DRILL_ALLOW_DESTROY=0 is set. "
            "Nothing was destroyed. Run `make down` yourself.",
            file=sys.stderr, flush=True,
        )
        return 0

    scenario = state.get("scenario")
    print("", flush=True)
    print("  " + "=" * 68, flush=True)
    print(f"  IDLE for {human_duration(policy.timeout)}. Nobody is home.", flush=True)
    print("", flush=True)
    print("  `make down` is about to run. It destroys THIS environment:", flush=True)
    print("    the EKS control plane, the nodes, the NAT gateway, the ALB,", flush=True)
    print("    the RDS instance and every volume the drill created.", flush=True)
    print("", flush=True)
    print(f"  Your progress is saved in {progress.progress_root().name}/ and survives this.", flush=True)
    if scenario:
        print(f"  I'll be back:   make scenario N={scenario}", flush=True)
    print("", flush=True)
    # Be honest about whether the abort gate actually exists on this run.
    #
    # `make scenario` starts the watcher DETACHED, with stdin on /dev/null and
    # output to drill-progress/watcher.log. On that path there is no terminal to
    # press ctrl-c in, so printing "ctrl-c to abort" would be describing a gate
    # that is not there - and a gate nobody can reach is worse than an absent one,
    # because it gets counted as a safeguard by whoever reads this next.
    interactive = sys.stdin is not None and sys.stdin.isatty()
    if interactive:
        print("  ctrl-c to abort.", flush=True)
    else:
        print("  No terminal is attached to this watcher, so ctrl-c is NOT", flush=True)
        print("  available. The countdown in the drill GUI was the warning, and", flush=True)
        print("  DRILL_ALLOW_DESTROY=0 is the way to disarm this entirely.", flush=True)
    print("  " + "=" * 68, flush=True)
    try:
        for remaining in range(policy.grace, 0, -1):
            print(f"  self-terminating in {human_duration(remaining)}... ", end="\r", flush=True)
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n  aborted. Nothing was destroyed. The cluster is still up and still billing.", flush=True)
        return 1

    print("\n  running `make down`", flush=True)
    return subprocess.run(["make", "down"], cwd=str(REPO)).returncode


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


def read_request(cfg: dict) -> dict:
    """Whatever the request currently says, or {}. The laptop is its only writer."""
    out = subprocess.run(
        ["kubectl", "-n", DRILL_NS, "get", "configmap", REQUEST_CM,
         "--ignore-not-found", "-o", "json"],
        capture_output=True, text=True,
    )
    if out.returncode != 0 or not out.stdout.strip():
        return {}
    try:
        data = (json.loads(out.stdout).get("data") or {}).get(REQUEST_KEY)
        parsed = json.loads(data) if data else {}
    except ValueError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def apply_request(payload: dict) -> None:
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


def write_request(cfg: dict, scenario: str, session_id: str, restored_from: str | None) -> None:
    """Tell the pod which scenario to converge to. The laptop owns this object."""
    # Merged onto whatever is already there, so writing a scenario does not drop
    # the idle policy and publishing the idle policy does not drop the scenario.
    # A read-modify-write is safe precisely because this object has one writer.
    payload = {
        **read_request(cfg),
        "scenario": scenario,
        "sessionId": session_id,
        "requestedAt": datetime.now(timezone.utc).isoformat(),
        **({"restoredFrom": restored_from} if restored_from else {}),
    }
    apply_request(payload)


def publish_idle_policy(cfg: dict, policy: IdlePolicy | None) -> None:
    """Tell the pod what the idle limit is, so the GUI can count down to the same second.

    The learner has to be able to SEE this coming, because the gate that the SHUT
    IT DOWN path gets from a typed confirmation is one this path cannot have. A
    countdown nobody can see is not a warning.

    Clearing it when the feature is off matters as much as setting it: a stale
    policy left in the ConfigMap would have the GUI counting down to a teardown
    that no watcher is going to perform.
    """
    current = read_request(cfg)
    if not current:
        return  # no session yet; the next write_request carries it
    fields = policy.as_request_fields() if policy else {
        "idleTimeoutSeconds": None, "idleAction": None, "idleWarnSeconds": None,
    }
    merged = {**current, **fields}
    merged = {k: v for k, v in merged.items() if v is not None}
    if merged != current:
        apply_request(merged)


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


def watch(cfg: dict, policy: IdlePolicy | None = None) -> int:
    """Follow the ConfigMap until a terminal phase, or forever."""
    proc = subprocess.Popen(
        ["kubectl", "-n", DRILL_NS, "get", "configmap", STATE_CM,
         "--watch", "--ignore-not-found", "-o", "json"],
        stdout=subprocess.PIPE, text=True, bufsize=1,
    )
    assert proc.stdout is not None

    monitor: IdleMonitor | None = None
    if policy is not None:
        # Terminating the kubectl pipe is how the thread wakes the main loop: it
        # is blocked reading stdout, and closing that is the one thing that
        # unblocks it from outside. The decision is the thread's; the countdown
        # and the destroy are the main thread's, so ctrl-c still reaches them.
        monitor = IdleMonitor(policy, on_fire=proc.terminate)
        monitor.start()
        print(
            f"drill-watch: idle limit {human_duration(policy.timeout)}, "
            f"action {policy.action}"
            + ("" if policy.armed else " (nothing will be destroyed)"),
            flush=True,
        )

    decoder = json.JSONDecoder()
    buf = ""
    last_state: dict = {}
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
                if not state:
                    continue
                last_state = state
                if monitor is not None:
                    monitor.observe(state)
                if handle(cfg, state) == "stop":
                    return 0
    except KeyboardInterrupt:
        print("\ndrill-watch: stopped. Your progress is saved.", flush=True)
        return 0
    finally:
        if monitor is not None:
            monitor.stop()
        proc.terminate()

    # The loop ended without a terminal phase. Either the idle clock fired and
    # terminated the pipe, or kubectl died - and those must not be confused: only
    # the first one is allowed to destroy anything.
    if monitor is not None and monitor.fired:
        sync(cfg, last_state)
        finish(last_state)
        return idle_destroy(policy, last_state)
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

    # Read before anything else, and fatal on a bad value. A destroy timer that
    # silently fell back to a default would be the worst kind of surprise: the
    # user believes they configured one thing and the machine believes another.
    try:
        policy = idle_policy_from_env()
    except IdleConfigError as e:
        print(f"drill-watch: {e}", file=sys.stderr)
        return 2

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
        # Published after the first sync, so the request object exists to merge onto.
        try:
            publish_idle_policy(cfg, policy)
        except (subprocess.CalledProcessError, OSError) as e:
            print(
                f"drill-watch: could not publish the idle policy to the drill ({e}) - "
                "the clock still runs here, but the GUI will not show the countdown",
                file=sys.stderr, flush=True,
            )
        return watch(cfg, policy)
    finally:
        release_pid_file()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
