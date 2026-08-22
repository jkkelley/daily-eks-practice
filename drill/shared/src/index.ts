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
}

/** One submission. Append-only: nothing here is ever rewritten or deleted. */
export interface Attempt {
  taskId: string;
  at: string;
  submitted: string;
  passed: boolean;
  message: string;
}
