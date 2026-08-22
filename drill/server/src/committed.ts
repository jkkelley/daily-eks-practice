/**
 * The file as CLUSTER GIT has it - which is what Argo CD will actually sync.
 *
 * This fills the `readCommitted` seam that `server.ts` has carried unimplemented
 * since Task 5.1. It is the one fact the grader cannot look up and the workspace
 * cannot answer, and scenario 03 task 2 turns entirely on it: you edit the tag, you
 * save, the file on disk is correct, and nothing deploys - because Argo reads the
 * repository, not your working tree. Without this the `uncommitted` hint can never
 * fire, the task passes on a saved-but-uncommitted file, and the GitOps lesson goes
 * ungraded with every test in the suite green.
 *
 * ---- THE THREE ANSWERS, AND WHY THEY ARE THREE ----------------------------
 *
 *   content    cluster git has this file, and this is what is in it
 *   ""         cluster git demonstrably does NOT have this file
 *   undefined  we could not find out
 *
 * The last one is the one to be careful with. `undefined` means commit state is not
 * graded AT ALL, and it must never come to mean "not committed": a caller that could
 * not look something up has not learned that the answer is no. Collapsing the two
 * would fail a learner who did everything right, on a task about committing, because
 * cluster git happened to restart.
 *
 * The distinction between "" and undefined is equally load-bearing in the other
 * direction. A brand new file that was never committed is a real fact, and the
 * grader renders it as "cluster git has nothing at that key"; answering undefined
 * there would let the task pass on a file Argo has never seen.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { isAbsolute, normalize } from "node:path";

const run = promisify(execFile);

export interface CommittedReaderOptions {
  workspaceDir: string;
  /** The remote Argo reads. `origin` is the in-cluster git daemon. */
  remote?: string;
  /**
   * The branch the Argo `Application` targets.
   *
   * Pinned rather than taken from HEAD on purpose: a learner who wandered onto a
   * feature branch is still going to be graded against what Argo will deploy, and
   * grading their branch would quietly tell them a change is live when it is not.
   */
  branch?: string;
}

/**
 * `git show` needs a path relative to the repository root, and this one comes from
 * an answers TOML rather than from user input - but it reaches a subprocess either
 * way, so it is checked here as well as at the workspace jail. Absolute paths and
 * anything climbing out are refused rather than normalised into something valid.
 */
function safeRelative(path: string): string | undefined {
  if (path.length === 0 || isAbsolute(path)) return undefined;
  const clean = normalize(path);
  if (clean.startsWith("..") || clean.includes("\0")) return undefined;
  return clean;
}

/** Does git's own message say the PATH is absent, as opposed to something failing? */
function pathIsAbsent(message: string): boolean {
  return (
    /does not exist in/.test(message) ||
    /exists on disk, but not in/.test(message) ||
    /path .* does not exist/.test(message)
  );
}

export function gitCommittedReader(
  opts: CommittedReaderOptions,
): (path: string) => Promise<string | undefined> {
  const remote = opts.remote ?? "origin";
  const branch = opts.branch ?? "main";
  const git = (...args: string[]) =>
    run("git", ["-C", opts.workspaceDir, ...args], {
      encoding: "utf8",
      // The remote is a ClusterIP Service one hop away. If it has not answered in
      // ten seconds it is not going to, and a submission must not hang on it.
      timeout: 10_000,
    });

  return async (path: string): Promise<string | undefined> => {
    const rel = safeRelative(path);
    if (rel === undefined) return undefined;

    // Fetch every time rather than trusting a cached ref. The learner pushes from
    // the terminal in the same pod, seconds before submitting, and a stale
    // origin/main would tell them their push had not happened.
    try {
      await git("fetch", "--quiet", remote, branch);
    } catch {
      // No remote, no network, no repo, cluster git restarting. All of them mean the
      // same thing here: not known.
      return undefined;
    }

    try {
      const { stdout } = await git("show", `FETCH_HEAD:${rel}`);
      return stdout;
    } catch (err) {
      const message =
        err instanceof Error
          ? `${err.message} ${String((err as { stderr?: string }).stderr ?? "")}`
          : String(err);
      // Only a message that clearly says the path is not in the tree becomes "".
      // Anything else is an unknown, because guessing wrong in this direction tells
      // a learner to commit something they already committed.
      return pathIsAbsent(message) ? "" : undefined;
    }
  };
}
