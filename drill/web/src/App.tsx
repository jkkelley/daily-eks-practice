import { Suspense, lazy, useCallback, useEffect, useState } from "react";
import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import type { DependencyStatus, SessionState, Verdict } from "@drill/shared";
import { useDrillSocket } from "./lib/ws.ts";
import {
  getScenario,
  getTasks,
  type PublicTask,
  type ScenarioMeta,
} from "./lib/api.ts";
import { TerminalPanel } from "./panels/TerminalPanel.tsx";
import { AnswersPanel } from "./panels/AnswersPanel.tsx";
import { HelpPanel } from "./panels/HelpPanel.tsx";
import { StatusBar } from "./panels/StatusBar.tsx";

/** Monaco is most of the bundle. It loads after the console has painted, not before. */
const EditorPanel = lazy(() =>
  import("./panels/EditorPanel.tsx").then((m) => ({ default: m.EditorPanel })),
);


type Theme = "dark" | "light";
type Side = "answers" | "help";

export function App() {
  const { send, onMessage, connected } = useDrillSocket();

  const [meta, setMeta] = useState<ScenarioMeta | null>(null);
  const [tasks, setTasks] = useState<PublicTask[]>([]);
  const [state, setState] = useState<SessionState | null>(null);
  const [deps, setDeps] = useState<DependencyStatus[]>([]);
  const [side, setSide] = useState<Side>("answers");
  const [savedAt, setSavedAt] = useState(0);
  const [theme, setTheme] = useState<Theme>("dark");

  useEffect(() => {
    void getScenario()
      .then(setMeta)
      .catch(() => setMeta(null));
    void getTasks()
      .then(setTasks)
      .catch(() => setTasks([]));
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  useEffect(
    () =>
      onMessage((msg) => {
        if (msg.type === "session") setState(msg.state);
        else if (msg.type === "deps") setDeps(msg.deps);
        else if (msg.type === "file:saved") setSavedAt(Date.now());
      }),
    [onMessage],
  );

  // A verdict changes what has passed, and what has passed changes which task the
  // editor is pointed at. Re-reading the session is one round trip and keeps a
  // single source of truth for progress instead of two that can disagree.
  const onGraded = useCallback((_v: Verdict) => {
    void fetch("/api/session")
      .then((r) => r.json() as Promise<SessionState>)
      .then(setState)
      .catch(() => undefined);
  }, []);

  const currentId = state?.currentTaskId ?? tasks[0]?.id;
  const currentTask = tasks.find((t) => t.id === currentId);

  // The current task names the file when it has one. When it does not, fall back
  // to the scenario's file task rather than showing an empty panel: a drill is
  // about one repo, the terminal and the editor are looking at the same working
  // tree, and being able to read values.yaml while running kubectl against it is
  // the point of having both on screen at once.
  const editorPath = currentTask?.path ?? tasks.find((t) => t.path)?.path;

  return (
    <div className="shell">
      <PanelGroup direction="horizontal" className="stage" autoSaveId="drill-h">
        <Panel defaultSize={62} minSize={30}>
          {/* Editor over terminal: you read the file, then you act on it, and
              reading top-to-bottom is the order the work happens in. */}
          <PanelGroup direction="vertical" autoSaveId="drill-v">
            <Panel defaultSize={45} minSize={15}>
              <Suspense fallback={<EditorLoading />}>
                <EditorPanel
                  path={editorPath}
                  send={send}
                  savedAt={savedAt}
                />
              </Suspense>
            </Panel>
            <PanelResizeHandle className="handle" />
            <Panel defaultSize={55} minSize={20}>
              <TerminalPanel
                send={send}
                onMessage={onMessage}
                connected={connected}
              />
            </Panel>
          </PanelGroup>
        </Panel>

        <PanelResizeHandle className="handle" />

        <Panel defaultSize={38} minSize={24}>
          <section className="panel">
            <header>
              <button
                className="tab"
                role="tab"
                aria-selected={side === "answers"}
                onClick={() => setSide("answers")}
              >
                tasks
              </button>
              <button
                className="tab"
                role="tab"
                aria-selected={side === "help"}
                onClick={() => setSide("help")}
              >
                card
              </button>
              <span className="grow" />
              <span>{meta?.title ?? ""}</span>
            </header>
            <div className="body">
              {side === "answers" ? (
                <AnswersPanel tasks={tasks} state={state} onGraded={onGraded} />
              ) : (
                <HelpPanel meta={meta} deps={deps} />
              )}
            </div>
          </section>
        </Panel>
      </PanelGroup>

      <StatusBar
        state={state}
        total={tasks.length}
        connected={connected}
        theme={theme}
        onToggleTheme={() => setTheme(theme === "dark" ? "light" : "dark")}
      />
    </div>
  );
}

/** The editor panel's own chrome, so the layout does not jump when Monaco lands. */
function EditorLoading() {
  return (
    <section className="panel">
      <header>
        <span className="dot starting" />
        <span>editor</span>
      </header>
      <div className="body">
        <p className="empty">loading the editor</p>
      </div>
    </section>
  );
}
