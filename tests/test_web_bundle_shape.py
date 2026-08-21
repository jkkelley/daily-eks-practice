#!/usr/bin/env python3
"""Guard the two import rules that keep Monaco bundled AND lazy.

Both have already broken once each, silently, with every test green and the build
output as the only witness:

  1. Something in the entry graph imported `lib/monaco.ts`, so Monaco landed in the
     entry chunk and the lazy loading did nothing. 473 KB became 3.7 MB.
  2. Nothing imported `lib/monaco.ts` at all, so `loader.config` never ran and
     `@monaco-editor/react` went back to fetching the editor from cdn.jsdelivr.net -
     which works on a laptop and hangs forever in a private subnet.

They are opposite failures with one cause: the import is a side effect nobody can
see. This asserts the shape directly, in the cheapest way that runs offline.

A real bundle-size assertion would be better and needs npm, Podman and a build;
this needs a file read, so it runs in `make -f Makefile.test test` with everything
else.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WEB = REPO / "drill" / "web" / "src"

MONACO = "lib/monaco"

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


def imports_monaco(path: Path) -> bool:
    """Does this file import lib/monaco at RUNTIME? `import type` is erased."""
    text = path.read_text(encoding="utf-8")
    for match in re.finditer(r"^\s*import\s+(.*?)from\s+[\"']([^\"']+)[\"']", text, re.M):
        clause, target = match.group(1), match.group(2)
        if MONACO in target and not clause.strip().startswith("type "):
            return True
    # Side-effect form: import "../lib/monaco.ts";
    return bool(re.search(rf"^\s*import\s+[\"'][^\"']*{MONACO}", text, re.M))


def main() -> int:
    print("== test_lazy_chunk_owns_monaco ==")
    editor = WEB / "panels" / "EditorPanel.tsx"
    check(
        "EditorPanel imports lib/monaco, so the loader is configured",
        imports_monaco(editor),
        f"{editor.relative_to(REPO)} does not import {MONACO} - "
        "the editor will fetch itself from a CDN the cluster cannot reach",
    )

    print("== test_entry_graph_stays_free_of_monaco ==")
    # Anything reachable from main.tsx WITHOUT going through the lazy import ends up
    # in the entry chunk. These three are that path.
    for name in ("main.tsx", "App.tsx", "lib/language.ts"):
        path = WEB / name
        check(
            f"{name} does not import {MONACO}",
            not imports_monaco(path),
            "it does, which drags all of Monaco into the entry bundle and "
            "undoes the lazy loading",
        )

    print("== test_the_lazy_boundary_still_exists ==")
    app = (WEB / "App.tsx").read_text(encoding="utf-8")
    check(
        "App.tsx loads EditorPanel through a lazy import",
        "lazy(" in app and "import(" in app,
        "EditorPanel is imported eagerly, so Monaco blocks the first paint",
    )

    print()
    print(f"web-bundle-shape: {passes} passed, {len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
