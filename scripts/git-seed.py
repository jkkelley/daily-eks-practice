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

Where the values come from: the namespace, deployment, container and repo path are
all terraform outputs, so this script and terraform/modules/platform/cluster-git.tf
cannot drift apart. The CLUSTER_GIT_* env vars override them, which is what the kind
acceptance test uses - there is no terraform state in that sandbox.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BUNDLE_DEST = "/tmp/seed.bundle"

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


def unbundle_script(repo_path: str) -> str:
    """The shell run inside the pod. Order matters: the marker is written LAST.

    If .seeded appeared before the fetch, the readiness probe would pass while the
    refs were still incomplete, and Argo would clone a half-served repo and sync a
    broken state that looks like it worked.

    There is deliberately no `git update-server-info` here. That publishes the flat
    files the DUMB http transport reads, and this server is `git daemon` speaking the
    smart protocol - see the rung-3 note at the top of cluster-git.tf. It would be
    dead code, not insurance.
    """
    return f"""
set -e
git -C {repo_path} fetch --force {BUNDLE_DEST} 'refs/heads/*:refs/heads/*'
git -C {repo_path} symbolic-ref HEAD refs/heads/main
rm -f {BUNDLE_DEST}
date -u +%Y-%m-%dT%H:%M:%SZ > {repo_path}/.seeded
echo "git-seed: refs published"
"""


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


def stream_command(ns: str, pod: str, container: str, dest: str) -> list[str]:
    """The kubectl argv that receives the bundle on stdin.

    `tee` is exec'd DIRECTLY, with no shell in between. This is not a style choice.
    Wrapping the receiver as `/bin/sh -c 'cat > file'` - the obvious way to write it,
    and what the plan originally specified - silently truncates the stream: measured
    443833 bytes sent and 98662 landed, with kubectl still exiting 0. The corruption
    only shows up later as "fatal: early EOF" from git. Do not reintroduce the shell.
    """
    return ["kubectl", "-n", ns, "exec", "-i", pod, "-c", container, "--", "tee", dest]


def tf_outputs() -> dict:
    """Every terraform output at once.

    One subprocess rather than one per value: each call re-runs bootstrap.py, which
    re-reads the config and rewrites the tfvars, so asking four times is four times
    the work for one answer.
    """
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "output", "-json"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        sys.exit(
            "git-seed: could not read the terraform outputs - is the cluster up?\n"
            f"{out.stderr}"
        )
    try:
        return {k: v.get("value") for k, v in json.loads(out.stdout).items()}
    except (ValueError, AttributeError):
        sys.exit("git-seed: terraform output -json did not return an object")


def settings() -> dict:
    """Where the git server is, from terraform unless the env overrides it."""
    env_keys = {
        "ns": "CLUSTER_GIT_NS",
        "deploy": "CLUSTER_GIT_DEPLOY",
        "container": "CLUSTER_GIT_CONTAINER",
        "repo_path": "CLUSTER_GIT_REPO_PATH",
    }
    found = {k: os.environ.get(v, "") for k, v in env_keys.items()}
    if all(found.values()):
        return found

    tf = tf_outputs()
    return {
        "ns": found["ns"] or tf.get("cluster_git_namespace") or "",
        "deploy": found["deploy"] or tf.get("cluster_git_deployment") or "",
        "container": found["container"] or tf.get("cluster_git_container") or "",
        "repo_path": found["repo_path"] or tf.get("cluster_git_repo_path") or "",
        "url": tf.get("cluster_git_url") or "",
    }


def main() -> int:
    cfg = settings()
    if not cfg["ns"] or not cfg["deploy"]:
        sys.exit(
            "git-seed: cluster git is disabled "
            "(enable_cluster_git = false in scripts/config.toml)"
        )

    print(f"git-seed: waiting for {cfg['deploy']} in namespace {cfg['ns']} to have a running pod...", flush=True)
    subprocess.run(
        ["kubectl", "-n", cfg["ns"], "wait", "--for=condition=Initialized", "pod",
         "-l", f"app={cfg['deploy']}", "--timeout=180s"],
        check=True,
    )
    pod = subprocess.check_output(
        ["kubectl", "-n", cfg["ns"], "get", "pod", "-l", f"app={cfg['deploy']}",
         "-o", "jsonpath={.items[0].metadata.name}"],
        text=True,
    ).strip()
    if not pod:
        sys.exit(f"git-seed: no pod matching app={cfg['deploy']} in namespace {cfg['ns']}")

    staging = Path(tempfile.mkdtemp(prefix="drill-seed-"))
    try:
        source = drill_tree(DRILL_PATHS, staging / "repo")
        print(
            f"git-seed: streaming a bundle of {', '.join(DRILL_PATHS)} into {pod}",
            flush=True,
        )
        return stream(cfg, pod, source)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def stream(cfg: dict, pod: str, source: Path) -> int:
    bundle = subprocess.Popen(
        ["git", "-C", str(source), "bundle", "create", "-", "--all"],
        stdout=subprocess.PIPE,
    )
    copy = subprocess.Popen(
        stream_command(cfg["ns"], pod, cfg["container"], BUNDLE_DEST),
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
    )
    # Pumped by hand rather than wired stdout-to-stdin so the bytes can be counted.
    # A truncated transfer is silent at this layer - it only fails three steps later
    # inside git - so the count is the only cheap way to catch it where it happened.
    sent = 0
    assert bundle.stdout is not None and copy.stdin is not None
    while chunk := bundle.stdout.read(64 * 1024):
        copy.stdin.write(chunk)
        sent += len(chunk)
    copy.stdin.close()
    bundle.stdout.close()
    if bundle.wait() != 0 or copy.wait() != 0:
        sys.exit("git-seed: streaming the bundle failed")

    landed = subprocess.run(
        ["kubectl", "-n", cfg["ns"], "exec", pod, "-c", cfg["container"], "--",
         "stat", "-c%s", BUNDLE_DEST],
        capture_output=True,
        text=True,
    ).stdout.strip()
    if landed != str(sent):
        sys.exit(
            f"git-seed: the bundle was truncated in transit - sent {sent} bytes, "
            f"{landed or 0} landed. Refusing to unbundle a partial repo."
        )
    print(f"git-seed: {sent} bytes arrived intact", flush=True)

    unbundle = subprocess.run(
        ["kubectl", "-n", cfg["ns"], "exec", pod, "-c", cfg["container"], "--",
         "/bin/sh", "-c", unbundle_script(cfg["repo_path"])],
    )
    if unbundle.returncode != 0:
        sys.exit("git-seed: unbundling inside the pod failed")

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
