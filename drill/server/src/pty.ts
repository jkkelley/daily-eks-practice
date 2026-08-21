/**
 * The terminal.
 *
 * Two different things can interrupt a drill and they need different fixes:
 *
 *   a browser disconnect  -> tmux keeps the session alive; reattaching lands you
 *                            exactly where you were, mid-command if need be.
 *   a pod restart         -> tmux dies with the pod, so every byte is also teed to
 *                            the PVC and the tail is replayed into the new terminal.
 *
 * Solving only the first leaves you staring at a blank screen after an OOM kill;
 * solving only the second loses your running command. Both are cheap.
 */
import { spawn, type IPty } from "node-pty";
import { execFileSync } from "node:child_process";
import { createWriteStream, mkdirSync, type WriteStream } from "node:fs";
import { open } from "node:fs/promises";
import { dirname } from "node:path";

const REPLAY_CAP_BYTES = 256 * 1024;

/** Is a tmux session with this name already running? Absence is not an error. */
function tmuxSessionExists(name: string): boolean {
  try {
    execFileSync("tmux", ["has-session", "-t", name], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

export interface TerminalOptions {
  cwd: string;
  /** tmux session name. Reused across reconnects on purpose. */
  sessionName: string;
  /** Where the PTY log is teed. Lives on the PVC in the cluster. */
  logPath: string;
  /** Overridable for tests; production is tmux. */
  shell?: string;
  /** Passed to `tmux -f`. Absent means tmux's own defaults. */
  tmuxConf?: string;
}

export class TerminalSession {
  private readonly pty: IPty;
  private readonly log: WriteStream;
  private readonly logPath: string;
  private disposed = false;

  /**
   * Everything the terminal emitted before anybody was listening.
   *
   * tmux dumps its entire redraw the instant it attaches, and that burst is gone
   * within a millisecond or two - well before a websocket route can subscribe,
   * because the route has to construct the session in order to have something to
   * subscribe TO. Dropping it drops the whole visible screen: a session running
   * perfectly, and a blank terminal in front of the user. The log tee caught those
   * bytes and the browser did not, which is exactly how it presented.
   */
  private early: string[] = [];
  private subscribed = false;


  /**
   * True when this handle attached to a tmux session that was already running.
   *
   * It is the difference between the two failures this class exists for. On a
   * reattach tmux repaints the pane itself, so replaying the log on top of that
   * paints stale bytes - half-finished escape sequences from an earlier redraw -
   * which the reattach then partly overwrites, and the terminal opens on visible
   * garbage. On a pod restart there is no tmux to repaint and the log is the only
   * scrollback there is. Callers use this to tell which one happened.
   */
  readonly reattached: boolean;

  constructor(opts: TerminalOptions) {
    this.logPath = opts.logPath;
    this.reattached = !opts.shell && tmuxSessionExists(opts.sessionName);

    // Opened synchronously, before the PTY exists. An async open here would let the
    // shell's first output - the prompt, and anything written in the same tick as
    // the constructor - reach the browser but miss the log, so a pod restart would
    // replay a scrollback with a hole at the top of it.
    mkdirSync(dirname(this.logPath), { recursive: true });
    this.log = createWriteStream(this.logPath, { flags: "a" });

    // `new-session -A` attaches if it exists and creates it if it does not, which
    // makes reconnect and first-connect the same code path.
    const [file, args] = opts.shell
      ? [opts.shell, [] as string[]]
      : [
          "tmux",
          [
            ...(opts.tmuxConf ? ["-f", opts.tmuxConf] : []),
            "new-session",
            "-A",
            "-s",
            opts.sessionName,
          ],
        ];

    this.pty = spawn(file, args, {
      name: "xterm-256color",
      cols: 120,
      rows: 32,
      cwd: opts.cwd,
      // HOME is inherited, not set. The workspace is a directory INSIDE the
      // learner's home rather than the home itself, so `~` is one level up and
      // every dotfile a shell writes - history most of all - lands outside the
      // git tree. In a drill whose entire subject is what is and is not
      // committed, a .ash_history showing up in `git status` is not cosmetic.
      env: { ...process.env, TERM: "xterm-256color" },
    });

    this.pty.onData((chunk) => {
      if (this.disposed) return;
      this.log.write(chunk);
      if (!this.subscribed) this.early.push(chunk);
    });
  }

  onData(cb: (chunk: string) => void): void {
    if (!this.subscribed) {
      this.subscribed = true;
      const buffered = this.early.join("");
      this.early = [];
      if (buffered) cb(buffered);
    }
    this.pty.onData(cb);
  }

  write(data: string): void {
    this.pty.write(data);
  }

  resize(cols: number, rows: number): void {
    try {
      this.pty.resize(cols, rows);
    } catch {
      // A resize race against a dying PTY is not worth crashing the server over.
    }
  }

  /** The tail of the log, capped, for painting the terminal on reconnect. */
  async replay(): Promise<string> {
    let handle;
    try {
      handle = await open(this.logPath, "r");
    } catch {
      return "";
    }
    try {
      const { size } = await handle.stat();
      const start = Math.max(0, size - REPLAY_CAP_BYTES);
      const buf = Buffer.alloc(Math.min(size, REPLAY_CAP_BYTES));
      await handle.read(buf, 0, buf.length, start);
      return buf.toString("utf8");
    } finally {
      await handle.close();
    }
  }

  /**
   * Drop this handle on the terminal. In production that is a browser disconnect,
   * and the tmux session it was attached to keeps running - killing the client is
   * the point, not a side effect.
   *
   * The flag is set before the kill because node-pty can deliver a last chunk after
   * it, and a write to an ended stream is an unhandled error event that takes the
   * whole server down.
   */
  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    try {
      this.pty.kill();
    } catch {
      // Already gone.
    }
    this.log.end();
  }
}
