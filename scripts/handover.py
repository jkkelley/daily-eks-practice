#!/usr/bin/env python3
"""One steering wheel at a time: the Makefile stands down while the GUI drives.

    python3 scripts/handover.py --check app-deploy   # exit 0 to proceed, 1 to refuse
    python3 scripts/handover.py --status
    FORCE=1 make app-deploy                          # override, always

---- THE MAKEFILE IS DEMOTED, NEVER ARCHIVED ------------------------------

If the GUI is the only way to drive the cluster and the GUI breaks, there is no
way in. Every target here still works; the locked ones just refuse while the
drill holds the wheel, and `FORCE=1` lifts any of them. Removing that escape
hatch would mean the only recovery from a wedged GUI is destroying a cluster you
are mid-drill on, which is not a recovery.

---- A REFUSAL NAMES THE CONSEQUENCE, NOT THE RULE ------------------------

"the GUI owns this now" tells you nothing you can act on. "this would re-apply
the Argo Application and fight the drill's own sync" tells you what would go
wrong and therefore whether you actually want to. That costs one line per target
and it belongs in a project whose entire job is teaching why things break.

---- WHAT IS NEVER LOCKED, AND WHY IT NEVER CAN BE -----------------------

You cannot create a cluster from a pod that does not exist yet, and you cannot
destroy the floor you are standing on from a GUI that is standing on it. `up`,
`plan`, `apply`, `down`, `kubeconfig` and `config` are the bootstrap and teardown
path, and `tests/test_handover.py` asserts the list is exactly this so a later
edit cannot quietly lock a learner out of stopping their own bill.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import progress  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
FLAG = ".gui-owns-the-wheel"

#: target -> what would actually go wrong, in the learner's terms.
LOCKED: dict[str, str] = {
    "app-deploy": "this re-applies the Argo Application, which would fight the drill's own sync and can roll the app back under you mid-task",
    "argo-sync": "the drill's Application syncs automatically every 10s - forcing one here races the sync the scenario is teaching you to watch",
    "argo-repo": "this registers a GITHUB repo with Argo CD, and the drill deliberately reads only in-cluster git; pointing Argo at github.com mid-drill breaks the loop",
    "app-status": "the drill GUI shows this live, next to the terminal that changed it - and reading it here means switching windows to see staler information",
    "argo-password": "Argo CD is proxied inside the drill, already signed in; you do not need this and printing it puts a credential in your shell history",
    "argo-ui": "the drill proxies Argo CD already - a second port-forward is a second view of the same thing, one of which will be stale",
    "grafana-ui": "same as argo-ui: the drill proxies Grafana, and two views of one dashboard is how you end up debugging the wrong one",
    "check": "the drill grades you continuously and knows what you have passed; running the outcome check here bypasses that and records nothing",
    "serve-answers": "you are mid-drill. The hints in the GUI are keyed to the mistake you actually made; the sealed key is not, and it is not going anywhere",
    "scenario": "one drill at a time - scenarios mutate the same app, so a second makes cluster state unattributable",
}

#: Bootstrap and teardown. See the header - this list is asserted, not merely written.
NEVER_LOCKED: frozenset[str] = frozenset(
    {"up", "plan", "apply", "down", "kubeconfig", "config"}
)


def flag_path() -> Path:
    return progress.progress_root() / FLAG


def held_by() -> dict | None:
    """The live drill, if one holds the wheel."""
    return progress.read_json(flag_path(), None)


def allowed(target: str, argument: str | None = None) -> tuple[bool, str]:
    """(may it run, why not). `argument` is `N=NN` for the scenario target."""
    if os.environ.get("FORCE"):
        return True, ""
    if target in NEVER_LOCKED:
        return True, ""

    live = held_by()
    if not live:
        return True, ""

    if target not in LOCKED:
        return True, ""

    # `scenario` is locked by ARGUMENT, not as a target.
    #
    # A flat lock makes AC-H2 unsatisfiable: the first `make scenario N=03` sets
    # this very flag, so the second run - which the criterion requires to succeed
    # and converge - would be refused by its own side effect. Converging the
    # scenario you are already in is the idempotent case, and it is not a
    # conflict. Starting a different one is.
    if target == "scenario":
        if argument is None or argument == live.get("scenario"):
            return True, ""
        return False, (
            f"scenario {live.get('scenario')} is open in the drill GUI.\n"
            f"  {LOCKED[target]}.\n"
            f"  Switch scenario from the GUI's pause menu - that is what it is for."
        )

    return False, (
        f"the drill GUI is driving (scenario {live.get('scenario')}).\n"
        f"  {LOCKED[target]}.\n"
        f"  Do it in the browser, or override:  FORCE=1 make {target}"
    )


def main(argv: list[str]) -> int:
    if not argv or argv[0] == "--status":
        live = held_by()
        if live:
            print(
                f"handover: the drill GUI holds the wheel "
                f"(scenario {live.get('scenario')}, session {live.get('sessionId')})"
            )
            return 0
        print("handover: the Makefile has the wheel - no drill is running")
        return 1

    if argv[0] != "--check" or len(argv) < 2:
        print("usage: handover.py --check <target> [N]", file=sys.stderr)
        return 2

    target = argv[1]
    argument = argv[2] if len(argv) > 2 else None
    ok, why = allowed(target, argument)
    if ok:
        return 0
    print(f"\nmake {target}: refused - {why}\n", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
