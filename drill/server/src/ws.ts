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
import type { ClientMessage, ServerMessage, SessionState } from "@drill/shared";
import { TerminalSession } from "./pty.ts";
import { writeWorkspaceFile, WorkspaceError } from "./workspace.ts";
import type { ServerDeps } from "./server.ts";

export async function registerTerminal(
  app: FastifyInstance,
  opts: ServerDeps,
  state: SessionState,
): Promise<void> {
  await app.register(fastifyWebsocket);

  app.register(async (scoped) => {
    scoped.get("/ws", { websocket: true }, async (socket) => {
      const send = (msg: ServerMessage) => socket.send(JSON.stringify(msg));

      // Named for the scenario, not for the connection: reattaching to the drill
      // you were already running is the entire point of putting tmux underneath.
      const term = new TerminalSession({
        cwd: opts.workspaceDir,
        sessionName: `drill-${opts.scenario}`,
        logPath: join(opts.logDir, `${opts.scenario}.log`),
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
      send({ type: "session", state });

      term.onData((data) => send({ type: "term:output", data }));

      socket.on("message", (raw: Buffer) => {
        let msg: ClientMessage;
        try {
          msg = JSON.parse(raw.toString()) as ClientMessage;
        } catch {
          return send({ type: "error", message: "malformed message" });
        }
        switch (msg.type) {
          case "term:input":
            return term.write(msg.data);
          case "term:resize":
            return term.resize(msg.cols, msg.rows);
          case "file:save":
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

      // tmux keeps the shell alive; only the local handle is dropped.
      socket.on("close", () => term.dispose());
    });
  });
}
