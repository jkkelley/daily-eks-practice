import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "./server.ts";
import type { FastifyInstance } from "fastify";

const WEB_ROOT = new URL("../test-fixtures/web", import.meta.url).pathname;
const ANSWERS_DIR = new URL("../../../scenarios/answers", import.meta.url)
  .pathname;
const WORKSPACE = new URL("../test-fixtures/workspace", import.meta.url)
  .pathname;

/** The terminal log never goes near the workspace; these tests never open one. */
const LOG_DIR = join(tmpdir(), "drill-server-test-logs");

let app: FastifyInstance;

before(async () => {
  app = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: WORKSPACE,
    logDir: LOG_DIR,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
  });
});

after(async () => {
  await app.close();
});

test("healthz is up", async () => {
  const res = await app.inject({ method: "GET", url: "/healthz" });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json(), { ok: true });
});

test("tasks are served without the answers", async () => {
  const res = await app.inject({ method: "GET", url: "/api/tasks" });
  assert.equal(res.statusCode, 200);
  const tasks = res.json() as Array<Record<string, unknown>>;
  assert.equal(tasks.length, 6);
  for (const t of tasks) {
    assert.ok(t.prompt, "task keeps its prompt");
    assert.equal(t.answer, undefined, "task must NOT carry the answer");
    assert.equal(t.accept, undefined, "task must NOT carry the accept rules");
    assert.equal(t.must_include, undefined, "task must NOT carry must_include");
    assert.equal(
      t.accept_pattern,
      undefined,
      "task must NOT carry accept_pattern",
    );
  }
});

test("the card panel gets the scenario's own text and no tasks with it", async () => {
  const res = await app.inject({ method: "GET", url: "/api/scenario" });
  assert.equal(res.statusCode, 200);
  const meta = res.json() as Record<string, unknown>;
  assert.equal(meta.scenario, "03");
  assert.equal(meta.title, "Rolling update + rollback");
  assert.ok(meta.ticket, "the card's ticket text is what the help panel shows");
  assert.equal(meta.tasks, undefined, "tasks have their own route");
  assert.ok(
    !JSON.stringify(meta).includes("accept_pattern"),
    "the answer key must not ride along on the metadata",
  );
});

test("hints are not served up front either", async () => {
  const res = await app.inject({ method: "GET", url: "/api/tasks" });
  for (const t of res.json() as Array<Record<string, unknown>>) {
    assert.equal(
      t.hints,
      undefined,
      "hints arrive with a verdict, not in the task list",
    );
  }
});

test("a file task tells the editor which file to open, and nothing more", async () => {
  const tasks = (
    await app.inject({ method: "GET", url: "/api/tasks" })
  ).json() as Array<Record<string, unknown>>;
  const fileTask = tasks.find((t) => t.grader === "file");
  assert.ok(fileTask, "scenario 03 has a file task");
  assert.equal(fileTask.path, "helm/practice-app/values.yaml");
  assert.equal(fileTask.key, undefined, "the graded key is not the browser's");
});

test("a correct submission grades as passed", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: {
      taskId: "1",
      answer:
        "kubectl -n practice-app rollout history deploy/practice-app-frontend",
    },
  });
  assert.equal(res.statusCode, 200);
  assert.equal(res.json().passed, true);
});

test("a wrong submission returns the hint, not the answer", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: {
      taskId: "1",
      answer: "kubectl rollout history deploy/practice-app-frontend",
    },
  });
  const verdict = res.json();
  assert.equal(verdict.passed, false);
  assert.equal(verdict.hint, "missing-namespace");
  assert.ok(
    !JSON.stringify(verdict).includes("jsonpath"),
    "the canonical answer must not leak in a verdict",
  );
});

test("an unknown task id is a 404, not a crash", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: { taskId: "99", answer: "x" },
  });
  assert.equal(res.statusCode, 404);
});

test("session state starts at the first task with nothing passed", async () => {
  const fresh = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: WORKSPACE,
    logDir: LOG_DIR,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
  });
  const state = (
    await fresh.inject({ method: "GET", url: "/api/session" })
  ).json();
  assert.equal(state.scenario, "03");
  assert.equal(state.currentTaskId, "1");
  assert.deepEqual(state.passed, []);
  await fresh.close();
});

