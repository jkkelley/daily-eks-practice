/**
 * The GUI's half of the idle clock, tested here because the web workspace runs no
 * unit tests and this is not logic anyone should be checking only by looking at it.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import type { SessionState } from "@drill/shared";
import { idleView, humanDuration, clockDuration } from "@drill/shared";

const T0 = Date.parse("2026-08-22T12:00:00.000Z");

function session(over: Partial<SessionState> = {}): SessionState {
  return {
    scenario: "03",
    sessionId: "s1",
    startedAt: new Date(T0).toISOString(),
    currentTaskId: "t1",
    passed: [],
    attempts: [],
    phase: "active",
    lastActivityAt: new Date(T0).toISOString(),
    idle: { timeoutSeconds: 300, action: "destroy", warnSeconds: 120 },
    ...over,
  };
}

test("the countdown runs down from the last human input", () => {
  const s = session();
  assert.equal(idleView(s, T0)?.secondsLeft, 300);
  assert.equal(idleView(s, T0 + 60_000)?.secondsLeft, 240);
  assert.equal(idleView(s, T0 + 299_000)?.secondsLeft, 1);
});

test("the banner turns on inside the warn window and not before", () => {
  const s = session();
  assert.equal(idleView(s, T0)?.warning, false);
  assert.equal(idleView(s, T0 + 179_000)?.warning, false);
  assert.equal(
    idleView(s, T0 + 180_000)?.warning,
    true,
    "at exactly the window",
  );
  assert.equal(idleView(s, T0 + 290_000)?.warning, true);
});

test("it never goes negative - zero is the floor", () => {
  const s = session();
  assert.equal(idleView(s, T0 + 900_000)?.secondsLeft, 0);
});

test("no policy, no stamp and no parseable stamp all render nothing", () => {
  // Three different situations, one correct response: show no countdown. What
  // must NOT happen is any of them being treated as "the deadline has passed".
  // Built by deleting rather than by assigning `undefined`: under
  // `exactOptionalPropertyTypes` those are different statements, and "absent" is
  // the one the watcher and this function both actually reason about.
  const noPolicy = session();
  delete noPolicy.idle;
  assert.equal(idleView(noPolicy, T0), null);

  const noStamp = session();
  delete noStamp.lastActivityAt;
  assert.equal(idleView(noStamp, T0), null);

  assert.equal(
    idleView(session({ lastActivityAt: "some time ago" }), T0),
    null,
  );
  assert.equal(idleView(null, T0), null);
});

test("a non-active phase shows no countdown", () => {
  // A switch or a game-over screen is already saying what happened. A teardown
  // countdown on top of it is noise, and on `destroy-requested` it would be
  // counting down to something that is already under way.
  for (const phase of ["switching", "ended", "destroy-requested"] as const) {
    assert.equal(
      idleView(session({ phase }), T0 + 290_000),
      null,
      `phase ${phase} should render no countdown`,
    );
  }
});

test("warn mode is carried through, because the copy differs on it", () => {
  const warn = session({
    idle: { timeoutSeconds: 300, action: "warn", warnSeconds: 120 },
  });
  assert.equal(idleView(warn, T0 + 290_000)?.action, "warn");
  assert.equal(idleView(session(), T0 + 290_000)?.action, "destroy");
});

test("the two duration formats agree with what drill-watch.py prints", () => {
  // The watcher prints `5m30s` and the status bar shows `5:30`. They are read
  // side by side during a drill, so they must describe the same number.
  assert.equal(humanDuration(330), "5m30s");
  assert.equal(humanDuration(300), "5m");
  assert.equal(humanDuration(3600), "1h");
  assert.equal(humanDuration(45), "45s");
  assert.equal(humanDuration(0), "0s");
  assert.equal(humanDuration(-5), "0s");

  assert.equal(clockDuration(330), "5:30");
  assert.equal(clockDuration(300), "5:00");
  assert.equal(clockDuration(9), "0:09");
  assert.equal(clockDuration(-5), "0:00");
});
