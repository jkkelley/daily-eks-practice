import { test } from "node:test";
import assert from "node:assert/strict";
import type { K8sReader } from "./integrations/k8s.ts";
import {
  parseRequest,
  readRequest,
  watchRequest,
  REQUEST_CONFIGMAP,
  REQUEST_KEY,
} from "./request.ts";

/** A reader over a mutable ConfigMap, so a test can change what the laptop asked for. */
function reader(box: {
  data?: Record<string, string>;
  throws?: boolean;
  reads?: number;
}): K8sReader {
  return {
    readCustomObject: async () => undefined,
    readDeployment: async () => undefined,
    readEndpoints: async () => undefined,
    readConfigMap: async (name) => {
      box.reads = (box.reads ?? 0) + 1;
      if (box.throws) throw new Error("the apiserver is having a moment");
      return name === REQUEST_CONFIGMAP ? box.data : undefined;
    },
  };
}

const req = (scenario: string, sessionId: string): Record<string, string> => ({
  [REQUEST_KEY]: JSON.stringify({ scenario, sessionId }),
});

test("a well-formed request parses", () => {
  const r = parseRequest(req("06", "2026-08-21T19-00-00Z"));
  assert.equal(r?.scenario, "06");
  assert.equal(r?.sessionId, "2026-08-21T19-00-00Z");
});

test("every unusable request answers undefined, not an exception", () => {
  // Absent, empty, malformed and structurally wrong are folded together on
  // purpose: the only sensible response to any of them is "keep running the
  // session you already have", and a distinction with no different behaviour
  // behind it is a branch waiting to be got wrong.
  assert.equal(parseRequest(undefined), undefined, "no ConfigMap at all");
  assert.equal(parseRequest({}), undefined, "ConfigMap with no key");
  assert.equal(parseRequest({ [REQUEST_KEY]: "" }), undefined, "empty value");
  assert.equal(
    parseRequest({ [REQUEST_KEY]: "{ half-written" }),
    undefined,
    "a torn write must never take a live drill down",
  );
  assert.equal(
    parseRequest({ [REQUEST_KEY]: "[]" }),
    undefined,
    "not an object",
  );
  assert.equal(
    parseRequest({ [REQUEST_KEY]: '{"scenario":"06"}' }),
    undefined,
    "a request with no session id is not a request",
  );
  assert.equal(
    parseRequest({ [REQUEST_KEY]: '{"sessionId":"x"}' }),
    undefined,
    "...and neither is one with no scenario",
  );
});

test("only the four known fields survive parsing", () => {
  const r = parseRequest({
    [REQUEST_KEY]: JSON.stringify({
      scenario: "03",
      sessionId: "s1",
      requestedAt: "2026-08-21T19:00:00Z",
      restoredFrom: "drill-progress/03/sessions/s0/workspace.bundle",
      somethingTheLaptopGrowsLater: "must not appear",
    }),
  });
  assert.deepEqual(Object.keys(r ?? {}).sort(), [
    "requestedAt",
    "restoredFrom",
    "scenario",
    "sessionId",
  ]);
});

test("readRequest asks for the right ConfigMap", async () => {
  const box = { data: req("03", "s1") };
  assert.equal(
    (await readRequest(reader(box), "practice-drill"))?.scenario,
    "03",
  );
});

test("the watcher fires on a NEW session id, not on a new scenario", async () => {
  // Restarting scenario 03 asks for the same scenario and a different session.
  // A comparison on scenario alone would silently ignore every restart, which is
  // one of the two most-used entries on the pause menu.
  const box = { data: req("03", "s1") };
  const seen: string[] = [];
  const stop = watchRequest(
    reader(box),
    "practice-drill",
    "s1",
    (r) => void seen.push(r.sessionId),
    { intervalMs: 5 },
  );

  await new Promise((r) => setTimeout(r, 40));
  assert.deepEqual(
    seen,
    [],
    "the request that STARTED this session is not a new one",
  );

  box.data = req("03", "s2");
  await new Promise((r) => setTimeout(r, 40));
  stop();

  assert.deepEqual(
    seen,
    ["s2"],
    "the same scenario with a new session id fires once",
  );
});

test("a repeated request fires exactly once, not on every poll", async () => {
  const box = { data: req("06", "s9") };
  const seen: string[] = [];
  const stop = watchRequest(
    reader(box),
    "practice-drill",
    undefined,
    (r) => void seen.push(r.sessionId),
    { intervalMs: 5 },
  );
  await new Promise((r) => setTimeout(r, 60));
  stop();

  assert.deepEqual(
    seen,
    ["s9"],
    "converging once per request, not once per tick",
  );
});

test("an API error is reported and then ignored - the drill keeps running", async () => {
  const box: { data?: Record<string, string>; throws?: boolean } = {
    data: req("03", "s1"),
    throws: true,
  };
  const errors: unknown[] = [];
  const seen: string[] = [];
  const stop = watchRequest(
    reader(box),
    "practice-drill",
    undefined,
    (r) => void seen.push(r.sessionId),
    { intervalMs: 5, onError: (e) => errors.push(e) },
  );

  await new Promise((r) => setTimeout(r, 30));
  assert.ok(errors.length > 0, "the failure was surfaced");
  assert.deepEqual(seen, [], "and nothing was converged on a failed read");

  // The learner is mid-task. A transient read failure is not a reason to do
  // anything at all - the next tick is moments away, and it recovers by itself.
  box.throws = false;
  await new Promise((r) => setTimeout(r, 40));
  stop();
  assert.deepEqual(seen, ["s1"], "it recovered without being restarted");
});

test("stopping actually stops it", async () => {
  const box = { data: req("03", "s1"), reads: 0 };
  const stop = watchRequest(reader(box), "practice-drill", "s1", () => {}, {
    intervalMs: 5,
  });
  await new Promise((r) => setTimeout(r, 30));
  stop();
  const after = box.reads;
  await new Promise((r) => setTimeout(r, 40));

  assert.equal(
    box.reads,
    after,
    "no reads after stop - a stopped watcher is stopped",
  );
});
