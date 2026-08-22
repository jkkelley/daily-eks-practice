#!/usr/bin/env python3
"""`make scenario N=NN` - converge a drill session, or print a card.

    make scenario N=03        # a ported scenario: converge a session, print the URL
    make scenario N=07        # not ported yet: print the card, as it always did
    make scenario-clean N=03  # end the session, stop the watcher, tidy the cluster

---- CONVERGE, NOT CREATE -------------------------------------------------

Running this twice shows you the same thing rather than making a second session.
It starts a session if none is open, restores from the newest bundle if one
exists, restarts the watcher if it died, and prints the URL. That is `AC-H2`, and
it is why the second run is not an error: the target describes a state you want,
and asking for a state you are already in is not a mistake.

---- IT STILL PRINTS A CARD FOR THE ELEVEN UNPORTED SCENARIOS -------------

`make scenario N=07` printing a card is the only way to read one outside the GUI,
and converting this target wholesale would have been a silent regression for
eleven twelfths of the curriculum. So it branches on whether the scenario has an
answers TOML - which is the same test everything else uses for "ported".

A third case is worth as much as the other two: a ported scenario with no cluster
up has nothing to converge against and no URL to print, so it refuses - but it
names how to read the card on its way out, because a refusal that leaves you with
nothing is a worse target than the one being replaced.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import clustergit  # noqa: E402
import progress  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SCENARIOS = REPO / "scenarios"
ANSWERS = SCENARIOS / "answers"
DRILL_NS = os.environ.get("DRILL_NAMESPACE", "practice-drill")
HANDOVER_FLAG = ".gui-owns-the-wheel"

TITLE_RE = re.compile(r"^#\s*\d{2}\s*-\s*(.+?)\s*$", re.MULTILINE)


# ---------------------------------------------------------------------------
# What the curriculum has
# ---------------------------------------------------------------------------


def card_path(scenario: str) -> Path | None:
    hits = sorted(SCENARIOS.glob(f"{scenario}-*.md"))
    return hits[0] if hits else None


def title(scenario: str) -> str:
    """The card's own H1, so a scenario is named in exactly one place."""
    card = card_path(scenario)
    if not card:
        return scenario
    m = TITLE_RE.search(card.read_text(encoding="utf-8"))
    return m.group(1) if m else scenario


def is_ported(scenario: str) -> bool:
    """Ported means there is something to grade it with. Same test the server applies."""
    return (ANSWERS / f"{scenario}.toml").is_file()


# ---------------------------------------------------------------------------
# Session bookkeeping - the part that is pure, and therefore the part that is tested
# ---------------------------------------------------------------------------


def conflict(scenario: str) -> dict | None:
    """The live session, if it is a DIFFERENT scenario. Same scenario is not a conflict.

    Conflating the two is how `AC-H2` and `AC-H3` end up contradicting each
    other: converging the scenario you are already in has to be a no-op, and
    starting a different one has to be refused. They are different questions.
    """
    live = progress.live_scenario()
    if live and live.get("scenario") and live["scenario"] != scenario:
        return live
    return None


def refusal(live: dict) -> str:
    """A refusal the learner can act on.

    Names the scenario AND its title AND the way out. "Another scenario is
    running" is a refusal you cannot do anything with.
    """
    other = live["scenario"]
    return (
        f"scenario {other} - {title(other)} is already open.\n"
        f"  Scenarios mutate the same app, so two at once makes cluster state unattributable.\n"
        f"  Switch from inside the drill GUI's pause menu (that is what it is for), or\n"
        f"  finish here first:  make scenario-clean N={other}"
    )


def open_session(scenario: str) -> tuple[str, bool]:
    """Return (session_id, is_new). Idempotent - this is the heart of `AC-H2`."""
    sid = progress.current_session(scenario)
    if sid and progress.session_dir(scenario, sid).is_dir():
        return sid, False
    return progress.new_session(scenario).name, True


# ---------------------------------------------------------------------------
# The cluster
# ---------------------------------------------------------------------------


