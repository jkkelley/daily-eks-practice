/**
 * The websocket protocol between the drill GUI's browser half and its server half.
 *
 * Both ends import these types, so adding a message without handling it is a
 * compile error rather than a runtime surprise. Every message is a discriminated
 * union on `type`.
 */

/** Which grader a task uses. Mirrors the `grader` key in scenarios/answers/*.toml. */
export type GraderKind = "command" | "file" | "prose";

/** The result of grading one submission. */
export interface Verdict {
  taskId: string;
  passed: boolean;
  /** Shown to the user. On failure this is the hint, keyed to the misconception. */
  message: string;
  /**
   * Which hint fired, if any. Useful for telling "wrong" from "wrong in a known way".
   *
   * A hint on a `passed: true` verdict is a nudge, not a correction - the answer was
   * right and was only part of what the task asked for, so the UI must still render
   * it as a pass. Scenario 03 task 5's `only-imperative` is the case that exists
   * today: rolling back with kubectl is correct, and Argo CD is about to undo it.
   */
  hint?: string;
}

/** Browser -> server. */
export type ClientMessage =
  | { type: "term:input"; data: string }
  | { type: "term:resize"; cols: number; rows: number }
  | { type: "file:save"; path: string; content: string }
  | { type: "submit"; taskId: string; answer: string }
  | { type: "hint:request"; taskId: string };

/** Server -> browser. */
export type ServerMessage =
  | { type: "term:output"; data: string }
  | { type: "verdict"; verdict: Verdict }
  | { type: "session"; state: SessionState }
  | { type: "deps"; deps: DependencyStatus[] }
  /**
   * The autosave landed on disk. The editor shows the same "saved" indicator VS
   * Code does, and it has to mean the server wrote the file rather than that the
   * browser sent a frame - the two differ exactly when it matters, which is when
   * the save was refused.
   */
  | { type: "file:saved"; path: string }
  | { type: "error"; message: string };

/** One link in the startup dependency chain, surfaced in the GUI's status view. */
export interface DependencyStatus {
  name: "cluster-git" | "argocd" | "practice-app";
  state: "ready" | "starting" | "waiting" | "absent";
  detail: string;
}

/**
 * Where a session is in its lifecycle.
 *
 * This is the channel the pod and the laptop talk through. The server writes it
 * into the `drill-state` ConfigMap; `scripts/drill-watch.py` reads it and is what
 * actually acts on the two terminal phases, because a pod can write an intent but
 * cannot reach a process on somebody's laptop.
 *
 * `destroy-requested` is the drill GUI's `SHUT IT DOWN`, and it is the one
 * sanctioned exception to this repo's rule that a destroy is always driven by
 * hand. Read the exception in CLAUDE.md hard rule 1 before touching anything that
 * produces this value - every clause of it is load-bearing.
 */
export type SessionPhase =
  "active" | "switching" | "ended" | "destroy-requested";

/** Live drill state. Mirrored into the drill-state ConfigMap. */
export interface SessionState {
  scenario: string;
  sessionId: string;
  startedAt: string;
  currentTaskId: string;
  passed: string[];
  attempts: Attempt[];
  phase: SessionPhase;
  /**
   * The scenario being converged to. Set only while `phase` is `switching`.
   *
   * Deliberately separate from `scenario`, which keeps naming the scenario the
   * learner is actually in until the switch completes. Overwriting `scenario` on
   * intent rather than on arrival would make a failed or slow switch look like it
   * had already happened, and the save file would be written under the wrong id.
   */
  target?: string;
  /** Set when the phase became terminal. */
  endedAt?: string;
  /**
   * How many of the oldest attempts were dropped to fit the ConfigMap's 1 MiB cap.
   *
   * Present and non-zero means this mirror is not the whole history. Recorded
   * rather than dropped silently: a save file that quietly is not the whole story
   * is the failure this project has now been bitten by three times.
   */
  attemptsDropped?: number;
  /**
   * When a HUMAN last did something. The idle clock's only input.
   *
   * Stamped by `markActivity` on a keystroke, a save, a submit or a hint request,
   * and by NOTHING else. Deliberately not touched by the dependency push, the
   * health probe, the Argo poll or the state mirror's own writes: if the app's
   * own chatter counted, an abandoned browser tab would hold the cluster open
   * forever and the idle timeout would silently never fire - which looks exactly
   * like the feature being broken, and would be.
   *
   * Absent means "this server does not report it", never "nobody is here". The
   * watcher treats the two differently and must keep doing so.
   */
  lastActivityAt?: string;
  /** Published by the laptop into `drill-request`; mirrored here so the GUI can render it. */
  idle?: IdlePolicyView;
}

