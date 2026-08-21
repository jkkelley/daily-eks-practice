#!/usr/bin/env python3
"""Guard the allow-list that keeps credentials out of a PUBLIC image.

The build context for `drill/Containerfile` is the repo root, because the grader
reads `scenarios/answers/*.toml` at runtime and those live above `drill/`. That puts
two files inside the context of an image published publicly to GHCR:

  scripts/config.toml               AWS account id, profile name, your public IP
  .kubeconfig-daily-eks-practice    the cluster endpoint and auth config

`.containerignore` denies everything and allows two trees back. That is the right
shape, and it is one careless `!` from becoming an exclude-list - at which point it
leaks the next secret file somebody adds and says nothing when it does.

This is the cheap half of the check. It runs offline in the static suite and asserts
the file still has the shape it needs. The expensive half is plan Task 5.5 Step 4,
which builds the image and looks inside it - that one checks the RESULT, this one
checks the INTENT, and the intent is what a reviewer changes by accident.
"""

import fnmatch
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
IGNORE = REPO / ".containerignore"

# Paths that must never be in the build context, whatever the file says.
FORBIDDEN = [
    "scripts/config.toml",
    "scripts/config.auto.tfvars.json",
    ".kubeconfig-daily-eks-practice",
    "terraform/envs/dev/terraform.tfstate",
    "terraform/envs/dev/.terraform/terraform.tfstate",
    ".git/config",
    "drill-progress/session.json",
]

failures: list[str] = []
passes = 0


def check(name: str, ok: bool, detail: str) -> None:
    global passes
    if ok:
        passes += 1
        print(f"  PASS  {name}")
    else:
        failures.append(f"{name}: {detail}")
        print(f"  FAIL  {name}: {detail}")


def rules(text: str) -> list[str]:
    """Every meaningful line, comments and blanks dropped."""
    out = []
    for raw in text.splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            out.append(line)
    return out


def included(path: str, patterns: list[str]) -> bool:
    """Would `path` end up in the build context?

    Buildah and Docker both apply every pattern in order and the LAST match wins, so
    a decision cannot be made by looking at one line. This walks the same way. It is
    a simplification - the real matcher has its own path semantics - which is exactly
    why the built-image assertion exists as well.
    """
    verdict = True
    for pattern in patterns:
        negated = pattern.startswith("!")
        pat = pattern[1:] if negated else pattern
        pat = pat.rstrip("/")
        hit = (
            fnmatch.fnmatch(path, pat)
            or fnmatch.fnmatch(path, pat + "/*")
            or any(
                fnmatch.fnmatch(parent, pat)
                for parent in _parents(path)
            )
        )
        if hit:
            # A plain pattern that matches EXCLUDES; a `!` pattern that matches
            # puts it back. Last match wins, so this keeps overwriting.
            verdict = negated
    return verdict


def _parents(path: str) -> list[str]:
    parts = path.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts))]


def main() -> int:
    print("== test_the_file_exists_and_denies_first ==")
    check(
        ".containerignore is at the repo root",
        IGNORE.is_file(),
        "it is missing, so the whole repo is in the build context",
    )
    if not IGNORE.is_file():
        print()
        print(f"containerignore: {passes} passed, {len(failures)} failed")
        return 1

    patterns = rules(IGNORE.read_text(encoding="utf-8"))
    check(
        "the first rule is a bare `*`",
        patterns[:1] == ["*"],
        f"it is {patterns[:1]!r} - without a leading deny-all this is an "
        "exclude-list, and an exclude-list leaks the next secret file added",
    )

    print("== test_nothing_re_admits_a_credential ==")
    for path in FORBIDDEN:
        check(
            f"{path} stays out of the build context",
            not included(path, patterns),
            "a rule re-admits it; this file would be baked into a PUBLIC image",
        )

    print("== test_the_image_can_still_be_built ==")
    # The other half of the failure mode: a deny-all with a typo in the allows is
    # safe and useless, and the symptom is a build error rather than a leak. These
    # two trees are exactly what drill/Containerfile copies.
    for path in [
        "drill/package.json",
        "drill/server/src/index.ts",
        "drill/web/src/main.tsx",
        "drill/tmux.conf",
        "scenarios/answers/03.toml",
    ]:
        check(
            f"{path} is still in the build context",
            included(path, patterns),
            "the allow-list does not cover it, so the build will fail",
        )

    print("== test_host_build_output_is_excluded ==")
    # node_modules is a HOST build - node-pty is native and compiled against
    # whichever libc ran `npm install`. Copying it in shadows the one `npm ci` builds
    # inside the image, and the pod starts with a .node it cannot load.
    for path in [
        "drill/node_modules/node-pty/build/Release/pty.node",
        "drill/server/dist/index.js",
    ]:
        check(
            f"{path} is excluded",
            not included(path, patterns),
            "host build output would shadow what the image builds for itself",
        )

    print()
    print(f"containerignore: {passes} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
