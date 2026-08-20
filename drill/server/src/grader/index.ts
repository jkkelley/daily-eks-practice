/**
 * Grading. Three kinds behind one interface.
 *
 * A failure is only useful if it names the misconception, so every grader tries to
 * classify HOW the answer was wrong and looks up a hint keyed to that. A bare
 * "incorrect" teaches nothing, which is the whole reason this is not a regex match.
 */
import type { Verdict } from "@drill/shared";
import { parse as parseYaml } from "yaml";
import {
  parseCommand,
  normaliseResource,
  commandVerbs,
  type ParsedCommand,
} from "./parse.ts";
import type { AnswerTask, AcceptRule } from "./answers.ts";

export function grade(
  task: AnswerTask,
  submitted: string,
  fileContent?: string,
): Verdict {
  switch (task.grader) {
    case "command":
      return gradeCommand(task, submitted);
    case "prose":
      return gradeProse(task, submitted);
    case "file":
      return gradeFile(task, fileContent ?? "");
  }
}

/**
 * Look up the hint the answers file authored for this specific misconception.
 *
 * Eight of the ten hint keys are reachable from here: missing-namespace,
 * wrong-namespace, wrong-resource, wrong-name and no-loop from a command, unchanged
 * from a file, and whatever a prose task lists first (no-numbers, no-signature).
 *
 * Two are not, and cannot be, because a grader that is a pure function of one
 * submission does not know anything else. `uncommitted` (03 task 2) needs the git
 * state of the workspace: the file is correct but the change was never committed, so
 * cluster git has not moved. `only-imperative` (03 task 5) needs the session's earlier
 * attempts: the submission passed, and the nudge is that it was the imperative half of
 * a two-part answer. Both belong to whatever owns session state - Phase 5's server or
 * Phase 6's watcher - and both are still authored in the TOML, waiting for a caller
 * that can supply the context.
 */
function hintFor(
  task: AnswerTask,
  key: string,
): { hint: string; message: string } | undefined {
  const hit = task.hints?.find((h) => h.when === key);
  return hit ? { hint: key, message: hit.text } : undefined;
}

function pass(task: AnswerTask, message: string): Verdict {
  return { taskId: task.id, passed: true, message };
}

function fail(
  task: AnswerTask,
  key: string | undefined,
  fallback: string,
): Verdict {
  const hinted = key ? hintFor(task, key) : undefined;
  return hinted
    ? {
        taskId: task.id,
        passed: false,
        message: hinted.message,
        hint: hinted.hint,
      }
    : { taskId: task.id, passed: false, message: fallback };
}

/** Does one parsed command satisfy one accept rule? Unset rule fields mean "do not care". */
function matches(
  rule: AcceptRule,
  cmd: ParsedCommand,
  verbs: string[],
): boolean {
  if (!verbs.includes(rule.verb)) return false;
  if (rule.resource && normaliseResource(rule.resource) !== cmd.resource)
    return false;
  if (rule.namespace && rule.namespace !== cmd.namespace) return false;
  if (rule.name && rule.name !== cmd.name) return false;
  for (const [flag, want] of Object.entries(rule.flags ?? {})) {
    if (cmd.flags[flag] !== want) return false;
  }
  return true;
}

export function gradeCommand(task: AnswerTask, submitted: string): Verdict {
  const cmd = parseCommand(submitted);
  const verbs = commandVerbs(cmd);
  const rules = task.accept ?? [];

  if (rules.some((r) => matches(r, cmd, verbs))) {
    return pass(task, "Correct.");
  }

  // Classify the near misses, most specific first. Only rules whose verb already
  // matched are considered, so a completely different command gets no hint rather
  // than a misleading one.
  const verbMatched = rules.filter((r) => verbs.includes(r.verb));
  for (const rule of verbMatched) {
    if (rule.namespace && cmd.namespace === undefined && !cmd.allNamespaces) {
      return fail(
        task,
        "missing-namespace",
        `Close - but which namespace? Expected -n ${rule.namespace}.`,
      );
    }
    if (
      rule.namespace &&
      cmd.namespace !== undefined &&
      cmd.namespace !== rule.namespace
    ) {
      return fail(
        task,
        "wrong-namespace",
        `Wrong namespace: you used ${cmd.namespace}, the app lives in ${rule.namespace}.`,
      );
    }
    if (rule.resource && cmd.resource !== normaliseResource(rule.resource)) {
      return fail(
        task,
        "wrong-resource",
        `Wrong resource: you asked about ${cmd.resource ?? "nothing"}, this is about a ${rule.resource}.`,
      );
    }
    if (rule.name && cmd.name !== rule.name) {
      return fail(
        task,
        "wrong-name",
        `Right idea, wrong object: expected ${rule.name}.`,
      );
    }
  }

  // A `<tool>-loop` rule asks for a stream, not a single shot. Running the body
  // command once is the near miss the "no-loop" hint was written for, and it is not
  // caught above because a bare `curl` matches no rule's verb at all.
  for (const rule of rules) {
    const body = loopBody(rule.verb);
    if (body && cmd.tool === body) {
      return fail(
        task,
        "no-loop",
        `One ${body} proves nothing here - the question is whether any request in a stream fails. Put it in a loop.`,
      );
    }
  }

  return fail(
    task,
    undefined,
    "Not what this task is asking for. Re-read the prompt, and try `hint` if you are stuck.",
  );
}

/** "curl-loop" -> "curl". Undefined for any rule verb that is not a loop rule. */
function loopBody(verb: string): string | undefined {
  return verb.endsWith("-loop") ? verb.slice(0, -"-loop".length) : undefined;
}

export function gradeProse(task: AnswerTask, submitted: string): Verdict {
  const haystack = submitted.toLowerCase();
  const missing = (task.must_include ?? []).filter(
    (term) => !haystack.includes(term.toLowerCase()),
  );
  if (missing.length === 0) return pass(task, "Correct.");

  // Give the first hint the task defines; a prose task's misconceptions are not
  // mechanically distinguishable the way a command's are.
  const key = task.hints?.[0]?.when;
  return fail(task, key, `Missing from your answer: ${missing.join(", ")}.`);
}

export function gradeFile(task: AnswerTask, fileContent: string): Verdict {
  let doc: unknown;
  try {
    doc = parseYaml(fileContent);
  } catch (e) {
    return fail(
      task,
      undefined,
      `${task.path} could not be parsed as YAML: ${(e as Error).message}`,
    );
  }

  const parts = (task.key ?? "").split(".");
  let cursor: unknown = doc;
  for (const part of parts) {
    if (cursor === null || typeof cursor !== "object") {
      cursor = undefined;
      break;
    }
    cursor = (cursor as Record<string, unknown>)[part];
  }

  if (cursor === undefined || cursor === null) {
    return fail(task, undefined, `${task.path} has no value at ${task.key}.`);
  }

  const value = String(cursor);
  if (new RegExp(task.accept_pattern ?? "").test(value)) {
    return pass(task, "Correct.");
  }
  return fail(
    task,
    "unchanged",
    `${task.key} is ${value}, which is not what this task wants.`,
  );
}