def cluster_reachable() -> bool:
    """`kubectl version --request-timeout` DOES exit 1 against a dead endpoint.

    Verified against a throwaway kubeconfig pointing at a closed port, after it
    was wrongly suspected of the exits-zero problem. Checked before believing it,
    which is the point.
    """
    return (
        subprocess.run(
            ["kubectl", "version", "--request-timeout=10s"],
            capture_output=True,
        ).returncode
        == 0
    )


def capture_baseline(cfg: dict) -> None:
    """Cluster git as `make git-seed` left it, captured once.

    A fresh start of any scenario restores from this. Without it the SECOND
    scenario a learner opens inherits the first one's finished working tree and
    begins already solved - which is the kind of bug that looks like the drill
    working perfectly.
    """
    dest = progress.baseline_bundle()
    if dest.is_file():
        return
    try:
        pod = clustergit.pod_name(cfg, timeout="60s")
        if clustergit.pull_bundle(cfg, pod, dest):
            print(f"scenario: captured {dest.name} - the clean starting state", flush=True)
    except (clustergit.ClusterGitError, subprocess.CalledProcessError) as e:
        print(f"scenario: could not capture a baseline bundle - {e}", file=sys.stderr, flush=True)


def restore_into_cluster_git(cfg: dict, scenario: str, *, fresh: bool) -> str | None:
    """Push this scenario's newest save file back, or the baseline if there is none.

    `fresh` is not a micro-optimisation, it is the difference between resuming and
    starting over. A NEW session of a scenario you have drilled before must begin
    at the baseline - if it restored the newest bundle it would hand you your last
    attempt's finished tree and the drill would open already solved, which looks
    exactly like it working.
    """
    source = None if fresh else progress.latest_bundle(scenario)
    if source is None:
        base = progress.baseline_bundle()
        source = base if base.is_file() else None
    if source is None:
        return None
    pod = clustergit.pod_name(cfg, timeout="60s")
    clustergit.push_bundle(cfg, pod, clustergit.bundle_from_file(source))
    print(f"scenario: restored cluster git from {source.name}", flush=True)
    return str(source)


def write_request(scenario: str, session_id: str, restored_from: str | None) -> None:
    payload = {
        "scenario": scenario,
        "sessionId": session_id,
        **({"restoredFrom": restored_from} if restored_from else {}),
    }
    manifest = subprocess.run(
        ["kubectl", "-n", DRILL_NS, "create", "configmap", "drill-request",
         f"--from-literal=request.json={json.dumps(payload)}",
         "--dry-run=client", "-o", "json"],
        check=True, capture_output=True, text=True,
    ).stdout
    subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, text=True, check=True)


def start_watcher() -> None:
    live = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "drill-watch.py"), "--status"],
        capture_output=True, text=True,
    )
    if live.returncode == 0:
        print("scenario: the progress watcher is already running", flush=True)
        return
    # Detached, so `make scenario` returns and the watcher outlives it. Its
    # output goes to a log rather than to the terminal, because the terminal is
    # about to print the GUI URL and that is what should be on screen.
    log = progress.progress_root() / "watcher.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("ab") as fh:
        subprocess.Popen(
            [sys.executable, str(REPO / "scripts" / "drill-watch.py")],
            stdout=fh, stderr=fh, stdin=subprocess.DEVNULL, cwd=str(REPO),
            start_new_session=(os.name != "nt"),
        )
    print(f"scenario: progress watcher started (logging to {log.relative_to(REPO)})", flush=True)


def gui_url() -> str:
    out = subprocess.run(
        ["kubectl", "-n", DRILL_NS, "get", "ingress", "drill-gui",
         "-o", "jsonpath={.status.loadBalancer.ingress[0].hostname}"],
        capture_output=True, text=True,
    )
    host = out.stdout.strip()
    if host:
        return f"http://{host}"
    return (
        "no Ingress address yet (normal on kind, and for a few minutes on a fresh ALB).\n"
        f"    meanwhile:  kubectl -n {DRILL_NS} port-forward svc/drill-gui 8090:8090\n"
        "    then:       http://localhost:8090"
    )


# ---------------------------------------------------------------------------
# The two entry points
# ---------------------------------------------------------------------------


