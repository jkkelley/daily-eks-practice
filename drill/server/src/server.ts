/**
 * The drill server.
 *
 * One rule shapes every route here: the answer key never reaches the browser.
 * The client sends what the user did; the server decides whether it was right and
 * sends back a verdict and, on failure, a hint. Ship the accept rules to the client
 * and the drill becomes a reading exercise.
 *
 * ---- WHAT THIS PROCESS IS ALLOWED TO CHANGE IN THE CLUSTER ----------------
 *
 * Exactly one thing: the `drill-state` ConfigMap, which is its own bookkeeping.
 * It reads plenty and it writes that. It does NOT delete the Argo Application on
 * QUIT, it does not scale anything, and it certainly does not destroy AWS.
 *
 * Every lifecycle action the pause menu offers is expressed as a PHASE written
 * into that ConfigMap, and `scripts/drill-watch.py` - a process the user started
 * on their own laptop, in their own checkout - is what acts on it. That is not
 * indirection for its own sake. It keeps the blast radius of an unauthenticated
 * cluster-admin web terminal to "it can write its own status", and it is what
 * makes the SHUT IT DOWN entry a sanctioned exception to CLAUDE.md hard rule 1
 * rather than a breach of it.
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
import {
  readWorkspaceFile,
  listWorkspaceTree,
  WorkspaceError,
} from "./workspace.ts";
import { registerTerminal } from "./ws.ts";
import { gitStatus, resetToRemote } from "./git.ts";
import type { K8sReader, K8sStateWriter } from "./integrations/k8s.ts";
import { absentApplication, getApplication } from "./integrations/argo.ts";
import { resolveDependencies } from "./integrations/deps.ts";
import { registerProxy } from "./proxy.ts";
import type { ServerOptions } from "./config.ts";
import { createStateStore, type StateStore } from "./state.ts";
import { createSessionHub } from "./session.ts";
import { readRequest, watchRequest } from "./request.ts";
import { loadCatalogue, type CatalogueEntry } from "./catalogue.ts";

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
  /**
   * Read-only access to the Kubernetes API, when there is one.
   *
   * Absent is the ordinary case on a laptop: `make -f Makefile.test drill-dev` runs
   * the whole GUI in a container with no cluster anywhere, and it has to keep
   * working. So the Argo and dependency routes answer "not available here" rather
   * than the server refusing to start - the same shape as `readCommitted`, for the
   * same reason.
   */
  reader?: K8sReader;
  /**
   * Write access to the server's OWN state ConfigMap, and nothing else.
   *
   * Absent means the session is not mirrored, which is exactly right on a laptop
   * with no cluster: the drill still runs, it just is not being saved anywhere.
   * Deliberately a different type from `reader` - see the header of k8s.ts.
   */
  writer?: K8sStateWriter;
  /** How long to wait for the laptop before converging a switch unaided. */
  switchTimeoutMs?: number;
  /** Poll interval for `drill-request`. Injected so tests do not wait 2s a time. */
  requestPollMs?: number;
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

/**
 * A session id in the same format `scripts/progress.py` uses for its directories.
 *
 * No colons: the laptop turns this straight into a directory name and Windows 11
 * is a supported target there. The two formats are not merely similar, they must
 * be identical - the watcher adopts whatever id arrives, so a mismatch here
 * creates a save directory the laptop can never find again.
 */
export function newSessionId(now: Date = new Date()): string {
  return now
    .toISOString()
    .replace(/\.\d+Z$/, "Z")
    .replace(/:/g, "-");
}

