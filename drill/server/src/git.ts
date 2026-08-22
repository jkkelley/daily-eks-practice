/**
 * What git thinks of the workspace.
 *
 * This exists for one lesson. Scenario 03 task 2 is "edit the tag and deploy", and
 * the trap is that editing is not deploying: the editor writes to the workspace,
 * git has not seen it, and Argo CD is therefore never going to sync it. Today you
 * discover that gap by waiting for a rollout that never comes. A panel that lists
 * what you have changed and not committed puts the gap on screen instead.
 *
 * Note what is deliberately NOT here: stage, unstage and commit. VS Code puts
 * buttons on all three and it would be easy to copy, but `git add && git commit`
 * in the terminal IS the exercise - scenario 03's model answer is literally that
 * command. A commit button would let the learner pass the task without once
 * running the thing the task is about, which is the same mistake as enabling the
 * HPA in the committed values.yaml. This view reports; the terminal acts.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { resolve } from "node:path";

const run = promisify(execFile);

export interface GitFile {
  /** Workspace-relative, and openable by /api/file as-is. */
  path: string;
  /** Index (staged) status letter, or " " for none. */
  index: string;
  /** Working-tree (unstaged) status letter, or " " for none. */
  worktree: string;
  staged: boolean;
  untracked: boolean;
  /** For a rename, where it came from. */
  from?: string;
}

export interface GitStatus {
  repo: boolean;
  branch: string | null;
  /** Commits ahead of the upstream, when there is one. */
  ahead: number;
  behind: number;
  files: GitFile[];
}

const EMPTY: GitStatus = {
  repo: false,
  branch: null,
  ahead: 0,
  behind: 0,
  files: [],
};

/**
 * Undo git's C-style quoting.
 *
 * `--porcelain=v1` wraps any path containing a space, a quote or a non-ASCII byte
 * in double quotes and backslash-escapes the contents. Left as-is, the one file
 * somebody names "my notes.md" comes back with literal quote marks and every
 * subsequent /api/file call for it 400s.
 */
function unquote(path: string): string {
  if (!path.startsWith('"')) return path;
  const inner = path.slice(1, -1);
  return inner.replace(/\\(x[0-9a-fA-F]{2}|[0-7]{3}|.)/g, (_m, esc: string) => {
    if (esc === "n") return "\n";
    if (esc === "t") return "\t";
    if (esc.startsWith("x"))
      return String.fromCharCode(parseInt(esc.slice(1), 16));
    if (/^[0-7]{3}$/.test(esc)) return String.fromCharCode(parseInt(esc, 8));
    return esc;
  });
}

/** `## main...origin/main [ahead 1, behind 2]` and its many shorter forms. */
function parseBranchLine(
  line: string,
): Pick<GitStatus, "branch" | "ahead" | "behind"> {
  const body = line.slice(3);
  const noCommits = /^No commits yet on (.+?)(?:\.\.\.|$)/.exec(body);
  if (noCommits) return { branch: noCommits[1] ?? null, ahead: 0, behind: 0 };

  const name = /^(.+?)(?:\.\.\.|\s|$)/.exec(body)?.[1] ?? null;
  const ahead = Number(/ahead (\d+)/.exec(body)?.[1] ?? 0);
  const behind = Number(/behind (\d+)/.exec(body)?.[1] ?? 0);
  return { branch: name, ahead, behind };
}

/**
 * Is `dir` itself the root of a repository?
 *
 * `git -C dir status` walks UP until it finds a repo, so a workspace that is not a
 * clone but happens to sit inside one answers with the PARENT's status - paths and
 * all, relative to a root outside the workspace. That is wrong twice over: it
 * reports files the panel cannot open, and it shows the learner a repository that
 * is not theirs. Caught by the server test, whose fixture workspace lives inside
 * this repo.
 */
