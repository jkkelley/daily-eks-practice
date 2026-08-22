#!/usr/bin/env python3
"""Talking to the in-cluster git server: where it is, and moving bundles both ways.

This is not a script. It is the one implementation of a primitive that three
callers need:

    scripts/git-seed.py    pushes the repo IN, at bring-up
    scripts/drill-watch.py pulls the learner's work OUT, on every state change
    scripts/scenario.py    pushes a saved session back IN, on resume

`git bundle` is the single mechanism in both directions, which is why there is no
second thing to build or keep in step. What there IS is a measured, silent
data-corruption bug in the transfer, and THAT is the real reason this file
exists rather than three copies of the same twenty lines.

---- THE BUG, WRITTEN DOWN WHERE IT CANNOT BE LOST -------------------------

Receiving a bundle with `kubectl exec -i pod -- /bin/sh -c 'cat > file'` - the
obvious way to write it - silently truncates the stream. Measured: 443833 bytes
sent, 98662 landed, with kubectl still exiting 0. A plain-file redirect instead
of a pipe changed the number to 131072 and did not fix it. `dd of=` is also
unreliable. Exec'ing `tee` DIRECTLY, with no shell in between, was byte-identical
three runs running.

The corruption is invisible at this layer and surfaces three steps later as
`fatal: early EOF` from git, where it reads as a git bug. So every transfer here
counts its bytes and refuses to proceed on a mismatch, and every bundle is
verified before anything is allowed to depend on it.

Getting this wrong once cost a bring-up. Getting it wrong on the way OUT would
cost a learner their save file, and they would not find out until the resume.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Iterable, Iterator

REPO = Path(__file__).resolve().parent.parent

#: Where a bundle lands inside the git pod on its way in. Removed by the unbundle
#: script, so a failed run does not leave a stale one to be re-fetched later.
BUNDLE_DEST = "/tmp/seed.bundle"


class ClusterGitError(RuntimeError):
    """Something about the git server or the transfer is wrong.

    Raised rather than sys.exit'd because two of the three callers are long-lived
    - the watcher runs for the length of a drill - and a library that exits the
    process takes a session down with it.
    """


# ---------------------------------------------------------------------------
# Where the git server is
# ---------------------------------------------------------------------------


def tf_outputs() -> dict:
    """Every terraform output at once.

    One subprocess rather than one per value: each call re-runs bootstrap.py,
    which re-reads the config and rewrites the tfvars, so asking four times is
    four times the work for one answer.
    """
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "output", "-json"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise ClusterGitError(
            "could not read the terraform outputs - is the cluster up?\n" + out.stderr
        )
    try:
        return {k: v.get("value") for k, v in json.loads(out.stdout).items()}
    except (ValueError, AttributeError):
        raise ClusterGitError("terraform output -json did not return an object")


def settings() -> dict:
    """Where the git server is, from terraform unless the env overrides it.

    The CLUSTER_GIT_* overrides are what the kind harnesses use - there is no
    terraform state in that sandbox, and a $0 test that needs one is not a $0
    test. When all four are set, terraform is never invoked at all.
    """
    env_keys = {
        "ns": "CLUSTER_GIT_NS",
        "deploy": "CLUSTER_GIT_DEPLOY",
        "container": "CLUSTER_GIT_CONTAINER",
        "repo_path": "CLUSTER_GIT_REPO_PATH",
    }
    found = {k: os.environ.get(v, "") for k, v in env_keys.items()}
    if all(found.values()):
        return {**found, "url": os.environ.get("CLUSTER_GIT_URL", "")}

    tf = tf_outputs()
    return {
        "ns": found["ns"] or tf.get("cluster_git_namespace") or "",
        "deploy": found["deploy"] or tf.get("cluster_git_deployment") or "",
        "container": found["container"] or tf.get("cluster_git_container") or "",
        "repo_path": found["repo_path"] or tf.get("cluster_git_repo_path") or "",
        "url": os.environ.get("CLUSTER_GIT_URL") or tf.get("cluster_git_url") or "",
    }


def pod_name(cfg: dict, timeout: str = "180s") -> str:
    """The git server's pod, once it has at least initialised.

    Waits on `Initialized` rather than `Ready`, because the readiness probe
    requires the `.seeded` marker that seeding is about to write - waiting for
    Ready before the first seed waits forever, by design.
    """
    subprocess.run(
        ["kubectl", "-n", cfg["ns"], "wait", "--for=condition=Initialized", "pod",
         "-l", f"app={cfg['deploy']}", f"--timeout={timeout}"],
        check=True,
    )
    pod = subprocess.check_output(
        ["kubectl", "-n", cfg["ns"], "get", "pod", "-l", f"app={cfg['deploy']}",
         "-o", "jsonpath={.items[0].metadata.name}"],
        text=True,
    ).strip()
    if not pod:
        raise ClusterGitError(f"no pod matching app={cfg['deploy']} in namespace {cfg['ns']}")
    return pod


# ---------------------------------------------------------------------------
# In: pushing a bundle to cluster git
# ---------------------------------------------------------------------------


def stream_command(ns: str, pod: str, container: str, dest: str) -> list[str]:
    """The kubectl argv that receives the bundle on stdin.

    `tee` is exec'd DIRECTLY, with no shell in between. See the module header -
    this is a regression guard for a measured corruption bug, not a style
    preference. Do not reintroduce the shell.
    """
    return ["kubectl", "-n", ns, "exec", "-i", pod, "-c", container, "--", "tee", dest]


def unbundle_script(repo_path: str) -> str:
    """The shell run inside the pod. Order matters: the marker is written LAST.

    If .seeded appeared before the fetch, the readiness probe would pass while
    the refs were still incomplete, and Argo would clone a half-served repo and
    sync a broken state that looks like it worked.

    There is deliberately no `git update-server-info` here. That publishes the
    flat files the DUMB http transport reads, and this server is `git daemon`
    speaking the smart protocol - see the rung-3 note at the top of
    cluster-git.tf. It would be dead code, not insurance.
    """
    return f"""
