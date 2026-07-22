#!/usr/bin/env python3
"""Register this repo in Argo CD using your existing `gh` CLI login.

The cluster is destroyed daily, and Argo CD's repo-credential Secret dies with
it - so this must be quick and keyless. It reads the repo URL from your git
remote and a token from `gh auth token`, then applies the standard Argo CD
repository Secret. Nothing is written to disk; the token lives only in the
cluster. Works the same on Linux, WSL, and Windows.

Scenario 09 still teaches the manual PAT/UI registration - this is the daily
shortcut once you understand what it does.
"""
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gen_argocd_app_url import repo_https_url  # shared with gen-argocd-app.py


def main() -> int:
    url = repo_https_url()
    try:
        token = subprocess.check_output(["gh", "auth", "token"], text=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit("argo-repo: `gh auth token` failed - install/login the GitHub CLI, "
                 "or register the repo manually in the Argo CD UI (scenario 09).")

    secret = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {
            "name": "repo-daily-eks-practice",
            "namespace": "argocd",
            "labels": {"argocd.argoproj.io/secret-type": "repository"},
        },
        "type": "Opaque",
        "stringData": {
            "type": "git",
            "url": url,
            "username": "git",
            "password": token,
        },
    }
    proc = subprocess.run(
        ["kubectl", "apply", "-f", "-"],
        input=json.dumps(secret),
        text=True,
    )
    if proc.returncode == 0:
        print(f"argo-repo: registered {url} in Argo CD (token from gh CLI, cluster-only)",
              file=sys.stderr)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
