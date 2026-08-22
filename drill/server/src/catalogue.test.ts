import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadCatalogue, parseCatalogue, CATALOGUE_FILE } from "./catalogue.ts";

const ANSWERS_DIR = new URL("../../../scenarios/answers", import.meta.url)
  .pathname;

test("the committed catalogue loads and covers the whole curriculum", async () => {
  const rows = await loadCatalogue(ANSWERS_DIR);

  assert.ok(rows.length >= 12, `expected the twelve cards, got ${rows.length}`);
  assert.ok(
    rows.some((r) => r.id === "03" && r.ported),
    "03 is the ported one",
  );
  assert.ok(
    rows.some((r) => r.id === "07" && !r.ported),
    "07 is on the menu and is not ported - shown disabled, not hidden",
  );
  assert.ok(
    rows.every((r) => r.title && r.title !== r.id),
    "every entry has a real title, not just its number",
  );
});

test("only the three public fields survive parsing", () => {
  // This is served straight to the browser. A spread would carry whatever the
  // generator grows next through to the client, and the generator reads a
  // directory that also holds the answer key.
  const rows = parseCatalogue(
    JSON.stringify({
      scenarios: [
        {
          id: "03",
          title: "Rolling update + rollback",
          ported: true,
          acceptRules: ["kubectl set image"],
          answer: "do not ship me",
        },
      ],
    }),
  );

  assert.deepEqual(rows, [
    { id: "03", title: "Rolling update + rollback", ported: true },
  ]);
  assert.ok(!JSON.stringify(rows).includes("do not ship me"));
});

test("ported is a strict boolean, not a truthy value", () => {
  const rows = parseCatalogue(
    JSON.stringify({
      scenarios: [
        { id: "01", title: "a", ported: "yes" },
        { id: "02", title: "b" },
        { id: "03", title: "c", ported: true },
      ],
    }),
  );
  // "yes" is truthy, and a scenario wrongly marked ported is an enabled menu
  // entry that loads a scenario with nothing to grade it - a dead end the
  // learner cannot get out of except by switching again.
  assert.deepEqual(
    rows.map((r) => r.ported),
    [false, false, true],
  );
});

test("a malformed row is dropped without taking the catalogue with it", () => {
  const rows = parseCatalogue(
    JSON.stringify({
      scenarios: [
        { id: "01", title: "fine", ported: false },
        null,
        "nonsense",
        { title: "no id" },
        { id: "04", title: "also fine", ported: false },
      ],
    }),
  );
  assert.deepEqual(
    rows.map((r) => r.id),
    ["01", "04"],
  );
});

test("a missing catalogue is an empty menu, never a server that will not start", async () => {
  // The cost of it being absent is a pause menu with no scenario list. The
  // drill, the terminal, the editor and the grader all still work, and trading
  // a running drill for a menu is the wrong way round.
  const empty = await mkdtemp(join(tmpdir(), "drill-cat-"));
  assert.deepEqual(await loadCatalogue(empty), []);

  await writeFile(join(empty, CATALOGUE_FILE), "{ this is not json");
  assert.deepEqual(
    await loadCatalogue(empty),
    [],
    "and neither is a corrupt one",
  );
});
