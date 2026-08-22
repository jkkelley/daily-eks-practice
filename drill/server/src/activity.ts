/**
 * When a human last did something, and how that reaches the laptop.
 *
 * The idle clock in `scripts/drill-watch.py` has exactly one input: the
 * `lastActivityAt` this module maintains. Everything about how it is decided
 * lives here, because getting it wrong has two failure modes and both of them
 * are silent.
 *
 * ---- WHAT COUNTS, AND WHY THE ANSWER IS SO NARROW ------------------------
 *
 * Activity is HUMAN INPUT. A keystroke in the terminal, a file saved from the
 * editor, a submission, a hint request. That is the whole list.
 *
 * It is emphatically NOT: the ten-second dependency push, the health probe, the
 * Argo poll, the git status poll, the request poll, or this module's own mirror
 * writes. Every one of those happens whether or not a person is in the room, and
 * counting any of them would mean an abandoned browser tab holds the cluster open
 * forever. The feature would appear to work - the field advances, the state
 * mirrors, every test passes - and it would never once fire. That is the failure
 * this project keeps meeting under different names, and it is the reason the
 * assertion "a dependency push does NOT stamp it" is the load-bearing test.
 *
 * The opposite error is cheaper but real: a terminal resize is not activity. It
 * fires on mount and on any layout change, including ones a browser does on its
 * own, so it would reset the clock for a tab nobody is looking at.
 *
 * ---- WHY IT COALESCES ----------------------------------------------------
 *
 * `hub.update()` mirrors the whole session into a ConfigMap. Stamping on every
 * keystroke would mean an API write per character - a `kubectl` storm from a
 * learner typing a command, for a value the clock only reads to the second.
 *
 * So the timestamp is kept in memory and flushed on an interval, and only when it
 * actually moved. While somebody is working that is one write every
 * `flushIntervalMs`; while nobody is, it is zero writes - and zero is exactly
 * right, because a `lastActivityAt` that stops advancing IS the idle signal.
 */
import type { SessionState } from "@drill/shared";

export interface ActivityTracker {
  /** Call on human input, as often as you like. Cheap: no I/O, no allocation. */
  mark(): void;
  /** The in-memory timestamp, which may be ahead of the mirrored one. */
  lastActivityAt(): string;
  /** Push it into the session if it moved. Returns whether it wrote. */
  flush(): Promise<boolean>;
  stop(): void;
}

export interface ActivityOptions {
  /**
   * How often the in-memory stamp is mirrored. Ten seconds matches the deps push
   * already on this socket, and is an order of magnitude finer than the shortest
   * idle limit anyone would sensibly set.
   */
  flushIntervalMs?: number;
  /** Injected in tests so a clock does not have to be real to be checked. */
  now?: () => Date;
}

export interface ActivitySink {
  update(mutate: (state: SessionState) => void): Promise<void>;
}

export function createActivityTracker(
  sink: ActivitySink,
  opts: ActivityOptions = {},
): ActivityTracker {
  const now = opts.now ?? (() => new Date());
  const interval = opts.flushIntervalMs ?? 10_000;

  let current = now().toISOString();
  let mirrored: string | undefined;

  const flush = async (): Promise<boolean> => {
    if (mirrored === current) return false;
    const pending = current;
    await sink.update((state) => {
      state.lastActivityAt = pending;
    });
    mirrored = pending;
    return true;
  };

  const timer = setInterval(
    () => void flush().catch(() => undefined),
    interval,
  );
  // A drill server is held open by its listening socket, so this only decides
  // whether a test that forgets to stop the tracker hangs rather than fails.
  timer.unref?.();

  return {
    mark() {
      current = now().toISOString();
    },
    lastActivityAt() {
      return current;
    },
    flush,
    stop() {
      clearInterval(timer);
    },
  };
}
