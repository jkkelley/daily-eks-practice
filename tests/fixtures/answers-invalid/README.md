# answers-invalid - the cross-language conformance set

Every `.toml` file in this directory is a deliberately-invalid answers document that **both** validators must reject.

- Python: `scripts/answers.py::_validate()`, exercised by `tests/test_answers.py::test_every_invalid_fixture_is_rejected`.
- TypeScript: `drill/server/src/grader/answers.ts::validate()`, built in Phase 2 (`WO-20260819-a56c`, plan Task 2.4 Step 6), which runs this same directory.

The TOML is validated twice because it is read by two languages in two places: Python renders `PRACTICE_ANSWERS.html` from it and never grades, TypeScript grades against it and never renders.
Two implementations of one ruleset drift, and when they drift a file passes generation and fails grading, which is the worst of both.
This directory is the drift alarm: if one side accepts what the other rejects, a test goes red instead of a drill silently mis-grading.

Each file is a minimal valid document with exactly one thing wrong, named after the rule it breaks, so a rejection can only be caused by the rule under test.
When you add a validation rule, add a fixture for it here in the same commit.
When a fixture is accepted, the fix is in the validator, never in the fixture.

## The validated shape

This is the contract Phase 2 implements against.
`scripts/answers.py`'s module docstring carries the same table next to the code that enforces it.

### Top level

| Key        | Type            | Rule                  |
| ---------- | --------------- | --------------------- |
| `schema`   | int             | must be exactly `1`   |
| `scenario` | str             | non-empty, two digits |
| `title`    | str             | non-empty             |
| `time`     | str             | non-empty             |
| `needs`    | str             | non-empty             |
| `ticket`   | str             | non-empty             |
| `tasks`    | array of tables | non-empty             |

### Every task, regardless of grader

| Key      | Type            | Rule                                                            |
| -------- | --------------- | --------------------------------------------------------------- |
| `id`     | str             | non-empty, unique within the file                               |
| `prompt` | str             | non-empty                                                       |
| `grader` | str             | one of `command`, `file`, `prose`                               |
| `hints`  | array of tables | optional; each hint needs a non-empty `when` and `text`         |
| `answer` | table           | optional, render-only. Keys: `pre` (list of str), `prose` (str) |

`answer` is consumed by `scripts/gen-answers.py` to render the HTML block and is ignored by the grader.
Nothing in `answer` is validated beyond its own types, because it is prose for a human, not a machine assertion.

### The three grader kinds

**`grader = "command"`** - the submission is a shell command, graded by parsing it.

| Key      | Type            | Rule                                                                                                     |
| -------- | --------------- | -------------------------------------------------------------------------------------------------------- |
| `accept` | array of tables | non-empty. Each entry needs a non-empty `verb`; `resource`, `namespace`, `name` and `flags` are optional |

**`grader = "file"`** - the submission is a file edit, graded by reading the file.

| Key              | Type | Rule                                          |
| ---------------- | ---- | --------------------------------------------- |
| `path`           | str  | non-empty, repo-relative                      |
| `key`            | str  | non-empty, dotted path into that file's YAML  |
| `accept_pattern` | str  | non-empty regex the value at `key` must match |

**`grader = "prose"`** - the submission is free text, graded by substring.

| Key            | Type        | Rule                                |
| -------------- | ----------- | ----------------------------------- |
| `must_include` | list of str | non-empty list of non-empty strings |

## Rules covered

| Fixture                            | Rule it breaks                                      |
| ---------------------------------- | --------------------------------------------------- |
| `schema-too-new.toml`              | `schema` must be `1`                                |
| `empty-title.toml`                 | top-level strings must be non-empty                 |
| `no-tasks.toml`                    | `tasks` must exist and be non-empty                 |
| `duplicate-task-id.toml`           | task `id` must be unique within the file            |
| `unknown-grader.toml`              | `grader` must be one of the three kinds             |
| `command-without-accept.toml`      | a `command` task needs a non-empty `accept`         |
| `command-accept-without-verb.toml` | every `accept` entry needs a `verb`                 |
| `file-without-key.toml`            | a `file` task needs `path`, `key`, `accept_pattern` |
| `prose-without-must-include.toml`  | a `prose` task needs a non-empty `must_include`     |
| `hint-without-text.toml`           | every hint needs both `when` and `text`             |

Rejection must name both the file and the problem, so the message is actionable without opening the file.
