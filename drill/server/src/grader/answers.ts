/**
 * Read a scenario's answers TOML.
 *
 * The TOML is the cross-language contract: scripts/answers.py reads it to render
 * PRACTICE_ANSWERS.html and never grades; this reads it to grade and never renders.
 * The validation here mirrors scripts/answers.py deliberately - if the two drift,
 * a file can pass generation and fail grading, which is the worst of both.
 */
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { parse as parseToml } from "smol-toml";
import type { GraderKind } from "@drill/shared";

export const SCHEMA_VERSION = 1;

/** The three grader kinds, in the order scripts/answers.py lists them. */
const GRADERS: readonly GraderKind[] = ["command", "file", "prose"];

/** Top-level keys that must each be a non-empty string. */
const TOP_LEVEL_STR = ["scenario", "title", "time", "needs", "ticket"] as const;

export interface AcceptRule {
  verb: string;
  resource?: string;
  namespace?: string;
  name?: string;
  flags?: Record<string, string>;
}

export interface Hint {
  when: string;
  text: string;
}

export interface AnswerTask {
  id: string;
  prompt: string;
  grader: GraderKind;
  accept?: AcceptRule[];
  hints?: Hint[];
  path?: string;
  key?: string;
  accept_pattern?: string;
  must_include?: string[];
  answer?: { pre?: string[]; prose?: string };
}

export interface AnswerSet {
  schema: number;
  scenario: string;
  title: string;
  time: string;
  needs: string;
  ticket: string;
  tasks: AnswerTask[];
}

export class AnswersError extends Error {}

export async function loadAnswers(
  scenario: string,
  dir: string,
): Promise<AnswerSet> {
  const path = join(dir, `${scenario}.toml`);
  let text: string;
  try {
    text = await readFile(path, "utf8");
  } catch {
    throw new AnswersError(
      `no answers file for scenario ${scenario} (looked for ${path})`,
    );
  }
  let data: unknown;
  try {
    data = parseToml(text);
  } catch (e) {
    throw new AnswersError(`${path}: not valid TOML: ${(e as Error).message}`);
  }
  return validate(data, path);
}

export function validate(data: unknown, where: string): AnswerSet {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw new AnswersError(`${where}: the document must be a TOML table`);
  }
  const doc = data as Record<string, unknown>;

  if (doc["schema"] !== SCHEMA_VERSION) {
    throw new AnswersError(
      `${where}: schema is ${repr(doc["schema"])}, this loader only understands schema ${SCHEMA_VERSION}`,
    );
  }

  for (const key of TOP_LEVEL_STR) {
    if (!isNonEmptyString(doc[key])) {
      throw new AnswersError(
        `${where}: top-level '${key}' must be a non-empty string`,
      );
    }
  }

  const tasks = doc["tasks"];
  if (!Array.isArray(tasks) || tasks.length === 0) {
    throw new AnswersError(`${where}: needs a non-empty [[tasks]] array`);
  }

  const seen = new Set<string>();
  for (let i = 0; i < tasks.length; i++) {
    const task = asTable(tasks[i]);
    const at = `${where}: tasks[${i}]`;

    const id = task["id"];
    if (!isNonEmptyString(id)) {
      throw new AnswersError(`${at}: 'id' must be a non-empty string`);
    }
    if (seen.has(id)) {
      throw new AnswersError(`${where}: duplicate task id ${repr(id)}`);
    }
    seen.add(id);

    const ctx = `${at} (id ${id})`;
    if (!isNonEmptyString(task["prompt"])) {
      throw new AnswersError(`${ctx}: 'prompt' must be a non-empty string`);
    }

    const grader = task["grader"];
    if (!GRADERS.includes(grader as GraderKind)) {
      throw new AnswersError(
        `${ctx}: unknown grader ${repr(grader)}, expected one of ('command', 'file', 'prose')`,
      );
    }
    validateGrader(task, grader as GraderKind, ctx);
    validateHints(task, ctx);
  }

  return data as AnswerSet;
}

function validateGrader(
  task: Record<string, unknown>,
  grader: GraderKind,
  where: string,
): void {
  if (grader === "command") {
    const accept = task["accept"];
    if (!Array.isArray(accept) || accept.length === 0) {
      throw new AnswersError(
        `${where}: a 'command' task needs a non-empty [[tasks.accept]] array`,
      );
    }
    for (let j = 0; j < accept.length; j++) {
      if (!isNonEmptyString(asTable(accept[j])["verb"])) {
        throw new AnswersError(
          `${where}: accept[${j}] needs a non-empty 'verb'`,
        );
      }
    }
  } else if (grader === "file") {
    for (const key of ["path", "key", "accept_pattern"] as const) {
      if (!isNonEmptyString(task[key])) {
        throw new AnswersError(
          `${where}: a 'file' task needs a non-empty '${key}'`,
        );
      }
    }
  } else {
    const must = task["must_include"];
    if (!Array.isArray(must) || must.length === 0) {
      throw new AnswersError(
        `${where}: a 'prose' task needs a non-empty 'must_include' list`,
      );
    }
    for (let j = 0; j < must.length; j++) {
      if (!isNonEmptyString(must[j])) {
        throw new AnswersError(
          `${where}: must_include[${j}] must be a non-empty string`,
        );
      }
    }
  }
}

function validateHints(task: Record<string, unknown>, where: string): void {
  const hints = task["hints"] ?? [];
  if (!Array.isArray(hints)) {
    throw new AnswersError(`${where}: 'hints' must be an array of tables`);
  }
  for (let j = 0; j < hints.length; j++) {
    const hint = asTable(hints[j]);
    for (const key of ["when", "text"] as const) {
      if (!isNonEmptyString(hint[key])) {
        throw new AnswersError(
          `${where}: hints[${j}] needs a non-empty '${key}'`,
        );
      }
    }
  }
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

function asTable(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/** Python's repr() for the values that reach an error message, so the two agree. */
function repr(value: unknown): string {
  return typeof value === "string" ? `'${value}'` : String(value);
}
