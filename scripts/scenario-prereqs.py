#!/usr/bin/env python3
"""Print a scenario's prereqs and check the ones we can verify live, before the card.

Called by `make scenario N=NN`. Non-blocking on purpose: it warns loudly but still
lets the card print, so you can read a drill even with no cluster up. kubectl inherits
the repo-local KUBECONFIG that the Makefile exports.
"""
import glob
import subprocess
import sys

OK = "[ ok ]"
MISS = "[MISS]"
SKIP = "[ -- ]"


def find_card(n: str) -> str | None:
    hits = sorted(glob.glob(f"scenarios/{n}-*.md"))
    return hits[0] if hits else None


def needs_line(card: str) -> str:
    with open(card, encoding="utf-8") as f:
        for line in f:
            if "**Needs:**" in line:
                # strip the leading "**Time:** ... **Needs:**" markdown down to the needs text
                after = line.split("**Needs:**", 1)[1]
                return after.replace("`", "").strip().rstrip(".")
    return ""


def kubectl(*args: str) -> tuple[int, str]:
    try:
        p = subprocess.run(
            ["kubectl", *args],
            capture_output=True,
            text=True,
            timeout=15,
        )
        return p.returncode, (p.stdout + p.stderr).strip()
    except FileNotFoundError:
        return 127, "kubectl not found on PATH"
    except subprocess.TimeoutExpired:
        return 124, "kubectl timed out (cluster unreachable?)"


def main(argv: list[str]) -> int:
    if not argv:
        return 0
    n = argv[0]
    card = find_card(n)
    if not card:
        return 0
    needs = needs_line(card)

    print("+-- prereqs for scenario " + n + " " + "-" * max(0, 46 - len(n)))
    if needs:
        print("| Needs: " + needs)
    print("|")

    # Live check 1: is the cluster reachable at all? (every hands-on card needs this)
    rc, out = kubectl("get", "--raw=/readyz")
    if rc == 0:
        print(f"| {OK} cluster reachable")
        cluster_up = True
    else:
        cluster_up = False
        if rc == 127:
            print(f"| {SKIP} kubectl not found - can't check cluster (install kubectl)")
        else:
            print(f"| {MISS} cluster NOT reachable")
            print("|        fix: make up   (then: make kubeconfig)")

    # Live check 2: is the app deployed? only relevant when the card says so.
    if "app deployed" in needs.lower():
        if not cluster_up:
            print(f"| {SKIP} app deployed - can't check until the cluster is reachable")
        else:
            rc, out = kubectl(
                "-n", "practice-app", "get", "deploy",
                "-o", "jsonpath={range .items[*]}{.status.readyReplicas}{'/'}{.spec.replicas}{' '}{end}",
            )
            ready = out if (rc == 0 and out.strip()) else ""
            if ready and "0/" not in ready and "/" in ready:
                print(f"| {OK} app deployed (practice-app deploys: {ready.strip()})")
            else:
                print(f"| {MISS} app NOT deployed (practice-app has no ready pods)")
                print("|        fix: make app-deploy   then: make argo-sync")

    print("+" + "-" * 62)
    print("")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
