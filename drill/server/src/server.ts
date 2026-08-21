/**
 * The drill server.
 *
 * One rule shapes every route here: the answer key never reaches the browser.
 * The client sends what the user did; the server decides whether it was right and
 * sends back a verdict and, on failure, a hint. Ship the accept rules to the client
 * and the drill becomes a reading exercise.
 */
import Fastify, { type FastifyInstance } from "fastify";
import fastifyStatic from "@fastify/static";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import type { SessionState, Verdict, Attempt } from "@drill/shared";
import {
  loadAnswers,
  type AnswerSet,
  type AnswerTask,
} from "./grader/answers.ts";
import { grade, type GradeContext } from "./grader/index.ts";
import type { ServerOptions } from "./config.ts";

/**
 * What the server needs beyond its configuration.
 *
 * `readCommitted` is the seam for the one fact the grader cannot look up and the
 * workspace cannot answer: the file as CLUSTER GIT has it, which is what Argo CD
 * will actually sync. Scenario 03 task 2's `uncommitted` hint exists for exactly the
 * gap between "saved" and "committed", and that gap is the GitOps lesson.
 *
 * It is injected rather than implemented here because the workspace is not a git
 * clone until the drill pod exists - Task 5.5 supplies the git-backed reader. Left
 * unset, or returning undefined, means commit state is NOT KNOWN and so is not
 * graded at all. It must never come to mean "not committed": a caller that could
 * not look something up has not learned that the answer is no.
 */
export interface ServerDeps extends ServerOptions {
  readCommitted?: (path: string) => Promise<string | undefined>;
}

/** The task shape the browser is allowed to see. */
interface PublicTask {
  id: string;
  prompt: string;
  grader: AnswerTask["grader"];
  /** Only for file tasks, so the editor can open the right file. Not the expected value. */
  path?: string;
}

function toPublic(task: AnswerTask): PublicTask {
  const out: PublicTask = {
    id: task.id,
    prompt: task.prompt,
    grader: task.grader,
  };
  if (task.grader === "file" && task.path) out.path = task.path;
  return out;
}

export async function createServer(opts: ServerDeps): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });
  const answers: AnswerSet = await loadAnswers(opts.scenario, opts.answersDir);

  const state: SessionState = {
    scenario: opts.scenario,
    sessionId: process.env.DRILL_SESSION_ID ?? "local",
    startedAt: new Date().toISOString(),
    currentTaskId: answers.tasks[0]?.id ?? "",
    passed: [],
    attempts: [],
  };

  app.get("/healthz", async () => ({ ok: true }));

  app.get("/api/session", async () => state);

  app.get("/api/tasks", async () => answers.tasks.map(toPublic));

  app.post<{ Body: { taskId: string; answer: string } }>(
    "/api/submit",
    async (req, reply) => {
      const { taskId, answer } = req.body ?? { taskId: "", answer: "" };
      const task = answers.tasks.find((t) => t.id === taskId);
      if (!task)
        return reply
          .code(404)
          .send({ error: `no task ${taskId} in scenario ${opts.scenario}` });

      const ctx: GradeContext = {
        // Everything this session already got right for THIS task, oldest first.
        // The grader is a pure function of its arguments, so a hint that turns on
        // history - 03 task 5's `only-imperative` - can only fire if the server
        // hands the history over.
        accepted: state.attempts
          .filter((a) => a.taskId === taskId && a.passed)
          .map((a) => a.submitted),
      };

      // A file task grades the workspace on disk, not something the user typed. The
      // point of the task is that the file really changed, which a text box cannot prove.
      if (task.grader === "file" && task.path) {
        try {
          ctx.content = await readFile(
            join(opts.workspaceDir, task.path),
            "utf8",
          );
        } catch {
          ctx.content = "";
        }
        if (opts.readCommitted) {
          const committed = await opts.readCommitted(task.path);
          if (committed !== undefined) ctx.committed = committed;
        }
      }

      const verdict: Verdict = grade(task, answer, ctx);

      const attempt: Attempt = {
        taskId,
        at: new Date().toISOString(),
        submitted: answer,
        passed: verdict.passed,
        message: verdict.message,
      };
      // Append-only. A failed attempt is the record of how you got there, and
      // deleting it would turn the log into a report card.
      state.attempts.push(attempt);

      if (verdict.passed && !state.passed.includes(taskId)) {
        state.passed.push(taskId);
        const next = answers.tasks.find((t) => !state.passed.includes(t.id));
        state.currentTaskId = next?.id ?? "";
      }

      return verdict;
    },
  );

  await app.register(fastifyStatic, { root: opts.webRoot, wildcard: false });
  app.setNotFoundHandler((req, reply) => {
    // SPA fallback, but only for navigations - a missing /api path stays a 404.
    if (req.url.startsWith("/api"))
      return reply.code(404).send({ error: "not found" });
    return reply.sendFile("index.html");
  });

  return app;
}