test("a submission is recorded as an attempt whether it passed or not", async () => {
  await app.inject({
    method: "POST",
    url: "/api/submit",
    payload: { taskId: "1", answer: "nonsense" },
  });
  const state = (
    await app.inject({ method: "GET", url: "/api/session" })
  ).json();
  assert.ok(
    state.attempts.length > 0,
    "attempts are append-only, including failures",
  );
});

// --- GradeContext: the two facts a submission cannot carry ---------------------
//
// CONTEXT_STATE records that the server is what supplies these: `accepted` from
// SessionState.attempts, `committed` from cluster git. The grader is a pure
// function and cannot look either up, so if the server does not pass them, two
// hints that scenario 03 authored can never fire and nothing else goes red.

test("only-imperative fires on the first kubectl rollback and stops once the git half lands", async () => {
  const s = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: WORKSPACE,
    logDir: LOG_DIR,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
  });
  const submit = (answer: string) =>
    s
      .inject({
        method: "POST",
        url: "/api/submit",
        payload: { taskId: "5", answer },
      })
      .then((r) => r.json());

  const imperative =
    "kubectl -n practice-app rollout undo deploy/practice-app-frontend";

  const first = await submit(imperative);
  assert.equal(first.passed, true, "rollout undo IS the right rollback");
  assert.equal(first.hint, "only-imperative", "and it is only half the answer");

  const gitHalf = await submit("git revert 1a2b3c4");
  assert.equal(gitHalf.passed, true);
  assert.equal(gitHalf.hint, undefined);

  const again = await submit(imperative);
  assert.equal(again.passed, true);
  assert.equal(
    again.hint,
    undefined,
    "the session already did it the GitOps way - nudging again would be noise",
  );
  await s.close();
});

test("a file task grades the workspace on disk, not what was typed", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-ws-"));
  await mkdir(join(dir, "helm/practice-app"), { recursive: true });
  await writeFile(
    join(dir, "helm/practice-app/values.yaml"),
    "frontend:\n  image:\n    tag: 1.28-alpine\n",
  );
  const s = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: dir,
    logDir: LOG_DIR,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
  });
  const verdict = (
    await s.inject({
      method: "POST",
      url: "/api/submit",
      payload: { taskId: "2", answer: "" },
    })
  ).json();
  assert.equal(verdict.passed, true, "the file really says 1.28-alpine");
  await s.close();
});

test("an unedited workspace file fails with the unchanged hint", async () => {
  const verdict = (
    await app.inject({
      method: "POST",
      url: "/api/submit",
      payload: { taskId: "2", answer: "" },
    })
  ).json();
  assert.equal(verdict.passed, false);
  assert.equal(verdict.hint, "unchanged");
});

test("a right-but-uncommitted file is graded against cluster git, not the workspace", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-ws-"));
  await mkdir(join(dir, "helm/practice-app"), { recursive: true });
  await writeFile(
    join(dir, "helm/practice-app/values.yaml"),
    "frontend:\n  image:\n    tag: 1.28-alpine\n",
  );
  const s = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: dir,
    logDir: LOG_DIR,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
    // Cluster git is still on the old tag, which is what Argo CD would sync.
    readCommitted: async () => "frontend:\n  image:\n    tag: 1.27-alpine\n",
  });
  const verdict = (
    await s.inject({
      method: "POST",
      url: "/api/submit",
      payload: { taskId: "2", answer: "" },
    })
  ).json();
  assert.equal(verdict.passed, false, "edited is not deployed");
  assert.equal(verdict.hint, "uncommitted");
  await s.close();
});

test("no reader means commit state is not graded at all, never graded as false", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-ws-"));
  await mkdir(join(dir, "helm/practice-app"), { recursive: true });
  await writeFile(
    join(dir, "helm/practice-app/values.yaml"),
    "frontend:\n  image:\n    tag: 1.28-alpine\n",
  );
  const s = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: dir,
    logDir: LOG_DIR,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
    readCommitted: async () => undefined,
  });
  const verdict = (
    await s.inject({
      method: "POST",
      url: "/api/submit",
      payload: { taskId: "2", answer: "" },
    })
  ).json();
  assert.equal(verdict.passed, true, "absent means not known, never false");
  await s.close();
});

