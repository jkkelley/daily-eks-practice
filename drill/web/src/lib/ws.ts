import { useEffect, useRef, useState, useCallback } from "react";
import type { ClientMessage, ServerMessage } from "@drill/shared";

/**
 * One socket for the whole app.
 *
 * It reconnects with backoff because a drill runs for half an hour and a dropped
 * frame should not mean a page refresh - tmux kept the shell alive, so the UI
 * should be able to catch up to it.
 */
export function useDrillSocket() {
  const socketRef = useRef<WebSocket | null>(null);
  const handlers = useRef(new Set<(m: ServerMessage) => void>());
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    let closed = false;
    let attempt = 0;
    let timer: number | undefined;

    const connect = () => {
      if (closed) return;
      const proto = location.protocol === "https:" ? "wss" : "ws";
      const ws = new WebSocket(`${proto}://${location.host}/ws`);
      socketRef.current = ws;

      ws.onopen = () => {
        attempt = 0;
        setConnected(true);
      };
      ws.onmessage = (ev) => {
        let msg: ServerMessage;
        try {
          msg = JSON.parse(ev.data as string) as ServerMessage;
        } catch {
          return;
        }
        for (const h of handlers.current) h(msg);
      };
      ws.onclose = () => {
        setConnected(false);
        if (closed) return;
        const delay = Math.min(1000 * 2 ** attempt++, 10_000);
        timer = window.setTimeout(connect, delay);
      };
      // Without this an offline server logs an unhandled error on every retry and
      // buries whatever the actual failure was.
      ws.onerror = () => ws.close();
    };

    connect();
    return () => {
      closed = true;
      if (timer) clearTimeout(timer);
      socketRef.current?.close();
    };
  }, []);

  const send = useCallback((msg: ClientMessage) => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      socketRef.current.send(JSON.stringify(msg));
    }
  }, []);

  const onMessage = useCallback((cb: (m: ServerMessage) => void) => {
    handlers.current.add(cb);
    return () => {
      handlers.current.delete(cb);
    };
  }, []);

  return { send, onMessage, connected };
}
