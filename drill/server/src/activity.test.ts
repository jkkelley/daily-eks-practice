import { test } from "node:test";
import assert from "node:assert/strict";
import type { SessionState } from "@drill/shared";
import { createActivityTracker, type ActivitySink } from "./activity.ts";

/** A sink that records every mirror write, so "did it write?" is checkable. */
function recordingSink(): ActivitySink & { writes: (string | undefined)[] } {
  const state = { lastActivityAt: undefined } as unknown as SessionState;
  const writes: (string | undefined)[] = [];
  return {
    writes,
    async update(mutate) {
      mutate(state);
      writes.push(state.lastActivityAt);
    },
  };
}

/** A clock the test drives, so nothing here waits on real time. */
function fakeClock(startMs = 1_700_000_000_000) {
  let t = startMs;
  return {
    now: () => new Date(t),
    advance: (ms: number) => {
      t += ms;
    },
  };
}

test("mark() is cheap and does not write - the mirror is on the flush", async () => {
  const sink = recordingSink();
  const clock = fakeClock();
  const tracker = createActivityTracker(sink, { now: clock.now });

  for (let i = 0; i < 500; i++) {
    clock.advance(10);
    tracker.mark();
  }

  // Five hundred keystrokes, zero API writes. This is the whole point of the
  // coalescing: `hub.update` mirrors the entire session into a ConfigMap, so a
  // write per character is a kubectl storm for a value read to the second.
  assert.equal(sink.writes.length, 0);

  assert.equal(await tracker.flush(), true);
  assert.equal(sink.writes.length, 1);
  assert.equal(sink.writes[0], tracker.lastActivityAt());
  tracker.stop();
});

test("a flush with nothing new does not write", async () => {
  const sink = recordingSink();
  const clock = fakeClock();
  const tracker = createActivityTracker(sink, { now: clock.now });

  tracker.mark();
  assert.equal(await tracker.flush(), true);

  // Nobody typed. Writing again would advance nothing and cost an API call, and
  // - far worse - a mirror that keeps writing while nobody is here is a mirror
  // that could never look idle to anything watching the object's age.
  assert.equal(await tracker.flush(), false);
  assert.equal(sink.writes.length, 1);

  clock.advance(1000);
  tracker.mark();
  assert.equal(await tracker.flush(), true);
  assert.equal(sink.writes.length, 2);
  tracker.stop();
});

test("the stamp moves forward with the clock", async () => {
  const clock = fakeClock();
  const tracker = createActivityTracker(recordingSink(), { now: clock.now });

  const first = tracker.lastActivityAt();
  clock.advance(60_000);
  tracker.mark();
  const second = tracker.lastActivityAt();

  assert.ok(
    Date.parse(second) - Date.parse(first) === 60_000,
    `expected a minute between ${first} and ${second}`,
  );
  tracker.stop();
});

test("a flush that throws does not lose the stamp", async () => {
  // The clock must keep working across an API blip. Marking `mirrored` before the
  // write succeeded would make the next flush a no-op, so one failed write would
  // freeze `lastActivityAt` for as long as the learner kept working - and the
  // watcher would tear the environment down underneath somebody actively typing.
  const clock = fakeClock();
  let fail = true;
  const writes: string[] = [];
  const tracker = createActivityTracker(
    {
      async update(mutate) {
        if (fail) throw new Error("API says no");
        const s = {} as SessionState;
        mutate(s);
        writes.push(s.lastActivityAt as string);
      },
    },
    { now: clock.now },
  );

  tracker.mark();
  await assert.rejects(() => tracker.flush());
  assert.equal(writes.length, 0);

  fail = false;
  assert.equal(
    await tracker.flush(),
    true,
    "the retry must still have work to do",
  );
  assert.equal(writes.length, 1);
  tracker.stop();
});
