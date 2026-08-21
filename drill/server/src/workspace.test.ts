import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  resolveInWorkspace,
  readWorkspaceFile,
  writeWorkspaceFile,
  listWorkspaceTree,
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

// --- the file tree -------------------------------------------------------------

const treeWs = async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-tree-"));
  await mkdir(join(dir, "helm/practice-app/templates"), { recursive: true });
  await mkdir(join(dir, ".git/refs"), { recursive: true });
  await mkdir(join(dir, "node_modules/left-pad"), { recursive: true });
  await writeFile(join(dir, "README.md"), "# repo\n");
  await writeFile(join(dir, "helm/practice-app/values.yaml"), "a: 1\n");
  await writeFile(join(dir, "helm/practice-app/Chart.yaml"), "name: x\n");
  await writeFile(
    join(dir, "helm/practice-app/templates/deployment.yaml"),
    "kind: Deployment\n",
  );
  await writeFile(join(dir, ".git/HEAD"), "ref: refs/heads/main\n");
  await writeFile(join(dir, "node_modules/left-pad/index.js"), "module.exports\n");
  return dir;
};

const flatten = (nodes: Array<{ path: string; children?: unknown }>): string[] =>
  nodes.flatMap((n) => [
    n.path,
    ...flatten((n.children ?? []) as Array<{ path: string; children?: unknown }>),
  ]);

test("the tree is nested, and directories sort above files", async () => {
  const tree = await listWorkspaceTree(await treeWs());
  assert.deepEqual(
    tree.map((n) => n.name),
    ["helm", "README.md"],
    "directories first, then files, each alphabetical",
  );
  const helm = tree[0];
  assert.equal(helm?.type, "dir");
  assert.equal(helm?.children?.[0]?.name, "practice-app");
});

test("paths in the tree are workspace-relative, so the editor can open them as-is", async () => {
  const tree = await listWorkspaceTree(await treeWs());
  assert.ok(
    flatten(tree).includes("helm/practice-app/values.yaml"),
    "the one path every drill needs is not addressable",
  );
  for (const p of flatten(tree)) {
    assert.ok(!p.startsWith("/"), `${p} leaks an absolute path to the browser`);
  }
});

test(".git and node_modules are not in the tree", async () => {
  const paths = flatten(await listWorkspaceTree(await treeWs()));
  // .git is noise the learner never wants and a place the editor must not write;
  // node_modules is thousands of entries that would drown the panel.
  for (const p of paths) {
    assert.ok(!p.startsWith(".git"), `${p} exposes the git internals`);
    assert.ok(!p.startsWith("node_modules"), `${p} is dependency noise`);
  }
  assert.ok(paths.includes("README.md"), "and ordinary files survive the filter");
});

test("the tree is capped, so a huge repo cannot blow up the first frame", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-big-"));
  for (let i = 0; i < 60; i++) {
    await writeFile(join(dir, `file-${i}.txt`), "x");
  }
  const tree = await listWorkspaceTree(dir, { maxEntries: 25 });
  assert.equal(flatten(tree).length, 25);
});
