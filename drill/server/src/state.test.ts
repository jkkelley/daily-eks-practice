import { test } from "node:test";
import assert from "node:assert/strict";
import type { Attempt, SessionState } from "@drill/shared";
import type { K8sStateWriter } from "./integrations/k8s.ts";
import {
  createStateStore,
  fitToConfigMap,
  MAX_STATE_BYTES,
  saveQuietly,
  STATE_CONFIGMAP,
  STATE_KEY,
} from "./state.ts";

function writes(): {
  writer: K8sStateWriter;
  seen: { name: string; ns: string; data: Record<string, string> }[];
} {
  const seen: { name: string; ns: string; data: Record<string, string> }[] = [];
  return {
    seen,
    writer: {
      async writeConfigMap(name, ns, data) {
        seen.push({ name, ns, data });
      },
    },
  };
}

function attempt(i: number, submitted = "kubectl get pods"): Attempt {
  return {
    taskId: "t1",
    at: `2026-08-21T00:00:${String(i % 60).padStart(2, "0")}.000Z`,
    submitted,
    passed: i % 3 === 0,
    message: "ok",
  };
}

function session(attempts: Attempt[] = []): SessionState {
  return {
    scenario: "03",
    sessionId: "2026-08-21T19-00-00Z",
    startedAt: "2026-08-21T19:00:00.000Z",
    currentTaskId: "t2",
    passed: ["t1"],
    attempts,
    phase: "active",
  };
}

test("an ordinary session round-trips whole", () => {
  const s = session([attempt(1), attempt(2)]);
  const { payload } = fitToConfigMap(s);

  assert.deepEqual(payload.attempts, s.attempts);
  assert.equal(payload.attemptsDropped, undefined);
  assert.equal(payload.phase, "active");
});

test("the phase and the switch target survive the mirror", () => {
  const s: SessionState = { ...session(), phase: "switching", target: "06" };
  const { payload } = fitToConfigMap(s);

  assert.equal(payload.phase, "switching");
  assert.equal(payload.target, "06");
});

test("an oversized session is trimmed to fit, keeping the NEWEST attempts", () => {
  // Big enough to blow the cap several times over. A learner will never do this;
  // a stuck client retrying a submit will.
  const many = Array.from({ length: 4000 }, (_, i) =>
    attempt(i, "x".repeat(400)),
  );
  const { payload, encoded } = fitToConfigMap(session(many));

  assert.ok(
    Buffer.byteLength(encoded, "utf8") <= MAX_STATE_BYTES,
    `trimmed payload is ${Buffer.byteLength(encoded, "utf8")} bytes, over the cap`,
  );
  assert.ok(
    payload.attempts.length > 0,
    "it trimmed to nothing rather than to a fit",
  );
  assert.ok(
    (payload.attemptsDropped ?? 0) > 0,
    "the drop was recorded, not silent",
  );

  // The tail is what a resume needs and what the only-imperative nudge reads.
  const lastKept = payload.attempts[payload.attempts.length - 1];
  assert.deepEqual(
    lastKept,
    many[many.length - 1],
    "the most recent attempt survived",
  );

  assert.equal(
    payload.attempts.length + (payload.attemptsDropped ?? 0),
    many.length,
    "kept + dropped accounts for every attempt, so the count can be trusted",
  );
});

test("a state that fits reports no drop at all, rather than zero", () => {
  // `attemptsDropped: 0` and "no attempts dropped" must not be spelled
  // differently in a payload another process branches on.
  const { payload, encoded } = fitToConfigMap(session([attempt(1)]));
  assert.equal(payload.attemptsDropped, undefined);
  assert.ok(!encoded.includes("attemptsDropped"));
});

test("save writes one key on the drill-state ConfigMap in the right namespace", async () => {
  const { writer, seen } = writes();
  await createStateStore(writer, "practice-drill").save(session([attempt(1)]));

  assert.equal(seen.length, 1);
  const write = seen[0]!;
  assert.equal(write.name, STATE_CONFIGMAP);
  assert.equal(write.ns, "practice-drill");
  assert.deepEqual(Object.keys(write.data), [STATE_KEY]);

  const back = JSON.parse(write.data[STATE_KEY]!) as SessionState;
  assert.equal(back.scenario, "03");
  assert.equal(back.sessionId, "2026-08-21T19-00-00Z");
});

test("a writer that throws does not take the submit down with it", async () => {
  const logged: string[] = [];
  const exploding: K8sStateWriter = {
    async writeConfigMap() {
      throw new Error("etcdserver: request timed out");
    },
  };

  await saveQuietly(
    createStateStore(exploding, "practice-drill"),
    session(),
    (m) => logged.push(m),
  );

  assert.equal(
    logged.length,
    1,
    "the failure was logged rather than swallowed",
  );
  assert.match(
    logged[0]!,
    /request timed out/,
    "the real cause reached the log",
  );
  assert.match(
    logged[0]!,
    /progress is not being saved/,
    "and the log says what it MEANS, not just what threw",
  );
});

test("no store at all is a no-op, because drill-dev has no cluster", async () => {
  const logged: string[] = [];
  await saveQuietly(undefined, session(), (m) => logged.push(m));
  assert.deepEqual(
    logged,
    [],
    "running without a cluster is normal, not a warning",
  );
});
