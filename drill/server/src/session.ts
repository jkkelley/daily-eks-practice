/**
 * The live session, and the one place it is allowed to change.
 *
 * Before Phase 6 the session was a plain object created once at startup and read
 * by three call sites. It now changes at runtime - a pass, a restart, a switch to
 * another scenario, a quit - and each change has to reach three places that were
 * never wired for it: the ConfigMap mirror, every open websocket, and the routes.
 *
 * ---- THE STATE OBJECT KEEPS ITS IDENTITY, ALWAYS -------------------------
 *
 * `update` and `converge` MUTATE the state in place and never reassign it. That
 * is not a style preference, it is the contract that keeps the rest working:
 * `registerTerminal` captured this object by reference at startup, and so did
 * every route closure. Swapping in a fresh object would leave the websocket
 * pushing a session that stopped being the real one the moment the learner
 * switched scenario - and it would do it silently, with every test green,
 * because the two objects are structurally identical right up until they differ.
 *
 * `converge` therefore deletes the optional keys by hand rather than trusting a
 * spread to clear them. A stale `target` left on an `active` session puts the
 * browser on a transition screen that will never end.
 */
import type { SessionPhase, SessionState } from "@drill/shared";
import { saveQuietly, type StateStore } from "./state.ts";

export interface ConvergeInput {
  scenario: string;
  sessionId: string;
  firstTaskId: string;
  startedAt?: string;
}

export interface SessionHub {
  /** Always the same object. See the header - do not reassign it. */
  readonly state: SessionState;
  /** Returns an unsubscribe. */
  onChange(fn: (state: SessionState) => void): () => void;
  /** Mutate, then notify every listener and mirror to the ConfigMap. */
  update(mutate: (state: SessionState) => void): Promise<void>;
  /** Start a different scenario, or the same one over again. */
  converge(input: ConvergeInput): Promise<void>;
  setPhase(phase: SessionPhase, target?: string): Promise<void>;
}

export function createSessionHub(
  initial: SessionState,
  store?: StateStore,
): SessionHub {
  const state: SessionState = initial;
  const listeners = new Set<(s: SessionState) => void>();

  const notify = (): void => {
    for (const fn of listeners) {
      // One listener throwing must not stop the others from being told. A dead
      // websocket that has not finished closing is the ordinary case here.
      try {
        fn(state);
      } catch {
        /* a listener's problem, not the session's */
      }
    }
  };

  const hub: SessionHub = {
    state,

    onChange(fn) {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },

    async update(mutate) {
      mutate(state);
      notify();
      await saveQuietly(store, state);
    },

    async converge({ scenario, sessionId, firstTaskId, startedAt }) {
      state.scenario = scenario;
      state.sessionId = sessionId;
      state.startedAt = startedAt ?? new Date().toISOString();
      state.currentTaskId = firstTaskId;
      // A new session starts with nothing passed and nothing attempted. The
      // previous run is not lost - it was mirrored and bundled before the switch
      // was allowed to proceed, which is the ordering drill-watch.py enforces.
      state.passed = [];
      state.attempts = [];
      state.phase = "active";
      delete state.target;
      delete state.endedAt;
      delete state.attemptsDropped;
      notify();
      await saveQuietly(store, state);
    },

    async setPhase(phase, target) {
      state.phase = phase;
      if (target === undefined) delete state.target;
      else state.target = target;
      if (phase === "ended" || phase === "destroy-requested") {
        state.endedAt = new Date().toISOString();
      } else {
        delete state.endedAt;
      }
      notify();
      await saveQuietly(store, state);
    },
  };

  return hub;
}
