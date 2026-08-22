import { useEffect, useRef } from "react";
import Editor, { type OnMount } from "@monaco-editor/react";
import type { ClientMessage } from "@drill/shared";
// Side-effect import, and load-bearing: it points the loader at the bundled Monaco
// instead of cdn.jsdelivr.net and registers the themes. It lives HERE, in the lazy
// chunk, rather than in main.tsx - that is what keeps Monaco out of the entry
// bundle. Remove it and nothing fails to compile, nothing fails to test, and the
// editor quietly starts fetching itself from the internet.
import "../lib/monaco.ts";
import { languageFor } from "../lib/language.ts";

export interface OpenFile {
  path: string;
  /**
   * null until the fetch lands.
   *
   * The tab appears immediately on click, because a tab that waits for a network
   * round trip makes the explorer feel broken. But the EDITOR must not mount until
   * the content is here: Monaco applies `defaultValue` once, when it creates the
   * model for a path, and ignores every later change to it. Mounting against a
   * placeholder therefore pins the buffer empty forever - the file loads, the state
   * updates, and the editor still shows nothing.
   */
  content: string | null;
}

interface Props {
  open: OpenFile[];
  activePath: string | null;
  dirty: Set<string>;
  theme: string;
  /** The file the current task is graded from, so the tab can say so. */
  taskPath: string | undefined;
  send: (m: ClientMessage) => void;
  onActivate: (path: string) => void;
  onClose: (path: string) => void;
  onDirty: (path: string) => void;
  onCursor: (line: number, column: number) => void;
}

const AUTOSAVE_MS = 600;

export function EditorPanel({
  open,
  activePath,
  dirty,
  theme,
  taskPath,
  send,
  onActivate,
  onClose,
  onDirty,
  onCursor,
}: Props) {
  const timers = useRef(new Map<string, number>());

  useEffect(() => {
    const pending = timers.current;
    return () => {
      for (const id of pending.values()) clearTimeout(id);
      pending.clear();
    };
  }, []);

  const active = open.find((f) => f.path === activePath);

  const onMount: OnMount = (editor) => {
    // Report where the cursor already is. onDidChangeCursorPosition only fires on
    // a CHANGE, so without this the status bar has no position until you click in
    // the editor, and the one thing it is there to show is blank on arrival.
    const at = editor.getPosition();
    if (at) onCursor(at.lineNumber, at.column);
    editor.onDidChangeCursorPosition((e) =>
      onCursor(e.position.lineNumber, e.position.column),
    );
  };

  const onChange = (next: string | undefined, path: string) => {
    if (next === undefined) return;
    onDirty(path);
    // Per path, not one shared timer: switching tabs mid-edit must not cancel the
    // save of the file you just left.
    const existing = timers.current.get(path);
    if (existing) clearTimeout(existing);
    timers.current.set(
      path,
      window.setTimeout(() => {
        send({ type: "file:save", path, content: next });
        timers.current.delete(path);
      }, AUTOSAVE_MS),
    );
  };

  return (
    <section className="panel editor-panel">
      <div className="tabs" role="tablist">
        {open.map((file) => (
          <div
            key={file.path}
            className={`tab-item ${file.path === activePath ? "on" : ""}`}
          >
            <button
              className="tab-open"
              role="tab"
              aria-selected={file.path === activePath}
              onClick={() => onActivate(file.path)}
              title={file.path}
            >
              <span className="tab-name">{file.path.split("/").pop()}</span>
              {file.path === taskPath && (
                <span className="tab-badge">task</span>
              )}
            </button>
            <button
              className="tab-close"
              onClick={() => onClose(file.path)}
              title={`Close ${file.path}`}
              aria-label={`Close ${file.path}`}
            >
              {/* A dot rather than an x while unsaved, which is the one editor
                  convention nobody has to be taught. */}
              {dirty.has(file.path) ? <span className="tab-dirty" /> : "×"}
            </button>
          </div>
        ))}
        <span className="grow" />
      </div>

      {active && (
        <div className="breadcrumb">
          {active.path.split("/").map((part, i, all) => (
            <span key={i}>
              {i > 0 && <span className="crumb-sep">{"›"}</span>}
              <span className={i === all.length - 1 ? "crumb-leaf" : "crumb"}>
                {part}
              </span>
            </span>
          ))}
        </div>
      )}

      <div className="body editor-host">
        {!active ? (
          <p className="empty">
            Nothing open.
            <br />
            Pick a file in the explorer.
          </p>
        ) : active.content === null ? (
          <p className="empty">opening {active.path}</p>
        ) : (
          <Editor
            height="100%"
            theme={theme}
            // `path` is what makes Monaco keep one model per file, so undo history
            // and cursor position survive a tab switch. Without it every switch is
            // a fresh buffer and the undo stack silently resets.
            path={active.path}
            defaultLanguage={languageFor(active.path)}
            defaultValue={active.content}
            onMount={onMount}
            onChange={(v) => onChange(v, active.path)}
            options={{
              fontFamily:
                "'JetBrains Mono', 'IBM Plex Mono', ui-monospace, 'SF Mono', Menlo, monospace",
              fontSize: 12.5,
              lineHeight: 20,
              minimap: { enabled: false },
              scrollBeyondLastLine: false,
              renderLineHighlight: "line",
              smoothScrolling: true,
              padding: { top: 8, bottom: 10 },
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
