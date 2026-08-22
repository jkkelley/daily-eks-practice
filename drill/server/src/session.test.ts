import { test } from "node:test";
import assert from "node:assert/strict";
import type { SessionState } from "@drill/shared";
import { createSessionHub } from "./session.ts";
import type { StateStore } from "./state.ts";

function initial(): SessionState {
  return {
    scenario: "03",
    sessionId: "s1",
    startedAt: "2026-08-21T19:00:00.000Z",
    currentTaskId: "t1",
    passed: [],
    attempts: [],
    phase: "active",
  };
}

function recorder(): { store: StateStore; saved: SessionState[] } {
  const saved: SessionState[] = [];
  return {
    saved,
    // Snapshotted, because the hub mutates one object - keeping the reference
    // would make every recorded entry the final state and the assertions vacuous.
    store: {
      async save(s) {
        saved.push(structuredClone(s));
      },
    },
  };
}

test("the state object keeps its identity across a converge", async () => {
  // This is THE invariant of this module. registerTerminal captured this object
  // by reference at startup and so did every route closure. Swap it and the
  // websocket pushes a session that stopped being the real one the moment the
  // learner switched scenario - silently, with every other test still green,
  // because the two objects are structurally identical right up until they differ.
  const hub = createSessionHub(initial());
  const captured = hub.state;

  await hub.converge({ scenario: "06", sessionId: "s2", firstTaskId: "a" });

  assert.equal(hub.state, captured, "same object");
  assert.equal(
    captured.scenario,
    "06",
    "and the captured reference sees the change",
  );
});

test("converging clears the previous run rather than carrying it over", async () => {
  const hub = createSessionHub(initial());
  await hub.update((s) => {
    s.passed.push("t1");
    s.attempts.push({
      taskId: "t1",
      at: "2026-08-21T19:01:00.000Z",
      submitted: "kubectl get pods",
      passed: true,
      message: "ok",
    });
  });

  await hub.converge({ scenario: "06", sessionId: "s2", firstTaskId: "a" });

  assert.deepEqual(hub.state.passed, []);
  assert.deepEqual(hub.state.attempts, []);
  assert.equal(hub.state.currentTaskId, "a");
  assert.equal(hub.state.sessionId, "s2");
});

test("converging clears a stale switch target", async () => {
  // A `target` left on an `active` session puts the browser on a transition
  // screen that will never end. `delete` by hand, because a spread cannot clear
  // a key that is not in the object being spread over.
  const hub = createSessionHub(initial());
  await hub.setPhase("switching", "06");
  assert.equal(hub.state.target, "06");

  await hub.converge({ scenario: "06", sessionId: "s2", firstTaskId: "a" });

  assert.equal(hub.state.phase, "active");
  assert.equal(hub.state.target, undefined, "no stale target");
  assert.equal(hub.state.endedAt, undefined, "and no stale end stamp");
});

test("setPhase stamps the terminal phases and only those", async () => {
  const hub = createSessionHub(initial());

  await hub.setPhase("switching", "06");
  assert.equal(hub.state.endedAt, undefined, "switching is not an ending");

  await hub.setPhase("ended");
  assert.ok(hub.state.endedAt, "quitting stamps when");
  assert.equal(hub.state.target, undefined, "and drops the target");

  await hub.setPhase("destroy-requested");
  assert.ok(hub.state.endedAt);
});

test("every change is pushed to listeners and mirrored to the store", async () => {
  const { store, saved } = recorder();
  const hub = createSessionHub(initial(), store);
  const seen: string[] = [];
  hub.onChange((s) => seen.push(s.phase));

  await hub.update((s) => s.passed.push("t1"));
  await hub.setPhase("ended");

  assert.deepEqual(seen, ["active", "ended"]);
  assert.equal(saved.length, 2, "both changes reached the ConfigMap");
  assert.deepEqual(saved[0]!.passed, ["t1"]);
  assert.equal(saved[1]!.phase, "ended");
});

test("unsubscribing stops the pushes", async () => {
  const hub = createSessionHub(initial());
  const seen: string[] = [];
  const off = hub.onChange((s) => seen.push(s.phase));

  await hub.setPhase("switching", "06");
  off();
  await hub.setPhase("ended");

  assert.deepEqual(
    seen,
    ["switching"],
    "a closed socket stops being written to",
  );
});

test("one listener throwing does not stop the others being told", async () => {
  // A websocket that has not finished closing is the ordinary case here, not an
  // exotic one, and a phase change reaching only some of the open tabs would be
  // a genuinely maddening bug to chase.
  const hub = createSessionHub(initial());
  const seen: string[] = [];
  hub.onChange(() => {
    throw new Error("this socket is already gone");
  });
  hub.onChange((s) => seen.push(s.phase));

  await hub.setPhase("ended");
  assert.deepEqual(seen, ["ended"]);
});

test("a store that throws does not take the update down with it", async () => {
  const hub = createSessionHub(initial(), {
    async save() {
      throw new Error("etcdserver: request timed out");
    },
  });
  await hub.update((s) => s.passed.push("t1"));
  assert.deepEqual(hub.state.passed, ["t1"], "the drill carried on");
});
