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
  | { type: "error"; message: string };

/** One link in the startup dependency chain, surfaced in the GUI's status view. */
export interface DependencyStatus {
  name: "cluster-git" | "argocd" | "practice-app";
  state: "ready" | "starting" | "waiting" | "absent";
  detail: string;
}

/** Live drill state. Mirrored into the drill-state ConfigMap. */
export interface SessionState {
  scenario: string;
  sessionId: string;
  startedAt: string;
  currentTaskId: string;
  passed: string[];
  attempts: Attempt[];
}

/** One submission. Append-only: nothing here is ever rewritten or deleted. */
export interface Attempt {
  taskId: string;
  at: string;
  submitted: string;
  passed: boolean;
  message: string;
}
