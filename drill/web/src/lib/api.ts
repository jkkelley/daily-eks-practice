import type { GraderKind, Verdict } from "@drill/shared";

/**
 * What the server is willing to tell the browser about a task.
 *
 * There is no `answer`, no `accept`, no `accept_pattern` and no `hints` here, and
 * that is not an omission to be tidied up later - GET /api/tasks strips them, and
 * server.test.ts fails if any of them reappears. A hint arrives attached to a
 * verdict, once it has been earned.
 */
export interface PublicTask {
  id: string;
  prompt: string;
  grader: GraderKind;
  /** File tasks only: which file the editor should open. Never the wanted value. */
  path?: string;
}

export interface ScenarioMeta {
  scenario: string;
  title: string;
  time: string;
  needs: string;
  ticket: string;
}

async function json<T>(input: string, init?: RequestInit): Promise<T> {
  const res = await fetch(input, init);
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`${input} -> ${res.status} ${detail.slice(0, 200)}`);
  }
  return (await res.json()) as T;
}

export const getScenario = () => json<ScenarioMeta>("/api/scenario");
export const getTasks = () => json<PublicTask[]>("/api/tasks");

export const getFile = (path: string) =>
  json<{ path: string; content: string }>(
    `/api/file?path=${encodeURIComponent(path)}`,
  );

export const submit = (taskId: string, answer: string) =>
  json<Verdict>("/api/submit", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ taskId, answer }),
  });

/** One entry in the explorer. `path` is workspace-relative and goes straight back to /api/file. */
export interface TreeNode {
  name: string;
  path: string;
  type: "file" | "dir";
  children?: TreeNode[];
}

export const getTree = () => json<TreeNode[]>("/api/tree");

export interface GitFile {
  path: string;
  index: string;
  worktree: string;
  staged: boolean;
  untracked: boolean;
  from?: string;
}

export interface GitStatus {
  repo: boolean;
  branch: string | null;
  ahead: number;
  behind: number;
  files: GitFile[];
}

export const getGitStatus = () => json<GitStatus>("/api/git/status");

/** One row of Argo's resource tree. Argo's own vocabulary, deliberately unnormalised. */
export interface ArgoResource {
  kind: string;
  name: string;
  namespace?: string;
  status: string;
  health?: string;
}

export interface ArgoApplication {
  present: boolean;
  name: string;
  namespace: string;
  sync: string;
  health: string;
  revision: string;
  revisionShort: string;
  message?: string;
  resources: ArgoResource[];
}

export const getArgo = () => json<ArgoApplication>("/api/argo");

// ---------------------------------------------------------------------------
// The pause menu.
//
// These four POSTs are the only calls in this client that change anything. The
// terminal beside them is a cluster-admin shell so it is not new exposure, but
// it IS a different kind of call, and they are kept together rather than sprinkled
// among the reads so that stays obvious.
// ---------------------------------------------------------------------------

/** One entry on the menu. Three fields, and never anything from an answers file. */
export interface ScenarioSlot {
  id: string;
  title: string;
  ported: boolean;
  current: boolean;
}

export const getScenarios = () => json<ScenarioSlot[]>("/api/scenarios");

const post = <T>(url: string, body?: unknown) =>
  json<T>(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });

export const restartSession = () => post<{ ok: true }>("/api/session/restart");

export const switchScenario = (target: string) =>
  post<{ ok: true; target: string }>("/api/session/switch", { target });

export const quitSession = () =>
  post<{ ok: true; scenario: string; passed: number }>("/api/session/quit");

/**
 * Arm the teardown. The literal string is required, and the SERVER re-checks it.
 *
 * The confirmation the learner types in the dialog is the friendly copy; the
 * route is the boundary. This is the one call in this application that can end
 * in `terraform destroy` - see CLAUDE.md hard rule 1 and the exception in it.
 */
export const destroyEnvironment = () =>
  post<{ ok: true }>("/api/session/destroy", { confirm: "DESTROY" });

export const getDeps = () => json<import("@drill/shared").DependencyStatus[]>("/api/deps");
