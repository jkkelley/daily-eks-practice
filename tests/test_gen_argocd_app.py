#!/usr/bin/env python3
"""Tests for scripts/gen-argocd-app.py - the Application's sync policy.

Two callers share one generated Application and they want opposite things.

The drill loop needs `syncPolicy.automated`: the learner edits an image tag in the
browser, commits and pushes to cluster git, and watches Argo roll it. A manual sync
button breaks that loop, because nothing in the drill UI presses it.

Scenario 09 needs manual sync: its task 5 is literally "turn on automated sync +
self-heal", and `scenario_testing/check.sh` passes N=09 only when
`.spec.syncPolicy.automated.selfHeal` is true. Emitting that by default pre-solves
the exercise and makes its own check meaningless.

The seam that separates them already exists: cluster git is the drill path, the
GitHub fallback is the pre-drill path scenario 09 runs on. So the policy follows the
source. `selfHeal` stays off even on the drill path - it is per-scenario and default
off, because it would stomp any scenario whose exercise is an imperative change.

Run: python3 tests/test_gen_argocd_app.py
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

spec = importlib.util.spec_from_file_location("gen_argocd_app", ROOT / "scripts" / "gen-argocd-app.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

CLUSTER_GIT = "git://git-server.git.svc.cluster.local/repo.git"
GITHUB = "https://github.com/example/daily-eks-practice.git"

PASS = 0
FAIL = 0


def check(label, condition):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ok   {label}")
    else:
        FAIL += 1
        print(f"  FAIL {label}")


def main():
    print("scripts/gen-argocd-app.py - sync policy follows the source")

    drill = gen.render(CLUSTER_GIT, cluster_git=True)
    check("cluster git: repoURL is the cluster git URL", f"repoURL: {CLUSTER_GIT}" in drill)
    check("cluster git: automated sync is on", "automated:" in drill)
    check("cluster git: selfHeal is off by default", "selfHeal: false" in drill)
    check("cluster git: namespace is not created by Argo", "CreateNamespace=false" in drill)

    fallback = gen.render(GITHUB, cluster_git=False)
    check("github fallback: repoURL is the GitHub URL", f"repoURL: {GITHUB}" in fallback)
    check(
        "github fallback: sync stays manual so scenario 09 task 5 is unsolved",
        "automated" not in fallback,
    )
    check("github fallback: namespace is not created by Argo", "CreateNamespace=false" in fallback)

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
