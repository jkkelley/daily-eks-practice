/**
 * The curriculum, for the pause menu.
 *
 * The menu shows all twelve scenarios with the unported ones disabled rather than
 * hidden, so the server has to know the whole curriculum and not just the part it
 * can grade. It cannot work that out for itself: the image ships
 * `scenarios/answers/` and nothing else from `scenarios/`, so the cards are not in
 * it, and a hardcoded `01`..`12` here would go stale in silence the day a
 * thirteenth card is written - the menu would simply never show it.
 *
 * So `scripts/gen-answers.py` generates `catalogue.json` from the cards on the
 * laptop and it is committed. `make -f Makefile.test test` fails if it is stale.
 *
 * Three fields, and it must never grow a fourth that comes from inside an answers
 * file. This is served straight to the browser.
 */
import { readFile } from "node:fs/promises";
import { join } from "node:path";

export interface CatalogueEntry {
  id: string;
  title: string;
  ported: boolean;
}

export const CATALOGUE_FILE = "catalogue.json";

export function parseCatalogue(raw: string): CatalogueEntry[] {
  const parsed = JSON.parse(raw) as unknown;
  const rows =
    typeof parsed === "object" && parsed !== null
      ? (parsed as { scenarios?: unknown }).scenarios
      : undefined;
  if (!Array.isArray(rows)) return [];

  return rows.flatMap((r): CatalogueEntry[] => {
    if (typeof r !== "object" || r === null) return [];
    const e = r as Record<string, unknown>;
    if (typeof e.id !== "string" || typeof e.title !== "string") return [];
    // Only the three fields, rebuilt by hand. A spread would carry whatever the
    // generator grows next straight through to the browser.
    return [{ id: e.id, title: e.title, ported: e.ported === true }];
  });
}

/**
 * Load the catalogue, or answer with an empty one.
 *
 * A missing or unreadable catalogue must not stop the server from starting. The
 * cost of it being absent is a pause menu with no scenario list - the drill, the
 * terminal, the editor and the grader all still work - and trading a running
 * drill for a menu is the wrong way round.
 */
export async function loadCatalogue(
  answersDir: string,
): Promise<CatalogueEntry[]> {
  try {
    return parseCatalogue(
      await readFile(join(answersDir, CATALOGUE_FILE), "utf8"),
    );
  } catch {
    return [];
  }
}
