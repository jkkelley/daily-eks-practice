import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AddressInfo } from "node:net";
import type { FastifyInstance } from "fastify";
import type { ServerMessage, ClientMessage } from "@drill/shared";
import { createServer } from "./server.ts";

const WEB_ROOT = new URL("../test-fixtures/web", import.meta.url).pathname;
const ANSWERS_DIR = new URL("../../../scenarios/answers", import.meta.url)
  .pathname;

/** A server on a real port, because inject() cannot speak websocket. */
async function listening(): Promise<{
  app: FastifyInstance;
  url: string;
  workspace: string;
  logDir: string;
}> {
  const root = await mkdtemp(join(tmpdir(), "drill-ws-"));
  const workspace = join(root, "workspace");
  // Deliberately NOT a sibling of the workspace. The plan derived the log path as
  // `workspaceDir/../pty`, which in the pod resolves off the PVC and onto the
  // container's ephemeral filesystem - the scrollback would survive a browser
  // reload and be gone after the restart it exists for. A sibling logDir here
  // would make that derivation accidentally correct and the test worthless.
  const logDir = await mkdtemp(join(tmpdir(), "drill-ptylog-"));
  await mkdir(join(workspace, "helm/practice-app"), { recursive: true });
  await writeFile(
    join(workspace, "helm/practice-app/values.yaml"),
    "frontend:\n  image:\n    tag: 1.27-alpine\n",
  );
  const app = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: workspace,
    logDir,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
  });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const { port } = app.server.address() as AddressInfo;
  return { app, url: `http://127.0.0.1:${port}`, workspace, logDir };
}

/** Opens a socket and buffers everything the server sends. */
async function connect(url: string) {
  const sock = new WebSocket(`${url.replace(/^http/, "ws")}/ws`);
  const seen: ServerMessage[] = [];
  sock.addEventListener("message", (ev) => {
    seen.push(JSON.parse(ev.data as string) as ServerMessage);
  });
  await new Promise<void>((ok, no) => {
    sock.addEventListener("open", () => ok(), { once: true });
    sock.addEventListener("error", () => no(new Error("socket failed")), {
      once: true,
    });
  });
  return {
    seen,
    send: (m: ClientMessage | string) =>
      sock.send(typeof m === "string" ? m : JSON.stringify(m)),
    close: () => sock.close(),
    /** Resolve once some buffered message satisfies `pred`, or throw. */
    until: async (
      pred: (m: ServerMessage) => boolean,
      what: string,
      ms = 6000,
    ): Promise<ServerMessage> => {
      const deadline = Date.now() + ms;
      for (;;) {
        const hit = seen.find(pred);
        if (hit) return hit;
        if (Date.now() > deadline)
          throw new Error(
            `timed out waiting for ${what}; saw ${JSON.stringify(seen).slice(0, 400)}`,
          );
        await new Promise((r) => setTimeout(r, 50));
      }
    },
  };
}

after(() => {
  // The terminal is deliberately named after the scenario, so every connection in
  // this file shares one tmux session. Leave the box tidy.
  try {
    execFileSync("tmux", ["kill-session", "-t", "drill-03"], {
      stdio: "ignore",
    });
  } catch {
    /* nothing to kill */
  }
});

test("a fresh connection is told the session state", async () => {
  const { app, url } = await listening();
  const sock = await connect(url);
  const msg = await sock.until(
    (m) => m.type === "session",
    "the session frame",
  );
  assert.equal(msg.type === "session" && msg.state.scenario, "03");
  sock.close();
  await app.close();
});

test("what is typed in the browser runs in the terminal and comes back", async () => {
  const { app, url } = await listening();
  const sock = await connect(url);
  sock.send({ type: "term:input", data: "echo ws-round-trip\n" });
  await sock.until(
    (m) => m.type === "term:output" && m.data.includes("ws-round-trip"),
    "the command's output",
  );
  sock.close();
  await app.close();
});

test("a resize is accepted rather than closing the socket", async () => {
  const { app, url } = await listening();
  const sock = await connect(url);
  sock.send({ type: "term:resize", cols: 100, rows: 30 });
  sock.send({ type: "term:input", data: "echo still-here\n" });
  await sock.until(
    (m) => m.type === "term:output" && m.data.includes("still-here"),
    "output after a resize",
  );
  sock.close();
  await app.close();
});

test("the editor's autosave writes the workspace file", async () => {
  const { app, url, workspace } = await listening();
  const sock = await connect(url);
  sock.send({
    type: "file:save",
    path: "helm/practice-app/values.yaml",
    content: "frontend:\n  image:\n    tag: 1.28-alpine\n",
  });
  await sock.until((m) => m.type === "file:saved", "the save acknowledgement");
  assert.match(
    await readFile(join(workspace, "helm/practice-app/values.yaml"), "utf8"),
    /1\.28-alpine/,
  );
  sock.close();
  await app.close();
});

test("an autosave aimed outside the workspace is refused and writes nothing", async () => {
  const { app, url } = await listening();
  const sock = await connect(url);
  sock.send({
    type: "file:save",
    path: "../../../../../../tmp/drill-escaped.txt",
    content: "should never land",
  });
  const err = await sock.until((m) => m.type === "error", "a refusal");
  assert.match(err.type === "error" ? err.message : "", /workspace/);
  await assert.rejects(() => readFile("/tmp/drill-escaped.txt", "utf8"));
  sock.close();
  await app.close();
});

