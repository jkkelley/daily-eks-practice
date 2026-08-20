/**
 * The grader against the curriculum it actually has to grade.
 *
 * Everything else in this directory tests the grader against tasks written for the
 * test. This tests it against scenarios/answers/03.toml, which is the shipped drill,
 * and asserts the two things that make the drill usable at all: the model answers
 * pass, and the plausible wrong ones come back with the hint the author wrote for
 * exactly that mistake. A unit test cannot catch an accept rule whose verb the parser
 * never emits - only running the real file through the real parser can.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { loadAnswers, type AnswerTask } from "./answers.ts";
import { gradeCommand, gradeProse, gradeFile } from "./index.ts";

const ANSWERS_DIR = "../../scenarios/answers";
const REPO_ROOT = "../..";

/**
 * The `answer.pre` lines are display text, so some carry a trailing "  # why" note.
 * Strip that here rather than teaching the parser about comments: the drill submits
 * what the user typed into the box, and nobody types the annotation.
 */
function submittable(line: string): string {
  return line.replace(/\s+#\s.*$/, "").trim();
}

function preLines(task: AnswerTask): string[] {
  return (task.answer?.pre ?? [])
    .map(submittable)
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

test("every model answer in 03 is accepted by the grader", async () => {
  const set = await loadAnswers("03", ANSWERS_DIR);
  const rejected: string[] = [];

  for (const task of set.tasks) {
    if (task.grader === "command") {
      for (const line of preLines(task)) {
        const v = gradeCommand(task, line);
        if (!v.passed)
          rejected.push(`task ${task.id}: ${line} -> ${v.message}`);
      }
    }
    if (task.grader === "prose") {
      const prose = task.answer?.prose ?? "";
      const v = gradeProse(task, prose);
      if (!v.passed) rejected.push(`task ${task.id}: prose -> ${v.message}`);
    }
  }

  assert.deepEqual(
    rejected,
    [],
    "the answers file's own model answers were graded wrong",
  );
});

test("03's file task is not pre-solved in the committed defaults", async () => {
  const set = await loadAnswers("03", ANSWERS_DIR);
  const task = set.tasks.find((t) => t.grader === "file");
  assert.ok(task, "03 has a file task");

  const committed = await readFile(`${REPO_ROOT}/${task.path}`, "utf8");
  const before = gradeFile(task, committed);
  assert.equal(
    before.passed,
    false,
    `${task.path} already satisfies ${task.accept_pattern} - the exercise is pre-solved`,
  );
  assert.equal(before.hint, "unchanged");

  const after = gradeFile(
    task,
    committed.replace("1.27-alpine", "1.28-alpine"),
  );
  assert.equal(after.passed, true, after.message);
});

test("03's authored hints fire on the mistakes they were written for", async () => {
  const set = await loadAnswers("03", ANSWERS_DIR);
  const byId = new Map(set.tasks.map((t) => [t.id, t]));

  const rolloutHistory = byId.get("1");
  assert.ok(rolloutHistory);
  const noNamespace = gradeCommand(
    rolloutHistory,
    "kubectl rollout history deploy/practice-app-frontend",
  );
  assert.equal(noNamespace.passed, false);
  assert.equal(noNamespace.hint, "missing-namespace");

  const onPods = gradeCommand(
    rolloutHistory,
    "kubectl -n practice-app rollout history pod/practice-app-frontend",
  );
  assert.equal(onPods.passed, false);
  assert.equal(onPods.hint, "wrong-resource");

  const curlLoop = byId.get("4");
  assert.ok(curlLoop);
  const oneCurl = gradeCommand(curlLoop, "curl localhost:8081");
  assert.equal(oneCurl.passed, false);
  assert.equal(
    oneCurl.hint,
    "no-loop",
    `a single curl is the mistake task 4 exists to catch, got: ${oneCurl.message}`,
  );

  const surge = byId.get("3");
  assert.ok(surge);
  const noNumbers = gradeProse(
    surge,
    "It rolls pods gradually using maxSurge and maxUnavailable",
  );
  assert.equal(noNumbers.passed, false);
  assert.equal(noNumbers.hint, "no-numbers");
});
