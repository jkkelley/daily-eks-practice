import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveInWorkspace,
  readWorkspaceFile,
  writeWorkspaceFile,
  WorkspaceError,
} from "./workspace.ts";

const ws = async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-jail-"));
  await mkdir(join(dir, "helm/practice-app"), { recursive: true });
  await writeFile(
    join(dir, "helm/practice-app/values.yaml"),
    "frontend:\n  image:\n    tag: 1.27-alpine\n",
  );
  return dir;
};

test("a path inside the workspace resolves", async () => {
  const dir = await ws();
  assert.equal(
    resolveInWorkspace(dir, "helm/practice-app/values.yaml"),
    join(dir, "helm/practice-app/values.yaml"),
  );
});

test("every way out of the workspace is refused", async () => {
  const dir = await ws();
  const escapes = [
    "../outside.txt",
    "helm/../../outside.txt",
    "/etc/passwd",
    "./../../etc/passwd",
    "helm/practice-app/../../../etc/passwd",
  ];
  for (const bad of escapes) {
    assert.throws(
      () => resolveInWorkspace(dir, bad),
      WorkspaceError,
      `${bad} escaped the workspace`,
    );
  }
});

test("the editor cannot write into .git", async () => {
  const dir = await ws();
  // The learner's own commits are the drill. An autosave that could rewrite
  // .git/HEAD or a hook would corrupt the exercise in a way nothing explains.
  for (const bad of [".git/config", ".git/hooks/pre-commit"]) {
    assert.throws(() => resolveInWorkspace(dir, bad), WorkspaceError, bad);
  }
});

test("reading a file returns its contents", async () => {
  const dir = await ws();
  assert.match(
    await readWorkspaceFile(dir, "helm/practice-app/values.yaml"),
    /1\.27-alpine/,
  );
});

test("reading a file that is not there is a WorkspaceError, not a crash", async () => {
  const dir = await ws();
  await assert.rejects(
    () => readWorkspaceFile(dir, "nope.yaml"),
    WorkspaceError,
  );
});

test("writing a file lands on disk and creates missing directories", async () => {
  const dir = await ws();
  await writeWorkspaceFile(
    dir,
    "helm/practice-app/values.yaml",
    "changed: yes\n",
  );
  assert.equal(
    await readFile(join(dir, "helm/practice-app/values.yaml"), "utf8"),
    "changed: yes\n",
  );
  await writeWorkspaceFile(dir, "new/nested/file.txt", "hi\n");
  assert.equal(
    await readFile(join(dir, "new/nested/file.txt"), "utf8"),
    "hi\n",
  );
});

test("writing outside the workspace is refused before anything is written", async () => {
  const dir = await ws();
  await assert.rejects(
    () => writeWorkspaceFile(dir, "../escaped.txt", "nope"),
    WorkspaceError,
  );
});
