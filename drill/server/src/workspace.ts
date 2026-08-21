/**
 * Every read and write the browser can reach goes through here.
 *
 * The GUI is an unauthenticated cluster-admin surface whose only access control is
 * a source-IP allow list, so the editor's save path is one of the few places a
 * request from the browser turns into a filesystem write. It is jailed to the
 * workspace, and the jail is a function with its own tests rather than a check
 * inlined at each call site, because there is more than one call site and only the
 * first one is ever remembered.
 */
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { resolve, dirname, sep } from "node:path";

export class WorkspaceError extends Error {}

/**
 * Resolve a workspace-relative path, or refuse.
 *
 * `.git` is refused as well as anything outside the root. The learner's own commits
 * are the drill - scenario 03's model answer is `git revert && git push` - and an
 * autosave that could rewrite `.git/HEAD` or drop in a hook would corrupt the
 * exercise in a way nothing on screen would explain.
 */
export function resolveInWorkspace(workspaceDir: string, path: string): string {
  const root = resolve(workspaceDir);
  const target = resolve(root, path);

  if (target !== root && !target.startsWith(root + sep)) {
    throw new WorkspaceError(`${path} is outside the workspace`);
  }
  const relative = target.slice(root.length + 1);
  if (relative === ".git" || relative.startsWith(`.git${sep}`)) {
    throw new WorkspaceError(
      `${path} is inside .git, which the editor may not touch`,
    );
  }
  return target;
}

export async function readWorkspaceFile(
  workspaceDir: string,
  path: string,
): Promise<string> {
  const target = resolveInWorkspace(workspaceDir, path);
  try {
    return await readFile(target, "utf8");
  } catch {
    throw new WorkspaceError(`${path} is not in the workspace`);
  }
}

export async function writeWorkspaceFile(
  workspaceDir: string,
  path: string,
  content: string,
): Promise<void> {
  const target = resolveInWorkspace(workspaceDir, path);
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, content, "utf8");
}