// --- the editor's file access ---------------------------------------------------

test("the editor can read the file its task names", async () => {
  const res = await app.inject({
    method: "GET",
    url: "/api/file?path=helm/practice-app/values.yaml",
  });
  assert.equal(res.statusCode, 200);
  assert.match(res.json().content, /1\.27-alpine/);
});

test("the explorer gets the workspace tree", async () => {
  const res = await app.inject({ method: "GET", url: "/api/tree" });
  assert.equal(res.statusCode, 200);
  const tree = res.json() as Array<{
    name: string;
    path: string;
    type: string;
  }>;
  const walk = (nodes: Array<{ path: string; children?: unknown }>): string[] =>
    nodes.flatMap((n) => [
      n.path,
      ...walk(
        (n.children ?? []) as Array<{ path: string; children?: unknown }>,
      ),
    ]);
  assert.ok(
    walk(tree).includes("helm/practice-app/values.yaml"),
    "the file every drill opens is not in the tree",
  );
});

test("the source control view gets a status, repo or no repo", async () => {
  const res = await app.inject({ method: "GET", url: "/api/git/status" });
  assert.equal(res.statusCode, 200);
  const status = res.json() as { repo: boolean; files: unknown[] };
  // The fixture workspace is a plain directory, not a clone. The route must still
  // answer - a missing repo is a state the panel renders, not a failed request.
  assert.equal(status.repo, false);
  assert.deepEqual(status.files, []);
});

test("the editor cannot read its way out of the workspace", async () => {
  for (const path of ["../../../etc/passwd", "/etc/passwd", ".git/config"]) {
    const res = await app.inject({
      method: "GET",
      url: `/api/file?path=${encodeURIComponent(path)}`,
    });
    assert.equal(res.statusCode, 400, `${path} was not refused`);
    assert.ok(!res.body.includes("root:"), `${path} leaked a file`);
  }
});

test("asking for no path at all is a 400, not a directory read", async () => {
  const res = await app.inject({ method: "GET", url: "/api/file" });
  assert.equal(res.statusCode, 400);
});

// --- the SPA fallback ----------------------------------------------------------

test("a browser navigation falls back to index.html but a missing api path stays 404", async () => {
  const page = await app.inject({ method: "GET", url: "/some/deep/route" });
  assert.equal(page.statusCode, 200);
  assert.match(page.body, /fixture/);

  const api = await app.inject({ method: "GET", url: "/api/nope" });
  assert.equal(api.statusCode, 404);
});

test("the answers directory is not reachable through the static route", async () => {
  // A 200 here is fine and expected - it is the SPA shell. What must never happen
  // is the answer key coming back, however the path is spelled.
  const traversals = [
    "/../../scenarios/answers/03.toml",
    "/%2e%2e%2f%2e%2e%2fscenarios%2fanswers%2f03.toml",
    "/..%2f..%2fscenarios/answers/03.toml",
  ];
  for (const url of traversals) {
    const res = await app.inject({ method: "GET", url });
    assert.ok(
      !res.body.includes("accept_pattern"),
      `${url} served the answer key`,
    );
  }
  // And prove the file being reached for really does hold the key, so these
  // assertions cannot pass merely because the path was wrong.
  const real = await readFile(join(ANSWERS_DIR, "03.toml"), "utf8");
  assert.match(real, /accept_pattern/);
});

// ---------------------------------------------------------------------------
// The pause menu's lifecycle routes.
//
// These are the only routes in this server that mutate. That is not a new
// exposure - the terminal beside them is a cluster-admin shell - but it IS a
// change in the shape of the API, and one of them can end in `terraform
// destroy`, so the assertions here are about the boundary rather than the happy
// path.
// ---------------------------------------------------------------------------