/**
 * The idle limit the laptop published, so the GUI can count down to the same second.
 *
 * The pod does not enforce this and must never try to. It renders it - which is
 * the point, because the gate the `SHUT IT DOWN` path gets from a typed
 * confirmation is one the idle path structurally cannot have, and a countdown
 * nobody can see is not a warning. Enforcement lives in `scripts/drill-watch.py`,
 * on the laptop, exactly as it does for every other way this repo destroys
 * anything.
 */
export interface IdlePolicyView {
  timeoutSeconds: number;
  /** `warn` counts down and does nothing. `destroy` runs `make down`. */
  action: "warn" | "destroy";
  /** How long before the deadline the learner starts being told. */
  warnSeconds: number;
}

/** One submission. Append-only: nothing here is ever rewritten or deleted. */
export interface Attempt {
  taskId: string;
  at: string;
  submitted: string;
  passed: boolean;
  message: string;
}


/* ---- the idle clock ------------------------------------------------------
 *
 * Pure, and here rather than in the web app, for two reasons. It is a function of
 * `SessionState` and nothing else, so it belongs beside the type it reads. And the
 * web workspace runs no unit tests, so logic that decides when to tell somebody
 * their environment is about to be destroyed would have had no test home at all -
 * which is exactly the kind of thing that must not be checked only by looking.
 *
 * The countdown is computed from `lastActivityAt` - the SAME field
 * `scripts/drill-watch.py` computes from - rather than from anything the browser
 * knows about its own keystrokes. That is deliberate. The browser has fresher
 * information, and using it would produce a countdown that disagreed with the
 * process actually holding the axe. A warning that says four minutes while the
 * watcher believes three is worse than no warning, because it will be trusted.
 *
 * The cost is that this reads slightly pessimistic - it warns a few seconds EARLY,
 * by up to one mirror flush. That is the safe direction, and the only direction
 * worth being wrong in here.
 */

export interface IdleView {
  /** Inside the warn window: show the banner. */
  warning: boolean;
  secondsLeft: number;
  action: "warn" | "destroy";
  timeoutSeconds: number;
}

/**
 * `null` when there is nothing to show, which covers three different situations
 * that must not be collapsed: no policy published, no activity stamp yet, and a
 * terminal phase where a countdown would be noise on top of a game-over screen.
 */
export function idleView(
  state: SessionState | null,
  now: number = Date.now(),
): IdleView | null {
  if (!state?.idle) return null;
  if (!state.lastActivityAt) return null;
  if (state.phase !== "active") return null;

  const stamped = Date.parse(state.lastActivityAt);
  if (Number.isNaN(stamped)) return null;

  const { timeoutSeconds, warnSeconds, action } = state.idle;
  const secondsLeft = Math.max(
    0,
    Math.round(timeoutSeconds - (now - stamped) / 1000),
  );

  return {
    warning: secondsLeft <= warnSeconds,
    secondsLeft,
    action,
    timeoutSeconds,
  };
}

/** `330` -> `5m30s`, matching what drill-watch.py prints, so the two agree on screen. */
export function humanDuration(seconds: number): string {
  if (seconds <= 0) return "0s";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  let out = h ? `${h}h` : "";
  out += m ? `${m}m` : "";
  if (s || !out) out += `${s}s`;
  return out;
}

/** `330` -> `5:30`. The compact form, for the status bar. */
export function clockDuration(seconds: number): string {
  const m = Math.floor(Math.max(0, seconds) / 60);
  const s = Math.floor(Math.max(0, seconds) % 60);
  return `${m}:${String(s).padStart(2, "0")}`;
}
