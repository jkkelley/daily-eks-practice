import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gitStatus } from "./git.ts";

/** A repo with one committed file, which is the shape every drill workspace has. */
async function repo(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "drill-git-"));
  const git = (...args: string[]) =>
    execFileSync("git", ["-C", dir, ...args], { stdio: "ignore" });
  git("init", "-q", "-b", "main");
  git("config", "user.email", "drill@localhost");
  git("config", "user.name", "drill");
  await mkdir(join(dir, "helm/practice-app"), { recursive: true });
  await writeFile(
    join(dir, "helm/practice-app/values.yaml"),
    "frontend:\n  image:\n    tag: 1.27-alpine\n",
  );
  git("add", "-A");
  git("commit", "-qm", "seed");
  return dir;
}

const gitIn = (dir: string, ...args: string[]) =>
  execFileSync("git", ["-C", dir, ...args], { stdio: "ignore" });

test("a clean workspace reports its branch and nothing to commit", async () => {
  const status = await gitStatus(await repo());
  assert.equal(status.repo, true);
  assert.equal(status.branch, "main");
  assert.deepEqual(status.files, []);
});

test("an edited-but-uncommitted file is exactly what the panel exists to show", async () => {
  // This is scenario 03 task 2. The editor saved it, git has not seen it, and Argo
  // CD is therefore never going to sync it. The gap IS the lesson.
  const dir = await repo();
  await writeFile(
    join(dir, "helm/practice-app/values.yaml"),
    "frontend:\n  image:\n    tag: 1.28-alpine\n",
  );
  const status = await gitStatus(dir);
  const hit = status.files.find(
    (f) => f.path === "helm/practice-app/values.yaml",
  );
  assert.ok(hit, "the edited file is not listed");
  assert.equal(hit.worktree, "M");
  assert.equal(hit.staged, false);
});

test("staging a file moves it, rather than listing it twice", async () => {
  const dir = await repo();
  await writeFile(join(dir, "helm/practice-app/values.yaml"), "changed: yes\n");
  gitIn(dir, "add", "helm/practice-app/values.yaml");
  const status = await gitStatus(dir);
  assert.equal(status.files.length, 1);
  assert.equal(status.files[0]?.staged, true);
  assert.equal(status.files[0]?.index, "M");
});

test("a new file shows as untracked, not as missing", async () => {
  const dir = await repo();
  await writeFile(join(dir, "notes.md"), "# scratch\n");
  const status = await gitStatus(dir);
  const hit = status.files.find((f) => f.path === "notes.md");
  assert.ok(hit);
  assert.equal(hit.untracked, true);
});

test("a deleted file is reported as deleted", async () => {
  const dir = await repo();
  await rm(join(dir, "helm/practice-app/values.yaml"));
  const status = await gitStatus(dir);
  assert.equal(
    status.files.find((f) => f.path === "helm/practice-app/values.yaml")
      ?.worktree,
    "D",
  );
});

test("a rename reports the new path, which is the one the editor can open", async () => {
  const dir = await repo();
  gitIn(
    dir,
    "mv",
    "helm/practice-app/values.yaml",
    "helm/practice-app/values-renamed.yaml",
  );
  const status = await gitStatus(dir);
  const hit = status.files.find((f) => f.path.includes("values-renamed"));
  assert.ok(hit, `rename not reported: ${JSON.stringify(status.files)}`);
  assert.equal(hit.index, "R");
  assert.equal(hit.from, "helm/practice-app/values.yaml");
});

test("a path with a space survives git's quoting", async () => {
  const dir = await repo();
  await writeFile(join(dir, "a file with spaces.md"), "hi\n");
  const status = await gitStatus(dir);
  assert.ok(
    status.files.some((f) => f.path === "a file with spaces.md"),
    `quoted path was not decoded: ${JSON.stringify(status.files)}`,
  );
});

test("a plain directory INSIDE a repo is not treated as that repo", async () => {
  // `git -C dir status` walks up until it finds a repo. Without a root check, a
  // workspace nested in one reports the parent's changes, with paths relative to a
  // root the panel cannot open and a repository that is not the learner's.
  const outer = await repo();
  const inner = join(outer, "not-a-clone");
  await mkdir(inner, { recursive: true });
  await writeFile(join(outer, "helm/practice-app/values.yaml"), "changed: yes\n");

  const status = await gitStatus(inner);
  assert.equal(status.repo, false, "it inherited the parent repository");
  assert.deepEqual(status.files, []);
});

test("a workspace that is not a repo is a result, not an exception", async () => {
  // Task 5.5 populates the workspace by cloning, so this should not happen in the
  // cluster - but the panel must degrade to "no repo here" rather than take the
  // whole request down if it ever does.
  const dir = await mkdtemp(join(tmpdir(), "drill-nogit-"));
  const status = await gitStatus(dir);
  assert.equal(status.repo, false);
  assert.deepEqual(status.files, []);
});
