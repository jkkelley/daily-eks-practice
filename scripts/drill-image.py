#!/usr/bin/env python3
"""Build and push the drill GUI image to the registry named in scripts/config.toml.

    make drill-image

The image reference is config-driven because it contains a GitHub username, and
CLAUDE.md keeps repo-owner strings out of the repo. The tag is the short git sha so
a running pod can always be traced back to a commit - `:latest` cannot answer "what
is actually running", which is the question you have at the worst possible moment.

This is the LOCAL path, for iterating. The long-term publisher is
.github/workflows/drill-image.yml, which builds from what is on `main` rather than
from whatever happens to be on someone's laptop, and authenticates with the
automatic GITHUB_TOKEN rather than with any credential a person has to hold.

Authentication here is `gh`'s existing token, extended once with
`gh auth refresh -h github.com -s write:packages`. Never a personal access token:
a PAT is a second credential with its own expiry, and every place to put it is
worse - config.toml is serialised into Terraform state, a shell export lands in
~/.zsh_history, and a dotfile is one `git add -A` from being committed.
"""

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CONTAINERFILE = "drill/Containerfile"


def die(message: str) -> "None":
    sys.exit(f"drill-image: {message}")


def run(*cmd: str) -> None:
    print("+ " + " ".join(cmd))
    if subprocess.run(cmd, cwd=REPO).returncode != 0:
        die(f"{cmd[0]} failed")


def config(key: str) -> str:
    """One merged value out of config.toml, via the only reader of that file."""
    out = subprocess.run(
        [sys.executable, str(REPO / "scripts" / "bootstrap.py"), "dev", "--print", key],
        capture_output=True,
        text=True,
        cwd=REPO,
    )
    value = out.stdout.strip()
    if out.returncode != 0 or not value:
        die(
            f"{key} is not set in scripts/config.toml - copy the block from "
            f"scripts/config.example.toml ({out.stderr.strip() or 'no value'})"
        )
    return value


def main() -> int:
    image = config("drill_gui_image")
    # The template ships a placeholder in angle brackets. Pushing it produces a
    # confusing 403 from GHCR about a repository nobody owns, ten minutes after the
    # build finishes.
    if "<" in image or ">" in image:
        die(
            f"drill_gui_image is still the placeholder ({image}) - set it to your "
            "own registry in scripts/config.toml"
        )

    sha = subprocess.check_output(
        ["git", "rev-parse", "--short", "HEAD"], text=True, cwd=REPO
    ).strip()

    # A dirty tree means `:<sha>` names a commit that does not contain what is in the
    # image. Not fatal - iterating is the whole point of this path - but the tag is
    # lying and you should know it.
    if subprocess.check_output(
        ["git", "status", "--porcelain"], text=True, cwd=REPO
    ).strip():
        print(
            "drill-image: WARNING - the working tree is dirty, so this tag will not "
            "reproduce from git"
        )

    run("podman", "build", "-t", f"{image}:{sha}", "-t", f"{image}:latest", "-f", CONTAINERFILE, ".")
    run("podman", "push", f"{image}:{sha}")
    run("podman", "push", f"{image}:latest")

    print(f"drill-image: pushed {image}:{sha}")
    print()
    print("If this is the FIRST push, make the package PUBLIC:")
    print("  https://github.com/users/<you>/packages -> the package -> Package settings")
    print("  -> Change visibility -> Public")
    print()
    print("GHCR packages are private by default even when the repo is public, and the")
    print("cluster is deliberately configured with no imagePullSecret. A private")
    print("package shows up as ImagePullBackOff on a pod that otherwise looks fine.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
