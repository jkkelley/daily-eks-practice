import { test } from "node:test";
import assert from "node:assert/strict";
import { grade, gradeCommand, gradeProse, gradeFile } from "./index.ts";
import type { AnswerTask } from "./answers.ts";

const rolloutTask: AnswerTask = {
  id: "1",
  prompt: "find the rollout history",
  grader: "command",
  accept: [
    {
      verb: "rollout-history",
      resource: "deployment",
      namespace: "practice-app",
      name: "practice-app-frontend",
    },
    {
      verb: "get",
      resource: "deployment",
      namespace: "practice-app",
      name: "practice-app-frontend",
    },
  ],
  hints: [
    {
      when: "missing-namespace",
      text: "Every command in this drill needs -n practice-app.",
    },
    {
      when: "wrong-resource",
      text: "Rollout history belongs to the Deployment, not the pods.",
    },
  ],
};

test("an exactly correct command passes", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl -n practice-app rollout history deploy/practice-app-frontend",
  );
  assert.equal(v.passed, true);
  assert.equal(v.taskId, "1");
});

test("the same command written differently still passes", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl rollout history deployment practice-app-frontend --namespace=practice-app",
  );
  assert.equal(v.passed, true);
});

test("an alias form passes", () => {
  const v = gradeCommand(
    {
      ...rolloutTask,
      accept: [{ verb: "get", resource: "pod", namespace: "practice-app" }],
    },
    "kgp -n practice-app",
  );
  assert.equal(v.passed, true);
});

test("a second accept rule also passes", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl -n practice-app get deploy practice-app-frontend",
  );
  assert.equal(v.passed, true);
});

test("missing namespace fails with the namespace hint, not a bare failure", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl rollout history deploy/practice-app-frontend",
  );
  assert.equal(v.passed, false);
  assert.equal(v.hint, "missing-namespace");
  assert.match(v.message, /-n practice-app/);
});

test("wrong resource fails with the resource hint", () => {
  const v = gradeCommand(
    rolloutTask,
    "kubectl -n practice-app rollout history pod/practice-app-frontend",
  );
  assert.equal(v.passed, false);
  assert.equal(v.hint, "wrong-resource");
});

test("an unrelated command fails without inventing a hint", () => {
  const v = gradeCommand(rolloutTask, "helm list -A");
  assert.equal(v.passed, false);
  assert.equal(v.hint, undefined);
});

test("a rule with no namespace accepts a command with any namespace", () => {
  const loose: AnswerTask = {
    id: "4",
    prompt: "curl loop",
    grader: "command",
    accept: [{ verb: "while" }],
  };
  assert.equal(
    gradeCommand(loose, "while true; do curl localhost:8081; done").passed,
    true,
  );
});

test("prose grading is case-insensitive and needs every term", () => {
  const task: AnswerTask = {
    id: "3",
    prompt: "surge behaviour",
    grader: "prose",
    must_include: ["25", "maxSurge", "maxUnavailable"],
    hints: [{ when: "no-numbers", text: "Name the actual defaults." }],
  };
  assert.equal(
    gradeProse(task, "RollingUpdate: 25% maxsurge and 25% maxunavailable")
      .passed,
    true,
  );
  const missing = gradeProse(
    task,
    "It rolls pods gradually using maxSurge and maxUnavailable",
  );
  assert.equal(missing.passed, false);
  assert.equal(missing.hint, "no-numbers");
  assert.match(missing.message, /Name the actual defaults/);
});

test("file grading reads a dotted key out of YAML", () => {
  const task: AnswerTask = {
    id: "2",
    prompt: "bump the tag",
    grader: "file",
    path: "helm/practice-app/values.yaml",
    key: "frontend.image.tag",
    accept_pattern: "^1\\.28-alpine$",
    hints: [{ when: "unchanged", text: "values.yaml still says 1.27-alpine." }],
  };
  const before =
    "frontend:\n  image:\n    repository: nginx\n    tag: 1.27-alpine\n";
  const after =
    "frontend:\n  image:\n    repository: nginx\n    tag: 1.28-alpine\n";
  assert.equal(gradeFile(task, after).passed, true);
  const v = gradeFile(task, before);
  assert.equal(v.passed, false);
  assert.equal(v.hint, "unchanged");
});

test("file grading reports a missing key rather than crashing", () => {
  const task: AnswerTask = {
    id: "2",
    prompt: "bump the tag",
    grader: "file",
    path: "x.yaml",
    key: "frontend.image.tag",
    accept_pattern: "^1\\.28-alpine$",
  };
  const v = gradeFile(task, "backend:\n  replicas: 1\n");
  assert.equal(v.passed, false);
  assert.match(v.message, /frontend\.image\.tag/);
});

test("file grading survives unparseable YAML", () => {
  const task: AnswerTask = {
    id: "2",
    prompt: "p",
    grader: "file",
    path: "x.yaml",
    key: "a.b",
    accept_pattern: "^c$",
  };
  const v = gradeFile(task, "\tthis: is: not: yaml:\n  - [unclosed\n");
  assert.equal(v.passed, false);
  assert.match(v.message, /could not be parsed/i);
});

test("grade() dispatches on the grader kind", () => {
  assert.equal(
    grade(
      rolloutTask,
      "kubectl -n practice-app get deploy practice-app-frontend",
    ).passed,
    true,
  );
});

test("a verdict always carries the task id", () => {
  for (const v of [
    gradeCommand(rolloutTask, "nonsense"),
    gradeProse(
      { id: "3", prompt: "p", grader: "prose", must_include: ["x"] },
      "y",
    ),
  ]) {
    assert.ok(v.taskId.length > 0);
  }
});