set -e
git -C {repo_path} fetch --force {BUNDLE_DEST} 'refs/heads/*:refs/heads/*'
git -C {repo_path} symbolic-ref HEAD refs/heads/main
rm -f {BUNDLE_DEST}
date -u +%Y-%m-%dT%H:%M:%SZ > {repo_path}/.seeded
echo "cluster-git: refs published"
"""


def bundle_from_repo(source: Path) -> Iterator[bytes]:
    """Chunks of `git bundle create - --all` run against a local repo."""
    proc = subprocess.Popen(
        ["git", "-C", str(source), "bundle", "create", "-", "--all"],
        stdout=subprocess.PIPE,
    )
    assert proc.stdout is not None
    try:
        while chunk := proc.stdout.read(64 * 1024):
            yield chunk
    finally:
        proc.stdout.close()
        if proc.wait() != 0:
            raise ClusterGitError(f"git bundle create failed in {source}")


def bundle_from_file(path: Path) -> Iterator[bytes]:
    """Chunks of an existing bundle file - the resume path."""
    with Path(path).open("rb") as fh:
        while chunk := fh.read(64 * 1024):
            yield chunk


def push_bundle(cfg: dict, pod: str, chunks: Iterable[bytes], *, unbundle: bool = True) -> int:
    """Stream a bundle into the pod, prove it arrived whole, then fetch from it.

    Returns the byte count. The count is not decoration: a truncated transfer is
    silent at this layer, so comparing what we sent against what `stat` reports
    is the only cheap way to catch it where it happened rather than three steps
    later inside git.
    """
    copy = subprocess.Popen(
        stream_command(cfg["ns"], pod, cfg["container"], BUNDLE_DEST),
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
    )
    assert copy.stdin is not None
    sent = 0
    try:
        for chunk in chunks:
            copy.stdin.write(chunk)
            sent += len(chunk)
    finally:
        copy.stdin.close()
    if copy.wait() != 0:
        raise ClusterGitError("streaming the bundle into the pod failed")

    landed = subprocess.run(
        ["kubectl", "-n", cfg["ns"], "exec", pod, "-c", cfg["container"], "--",
         "stat", "-c%s", BUNDLE_DEST],
        capture_output=True,
        text=True,
    ).stdout.strip()
    if landed != str(sent):
        raise ClusterGitError(
            f"the bundle was truncated in transit - sent {sent} bytes, {landed or 0} landed. "
            "Refusing to unbundle a partial repo."
        )

    if unbundle:
        done = subprocess.run(
            ["kubectl", "-n", cfg["ns"], "exec", pod, "-c", cfg["container"], "--",
             "/bin/sh", "-c", unbundle_script(cfg["repo_path"])],
        )
        if done.returncode != 0:
            raise ClusterGitError("unbundling inside the pod failed")
    return sent


# ---------------------------------------------------------------------------
# Out: pulling a bundle from cluster git
# ---------------------------------------------------------------------------


def pull_bundle(cfg: dict, pod: str, dest: Path) -> Path | None:
    """Bundle cluster git out to `dest`, atomically, and only if it verifies.

    `None` means the repo has nothing to bundle yet - git refuses to create an
    empty bundle, and a freshly-created repo before the first seed is exactly
    that. It is a normal state during startup, not an error, and the watcher
    must be able to tell the difference.

    The verify step is the one that earns its place. A bundle that cannot be
    cloned back out is not a save file, it is a file, and the moment to discover
    that is now rather than at the resume that needed it.
    """
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".tmp")

    try:
        with tmp.open("wb") as fh:
            proc = subprocess.run(
                ["kubectl", "-n", cfg["ns"], "exec", pod, "-c", cfg["container"], "--",
                 "git", "-C", cfg["repo_path"], "bundle", "create", "-", "--all"],
                stdout=fh,
                stderr=subprocess.PIPE,
            )
        if proc.returncode != 0:
            err = proc.stderr.decode("utf-8", "replace")
            if "empty bundle" in err or "does not have any commits" in err:
                return None
            raise ClusterGitError(f"bundling cluster git failed: {err.strip()}")

        if tmp.stat().st_size == 0:
            raise ClusterGitError("cluster git produced a zero-byte bundle")

        verify = subprocess.run(
            ["git", "bundle", "verify", str(tmp)],
            capture_output=True,
            text=True,
        )
        if verify.returncode != 0:
            raise ClusterGitError(
                "the bundle pulled out of cluster git does not verify, so it is not a "
                f"save file. Refusing to keep it.\n{verify.stderr.strip()}"
            )

        os.replace(tmp, dest)
        return dest
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise
