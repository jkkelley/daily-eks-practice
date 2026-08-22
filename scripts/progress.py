#!/usr/bin/env python3
"""The learner's drill history, on their own laptop, as append-only save files.

    drill-progress/                      <- git-ignored, see .gitignore
      curriculum.json                    # running totals across all scenarios
      baseline.bundle                    # cluster git as `make git-seed` left it
      current.json                       # which scenario is live, if any
      .watcher.pid                       # scripts/drill-watch.py
      .gui-owns-the-wheel                # scripts/handover.py
      03/
        index.json                       # results rows + current-session pointer
        sessions/
          2026-08-19T14-03-11Z/
            state.json                   # the mirrored SessionState
            workspace.bundle             # cluster git, clonable back out

Three rules shape every function here.

**Append-only.** A session directory is never reused, never overwritten and never
deleted. `close_session` clears a pointer; it does not remove anything. The
directory is a save file, and a save file that a later run can quietly replace is
not one.

**A state snapshot, never a diary.** This records where the drill GOT TO, not what
the learner typed on the way. Resume works by converging to a declared state, so
it either works completely or it does not work at all - there is no partial replay
to get subtly wrong.

**Windows 11 is a supported target.** No colons in any path component, and the
current-session pointer is JSON rather than a symlink. Both would work on Linux
and fail on the other half of this project's audience.
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# `%H-%M-%S`, not `%H:%M:%S`. A colon is legal in a Linux filename and is one of
# the nine characters Windows rejects outright, so an ISO-8601 timestamp used as
# a directory name is a cross-platform bug wearing a standard's name.
STAMP = "%Y-%m-%dT%H-%M-%SZ"


def progress_root() -> Path:
    """Where the save files live.

    `DRILL_PROGRESS_DIR` overrides it, which is what the tests and the kind
    harness use. Deliberately does NOT create the directory: a module that
    mkdir'd at import time would make drill-progress/ appear during
    `make -f Makefile.test test`, in a checkout where nobody is drilling.
    """
    override = os.environ.get("DRILL_PROGRESS_DIR")
    return Path(override) if override else REPO / "drill-progress"


# ---------------------------------------------------------------------------
# Atomic writes
# ---------------------------------------------------------------------------


def write_atomic(path: Path, data: object) -> None:
    """Write `data` to `path` so that a crash leaves the OLD file, never half of
    the new one.

    Two details are load-bearing and both look like style until they are not:

    1. The temp file is a SIBLING of the target. `os.replace` is atomic only
       within a filesystem, and on Linux the system temp dir is frequently a
       different mount - which silently turns the rename back into a copy that
       can be interrupted, defeating the whole function.
    2. `json.dump` streams into the temp handle rather than `json.dumps` building
       a string first. That is what makes an encoding failure partway through a
       real, tested case rather than a theoretical one.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        with tmp.open("w", encoding="utf-8", newline="\n") as fh:
            if isinstance(data, (bytes, bytearray)):
                raise TypeError("write_atomic takes text or JSON, not bytes - use write_bytes_atomic")
            if isinstance(data, str):
                fh.write(data)
            else:
                json.dump(data, fh, indent=2, sort_keys=True)
                fh.write("\n")
        os.replace(tmp, path)
    except BaseException:
        # The target is untouched at this point either way. Removing the temp
        # matters because the next reader globs this directory, and a stale
        # `state.json.tmp` next to `state.json` is exactly the kind of thing
        # somebody later "restores" from.
        tmp.unlink(missing_ok=True)
        raise


def write_bytes_atomic(path: Path, data: bytes) -> None:
    """Same contract, for the bundle. Kept separate so the text path can assume text."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    try:
        tmp.write_bytes(data)
        os.replace(tmp, path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def read_json(path: Path, default=None):
    """A missing or unparsable file is `default`, not an exception.

    Unparsable is folded in with missing on purpose: the alternative is that one
    corrupt index.json makes `make scenario` unusable for every scenario, and the
    thing it would be protecting is a results table.
    """
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------


def session_stamp(started_at: datetime | None = None) -> str:
    if started_at is None:
        started_at = datetime.now(timezone.utc)
    if started_at.tzinfo is not None:
        started_at = started_at.astimezone(timezone.utc)
    return started_at.strftime(STAMP)


def scenario_dir(scenario: str) -> Path:
    return progress_root() / scenario


def sessions_dir(scenario: str) -> Path:
    return scenario_dir(scenario) / "sessions"


def session_dir(scenario: str, session_id: str) -> Path:
    return sessions_dir(scenario) / session_id


def index_path(scenario: str) -> Path:
    return scenario_dir(scenario) / "index.json"


def _index(scenario: str) -> dict:
    return read_json(index_path(scenario), None) or {
        "scenario": scenario,
        "current": None,
        "results": [],
    }


def sessions(scenario: str) -> list[str]:
    """Every session id for a scenario, oldest first.

    Sorted lexically, which for this stamp format is chronological - that is the
    reason the format is what it is. The `-2` disambiguation suffix sorts after
    the bare stamp, which is also correct.
    """
    d = sessions_dir(scenario)
    if not d.is_dir():
        return []
    return sorted(p.name for p in d.iterdir() if p.is_dir())


def new_session(scenario: str, started_at: datetime | None = None) -> Path:
    """Create and return a fresh session directory, and make it the current one.

    The disambiguation loop is not defensive programming. Restart a drill twice
    inside one second - which the pause menu's RESTART makes a single keystroke -
    and both sessions want the same stamp. Without the suffix the second one
    silently adopts the first one's directory and the first run's save file is
    overwritten by the second run's, which is the one outcome an append-only
    store must never produce.
    """
    base = session_stamp(started_at)
    sid, n = base, 1
    while session_dir(scenario, sid).exists():
        n += 1
        sid = f"{base}-{n}"

    d = session_dir(scenario, sid)
    d.mkdir(parents=True)

    idx = _index(scenario)
    idx["current"] = sid
    idx["results"] = [r for r in idx.get("results", []) if r.get("session") != sid] + [
        {
            "session": sid,
            "startedAt": (started_at or datetime.now(timezone.utc)).isoformat(),
            "passed": 0,
            "total": 0,
            "endedAt": None,
        }
    ]
    write_atomic(index_path(scenario), idx)
    return d


def ensure_session(scenario: str, session_id: str) -> Path:
    """Adopt a session id that was minted somewhere else, and make it current.

    The pause menu's RESTART and SWITCH mint an id inside the pod, so the first
    this side hears of a session is a mirrored state naming one. Without this
    those sessions have nowhere on disk to live and are simply never saved - and
    it is why the id format is pinned identically on both sides of the contract
    rather than merely being similar.

    Idempotent: an id that already exists is left exactly as it is.
    """
    d = session_dir(scenario, session_id)
    if d.is_dir():
        return d
    d.mkdir(parents=True, exist_ok=True)
    idx = _index(scenario)
    if not any(r.get("session") == session_id for r in idx.get("results", [])):
        idx.setdefault("results", []).append(
            {
                "session": session_id,
                "startedAt": datetime.now(timezone.utc).isoformat(),
                "passed": 0,
                "total": 0,
                "endedAt": None,
            }
        )
    idx["current"] = session_id
    write_atomic(index_path(scenario), idx)
    return d


def current_session(scenario: str) -> str | None:
    return _index(scenario).get("current")


def results(scenario: str) -> list[dict]:
    return _index(scenario).get("results", [])


def record_result(scenario: str, session_id: str, passed: int, total: int) -> None:
    """Update this session's row, or add it if it is not there yet.

    Update rather than append, because every submit calls this: an appending
    implementation produces one row per keystroke and an index nobody can read.
    No other row is ever touched, which is the invariant the test pins.
    """
    idx = _index(scenario)
    rows = idx.get("results", [])
    for row in rows:
        if row.get("session") == session_id:
            row["passed"] = passed
            row["total"] = total
            break
    else:
        rows.append(
            {
                "session": session_id,
                "startedAt": None,
                "passed": passed,
                "total": total,
                "endedAt": None,
            }
        )
    idx["results"] = rows
    write_atomic(index_path(scenario), idx)
    _refresh_curriculum()


def close_session(scenario: str, session_id: str, ended_at: datetime | None = None) -> None:
    """Clear the current-session pointer and stamp the row.

    It does NOT delete the directory. `close` here means "this run is over", not
    "this run can be discarded" - the save file is the entire point of the phase.
    """
    idx = _index(scenario)
    if idx.get("current") == session_id:
        idx["current"] = None
    for row in idx.get("results", []):
        if row.get("session") == session_id and not row.get("endedAt"):
            row["endedAt"] = (ended_at or datetime.now(timezone.utc)).isoformat()
    write_atomic(index_path(scenario), idx)
    _refresh_curriculum()


def latest_bundle(scenario: str, session_id: str | None = None) -> Path | None:
    """The newest workspace bundle for a scenario, or None if there is none.

    Newest that ACTUALLY EXISTS, walking backwards - a session directory with no
    bundle is normal (it was created seconds ago, or the watcher was not
    running), and treating the newest session as authoritative regardless would
    resume from a file that is not there.
    """
    candidates = [session_id] if session_id else list(reversed(sessions(scenario)))
    for sid in candidates:
        b = session_dir(scenario, sid) / "workspace.bundle"
        if b.is_file() and b.stat().st_size > 0:
            return b
    return None


def baseline_bundle() -> Path:
    """Cluster git as `make git-seed` left it.

    A fresh start of ANY scenario restores from this. Without it the second
    scenario a learner opens inherits the first one's finished working tree as
    its starting state, which is a drill that begins already solved.
    """
    return progress_root() / "baseline.bundle"


# ---------------------------------------------------------------------------
# Which scenario is live
# ---------------------------------------------------------------------------


def live_path() -> Path:
    return progress_root() / "current.json"


def live_scenario() -> dict | None:
    return read_json(live_path(), None)


def set_live_scenario(scenario: str, session_id: str) -> None:
    write_atomic(
        live_path(),
        {
            "scenario": scenario,
            "sessionId": session_id,
            "since": datetime.now(timezone.utc).isoformat(),
        },
    )


def clear_live_scenario() -> None:
    live_path().unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Running totals
# ---------------------------------------------------------------------------


def _refresh_curriculum() -> None:
    root = progress_root()
    if not root.is_dir():
        return
    out: dict = {}
    for d in sorted(root.iterdir()):
        if not d.is_dir() or not d.name.isdigit():
            continue
        rows = results(d.name)
        if not rows:
            continue
        out[d.name] = {
            "sessions": len(rows),
            "best": max((r.get("passed") or 0) for r in rows),
            "total": max((r.get("total") or 0) for r in rows),
        }
    write_atomic(
        root / "curriculum.json",
        {"updated": datetime.now(timezone.utc).isoformat(), "scenarios": out},
    )


def curriculum() -> dict:
    return read_json(progress_root() / "curriculum.json", {"scenarios": {}})