export async function createServer(opts: ServerDeps): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });

  const stateNs = opts.drillNamespace;
  const store: StateStore | undefined = opts.writer
    ? createStateStore(opts.writer, stateNs)
    : undefined;

  const catalogue: CatalogueEntry[] = await loadCatalogue(opts.answersDir);

  // What the laptop asked for wins over the environment. The Deployment sets
  // DRILL_SCENARIO as a placeholder and says in its own comment that Phase 6's
  // ConfigMap takes ownership of it - this is where that happens. The env var
  // stays as the fallback, because it is what makes drill-dev work with no
  // cluster anywhere.
  const requested = opts.reader
    ? await readRequest(opts.reader, stateNs).catch(() => undefined)
    : undefined;

  let scenario = requested?.scenario ?? opts.scenario;
  let answers: AnswerSet = await loadAnswers(scenario, opts.answersDir);

  const hub = createSessionHub(
    {
      scenario,
      sessionId:
        requested?.sessionId ?? process.env.DRILL_SESSION_ID ?? "local",
      startedAt: new Date().toISOString(),
      currentTaskId: answers.tasks[0]?.id ?? "",
      passed: [],
      attempts: [],
      phase: "active",
    } satisfies SessionState,
    store,
  );
  const state = hub.state;

  /**
   * Point the whole server at a different scenario, in place.
   *
   * `answers` is reassigned and `state` is mutated, never replaced - the websocket
   * and every route closure captured that object at startup, and swapping it would
   * leave them pushing a session that quietly stopped being the real one.
   */
  async function converge(to: string, sessionId: string): Promise<void> {
    answers = await loadAnswers(to, opts.answersDir);
    scenario = to;
    // The PVC outlives the switch - the init container clones once and leaves an
    // existing workspace alone on purpose - so the working tree has to be pulled
    // forward to whatever cluster git now holds. Without this the learner lands
    // in the new scenario looking at the old one's finished tree.
    await resetToRemote(opts.workspaceDir);
    await hub.converge({
      scenario: to,
      sessionId,
      firstTaskId: answers.tasks[0]?.id ?? "",
    });
  }

  app.get("/healthz", async () => ({ ok: true }));

  app.get("/api/session", async () => state);

  // The card, for the help panel. Spelled out field by field rather than spread
  // from `answers`, so a key added to the TOML tomorrow cannot quietly become a
  // key the browser is served.
  app.get("/api/scenario", async () => ({
    scenario: answers.scenario,
    title: answers.title,
    time: answers.time,
    needs: answers.needs,
    ticket: answers.ticket,
  }));

  // The pause menu's contents: every scenario the curriculum has, and whether it
  // can be drilled yet. Id, title and a boolean - it must never grow a field that
  // comes from inside an answers file.
  app.get("/api/scenarios", async () =>
    catalogue.map((e) => ({ ...e, current: e.id === state.scenario })),
  );

  app.get("/api/tasks", async () => answers.tasks.map(toPublic));

  // The explorer. Read fresh on each request rather than cached or watched: the
  // terminal is a real shell in the same working tree, so `git checkout` or a `helm
  // template > out.yaml` changes the tree behind the panel's back, and a stale tree
  // in a drill about editing files is worse than a re-walk that costs milliseconds.
  app.get("/api/tree", async () => listWorkspaceTree(opts.workspaceDir));

  // What git makes of the workspace. Reports only - stage, unstage and commit are
  // deliberately absent, because `git add && git commit` in the terminal IS
  // scenario 03's model answer and a button would let it be skipped.
  app.get("/api/git/status", async () => gitStatus(opts.workspaceDir));

  // What Argo CD makes of the app. For scenario 03 task 5 this is the whole lesson:
  // you run `kubectl rollout undo`, the pods roll back, and then you watch Argo
  // notice, mark the app OutOfSync and put the bad version back - next to the
  // terminal where you ran the command that did not stick.
  app.get("/api/argo", async () =>
    opts.reader
      ? getApplication(opts.reader, opts.argoAppName, opts.argoNamespace)
      : absentApplication(opts.argoAppName, opts.argoNamespace),
  );

  // The startup chain, so "why is nothing happening" has an answer that is not
  // "the drill is broken". Also the transition screen's whole content.
  app.get("/api/deps", async () => resolveDependencies(opts));

  // The editor opens the file the current task names. It is a route rather than a
  // websocket message because Monaco asks for it once, on mount, and a request that
  // has an answer is a request.
  app.get<{ Querystring: { path?: string } }>(
    "/api/file",
    async (req, reply) => {
      const path = req.query.path;
      if (!path) return reply.code(400).send({ error: "path is required" });
      try {
        return {
          path,
          content: await readWorkspaceFile(opts.workspaceDir, path),
        };
      } catch (e) {
        if (e instanceof WorkspaceError)
          return reply.code(400).send({ error: e.message });
        throw e;
      }
    },
  );

  app.post<{ Body: { taskId: string; answer: string } }>(
    "/api/submit",
    async (req, reply) => {
      const { taskId, answer } = req.body ?? { taskId: "", answer: "" };
      const task = answers.tasks.find((t) => t.id === taskId);
      if (!task)
        return reply
          .code(404)
          .send({ error: `no task ${taskId} in scenario ${state.scenario}` });

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

      // Append-only, and mirrored. A save failure is logged and does NOT fail the
      // submit: the learner answered correctly, and whether we managed to write a
      // ConfigMap is our problem, not theirs.
      await hub.update((s) => {
        s.attempts.push(attempt);
        if (verdict.passed && !s.passed.includes(taskId)) {
          s.passed.push(taskId);
          const next = answers.tasks.find((t) => !s.passed.includes(t.id));
          s.currentTaskId = next?.id ?? "";
        }
      });

      return verdict;
    },
  );

  // -------------------------------------------------------------------------
  // The pause menu's lifecycle routes.
  //
  // These MUTATE, which no other route in this server does. That is not a new
  // exposure - the terminal beside them is a cluster-admin shell, so anyone who
  // can reach these can already do strictly more - but it is a change in the
  // shape of the API, and it is said here rather than discovered.
  // -------------------------------------------------------------------------

  app.post("/api/session/restart", async () => {
    await converge(state.scenario, newSessionId());
    return { ok: true, scenario: state.scenario, sessionId: state.sessionId };
  });

  app.post<{ Body: { target?: string } }>(
    "/api/session/switch",
    async (req, reply) => {
      const target = req.body?.target;
      const entry = catalogue.find((e) => e.id === target);
      if (!target || !entry)
        return reply
          .code(400)
          .send({ error: `no scenario ${target ?? "(none given)"}` });
      if (!entry.ported)
        return reply.code(409).send({
          error: `scenario ${target} - ${entry.title} is not ported to the drill format yet, so there is nothing to grade`,
        });

      // Hand off to the laptop, which owns the save files and is the only side
      // that can restore one. It bundles the current session FIRST - that
      // ordering is the watcher's, and getting it wrong saves the next
      // scenario's baseline under this session's id.
      await hub.setPhase("switching", target);

      // ...but do not hang forever if nobody is listening. A learner running the
      // pod without the laptop watcher gets a fresh session and is told plainly
      // that nothing was restored, which beats a transition screen that never ends.
      const waitMs = opts.switchTimeoutMs ?? 60_000;
      const timer = setTimeout(() => {
        if (state.phase !== "switching" || state.target !== target) return;
        void converge(target, newSessionId());
      }, waitMs);
      timer.unref?.();

      return { ok: true, target };
    },
  );

  app.post("/api/session/quit", async () => {
    await hub.setPhase("ended");
    return { ok: true, scenario: state.scenario, passed: state.passed.length };
  });

  app.post<{ Body: { confirm?: string } }>(
    "/api/session/destroy",
    async (req, reply) => {
      // Re-checked HERE, not only in the browser. A confirmation enforced in the
      // client is a suggestion; this route is the boundary, and it is the one
      // route in this repo that can end in `terraform destroy`. See CLAUDE.md
      // hard rule 1 and the exception written into it.
      if (req.body?.confirm !== "DESTROY")
        return reply.code(400).send({
          error:
            'tearing the environment down needs confirm: "DESTROY", exactly',
        });
      await hub.setPhase("destroy-requested");
      return { ok: true };
    },
  );

  // The laptop's side of the handshake. Any request naming a session id we are
  // not already running converges us onto it - which covers `make scenario N=06`,
  // and covers the watcher answering a switch we asked for.
  if (opts.reader) {
    const stop = watchRequest(
      opts.reader,
      stateNs,
      state.sessionId,
      async (req) => {
        await converge(req.scenario, req.sessionId);
      },
      { ...(opts.requestPollMs ? { intervalMs: opts.requestPollMs } : {}) },
    );
    app.addHook("onClose", async () => stop());
  }

  await registerTerminal(app, opts, hub);
  await registerProxy(app, {
    ...(opts.argoUpstream ? { argo: opts.argoUpstream } : {}),
    ...(opts.grafanaUpstream ? { grafana: opts.grafanaUpstream } : {}),
  });

  await app.register(fastifyStatic, { root: opts.webRoot, wildcard: false });
  app.setNotFoundHandler((req, reply) => {
    // SPA fallback, but only for navigations - a missing /api path stays a 404.
    if (req.url.startsWith("/api"))
      return reply.code(404).send({ error: "not found" });
    return reply.sendFile("index.html");
  });

  return app;
}
