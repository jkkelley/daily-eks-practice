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
import { readFile, writeFile, mkdir, readdir } from "node:fs/promises";
import { resolve, dirname, join, sep } from "node:path";

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

/** One entry in the explorer. Paths are workspace-relative; the browser never sees an absolute one. */
export interface TreeNode {
  name: string;
  /** Workspace-relative, so it can be handed straight back to /api/file. */
  path: string;
  type: "file" | "dir";
  children?: TreeNode[];
}

/**
 * Directories the explorer never shows.
 *
 * `.git` is both noise and a place the editor is forbidden to write - see
 * resolveInWorkspace - so listing it would only offer the learner a door that is
 * already locked. `node_modules` is thousands of entries that would drown the
 * panel and the response with it. Neither is a security control; the terminal is
 * an unrestricted shell and can see everything either way. This is about the
 * panel being readable.
 */
const HIDDEN = new Set([".git", "node_modules"]);

export interface TreeOptions {
  /** Total nodes across the whole tree, not per directory. */
  maxEntries?: number;
}

const DEFAULT_MAX_ENTRIES = 2000;

export async function listWorkspaceTree(
  workspaceDir: string,
  opts: TreeOptions = {},
): Promise<TreeNode[]> {
  const budget = { left: opts.maxEntries ?? DEFAULT_MAX_ENTRIES };

  const walk = async (dir: string, prefix: string): Promise<TreeNode[]> => {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      // A directory that vanished mid-walk, or one we cannot read, is an empty
      // branch rather than a failed request - the explorer is not worth a 500.
      return [];
    }

    // Directories first, then files, each alphabetical. This is what every file
    // explorer does, and doing anything else reads as a bug.
    entries.sort((a, b) => {
      const aDir = a.isDirectory();
      if (aDir !== b.isDirectory()) return aDir ? -1 : 1;
      return a.name.localeCompare(b.name);
    });

    const out: TreeNode[] = [];
    for (const entry of entries) {
      if (budget.left <= 0) break;
      if (HIDDEN.has(entry.name)) continue;

      const path = prefix ? `${prefix}/${entry.name}` : entry.name;
      budget.left--;

      if (entry.isDirectory()) {
        out.push({
          name: entry.name,
          path,
          type: "dir",
          children: await walk(join(dir, entry.name), path),
        });
      } else if (entry.isFile()) {
        out.push({ name: entry.name, path, type: "file" });
      }
      // Symlinks are skipped rather than followed: a link out of the workspace
      // would hand the explorer a path that resolveInWorkspace then refuses,
      // which is a confusing way to present a file that was never openable.
    }
    return out;
  };

  return walk(resolve(workspaceDir), "");
}
