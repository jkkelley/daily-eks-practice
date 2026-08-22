/**
 * The one socket the GUI holds open.
 *
 * It carries the terminal in both directions and the editor's autosave in one, so
 * a drill needs exactly one connection and a reconnect restores everything at
 * once. Grading stays on POST /api/submit: a verdict is a request with an answer,
 * and giving it a second spelling over the socket would mean two code paths that
 * have to agree about what a pass is.
 */
import type { FastifyInstance } from "fastify";
import fastifyWebsocket from "@fastify/websocket";
import { join } from "node:path";
import type { ClientMessage, ServerMessage } from "@drill/shared";
import { TerminalSession } from "./pty.ts";
import { writeWorkspaceFile, WorkspaceError } from "./workspace.ts";
import { resolveDependencies } from "./integrations/deps.ts";
import type { ServerDeps } from "./server.ts";
import type { SessionHub } from "./session.ts";

export async function registerTerminal(
  app: FastifyInstance,
  opts: ServerDeps,
  hub: SessionHub,
): Promise<void> {
  await app.register(fastifyWebsocket);

  app.register(async (scoped) => {
    scoped.get("/ws", { websocket: true }, async (socket) => {
      const send = (msg: ServerMessage) => socket.send(JSON.stringify(msg));

      // Named for the scenario, not for the connection: reattaching to the drill
      // you were already running is the entire point of putting tmux underneath.
      //
      // Read from the hub rather than from `opts`, because the scenario can now
      // change under a running server. Off `opts` it would be frozen at whatever
      // the pod booted with, so switching to 06 would silently reattach you to
      // 03's shell and 03's scrollback - a terminal holding the previous drill,
      // in a UI insisting you are in the new one.
      const scenario = hub.state.scenario;
      const term = new TerminalSession({
        cwd: opts.workspaceDir,
        sessionName: `drill-${scenario}`,
        logPath: join(opts.logDir, `${scenario}.log`),
        ...(opts.tmuxConf ? { tmuxConf: opts.tmuxConf } : {}),
      });

      // Paint the tail, so a restart never opens onto a blank screen - but ONLY
      // when there was no tmux session to attach to. tmux repaints the pane on
      // reattach, and replaying the log underneath that means writing a slice of
      // an old redraw, mid-escape-sequence, which shows up as visible junk above
      // the prompt. Two mechanisms for two different failures; running both for
      // one failure is what produced the garbage.
      if (!term.reattached) {
        const tail = await term.replay();
        if (tail) send({ type: "term:output", data: tail });
      }
      send({ type: "session", state: hub.state });

      // ...and again on every change, which is what makes the pause menu work at
      // all. A phase only the server knows about is a transition screen that
      // never appears and a game-over screen that never arrives. Pushed rather
      // than polled because these are single, discrete events - a switch, a quit
      // - and an interval would put a random fraction of a second of "nothing is
      // happening" in front of every one of them.
      const unsubscribe = hub.onChange((state) =>
        send({ type: "session", state }),
      );

      term.onData((data) => send({ type: "term:output", data }));

      // The startup chain, pushed rather than polled, because the panel that shows
      // it is the one being read while the user waits for the cluster.
      //
      // Ten seconds, not the three the git poll uses: this is three API reads
      // against the control plane rather than one `git status` on a local tree, and
      // the thing being watched changes on the scale of pods starting.
      const pushDeps = () =>
        void resolveDependencies(opts)
          .then((deps) => send({ type: "deps", deps }))
          .catch(() => undefined);
      pushDeps();
      const depsTimer = setInterval(pushDeps, 10_000);

      socket.on("message", (raw: Buffer) => {
        let msg: ClientMessage;
        try {
          msg = JSON.parse(raw.toString()) as ClientMessage;
        } catch {
          return send({ type: "error", message: "malformed message" });
        }
        switch (msg.type) {
          case "term:input":
            // A keystroke is the clearest evidence a human is here, and it is
            // the reason the idle clock can be trusted at all.
            opts.activity?.mark();
            return term.write(msg.data);
          case "term:resize":
            // Deliberately NOT activity. This fires on mount and on any layout
            // change, including ones the browser makes on its own, so counting
            // it would keep the idle clock reset for a tab nobody is looking at.
            return term.resize(msg.cols, msg.rows);
          case "file:save":
            opts.activity?.mark();
            // Acknowledged only once it is on disk. The editor's "saved" indicator
            // means the server wrote the file, never that the browser sent a frame.
            void writeWorkspaceFile(opts.workspaceDir, msg.path, msg.content)
              .then(() => send({ type: "file:saved", path: msg.path }))
              .catch((e: unknown) =>
                send({
                  type: "error",
                  message:
                    e instanceof WorkspaceError
                      ? e.message
                      : `could not save ${msg.path}`,
                }),
              );
            return;
          default:
            return;
        }
      });

      // tmux keeps the shell alive; only the local handle is dropped. The timer is
      // not so forgiving: left running it holds a reference to a closed socket and
      // hits the API server every ten seconds for a session nobody is watching.
      socket.on("close", () => {
        clearInterval(depsTimer);
        // Left subscribed, the hub holds a closure over a closed socket for the
        // life of the process, and every later phase change calls send() on it.
        unsubscribe();
        term.dispose();
      });
    });
  });
}
