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