test("a malformed frame is answered, not fatal", async () => {
  const { app, url } = await listening();
  const sock = await connect(url);
  sock.send("{not json");
  await sock.until(
    (m) => m.type === "error" && /malformed/.test(m.message),
    "the malformed-message error",
  );
  // The socket survives it.
  sock.send({ type: "term:input", data: "echo survived-garbage\n" });
  await sock.until(
    (m) => m.type === "term:output" && m.data.includes("survived-garbage"),
    "output after the bad frame",
  );
  sock.close();
  await app.close();
});

test("a reconnect is repainted by tmux, not by replaying the log underneath it", async () => {
  // Replaying the log on a reattach writes a slice of an old redraw, mid-escape
  // sequence, which tmux then only partly overwrites - it shows up as visible
  // junk above the prompt. The scrollback still arrives, from tmux.
  const { app, url } = await listening();
  const first = await connect(url);
  first.send({ type: "term:input", data: "echo tmux-repaints-this\n" });
  await first.until(
    (m) => m.type === "term:output" && m.data.includes("tmux-repaints-this"),
    "the first connection's output",
  );
  first.close();
  await new Promise((r) => setTimeout(r, 400));

  const second = await connect(url);
  await second.until(
    (m) => m.type === "term:output" && m.data.includes("tmux-repaints-this"),
    "tmux's repaint of the pane",
  );
  second.close();
  await app.close();
});

test("the pty log is written where config said, not somewhere derived from it", async () => {
  const { app, url, logDir } = await listening();
  const sock = await connect(url);
  sock.send({ type: "term:input", data: "echo teed-to-the-volume\n" });
  await sock.until(
    (m) => m.type === "term:output" && m.data.includes("teed-to-the-volume"),
    "the command's output",
  );
  sock.close();
  await app.close();

  // logDir is deliberately not a sibling of workspaceDir, so the plan's
  // `workspaceDir/../pty` derivation cannot pass this by coincidence.
  assert.match(
    await readFile(join(logDir, "03.log"), "utf8"),
    /teed-to-the-volume/,
  );
});

test("the idle clock is stamped by human input and by NOTHING else", async () => {
  // THE load-bearing assertion of the idle-teardown feature.
  //
  // If the app's own chatter counted as activity, an abandoned browser tab would
  // hold the cluster open forever: this socket alone pushes a dependency frame
  // every ten seconds, and the web app polls on top of that. The feature would
  // look completely healthy - the field advances, the state mirrors, every other
  // test passes - and it would never once fire. That is the exact shape of the
  // vacuous pass this project has now been bitten by four times.
  const marks: string[] = [];
  const spy = {
    mark: () => marks.push("mark"),
    lastActivityAt: () => new Date().toISOString(),
    flush: async () => false,
    stop: () => undefined,
  };

  const root = await mkdtemp(join(tmpdir(), "drill-idle-"));
  const workspace = join(root, "workspace");
  const logDir = await mkdtemp(join(tmpdir(), "drill-idlelog-"));
  await mkdir(join(workspace, "helm/practice-app"), { recursive: true });
  await writeFile(join(workspace, "helm/practice-app/values.yaml"), "a: 1\n");

  const app = await createServer({
    port: 0,
    host: "127.0.0.1",
    webRoot: WEB_ROOT,
    answersDir: ANSWERS_DIR,
    workspaceDir: workspace,
    logDir,
    scenario: "03",
    argoNamespace: "argocd",
    argoAppName: "practice-app",
    drillNamespace: "practice-drill",
    activity: spy,
  });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const { port } = app.server.address() as AddressInfo;
  const url = `http://127.0.0.1:${port}`;

  // try/finally, not cleanup after the assertions. A pty keeps the event loop
  // alive, so a throw before the teardown line makes the whole run HANG for its
  // full timeout instead of failing - which reads as a broken harness and hides
  // the very failure the test was written to report. Learned the hard way, twice.
  let sock: Awaited<ReturnType<typeof connect>> | undefined;
  try {
    // createServer stamps once at startup so a just-converged session does not
    // read as idle since the epoch. Everything after this is what we are judging.
    const atStartup = marks.length;
    assert.equal(atStartup, 1, "startup should stamp exactly once");

    sock = await connect(url);
    await sock.until((m) => m.type === "session", "the session frame");
    // A dependency frame is pushed on connect and every ten seconds after.
    await sock.until((m) => m.type === "deps", "the dependency push");

    assert.equal(
      marks.length,
      atStartup,
      "connecting and receiving a dependency push must NOT count as activity",
    );

    // A resize is not activity either: it fires on mount and on any layout
    // change, including ones the browser makes on its own, so counting it would
    // keep the clock reset for a tab nobody is looking at.
    sock.send({ type: "term:resize", cols: 100, rows: 30 });
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(marks.length, atStartup, "a resize must NOT count as activity");

    // A keystroke is.
    sock.send({ type: "term:input", data: "e" });
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(marks.length, atStartup + 1, "a keystroke MUST count");

    // So is saving a file.
    sock.send({
      type: "file:save",
      path: "helm/practice-app/values.yaml",
      content: "a: 2\n",
    });
    await sock.until((m) => m.type === "file:saved", "the save acknowledgement");
    assert.equal(marks.length, atStartup + 2, "a save MUST count");

    // And so is submitting an answer.
    const res = await app.inject({
      method: "POST",
      url: "/api/submit",
      payload: { taskId: "t1", answer: "kubectl get pods" },
    });
    assert.ok(res.statusCode < 500);
    assert.equal(marks.length, atStartup + 3, "a submission MUST count");
  } finally {
    sock?.close();
    await app.close();
  }
});
