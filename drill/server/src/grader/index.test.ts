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

/**
 * AC-H1 and AC-H2 on WO-20260819-a56c, pinned as tests rather than as a one-off
 * observation. The whole argument for a semantic grader is that these hold: a drill
 * that marks one of an equivalent pair wrong is teaching typing, not Kubernetes.
 */
test("AC-H1: the alias form and the spelled-out form get the same verdict", () => {
  const task: AnswerTask = {
    id: "h1",
    prompt: "list the pods",
    grader: "command",
    accept: [{ verb: "get", resource: "pod", namespace: "x" }],
  };
  const short = gradeCommand(task, "k get po -n x");
  const long = gradeCommand(task, "kubectl get pods --namespace x");
  assert.deepEqual(short, long);
  assert.equal(short.passed, true);
});

test("AC-H2: flag order and short-or-long form do not change the verdict", () => {
  const task: AnswerTask = {
    id: "h2",
    prompt: "rollout history",
    grader: "command",
    accept: [
      {
        verb: "rollout-history",
        resource: "deployment",
        namespace: "practice-app",
        name: "practice-app-frontend",
      },
    ],
  };
  const forms = [
    "kubectl rollout history deploy/practice-app-frontend -n practice-app",
    "kubectl -n practice-app rollout history deploy/practice-app-frontend",
    "kubectl rollout history -n practice-app deploy/practice-app-frontend",
    "kubectl rollout history deployment/practice-app-frontend --namespace practice-app",
    "kubectl rollout history deployment practice-app-frontend --namespace=practice-app",
  ];
  const verdicts = forms.map((f) => gradeCommand(task, f));
  for (const [i, v] of verdicts.entries()) {
    assert.equal(v.passed, true, `${forms[i]} -> ${v.message}`);
  }

  // The same equivalence has to hold when the answer is wrong, or a near miss could
  // still be graded by spelling: every one of these is the same wrong answer.
  const wrong = [
    "kubectl rollout history deploy/practice-app-frontend",
    "kubectl rollout history -o wide deploy/practice-app-frontend",
    "kubectl rollout history deployment practice-app-frontend",
  ].map((f) => gradeCommand(task, f));
  for (const v of wrong) {
    assert.deepEqual(v, wrong[0]);
    assert.equal(v.passed, false);
  }
});

/**
 * The two hints that need more than the submission string.
 *
 * `uncommitted` needs the file as cluster git has it; `only-imperative` needs what
 * this session has already got right. Both arrive as an explicit GradeContext, so
 * the graders stay pure functions - the caller does the looking-up, the grader does
 * the deciding.
 */
const bumpTask: AnswerTask = {
  id: "2",
  prompt: "bump the tag and deploy",
  grader: "file",
  path: "helm/practice-app/values.yaml",
  key: "frontend.image.tag",
  accept_pattern: "^1\\.28-alpine$",
  hints: [
    { when: "unchanged", text: "values.yaml still says 1.27-alpine." },
    {
      when: "uncommitted",
      text: "The file is right but the change is not committed, so cluster git has not changed.",
    },
  ],
};
const OLD_TAG = "frontend:\n  image:\n    tag: 1.27-alpine\n";
const NEW_TAG = "frontend:\n  image:\n    tag: 1.28-alpine\n";

const rollbackTask: AnswerTask = {
  id: "5",
  prompt: "roll back two ways",
  grader: "command",
  accept: [
    {
      verb: "rollout-undo",
      resource: "deployment",
      namespace: "practice-app",
      name: "practice-app-frontend",
    },
    { verb: "git-revert" },
  ],
  hints: [
    {
      when: "only-imperative",
      text: "That is the fast way. Now do it the way that survives the next sync.",
    },
  ],
};
const UNDO =
  "kubectl -n practice-app rollout undo deploy/practice-app-frontend";

test("uncommitted fires when the file is right but cluster git has not moved", () => {
  const v = gradeFile(bumpTask, NEW_TAG, { committed: OLD_TAG });
  assert.equal(v.passed, false);
  assert.equal(v.hint, "uncommitted");
  assert.match(v.message, /not committed/);
});

test("the same edit passes once it is committed", () => {
  const v = gradeFile(bumpTask, NEW_TAG, { committed: NEW_TAG });
  assert.equal(v.passed, true);
  assert.equal(v.hint, undefined);
});

test("an uncommitted WRONG file still gets unchanged, not uncommitted", () => {
  // The commit state only matters once the edit itself is right, or the drill would
  // tell you to commit a value it is about to reject.
  const v = gradeFile(bumpTask, OLD_TAG, { committed: OLD_TAG });
  assert.equal(v.hint, "unchanged");
});

test("with no git context the file grader keeps its old verdict", () => {
  assert.equal(gradeFile(bumpTask, NEW_TAG).passed, true);
});

test("only-imperative nudges a pass that is only half the answer", () => {
  const v = gradeCommand(rollbackTask, UNDO);
  assert.equal(v.passed, true, "the imperative rollback IS correct");
  assert.equal(v.hint, "only-imperative");
  assert.match(v.message, /^Correct\./);
  assert.match(v.message, /survives the next sync/);
});

test("the nudge stops once the other half is done", () => {
  const v = gradeCommand(rollbackTask, UNDO, {
    accepted: ["git revert abc123 && git push"],
  });
  assert.equal(v.passed, true);
  assert.equal(v.hint, undefined);
  assert.equal(v.message, "Correct.");
});

test("the git half on its own is never nudged", () => {
  const v = gradeCommand(rollbackTask, "git revert abc123");
  assert.equal(v.passed, true);
  assert.equal(v.hint, undefined);
});

test("a task whose accept rules are mere spellings of each other never nudges", () => {
  // rolloutTask accepts `rollout history` or `get`, which are two ways to see one
  // thing, not two halves of one answer. Nudging there would be noise.
  const v = gradeCommand(
    rolloutTask,
    "kubectl -n practice-app rollout history deploy/practice-app-frontend",
  );
  assert.equal(v.passed, true);
  assert.equal(v.hint, undefined);
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