async function isRepoRoot(workspaceDir: string): Promise<boolean> {
  try {
    const { stdout } = await run(
      "git",
      ["-C", workspaceDir, "rev-parse", "--show-toplevel"],
      { encoding: "utf8" },
    );
    return resolve(stdout.trim()) === resolve(workspaceDir);
  } catch {
    return false;
  }
}

export async function gitStatus(workspaceDir: string): Promise<GitStatus> {
  if (!(await isRepoRoot(workspaceDir))) return EMPTY;

  let stdout: string;
  try {
    ({ stdout } = await run(
      "git",
      [
        "-C",
        workspaceDir,
        "status",
        "--porcelain=v1",
        "-b",
        "--untracked-files=all",
        // Without this, a rename shows as a delete plus an untracked add, which
        // reads as "you lost a file" rather than "you moved one".
        "--renames",
      ],
      { encoding: "utf8" },
    ));
  } catch {
    // Not a repo, or no git. Either way the panel says so rather than 500ing: the
    // rest of the drill works perfectly well without this view.
    return EMPTY;
  }

  const lines = stdout.split("\n").filter((l) => l.length > 0);
  const head = lines.find((l) => l.startsWith("## "));
  const { branch, ahead, behind } = head
    ? parseBranchLine(head)
    : { branch: null, ahead: 0, behind: 0 };

  const files: GitFile[] = [];
  for (const line of lines) {
    if (line.startsWith("## ")) continue;
    const index = line[0] ?? " ";
    const worktree = line[1] ?? " ";
    const rest = line.slice(3);

    // A rename is `R  old -> new`. The new path is the one that exists and the one
    // the editor can open, so it is the entry's path.
    const arrow = rest.indexOf(" -> ");
    const path = unquote(arrow === -1 ? rest : rest.slice(arrow + 4));
    const from = arrow === -1 ? undefined : unquote(rest.slice(0, arrow));

    files.push({
      path,
      index,
      worktree,
      staged: index !== " " && index !== "?",
      untracked: index === "?",
      ...(from ? { from } : {}),
    });
  }

  return { repo: true, branch, ahead, behind, files };
}

/**
 * Point the workspace at whatever cluster git now holds, discarding local state.
 *
 * Called on a scenario switch, and only then. The workspace PVC survives the
 * switch - the init container clones once, at first pod start, and deliberately
 * leaves an existing workspace alone - so without this the learner lands in
 * scenario 06 looking at scenario 03's finished working tree.
 *
 * ---- THIS DISCARDS UNCOMMITTED WORK, AND THAT IS THE HONEST BEHAVIOUR -----
 *
 * The save file is a `git bundle` of CLUSTER GIT. Anything the learner edited and
 * did not commit and push was never in it and never could be, and pretending
 * otherwise would be worse: it would mean a resume that silently restores some of
 * your work. The drill's own subject is the gap between saved, committed and
 * pushed, so this is the lesson rather than a limitation of it - but the GUI must
 * SAY SO before it gets here, which is why the pause menu reads
 * `GET /api/git/status` and warns on a dirty tree before it offers to switch.
 *
 * Returns false rather than throwing when there is no repo or no remote. A
 * workspace that is not a clone is a broken deployment, not a reason to lose the
 * session that is currently running fine.
 */
export async function resetToRemote(workspaceDir: string): Promise<boolean> {
  if (!(await isRepoRoot(workspaceDir))) return false;
  const git = (...args: string[]) =>
    run("git", ["-C", resolve(workspaceDir), ...args], { maxBuffer: 8 << 20 });
  try {
    await git("fetch", "--prune", "origin");
    // `origin/HEAD` is frequently unset on a bare-served clone, so main is named
    // explicitly - the same branch git-seed publishes and Argo tracks.
    await git("reset", "--hard", "origin/main");
    // -x as well as -d: a switch has to clear ignored build output too, or a
    // `helm template > out.yaml` from the previous drill survives into the next.
    await git("clean", "-fdx");
    return true;
  } catch {
    return false;
  }
}
