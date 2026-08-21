import { useEffect, useRef, useState } from "react";
import Editor from "@monaco-editor/react";
import type { ClientMessage } from "@drill/shared";
import { getFile } from "../lib/api.ts";
import { DRILL_DARK } from "../lib/monaco.ts";

interface Props {
  /** The file the current task is about, or undefined when the task is not a file task. */
  path: string | undefined;
  send: (m: ClientMessage) => void;
  /** Bumped by App each time the server acknowledges a save. */
  savedAt: number;
}

const AUTOSAVE_MS = 600;

export function EditorPanel({ path, send, savedAt }: Props) {
  const [content, setContent] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [showSaved, setShowSaved] = useState(false);
  const timer = useRef<number | undefined>(undefined);

  useEffect(() => {
    setContent(null);
    setError(null);
    if (!path) return;
    let stale = false;
    getFile(path)
      .then((f) => !stale && setContent(f.content))
      .catch((e: Error) => !stale && setError(e.message));
    return () => {
      stale = true;
    };
  }, [path]);

  // The indicator is driven by the server's acknowledgement, not by the keystroke
  // that triggered the save. The two differ exactly when it matters.
  useEffect(() => {
    if (!savedAt) return;
    setShowSaved(true);
    const t = window.setTimeout(() => setShowSaved(false), 1600);
    return () => clearTimeout(t);
  }, [savedAt]);

  useEffect(() => () => clearTimeout(timer.current), []);

  const onChange = (next: string | undefined) => {
    if (next === undefined || !path) return;
    // Debounced rather than per-keystroke: the same contract as VS Code, so
    // nothing about it has to be explained.
    clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      send({ type: "file:save", path, content: next });
    }, AUTOSAVE_MS);
  };

  return (
    <section className="panel">
      <header>
        <span className={path ? "dot ready" : "dot"} />
        <span>editor</span>
        <span className="grow" />
        <span
          className="mono"
          style={{ letterSpacing: 0, textTransform: "none" }}
        >
          {path ?? "no file for this task"}
        </span>
        <span className={showSaved ? "saved on" : "saved"}>saved</span>
      </header>
      <div className="body editor-host">
        {!path ? (
          <p className="empty">
            This task is not about a file.
            <br />
            The editor opens when one is.
          </p>
        ) : error ? (
          <p className="empty">{error}</p>
        ) : content === null ? (
          <p className="empty">opening {path}</p>
        ) : (
          <Editor
            height="100%"
            theme={DRILL_DARK}
            defaultLanguage="yaml"
            path={path}
            defaultValue={content}
            onChange={onChange}
            options={{
              fontFamily:
                "'JetBrains Mono', 'IBM Plex Mono', ui-monospace, 'SF Mono', Menlo, monospace",
              fontSize: 12.5,
              lineHeight: 20,
              minimap: { enabled: false },
              scrollBeyondLastLine: false,
              renderLineHighlight: "line",
              smoothScrolling: true,
              padding: { top: 10, bottom: 10 },
              tabSize: 2,
              automaticLayout: true,
              scrollbar: {
                verticalScrollbarSize: 9,
                horizontalScrollbarSize: 9,
              },
            }}
          />
        )}
      </div>
    </section>
  );
}