test("the menu lists the whole curriculum, marking what is ported and where you are", async () => {
  const res = await app.inject({ method: "GET", url: "/api/scenarios" });
  assert.equal(res.statusCode, 200);
  const rows = res.json() as {
    id: string;
    title: string;
    ported: boolean;
    current: boolean;
  }[];

  assert.ok(rows.length >= 12, "all twelve, not just the ported one");
  assert.equal(rows.filter((r) => r.current).length, 1, "exactly one is current");
  assert.ok(rows.find((r) => r.id === "03")?.current);
  assert.ok(rows.find((r) => r.id === "07") && !rows.find((r) => r.id === "07")!.ported);
});

test("the menu never carries anything from inside an answers file", async () => {
  // Same rule as /api/tasks, and it needs its own guard because this route reads
  // a file that lives in the same directory as the answer key.
  const body = (await app.inject({ method: "GET", url: "/api/scenarios" })).body;
  for (const leak of ["accept", "answer", "hint", "expect", "verb"]) {
    assert.ok(!body.includes(`"${leak}"`), `/api/scenarios leaked ${leak}`);
  }
});

test("restart starts a new session on the same scenario", async () => {
  const before = (await app.inject({ method: "GET", url: "/api/session" })).json() as {
    sessionId: string;
  };

  const res = await app.inject({ method: "POST", url: "/api/session/restart" });
  assert.equal(res.statusCode, 200);

  const after = (await app.inject({ method: "GET", url: "/api/session" })).json() as {
    scenario: string;
    sessionId: string;
    passed: string[];
    phase: string;
  };
  assert.equal(after.scenario, "03", "same scenario");
  assert.notEqual(after.sessionId, before.sessionId, "different session");
  assert.deepEqual(after.passed, [], "and a clean slate");
  assert.equal(after.phase, "active");
});

test("a session id is a legal directory name on Windows", async () => {
  // The laptop turns this straight into a directory under drill-progress/, and
  // Windows 11 is a supported target there. A colon here creates a save
  // directory that cannot be created on half this project's audience's machines.
  const { sessionId } = (
    await app.inject({ method: "POST", url: "/api/session/restart" })
  ).json() as { sessionId: string };

  assert.ok(!/[<>:"/\\|?*]/.test(sessionId), `illegal character in ${sessionId}`);
  assert.match(sessionId, /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z$/);
});

test("switching to a scenario that is not ported is refused, by name", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/session/switch",
    payload: { target: "07" },
  });
  assert.equal(res.statusCode, 409);
  const { error } = res.json() as { error: string };
  assert.match(error, /07/, "the refusal names the scenario");
  assert.match(error, /Observability/, "...and its title, so it is actionable");
  assert.match(error, /not ported/);
});

test("switching to a scenario that does not exist is a 400, not a hang", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/api/session/switch",
    payload: { target: "99" },
  });
  assert.equal(res.statusCode, 400);
});

test("quitting ends the session without pretending to have torn anything down", async () => {
  const res = await app.inject({ method: "POST", url: "/api/session/quit" });
  assert.equal(res.statusCode, 200);

  const state = (await app.inject({ method: "GET", url: "/api/session" })).json() as {
    phase: string;
    endedAt?: string;
  };
  assert.equal(state.phase, "ended");
  assert.ok(state.endedAt, "stamped when");
});

test("tearing down demands the exact word, and the SERVER is what checks it", async () => {
  // The browser asks for it too, and that is the friendly copy. This route is
  // the boundary, and it is the one route in this repo that can end in
  // `terraform destroy` - see CLAUDE.md hard rule 1 and the exception in it.
  for (const payload of [{}, { confirm: "" }, { confirm: "destroy" }, { confirm: "DESTROY " }, { confirm: "yes" }]) {
    const res = await app.inject({
      method: "POST",
      url: "/api/session/destroy",
      payload,
    });
    assert.equal(
      res.statusCode,
      400,
      `confirm=${JSON.stringify(payload)} must not arm a teardown`,
    );
  }

  const ok = await app.inject({
    method: "POST",
    url: "/api/session/destroy",
    payload: { confirm: "DESTROY" },
  });
  assert.equal(ok.statusCode, 200);

  const state = (await app.inject({ method: "GET", url: "/api/session" })).json() as {
    phase: string;
  };
  assert.equal(
    state.phase,
    "destroy-requested",
    "the pod records an INTENT - it never destroys anything itself",
  );
});
