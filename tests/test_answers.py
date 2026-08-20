#!/usr/bin/env python3
"""Unit tests for scripts/answers.py - the answers TOML loader and validator.

Pure functions over files. No cluster, no AWS, no network.
Run: python3 tests/test_answers.py
"""
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import answers  # noqa: E402

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


def expect_error(fn, needle, label):
    try:
        fn()
    except answers.AnswersError as e:
        if needle in str(e):
            ok(f"{label}: rejected with '{needle}'")
        else:
            bad(f"{label}: rejected but message was {e!r}, wanted '{needle}'")
    except Exception as e:  # noqa: BLE001
        bad(f"{label}: raised {type(e).__name__} instead of AnswersError: {e}")
    else:
        bad(f"{label}: accepted invalid input")


def load_text(text):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "99.toml"
        p.write_text(text, encoding="utf-8")
        return answers.load_path(p)


def test_real_03_loads():
    data = answers.load("03")
    if data["scenario"] == "03":
        ok("03.toml loads and reports scenario 03")
    else:
        bad(f"03.toml scenario is {data['scenario']!r}")
    if data["schema"] == 1:
        ok("03.toml declares schema 1")
    else:
        bad(f"03.toml schema is {data['schema']!r}")
    if len(data["tasks"]) == 6:
        ok("03.toml has 6 tasks, matching the card")
    else:
        bad(f"03.toml has {len(data['tasks'])} tasks, card has 6")
    graders = {t["grader"] for t in data["tasks"]}
    if graders <= {"command", "file", "prose"}:
        ok(f"03.toml graders are all known: {sorted(graders)}")
    else:
        bad(f"03.toml has unknown graders: {sorted(graders)}")


def test_available_includes_03():
    if "03" in answers.available():
        ok("available() includes 03")
    else:
        bad(f"available() returned {answers.available()}")


def test_missing_scenario():
    expect_error(lambda: answers.load("99"), "no answers file", "missing scenario")


def test_wrong_schema():
    expect_error(
        lambda: load_text('schema = 2\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "prose"\nmust_include = ["a"]\n'),
        "schema",
        "unsupported schema version",
    )


def test_unknown_grader():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "vibes"\n'),
        "grader",
        "unknown grader",
    )


def test_command_task_needs_accept():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "command"\n'),
        "accept",
        "command task with no accept block",
    )


def test_no_tasks():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n'),
        "tasks",
        "no tasks",
    )


def test_duplicate_task_ids():
    expect_error(
        lambda: load_text('schema = 1\nscenario = "99"\ntitle = "x"\ntime = "x"\nneeds = "x"\nticket = "x"\n[[tasks]]\nid = "1"\nprompt = "p"\ngrader = "prose"\nmust_include = ["a"]\n[[tasks]]\nid = "1"\nprompt = "q"\ngrader = "prose"\nmust_include = ["b"]\n'),
        "duplicate",
        "duplicate task ids",
    )


def test_every_invalid_fixture_is_rejected():
    """The same fixtures are run through the TypeScript validator in Task 2.4.
    If one side accepts what the other rejects, the two loaders have drifted."""
    fixtures = sorted((ROOT / "tests" / "fixtures" / "answers-invalid").glob("*.toml"))
    if not fixtures:
        bad("no invalid fixtures found - the conformance set is the drift alarm")
        return
    for path in fixtures:
        try:
            answers.load_path(path)
        except answers.AnswersError:
            ok(f"{path.name} rejected")
        else:
            bad(f"{path.name} was ACCEPTED - the validator is missing a rule")


def main():
    for fn in (
        test_real_03_loads,
        test_available_includes_03,
        test_missing_scenario,
        test_wrong_schema,
        test_unknown_grader,
        test_command_task_needs_accept,
        test_no_tasks,
        test_duplicate_task_ids,
        test_every_invalid_fixture_is_rejected,
    ):
        print(f"== {fn.__name__} ==")
        fn()
    print()
    print(f"answers: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    raise SystemExit(main())
