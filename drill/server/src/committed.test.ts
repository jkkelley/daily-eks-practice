import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile, mkdir, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gitCommittedReader } from "./committed.ts";

const VALUES = "helm/practice-app/values.yaml";

function git(dir: string, ...args: string[]): void {
  execFileSync("git", ["-C", dir, ...args], { stdio: "ignore" });
}

/**
 * A bare "cluster git" and a clone of it, which is exactly the shape the pod has:
 * the workspace is a clone, and `origin` is the in-cluster git daemon.
 */
async function world(): Promise<{ remote: string; workspace: string }> {
  const root = await mkdtemp(join(tmpdir(), "drill-committed-"));
  const remote = join(root, "repo.git");
  const seed = join(root, "seed");
  const workspace = join(root, "workspace");

  execFileSync("git", ["init", "-q", "--bare", "-b", "main", remote], {
    stdio: "ignore",
  });

  await mkdir(join(seed, "helm/practice-app"), { recursive: true });
  execFileSync("git", ["init", "-q", "-b", "main", seed], { stdio: "ignore" });
  git(seed, "config", "user.email", "drill@localhost");
  git(seed, "config", "user.name", "drill");
  await writeFile(
    join(seed, VALUES),
    "frontend:\n  image:\n    tag: 1.27-alpine\n",
  );
  git(seed, "add", "-A");
  git(seed, "commit", "-qm", "seed");
  git(seed, "remote", "add", "origin", remote);
  git(seed, "push", "-q", "origin", "main");

  execFileSync("git", ["clone", "-q", remote, workspace], { stdio: "ignore" });
  git(workspace, "config", "user.email", "drill@localhost");
  git(workspace, "config", "user.name", "drill");

  return { remote, workspace };
}

test("it reads the file as cluster git has it", async () => {
  const { workspace } = await world();
  const read = gitCommittedReader({ workspaceDir: workspace });
  assert.match((await read(VALUES)) ?? "", /1\.27-alpine/);
});

test("an edit saved but NOT committed still reads as the old value", async () => {
  // This is the whole reason the seam exists. Scenario 03 task 2's `uncommitted`
  // hint fires exactly here: the workspace is right, cluster git is not, and Argo CD
  // therefore has nothing to sync. If this returned the workspace's content the hint
  // could never fire and the GitOps lesson would go ungraded with every test green.
  const { workspace } = await world();
  await writeFile(
    join(workspace, VALUES),
    "frontend:\n  image:\n    tag: 1.28-alpine\n",
  );

  const read = gitCommittedReader({ workspaceDir: workspace });
  const committed = (await read(VALUES)) ?? "";
  assert.match(committed, /1\.27-alpine/);
  assert.doesNotMatch(committed, /1\.28-alpine/);
});

test("committing locally is still not enough - it has to be pushed", async () => {
  // The second half of the same lesson, and the one people are surprised by. Argo CD
  // reads the REMOTE. A local commit is invisible to it.
  const { workspace } = await world();
  await writeFile(
    join(workspace, VALUES),
    "frontend:\n  image:\n    tag: 1.28-alpine\n",
  );
  git(workspace, "add", "-A");
  git(workspace, "commit", "-qm", "bump the tag");

  const read = gitCommittedReader({ workspaceDir: workspace });
  assert.match((await read(VALUES)) ?? "", /1\.27-alpine/);
});

test("once it is pushed, that is what cluster git has", async () => {
  const { workspace } = await world();
  await writeFile(
    join(workspace, VALUES),
    "frontend:\n  image:\n    tag: 1.28-alpine\n",
  );
  git(workspace, "add", "-A");
  git(workspace, "commit", "-qm", "bump the tag");
  git(workspace, "push", "-q", "origin", "main");

  const read = gitCommittedReader({ workspaceDir: workspace });
  assert.match((await read(VALUES)) ?? "", /1\.28-alpine/);
});

test("a file that git genuinely does not have reads as empty, not as unknown", async () => {
  // A real fact, and a different one from "could not look it up". Empty lets the
  // grader say "cluster git has nothing at that key"; undefined would mean commit
  // state is not graded at all, and the task would pass on an uncommitted file.
  const { workspace } = await world();
  await writeFile(join(workspace, "brand-new.yaml"), "nope: true\n");

  const read = gitCommittedReader({ workspaceDir: workspace });
  assert.equal(await read("brand-new.yaml"), "");
});

test("no remote at all is UNKNOWN, never 'not committed'", async () => {
  // The contract that matters most. A caller that could not look something up has
  // not learned that the answer is no - and answering "" here would fail a learner
  // who did everything right, on a task about committing, because of a network blip.
  const dir = await mkdtemp(join(tmpdir(), "drill-noremote-"));
  execFileSync("git", ["init", "-q", "-b", "main", dir], { stdio: "ignore" });
  const read = gitCommittedReader({ workspaceDir: dir });
  assert.equal(await read(VALUES), undefined);
});

test("a workspace that is not a repo at all is UNKNOWN", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-norepo-"));
  const read = gitCommittedReader({ workspaceDir: dir });
  assert.equal(await read(VALUES), undefined);
});

test("an unreachable remote is UNKNOWN rather than an exception", async () => {
  // The pod outlives cluster git restarts. A fetch failing mid-drill must degrade to
  // "not graded", not take the submission down with it.
  const { workspace } = await world();
  git(workspace, "remote", "set-url", "origin", "/nonexistent/repo.git");
  const read = gitCommittedReader({ workspaceDir: workspace });
  assert.equal(await read(VALUES), undefined);
});

test("a path outside the workspace is refused rather than read", async () => {
  const { workspace } = await world();
  const read = gitCommittedReader({ workspaceDir: workspace });
  assert.equal(await read("../../../etc/passwd"), undefined);
});

test("it tracks the branch Argo actually syncs, not whatever is checked out", async () => {
  // Argo's Application targets `main`. A learner on a feature branch is still going
  // to be graded against what Argo will deploy.
  const { workspace } = await world();
  git(workspace, "checkout", "-q", "-b", "experiment");
  await writeFile(
    join(workspace, VALUES),
    "frontend:\n  image:\n    tag: 9.9\n",
  );
  git(workspace, "add", "-A");
  git(workspace, "commit", "-qm", "experiment");
  git(workspace, "push", "-q", "origin", "experiment");

  const read = gitCommittedReader({ workspaceDir: workspace });
  assert.match((await read(VALUES)) ?? "", /1\.27-alpine/);
});
