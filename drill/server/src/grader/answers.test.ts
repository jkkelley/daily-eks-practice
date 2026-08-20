import { test } from "node:test";
import assert from "node:assert/strict";
import { readdir } from "node:fs/promises";
import { loadAnswers, AnswersError } from "./answers.ts";

test("the real scenario 03 answers file loads and validates", async () => {
  const set = await loadAnswers("03", "../../scenarios/answers");
  assert.equal(set.scenario, "03");
  assert.equal(set.tasks.length, 6);
  assert.deepEqual(
    set.tasks.map((t) => t.grader),
    ["command", "file", "prose", "command", "command", "prose"],
  );
});

/**
 * What each fixture must be rejected FOR, not merely that it was rejected.
 *
 * AC-H3 asks for the same failure the Python validator gives, so each pattern is
 * lifted from the message scripts/answers.py raises. Without this a validator could
 * pass the whole conformance set by throwing on the wrong rule - every fixture is a
 * valid document with exactly one thing wrong, so a single over-strict rule would
 * reject all ten and look green. The table mirrors the one in the fixtures' README.
 */
const EXPECTED_FAILURE: Readonly<Record<string, RegExp>> = {
  "schema-too-new.toml": /schema is 2, this loader only understands schema 1/,
  "empty-title.toml": /top-level 'title' must be a non-empty string/,
  "no-tasks.toml": /needs a non-empty \[\[tasks\]\] array/,
  "duplicate-task-id.toml": /duplicate task id '1'/,
  "unknown-grader.toml": /unknown grader 'vibes', expected one of/,
  "command-without-accept.toml":
    /a 'command' task needs a non-empty \[\[tasks\.accept\]\] array/,
  "command-accept-without-verb.toml": /accept\[0\] needs a non-empty 'verb'/,
  "file-without-key.toml": /a 'file' task needs a non-empty 'key'/,
  "prose-without-must-include.toml":
    /a 'prose' task needs a non-empty 'must_include' list/,
  "hint-without-text.toml": /hints\[0\] needs a non-empty 'text'/,
};

/**
 * The same fixtures scripts/answers.py rejects in tests/test_answers.py.
 *
 * Two implementations of one ruleset drift. When they drift, a TOML file passes
 * generation and fails grading, or worse, passes grading with a rule silently
 * unenforced. This turns that drift into a red test on whichever side moved.
 */
test("every invalid fixture is rejected here too", async () => {
  const dir = "../../tests/fixtures/answers-invalid";
  const files = (await readdir(dir)).filter((f) => f.endsWith(".toml"));
  assert.ok(
    files.length > 0,
    "no fixtures found - the conformance set is the drift alarm",
  );

  // Collected rather than asserted one at a time, so a run names every fixture that
  // drifted instead of stopping at whichever sorts first.
  const accepted: string[] = [];
  const wrongError: string[] = [];
  for (const file of files) {
    try {
      await loadAnswers(file.replace(/\.toml$/, ""), dir);
      accepted.push(file);
    } catch (e) {
      if (!(e instanceof AnswersError)) {
        wrongError.push(
          `${file}: ${(e as Error).name} - ${(e as Error).message}`,
        );
        continue;
      }
      // The message has to name the file and the problem, or it is not actionable
      // without opening the file. Same rule the Python side is held to.
      assert.match(
        e.message,
        new RegExp(file.replace(/[.]/g, "\\.")),
        `${file} was rejected, but its message does not name the file: ${e.message}`,
      );
      const expected = EXPECTED_FAILURE[file];
      assert.ok(
        expected,
        `${file} has no entry in EXPECTED_FAILURE - a new fixture needs one, or the conformance set is only half pinned`,
      );
      assert.match(
        e.message,
        expected,
        `${file} was rejected for the wrong reason: ${e.message}`,
      );
    }
  }
  assert.deepEqual(
    Object.keys(EXPECTED_FAILURE).sort(),
    [...files].sort(),
    "EXPECTED_FAILURE and the fixture directory disagree about which fixtures exist",
  );
  assert.deepEqual(
    accepted,
    [],
    "ACCEPTED by the TypeScript validator but rejected by the Python one",
  );
  assert.deepEqual(wrongError, [], "rejected, but not with an AnswersError");
});
