#!/usr/bin/env python3
"""Generate PRACTICE_ANSWERS.html from per-scenario answers TOML.

MIXED MODE ON PURPOSE. Scenarios with a file in scenarios/answers/ are rendered
from it; every other scenario's hand-written block is passed through byte-for-byte.
That is what lets the twelve cards migrate one at a time instead of in a big bang.

  python3 scripts/gen-answers.py            # rewrite PRACTICE_ANSWERS.html in place
  python3 scripts/gen-answers.py --check    # exit 1 if the file is stale (CI / make test)
  python3 scripts/gen-answers.py --stdout   # print, do not write

Stdlib only. The hand-written blocks are the reason this is a surgical splice
rather than a template render: regenerating the whole document from scratch would
mean re-authoring eleven scenarios' worth of prose that is already correct.
"""
from __future__ import annotations

import difflib
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import answers  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
TARGET = REPO / "PRACTICE_ANSWERS.html"

# Matches a whole <details>...</details> block and captures the scenario number
# out of its summary heading. DOTALL because blocks span many lines; non-greedy
# so consecutive blocks do not get swallowed into one.
BLOCK_RE = re.compile(
    r"[ \t]*<details>.*?<h2[^>]*>(\d{2}) - .*?</details>\n",
    re.DOTALL,
)


def split(doc: str) -> tuple[str, dict[str, str], str]:
    """Split into (head, {number: block}, tail). Lossless: the parts reassemble exactly."""
    blocks: dict[str, str] = {}
    spans: list[tuple[int, int]] = []
    for m in BLOCK_RE.finditer(doc):
        blocks[m.group(1)] = m.group(0)
        spans.append((m.start(), m.end()))
    if not spans:
        return doc, {}, ""
    head = doc[: spans[0][0]]
    tail = doc[spans[-1][1] :]
    # Anything between blocks (blank lines) belongs to the preceding block so the
    # round-trip stays exact. The regex already consumes the trailing newline.
    for (prev_start, prev_end), (next_start, _) in zip(spans, spans[1:]):
        gap = doc[prev_end:next_start]
        if gap:
            num = next(k for k, v in blocks.items() if v == doc[prev_start:prev_end])
            blocks[num] = blocks[num] + gap
    return head, blocks, tail


def _esc(text: str) -> str:
    return html.escape(text, quote=False)


def render(data: dict) -> str:
    """Render one validated answers dict into a <details> block."""
    out: list[str] = []
    out.append("    <details>\n")
    out.append("      <summary>\n")
    out.append(f'        <h2 style="display: inline">{_esc(data["scenario"])} - {_esc(data["title"])}</h2>\n')
    out.append("      </summary>\n")

    for task in data["tasks"]:
        ans = task.get("answer", {})
        pre = ans.get("pre", [])
        prose = ans.get("prose", "")
        out.append(f'      <h3>{_esc(task["id"])}. {_esc(task["prompt"])}</h3>\n')
        if pre:
            body = "\n".join(_esc(line) for line in pre)
            out.append(f"      <pre>\n{body}</pre>\n")
        if prose:
            out.append(f"      <p>{_esc(prose)}</p>\n")

    out.append("    </details>\n")
    return "".join(out)


def generate(doc: str, scenarios: list[str]) -> str:
    """Replace the named scenarios' blocks with rendered ones; leave the rest alone."""
    head, blocks, tail = split(doc)
    for num in scenarios:
        if num not in blocks:
            raise answers.AnswersError(f"scenario {num} has an answers file but no block in {TARGET.name}")
        trailing = blocks[num][len(blocks[num].rstrip("\n")) :]
        blocks[num] = render(answers.load(num)).rstrip("\n") + trailing
    return head + "".join(blocks[k] for k in sorted(blocks)) + tail


def main(argv: list[str]) -> int:
    mode = argv[0] if argv else ""
    doc = TARGET.read_text(encoding="utf-8")
    out = generate(doc, answers.available())

    if mode == "--stdout":
        sys.stdout.write(out)
        return 0
    if mode == "--check":
        if out == doc:
            print(f"gen-answers: {TARGET.name} is up to date")
            return 0
        diff = difflib.unified_diff(
            doc.splitlines(keepends=True),
            out.splitlines(keepends=True),
            fromfile=f"{TARGET.name} (committed)",
            tofile=f"{TARGET.name} (generated)",
        )
        sys.stdout.writelines(diff)
        print(f"\ngen-answers: {TARGET.name} is STALE - run `make answers-gen`", file=sys.stderr)
        return 1

    if out == doc:
        print(f"gen-answers: {TARGET.name} already up to date")
        return 0
    TARGET.write_text(out, encoding="utf-8")
    print(f"gen-answers: rewrote {TARGET.name} from {', '.join(answers.available())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
