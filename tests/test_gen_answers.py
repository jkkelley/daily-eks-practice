#!/usr/bin/env python3
"""Tests for scripts/gen-answers.py.

The contract that matters: generating with NO scenarios must reproduce the
committed PRACTICE_ANSWERS.html byte-for-byte, and generating scenario 03 must
leave the other eleven blocks byte-for-byte unchanged. If either breaks, the
generator is rewriting hand-authored prose it was never asked to touch.

Run: python3 tests/test_gen_answers.py
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

spec = importlib.util.spec_from_file_location("gen_answers", ROOT / "scripts" / "gen-answers.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)

HTML = (ROOT / "PRACTICE_ANSWERS.html").read_text(encoding="utf-8")

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  PASS  {msg}")


def bad(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL  {msg}")


def test_split_is_lossless():
    head, blocks, tail = gen.split(HTML)
    rebuilt = head + "".join(blocks[k] for k in sorted(blocks)) + tail
    if rebuilt == HTML:
        ok("split() round-trips byte-for-byte")
    else:
        bad(f"split() lost data: {len(rebuilt)} chars vs {len(HTML)}")


def test_split_finds_twelve():
    _, blocks, _ = gen.split(HTML)
    want = {f"{i:02d}" for i in range(1, 13)}
    if set(blocks) == want:
        ok("split() found all twelve scenario blocks")
    else:
        bad(f"split() found {sorted(blocks)}, wanted {sorted(want)}")


def test_passthrough_is_identical():
    out = gen.generate(HTML, [])
    if out == HTML:
        ok("generate() with no scenarios is byte-identical")
    else:
        bad("generate() with no scenarios changed the file")


def test_mixed_leaves_others_untouched():
    """The contract is that the eleven hand-written blocks survive byte-for-byte.

    It is deliberately NOT "03 changed". Once PRACTICE_ANSWERS.html has been
    regenerated, the committed 03 block already IS the rendered one, so a second
    generation is a no-op - and asserting that 03 changed would make this test
    unsatisfiable exactly when the repo is in its correct, up-to-date state.
    """
    out = gen.generate(HTML, ["03"])
    _, before, _ = gen.split(HTML)
    _, after, _ = gen.split(out)
    collateral = [k for k in sorted(before) if k != "03" and before[k] != after.get(k)]
    if not collateral:
        ok("generating 03 left all eleven other blocks byte-identical")
    else:
        bad(f"generating 03 also changed: {collateral}")


def test_generation_is_idempotent():
    """Regenerating an already-generated document must be a no-op.

    This is what makes `gen-answers.py --check` a stable gate instead of a
    permanently-red one, so it is asserted rather than assumed.
    """
    once = gen.generate(HTML, ["03"])
    twice = gen.generate(once, ["03"])
    if once == twice:
        ok("generate() is idempotent")
    else:
        bad("generate() is not idempotent - --check would never go green")


def test_head_and_tail_survive_generation():
    out = gen.generate(HTML, ["03"])
    head_b, _, tail_b = gen.split(HTML)
    head_a, _, tail_a = gen.split(out)
    if head_a == head_b and tail_a == tail_b:
        ok("head (styles, seal) and tail (script) are untouched")
    else:
        bad("generation modified the document head or tail")


def test_rendered_block_is_serveable():
    """serve-answers.sh greps for '<h2[^>]*>NN - ' to scope to one card."""
    out = gen.generate(HTML, ["03"])
    _, blocks, _ = gen.split(out)
    if '<h2 style="display: inline">03 - ' in blocks["03"]:
        ok("rendered 03 block still matches the serve-answers.sh awk pattern")
    else:
        bad("rendered 03 block would break `make serve-answers N=03`")


def test_rendered_block_contains_the_answers():
    out = gen.generate(HTML, ["03"])
    _, blocks, _ = gen.split(out)
    body = blocks["03"]
    for needle in ("rollout history", "1.28-alpine", "rollout undo", "ImagePullBackOff"):
        if needle in body:
            ok(f"rendered 03 contains {needle!r}")
        else:
            bad(f"rendered 03 is missing {needle!r}")


def test_html_is_escaped():
    """Angle brackets from the TOML must not become live markup."""
    out = gen.generate(HTML, ["03"])
    _, blocks, _ = gen.split(out)
    if "&lt;commit&gt;" in blocks["03"]:
        ok("angle brackets in answers are HTML-escaped")
    else:
        bad("'<commit>' was not escaped - the generator emits raw markup")


def main():
    for fn in (
        test_split_is_lossless,
        test_split_finds_twelve,
        test_passthrough_is_identical,
        test_mixed_leaves_others_untouched,
        test_generation_is_idempotent,
        test_head_and_tail_survive_generation,
        test_rendered_block_is_serveable,
        test_rendered_block_contains_the_answers,
        test_html_is_escaped,
    ):
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"gen-answers: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
