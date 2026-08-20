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

/**
 * Everything a grader may need beyond the submission itself.
 *
 * The graders stay pure functions of their arguments: the caller does the looking-up
 * - reading the workspace, asking cluster git, walking the session's attempts - and
 * the grader does the deciding. Every field is optional, and a missing field means
 * "not known", never "false". A grader must never punish a caller for not supplying
 * context it could not get.
 */
export interface GradeContext {
  /** For a file task: the file as it stands in the workspace. */
  content?: string;
  /**
   * For a file task: the same file as cluster git currently has it, which is what
   * Argo CD will actually sync. Absent means nobody asked, so commit state is not
   * graded at all.
   */
  committed?: string;
  /**
   * Submissions already accepted for THIS task in this session, oldest first.
   * Phase 5 supplies `SessionState.attempts` filtered to this task's passes.
   */
  accepted?: string[];
}

export function grade(
  task: AnswerTask,
  submitted: string,
  ctx: GradeContext = {},
): Verdict {
  switch (task.grader) {
    case "command":
      return gradeCommand(task, submitted, ctx);
    case "prose":
      return gradeProse(task, submitted);
    case "file":
      return gradeFile(task, ctx.content ?? "", ctx);
  }
}

/**
 * Look up the hint the answers file authored for this specific misconception.
 *
 * All ten keys are reachable. Eight need nothing but the submission:
 * missing-namespace, wrong-namespace, wrong-resource, wrong-name and no-loop from a
 * command, unchanged from a file, and whatever a prose task lists first (no-numbers,
 * no-signature).
 *
 * Two need a fact the submission cannot carry, and take it from `GradeContext`.
 * `uncommitted` (03 task 2) needs the file as cluster git has it, because an edit
 * that was never committed is an edit Argo CD cannot see. `only-imperative`
 * (03 task 5) needs the session's earlier passes, because it fires on a CORRECT
 * answer that is only half of the one the task asked for.
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

/**
 * A pass that still has something to say. The verdict stays passed - the answer was
 * right and the drill must not pretend otherwise - and carries the authored nudge.
 * If the task never wrote that hint, this is an ordinary pass.
 */
function passWithHint(task: AnswerTask, key: string): Verdict {
  const hinted = hintFor(task, key);
  return hinted
    ? {
        taskId: task.id,
        passed: true,
        message: `Correct. ${hinted.message}`,
        hint: hinted.hint,
      }
    : pass(task, "Correct.");
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

export function gradeCommand(
  task: AnswerTask,
  submitted: string,
  ctx: GradeContext = {},
): Verdict {
  const cmd = parseCommand(submitted);
  const verbs = commandVerbs(cmd);
  const rules = task.accept ?? [];

  if (rules.some((r) => matches(r, cmd, verbs))) {
    return onlyImperative(task, cmd, ctx)
      ? passWithHint(task, "only-imperative")
      : pass(task, "Correct.");
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

/**
 * Did this correct answer do it the imperative way and stop there?
 *
 * A task that accepts both a kubectl rule and a `git-*` rule is asking for both ways,
 * not offering a choice of spellings - scenario 03 task 5 is "roll back two ways, and
 * when would the first bite you in a GitOps shop?". Passing with `kubectl rollout
 * undo` is correct and incomplete, and the incompleteness IS the lesson: Argo CD puts
 * the bad version straight back, because git is the source of truth and git still
 * says what it said.
 *
 * A task whose rules are merely alternative spellings of one answer has no `git-*`
 * rule and so never nudges. Neither does a session that already got the git half.
 */
function onlyImperative(
  task: AnswerTask,
  cmd: ParsedCommand,
  ctx: GradeContext,
): boolean {
  const gitRules = (task.accept ?? []).filter((r) => r.verb.startsWith("git-"));
  if (gitRules.length === 0) return false;
  if (cmd.tool === "git") return false;
  return !(ctx.accepted ?? []).some((earlier) => {
    const prev = parseCommand(earlier);
    const verbs = commandVerbs(prev);
    return gitRules.some((r) => matches(r, prev, verbs));
  });
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

export function gradeFile(
  task: AnswerTask,
  fileContent: string,
  ctx: GradeContext = {},
): Verdict {
  const read = readKey(fileContent, task.key ?? "");
  if (read.ok === false) {
    return read.reason === "unparseable"
      ? fail(
          task,
          undefined,
          `${task.path} could not be parsed as YAML: ${read.detail}`,
        )
      : fail(task, undefined, `${task.path} has no value at ${task.key}.`);
  }

  const wanted = new RegExp(task.accept_pattern ?? "");
  if (!wanted.test(read.value)) {
    return fail(
      task,
      "unchanged",
      `${task.key} is ${read.value}, which is not what this task wants.`,
    );
  }

  // The edit is right. Whether it is DEPLOYED is a different question, and one only
  // cluster git can answer - which is the whole GitOps lesson, so it is graded rather
  // than assumed. Checked only after the value is correct: telling somebody to commit
  // a value the grader is about to reject would be worse than saying nothing.
  if (ctx.committed !== undefined) {
    const inGit = readKey(ctx.committed, task.key ?? "");
    if (inGit.ok === false || !wanted.test(inGit.value)) {
      const has = inGit.ok === false ? "nothing at that key" : inGit.value;
      return fail(
        task,
        "uncommitted",
        `${task.path} is right in your workspace, but cluster git still has ${has}, so Argo CD has nothing to sync. Commit it.`,
      );
    }
  }

  return pass(task, "Correct.");
}

type KeyRead =
  | { ok: true; value: string }
  | { ok: false; reason: "unparseable"; detail: string }
  | { ok: false; reason: "missing" };

/** Walk a dotted key into a YAML document. Never throws - a bad document is a result. */
function readKey(content: string, key: string): KeyRead {
  let cursor: unknown;
  try {
    cursor = parseYaml(content);
  } catch (e) {
    return { ok: false, reason: "unparseable", detail: (e as Error).message };
  }

  for (const part of key.split(".")) {
    if (cursor === null || typeof cursor !== "object")
      return { ok: false, reason: "missing" };
    cursor = (cursor as Record<string, unknown>)[part];
  }

  return cursor === undefined || cursor === null
    ? { ok: false, reason: "missing" }
    : { ok: true, value: String(cursor) };
}
