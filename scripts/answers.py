#!/usr/bin/env python3
"""Load and validate a scenario's answers TOML.

The TOML is the single source of truth for a scenario: scripts/gen-answers.py
renders it into PRACTICE_ANSWERS.html, and the drill GUI grades against it.
Validation is strict on purpose - a typo here silently degrades grading, which
is worse than a loud failure at generation time.

Stdlib only (tomllib), matching scripts/bootstrap.py.

THE VALIDATED SHAPE (the contract the TypeScript grader must also implement,
see drill/server/src/grader/answers.ts):

  top level
    schema          int, must be 1
    scenario        str, two digits, e.g. "03"
    title           str, non-empty
    time            str, non-empty
    needs           str, non-empty
    ticket          str, non-empty
    tasks           array of tables, non-empty

  every task
    id              str, non-empty, unique within the file
    prompt          str, non-empty
    grader          str, one of "command", "file", "prose"
    hints           optional array of tables, each with non-empty 'when' and 'text'
    answer          optional table, render-only, ignored by the grader:
                      pre     optional list of str (shell lines)
                      prose   optional str

  grader = "command"
    accept          array of tables, non-empty. Each carries a non-empty 'verb'
                    and optionally 'resource', 'namespace', 'name', 'flags'.

  grader = "file"
    path            str, non-empty - repo-relative file the answer must change
    key             str, non-empty - dotted path into that file's YAML
    accept_pattern  str, non-empty - regex the value at 'key' must match

  grader = "prose"
    must_include    list of non-empty str, non-empty list

Any file that breaks one of these rules must raise AnswersError naming both the
file and the problem. tests/fixtures/answers-invalid/ holds one file per rule and
is a shared conformance set: the TypeScript validator is held to the same files,
so the two implementations cannot drift silently.
"""
from __future__ import annotations

import tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ANSWERS_DIR = REPO / "scenarios" / "answers"

SCHEMA_VERSION = 1
GRADERS = ("command", "file", "prose")
TOP_LEVEL_STR = ("scenario", "title", "time", "needs", "ticket")


class AnswersError(Exception):
    """Raised when an answers file is missing, unparseable, or invalid."""


def available() -> list[str]:
    """Scenario numbers that have an answers TOML, sorted."""
    if not ANSWERS_DIR.is_dir():
        return []
    return sorted(p.stem for p in ANSWERS_DIR.glob("*.toml"))


def load(scenario: str) -> dict:
    """Load and validate scenarios/answers/<scenario>.toml."""
    path = ANSWERS_DIR / f"{scenario}.toml"
    if not path.is_file():
        raise AnswersError(f"no answers file for scenario {scenario} (looked for {path})")
    return load_path(path)


def load_path(path: Path) -> dict:
    """Load and validate an answers TOML at an explicit path (used by tests)."""
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise AnswersError(f"{path}: not valid TOML: {e}") from e
    _validate(data, path)
    return data


def _validate(data: dict, path: Path) -> None:
    got = data.get("schema")
    if got != SCHEMA_VERSION:
        raise AnswersError(
            f"{path}: schema is {got!r}, this loader only understands schema {SCHEMA_VERSION}"
        )

    for key in TOP_LEVEL_STR:
        if not isinstance(data.get(key), str) or not data[key].strip():
            raise AnswersError(f"{path}: top-level '{key}' must be a non-empty string")

    tasks = data.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise AnswersError(f"{path}: needs a non-empty [[tasks]] array")

    seen: set[str] = set()
    for i, task in enumerate(tasks):
        where = f"{path}: tasks[{i}]"
        tid = task.get("id")
        if not isinstance(tid, str) or not tid.strip():
            raise AnswersError(f"{where}: 'id' must be a non-empty string")
        if tid in seen:
            raise AnswersError(f"{path}: duplicate task id {tid!r}")
        seen.add(tid)

        if not isinstance(task.get("prompt"), str) or not task["prompt"].strip():
            raise AnswersError(f"{where} (id {tid}): 'prompt' must be a non-empty string")

        grader = task.get("grader")
        if grader not in GRADERS:
            raise AnswersError(
                f"{where} (id {tid}): unknown grader {grader!r}, expected one of {GRADERS}"
            )
        _validate_grader(task, grader, f"{where} (id {tid})")
        _validate_hints(task, f"{where} (id {tid})")


def _validate_grader(task: dict, grader: str, where: str) -> None:
    if grader == "command":
        accept = task.get("accept")
        if not isinstance(accept, list) or not accept:
            raise AnswersError(f"{where}: a 'command' task needs a non-empty [[tasks.accept]] array")
        for j, acc in enumerate(accept):
            if not isinstance(acc.get("verb"), str) or not acc["verb"].strip():
                raise AnswersError(f"{where}: accept[{j}] needs a non-empty 'verb'")
    elif grader == "file":
        for key in ("path", "key", "accept_pattern"):
            if not isinstance(task.get(key), str) or not task[key].strip():
                raise AnswersError(f"{where}: a 'file' task needs a non-empty '{key}'")
    elif grader == "prose":
        must = task.get("must_include")
        if not isinstance(must, list) or not must:
            raise AnswersError(f"{where}: a 'prose' task needs a non-empty 'must_include' list")
        for j, item in enumerate(must):
            if not isinstance(item, str) or not item.strip():
                raise AnswersError(f"{where}: must_include[{j}] must be a non-empty string")


def _validate_hints(task: dict, where: str) -> None:
    hints = task.get("hints", [])
    if not isinstance(hints, list):
        raise AnswersError(f"{where}: 'hints' must be an array of tables")
    for j, hint in enumerate(hints):
        for key in ("when", "text"):
            if not isinstance(hint.get(key), str) or not hint[key].strip():
                raise AnswersError(f"{where}: hints[{j}] needs a non-empty '{key}'")
