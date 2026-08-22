#!/usr/bin/env python3
"""Seed the in-cluster git server from this local clone.

    make git-seed

Streams `git bundle create - --all` from the local repo straight into the pod over
`kubectl exec`, so nothing hits disk on the way and no port-forward has to be held
open. A bundle carries every ref and object in one file, which is why the same
primitive works in reverse for saving drill progress.

This exists instead of an init container that clones GitHub because that would need
a PAT inside the cluster and would fail outright for a private repo on first apply.
Seeding from the laptop needs no credentials and no egress.

**The transfer itself lives in `scripts/clustergit.py`**, along with where the git
server is and the measured corruption bug the streaming shape guards against.
Three callers move bundles in and out of that pod - this one, `drill-watch.py` and
`scenario.py` - and re-implementing the transfer per caller is how the truncating
version comes back. What stays here is what is genuinely this script's own: WHICH
paths the learner gets, and how the baseline commit is built.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from clustergit import (  # noqa: F401  - re-exported; tests/test_git_seed.py pins both
    BUNDLE_DEST,
    ClusterGitError,
    bundle_from_repo,
    pod_name,
    push_bundle,
    settings,
    stream_command,
    tf_outputs,
    unbundle_script,
)

REPO = Path(__file__).resolve().parent.parent

# ---------------------------------------------------------------------------
# WHAT THE LEARNER'S REPOSITORY CONTAINS, AND WHY IT IS NOT ALL OF THIS ONE.
#
# Cluster git is cloned into the drill workspace, so whatever is seeded here is
# what the learner sees in the explorer AND in `ls` - the terminal is a real shell
# in that working tree. Seeding `--all`, which is what this did originally, handed
# them the whole project: scenarios/answers/*.toml is the ANSWER KEY, docs/ holds
# the plan that explains every task, drill/ is the grader's own source, and
# work-orders/ is the build log. The server goes to great lengths to keep accept
# rules out of the browser; there is no point in that if `cat` reaches them.
#
# The reason is SIMULATION FIDELITY, not secrecy, and the difference matters when
# somebody later argues about how strict to be. This is not a security boundary and
# must not be sold as one: the repository is public and PRACTICE_ANSWERS.html is
# committed to it, so anyone who wants the answers can go and read them, and that is
# fine. What the filter buys is that the environment looks like an environment. A
# real engineer's working tree holds the application they are deploying - not the
# curriculum that set them the task, not the grader marking it, not the tickets that
# built the trainer. Seeding all of that makes it obvious you are inside somebody's
# project repo, and the whole point of this thing is that it is a place that
# genuinely works for practising Kubernetes.
#
# Add a path here when a scenario genuinely needs it in the workspace. Scenario 12
# is about terraform, so porting it will mean adding terraform/ - and that is the
# moment to decide, not now.
DRILL_PATHS = ["helm"]


def drill_tree(paths: list[str], into: Path) -> Path:
    """A throwaway repo holding only `paths`, taken from HEAD, with one commit.

    Built from `git archive HEAD -- <paths>` rather than from the working tree, so
    an uncommitted local experiment cannot leak into the learner's environment and
    the seed is reproducible from a commit.

    The prefixes are preserved: helm/practice-app stays at helm/practice-app, which
    is what Argo CD's `path:` points at. A `git subtree split` would have moved it
    to the root and broken the Application.

    History is deliberately NOT preserved. The learner gets one baseline commit,
    which is all scenario 03 needs - `git revert <commit>` there is reverting the
    commit THEY just made, not one of ours - and it means the project's own history
    is not part of the drill environment either.
    """
    into.mkdir(parents=True, exist_ok=True)
    missing = [p for p in paths if not (REPO / p).exists()]
    if missing:
        sys.exit(f"git-seed: DRILL_PATHS names paths that are not in this repo: {missing}")

    archive = subprocess.run(
        ["git", "-C", str(REPO), "archive", "HEAD", "--", *paths],
        stdout=subprocess.PIPE,
    )
    if archive.returncode != 0:
        sys.exit("git-seed: could not archive the drill paths out of HEAD")
    extract = subprocess.run(["tar", "-x", "-C", str(into)], input=archive.stdout)
    if extract.returncode != 0:
        sys.exit("git-seed: could not unpack the drill paths")

    def git(*args: str) -> None:
        if subprocess.run(["git", "-C", str(into), *args]).returncode != 0:
            sys.exit(f"git-seed: git {args[0]} failed while building the drill repo")

    git("init", "-q", "-b", "main")
    # A committer identity that is the environment's, not the operator's. The
    # learner's own commits get whatever identity the pod sets for them.
    git("config", "user.email", "drill@cluster.local")
    git("config", "user.name", "drill")
    git("add", "-A")
    git("commit", "-qm", "drill baseline")
    return into


def main() -> int:
    try:
        cfg = settings()
    except ClusterGitError as e:
        sys.exit(f"git-seed: {e}")

    if not cfg["ns"] or not cfg["deploy"]:
        sys.exit(
            "git-seed: cluster git is disabled "
            "(enable_cluster_git = false in scripts/config.toml)"
        )

    print(
        f"git-seed: waiting for {cfg['deploy']} in namespace {cfg['ns']} to have a running pod...",
        flush=True,
    )
    try:
        pod = pod_name(cfg)
    except (ClusterGitError, subprocess.CalledProcessError) as e:
        sys.exit(f"git-seed: {e}")

    staging = Path(tempfile.mkdtemp(prefix="drill-seed-"))
    try:
        source = drill_tree(DRILL_PATHS, staging / "repo")
        print(
            f"git-seed: streaming a bundle of {', '.join(DRILL_PATHS)} into {pod}",
            flush=True,
        )
        try:
            sent = push_bundle(cfg, pod, bundle_from_repo(source))
        except ClusterGitError as e:
            sys.exit(f"git-seed: {e}")
        print(f"git-seed: {sent} bytes arrived intact", flush=True)
    finally:
        shutil.rmtree(staging, ignore_errors=True)

    print("git-seed: waiting for the readiness probe to pass...", flush=True)
    subprocess.run(
        ["kubectl", "-n", cfg["ns"], "rollout", "status",
         f"deploy/{cfg['deploy']}", "--timeout=120s"],
        check=True,
    )
    url = cfg.get("url") or "cluster git"
    print(f"git-seed: cluster git is serving. Argo CD can now read {url}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
