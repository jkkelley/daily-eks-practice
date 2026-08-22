import { test } from "node:test";
import assert from "node:assert/strict";
import { loadConfig, DEFAULT_PORT } from "./config.ts";

const paths = {
  DRILL_WEB_ROOT: "/app/web",
  DRILL_ANSWERS_DIR: "/app/scenarios/answers",
  DRILL_WORKSPACE: "/drill/workspace",
  DRILL_LOG_DIR: "/drill/pty",
  DRILL_SCENARIO: "03",
};

test("the port and host have defaults; the paths do not", () => {
  const cfg = loadConfig({ ...paths });
  assert.equal(cfg.port, DEFAULT_PORT);
  assert.equal(cfg.host, "0.0.0.0");
  assert.equal(cfg.webRoot, "/app/web");
  assert.equal(cfg.scenario, "03");
});

test("the pty log lives outside the workspace, so it is not in the learner's git status", () => {
  const cfg = loadConfig({ ...paths });
  assert.ok(
    !cfg.logDir.startsWith(cfg.workspaceDir),
    "the terminal log must not sit inside the cloned repo",
  );
});

test("DRILL_PORT overrides the default", () => {
  assert.equal(loadConfig({ ...paths, DRILL_PORT: "9999" }).port, 9999);
});

test("a missing path is refused by name rather than guessed", () => {
  for (const key of Object.keys(paths)) {
    const env = { ...paths };
    delete (env as Record<string, string>)[key];
    assert.throws(() => loadConfig(env), new RegExp(key), `${key} unguarded`);
  }
});

test("a port that is not a number is refused, not silently NaN", () => {
  assert.throws(
    () => loadConfig({ ...paths, DRILL_PORT: "eight-thousand-and-ninety" }),
    /DRILL_PORT/,
  );
});