def print_card(scenario: str) -> int:
    card = card_path(scenario)
    if card is None:
        print(f"scenario: no scenario {scenario} (see scenarios/)", file=sys.stderr)
        return 1
    subprocess.run([sys.executable, str(REPO / "scripts" / "scenario-prereqs.py"), scenario])
    sys.stdout.write(card.read_text(encoding="utf-8"))
    print(
        f"\n---\nScenario {scenario} is not ported to the drill format yet, so this is the card "
        "rather than a graded session.\n",
        flush=True,
    )
    return 0


def converge(scenario: str) -> int:
    live = conflict(scenario)
    if live:
        print(f"scenario: {refusal(live)}", file=sys.stderr)
        return 1

    if not cluster_reachable():
        card = card_path(scenario)
        print(
            "scenario: no cluster is reachable, so there is nothing to converge.\n"
            "  Bring one up:  make up\n"
            + (f"  Read the card meanwhile:  cat {card.relative_to(REPO)}\n" if card else ""),
            file=sys.stderr,
        )
        return 1

    try:
        cfg = clustergit.settings()
    except clustergit.ClusterGitError as e:
        print(f"scenario: {e}", file=sys.stderr)
        return 1

    capture_baseline(cfg)
    session_id, is_new = open_session(scenario)

    try:
        restored = restore_into_cluster_git(cfg, scenario, fresh=is_new)
        write_request(scenario, session_id, restored)
    except (clustergit.ClusterGitError, subprocess.CalledProcessError) as e:
        print(f"scenario: could not converge - {e}", file=sys.stderr)
        return 1

    progress.set_live_scenario(scenario, session_id)
    progress.write_atomic(
        progress.progress_root() / HANDOVER_FLAG,
        {"scenario": scenario, "sessionId": session_id},
    )
    start_watcher()

    print("", flush=True)
    print(f"  scenario {scenario} - {title(scenario)}", flush=True)
    print(f"  session  {session_id}{'  (new)' if is_new else '  (resumed)'}", flush=True)
    print(f"  drill    {gui_url()}", flush=True)
    print("", flush=True)
    print("  Everything happens in the browser from here. Your laptop terminal is not", flush=True)
    print("  in the loop - the Makefile is locked while the GUI holds the wheel.", flush=True)
    print("  Cost reminder: the control plane bills ~$0.10/hr. `make down` when done.", flush=True)
    print("", flush=True)
    return 0


def clean(scenario: str) -> int:
    """End the session and tidy up. Never destroys the cluster, never touches save files."""
    subprocess.run([sys.executable, str(REPO / "scripts" / "drill-watch.py"), "--stop"])

    sid = progress.current_session(scenario)
    if sid:
        progress.close_session(scenario, sid)
        print(f"scenario-clean: closed session {sid} of scenario {scenario}", flush=True)
    else:
        print(f"scenario-clean: no open session for scenario {scenario}", flush=True)

    live = progress.live_scenario()
    if live and live.get("scenario") == scenario:
        progress.clear_live_scenario()
    (progress.progress_root() / HANDOVER_FLAG).unlink(missing_ok=True)

    if cluster_reachable():
        # What the DRILL created, not what the cluster is. The Application and the
        # app's namespace go; cluster git, Argo itself and the drill pod stay,
        # because the point of this target is that it is not `make down`.
        for argv in (
            ["kubectl", "-n", "argocd", "delete", "application", "practice-app", "--ignore-not-found"],
            ["kubectl", "delete", "namespace", "practice-app", "--ignore-not-found"],
            ["kubectl", "-n", DRILL_NS, "delete", "configmap", "drill-request", "--ignore-not-found"],
        ):
            subprocess.run(argv, capture_output=True)
        print("scenario-clean: removed the Argo Application and the practice-app namespace", flush=True)

    print("scenario-clean: your save files in drill-progress/ are untouched", flush=True)
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: scenario.py <NN> [--clean]", file=sys.stderr)
        return 1
    scenario = argv[0]
    if "--clean" in argv:
        return clean(scenario)
    if card_path(scenario) is None:
        print(f"scenario: no scenario {scenario} (see scenarios/)", file=sys.stderr)
        return 1
    return converge(scenario) if is_ported(scenario) else print_card(scenario)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
