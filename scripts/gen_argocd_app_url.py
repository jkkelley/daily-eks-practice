"""Shared helper: the repo's https URL from the local git remote (never committed)."""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def repo_https_url() -> str:
    try:
        url = subprocess.check_output(
            ["git", "-C", str(REPO), "remote", "get-url", "origin"], text=True
        ).strip()
    except subprocess.CalledProcessError:
        sys.exit("no 'origin' git remote - push this repo to GitHub first.")
    # Normalize ssh form (git@github.com:owner/repo.git) to https for Argo CD.
    if url.startswith("git@"):
        host, path = url.removeprefix("git@").split(":", 1)
        url = f"https://{host}/{path}"
    if not url.endswith(".git"):
        url += ".git"
    return url
