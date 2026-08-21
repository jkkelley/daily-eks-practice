import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import type { ClientMessage, ServerMessage } from "@drill/shared";

interface Props {
  send: (m: ClientMessage) => void;
  onMessage: (cb: (m: ServerMessage) => void) => () => void;
  connected: boolean;
}

export function TerminalPanel({ send, onMessage, connected }: Props) {
  const hostRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);

  useEffect(() => {
    if (!hostRef.current) return;

    const term = new Terminal({
      fontFamily:
        "'JetBrains Mono', 'IBM Plex Mono', ui-monospace, 'SF Mono', Menlo, monospace",
      fontSize: 12.5,
      // Slightly open leading; the default is cramped at this size and it is the
      // single biggest thing separating a terminal that feels good from one that does not.
      lineHeight: 1.3,
      cursorBlink: true,
      cursorStyle: "bar",
      allowProposedApi: true,
      scrollback: 10_000,
      theme: {
        background: "#171c26",
        foreground: "#e6e6e6",
        cursor: "#7aa2f7",
        cursorAccent: "#171c26",
        selectionBackground: "#7aa2f733",
        black: "#1c222e",
        red: "#f7768e",
        green: "#9ece6a",
        yellow: "#e0af68",
        blue: "#7aa2f7",
        magenta: "#bb9af7",
        cyan: "#7dcfff",
        white: "#e6e6e6",
        brightBlack: "#9aa5b1",
      },
    });

    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(hostRef.current);
    termRef.current = term;
    fitRef.current = fit;

    // A frame, not the same tick. Calling fit() immediately after open() measures
    // an element the browser has not laid out yet, and xterm's viewport then throws
    // "Cannot read properties of undefined (reading 'dimensions')" out of
    // syncScrollArea - silent unless you are watching the console, and it leaves
    // the terminal wrongly sized.
    //
    // No WebglAddon. It was tried and removed: under software rendering it creates
    // a context, throws nothing, never reports a context loss, and draws NOTHING.
    // The whole terminal is blank with no error anywhere, which is the single worst
    // failure this surface has - the drill is run from here. A GPU-blocklisted
    // browser, a VM or a remote desktop can all land in that state, and the DOM
    // renderer xterm uses by default is correct in every one of them. The throughput
    // WebGL buys matters for a firehose; this terminal watches a rollout.
    const frame = requestAnimationFrame(() => {
      try {
        fit.fit();
      } catch {
        /* the panel is not measurable yet; the ResizeObserver will get it */
      }
      term.focus();
    });

    term.onData((data) => send({ type: "term:input", data }));

    const unsubscribe = onMessage((msg) => {
      if (msg.type === "term:output") term.write(msg.data);
    });

    // ResizeObserver rather than a window listener: the panel is resizable
    // independently of the window, and a mis-sized PTY corrupts every redraw.
    // Deferred a frame because a resize during layout throws in xterm's renderer.
    const ro = new ResizeObserver(() => {
      requestAnimationFrame(() => {
        try {
          fit.fit();
        } catch {
          return;
        }
        send({ type: "term:resize", cols: term.cols, rows: term.rows });
      });
    });
    ro.observe(hostRef.current);

    return () => {
      cancelAnimationFrame(frame);
      unsubscribe();
      ro.disconnect();
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
  }, [send, onMessage]);

  /**
   * Tell the server how big this terminal actually is, the moment there is a
   * server to tell.
   *
   * The ResizeObserver fires on mount, which is BEFORE the websocket has opened,
   * and send() drops anything sent on a socket that is not OPEN. So the very
   * message that matters most was the one guaranteed to be thrown away: the PTY
   * stayed at the 120x32 it was spawned with while the browser rendered something
   * else entirely, and tmux redrew a 32-row screen into a 23-row terminal. That
   * does not fail loudly - it paints a scroll region past the bottom of the screen
   * and leaves the prompt in a row nothing displays, so the terminal looks blank
   * while the session behind it is perfectly healthy.
   */
  useEffect(() => {
    const term = termRef.current;
    const fit = fitRef.current;
    if (!connected || !term || !fit) return;
    try {
      fit.fit();
    } catch {
      /* not measurable yet; the ResizeObserver will follow up */
    }
    send({ type: "term:resize", cols: term.cols, rows: term.rows });
  }, [connected, send]);

  return (
    <section className="panel">
      <header>
        <span className={connected ? "dot live" : "dot absent"} />
        <span>terminal</span>
        <span className="grow" />
        <span>{connected ? "tmux · drill" : "reconnecting"}</span>
      </header>
      <div className="body term-host" ref={hostRef} />
    </section>
  );
}
