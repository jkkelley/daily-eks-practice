import {
  Suspense,
  lazy,
  useCallback,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { Panel, PanelGroup, PanelResizeHandle } from "react-resizable-panels";
import type { DependencyStatus, SessionState, Verdict } from "@drill/shared";
import { useDrillSocket } from "./lib/ws.ts";
import {
  getFile,
  getScenario,
  getTasks,
  getTree,
  getGitStatus,
  getArgo,
  type ArgoApplication,
  type GitStatus,
  type PublicTask,
  type ScenarioMeta,
  type TreeNode,
} from "./lib/api.ts";
import {
  applyChrome,
  loadSavedTheme,
  saveTheme,
  themeById,
} from "./lib/themes.ts";
import { languageFor } from "./lib/language.ts";
import { TerminalPanel } from "./panels/TerminalPanel.tsx";
import { Explorer } from "./panels/Explorer.tsx";
import {
  ActivityRail,
  type SidebarView,
} from "./panels/ActivityRail.tsx";
import { SourceControl } from "./panels/SourceControl.tsx";
import { ThemePicker } from "./panels/ThemePicker.tsx";
import { AnswersPanel } from "./panels/AnswersPanel.tsx";
import { HelpPanel } from "./panels/HelpPanel.tsx";
import { ArgoWidget } from "./panels/ArgoWidget.tsx";
import { StatusBar } from "./panels/StatusBar.tsx";
import type { OpenFile } from "./panels/EditorPanel.tsx";

/** Monaco is most of the bundle. It loads after the console has painted, not before. */
const EditorPanel = lazy(() =>
  import("./panels/EditorPanel.tsx").then((m) => ({ default: m.EditorPanel })),
);

type Side = "answers" | "help" | "argo";

export function App() {
  const { send, onMessage, connected } = useDrillSocket();

  const [meta, setMeta] = useState<ScenarioMeta | null>(null);
  const [tasks, setTasks] = useState<PublicTask[]>([]);
  const [tree, setTree] = useState<TreeNode[]>([]);
  const [state, setState] = useState<SessionState | null>(null);
  const [deps, setDeps] = useState<DependencyStatus[]>([]);
  const [side, setSide] = useState<Side>("answers");

  const [openFiles, setOpenFiles] = useState<OpenFile[]>([]);
  const [activePath, setActivePath] = useState<string | null>(null);
  const [dirty, setDirty] = useState<Set<string>>(new Set());
  const [cursor, setCursor] = useState<{ line: number; column: number } | null>(
    null,
  );

  const [sidebar, setSidebar] = useState<SidebarView | null>("explorer");
  const [git, setGit] = useState<GitStatus | null>(null);
  const [argo, setArgo] = useState<ArgoApplication | null>(null);
  const [picking, setPicking] = useState(false);
  const [theme, setTheme] = useState(loadSavedTheme);

  useEffect(() => {
    void getScenario()
      .then(setMeta)
      .catch(() => setMeta(null));
    void getTasks()
      .then(setTasks)
      .catch(() => setTasks([]));
    void getTree()
      .then(setTree)
      .catch(() => setTree([]));
  }, []);

  /**
   * Poll git while the drill is running.
   *
   * Commits happen in the TERMINAL, not here - that is the whole design - so
   * nothing in this app knows when the working tree changed. There is no event to
   * subscribe to, and a stale "1 change" badge next to a clean tree teaches the
   * opposite of the lesson. A `git status` on a small workspace is a few
   * milliseconds; three seconds of it is cheaper than being wrong.
   */
  useEffect(() => {
    let alive = true;
    const read = () =>
      void getGitStatus()
        .then((s) => alive && setGit(s))
        .catch(() => undefined);
    read();
    const timer = window.setInterval(read, 3000);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, []);

  /**
   * Poll Argo, but only while its tab is open.
   *
   * Three seconds because the interesting window is short: after a `rollout undo`
   * you have until Argo's next reconciliation to see the app go OutOfSync, and the
   * cluster is configured to reconcile every ten. Gating on the tab keeps a drill
   * that never opens this panel from making an API call a thousand times an hour.
   */
  useEffect(() => {
    if (side !== "argo") return;
    let alive = true;
    const read = () =>
      void getArgo()
        .then((a) => alive && setArgo(a))
        .catch(() => undefined);
    read();
    const timer = window.setInterval(read, 3000);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [side]);

  useEffect(() => {
    applyChrome(themeById(theme));
  }, [theme]);

  const openFile = useCallback((path: string) => {
    setActivePath(path);
    setOpenFiles((prev) => {
      if (prev.some((f) => f.path === path)) return prev;
      // Placeholder first, real content when it lands. Without it the tab does not
      // appear until the fetch resolves, and clicking a file in the explorer looks
      // like it did nothing at all. The placeholder content is null, not "" - see
      // OpenFile, where an empty string would pin the buffer empty for good.
      void getFile(path)
        .then((f) =>
          setOpenFiles((cur) =>
            cur.map((o) =>
              o.path === path ? { ...o, content: f.content } : o,
            ),
          ),
        )
        .catch(() => undefined);
      return [...prev, { path, content: null }];
    });
  }, []);

  const closeFile = useCallback((path: string) => {
    setOpenFiles((prev) => {
      const next = prev.filter((f) => f.path !== path);
      setActivePath((cur) =>
        cur === path ? (next[next.length - 1]?.path ?? null) : cur,
      );
      return next;
    });
  }, []);

  const currentId = state?.currentTaskId ?? tasks[0]?.id;
  const currentTask = tasks.find((t) => t.id === currentId);
  // The current task names the file when it has one; otherwise the scenario's file
  // task does. A drill is about one repo, and an editor that starts empty wastes
  // the most valuable rectangle on the screen.
  const taskPath = currentTask?.path ?? tasks.find((t) => t.path)?.path;

  const [seeded, setSeeded] = useState(false);
  useEffect(() => {
    if (!seeded && taskPath) {
      setSeeded(true);
      openFile(taskPath);
    }
  }, [seeded, taskPath, openFile]);

  useEffect(
    () =>
      onMessage((msg) => {
        if (msg.type === "session") setState(msg.state);
        else if (msg.type === "deps") setDeps(msg.deps);
        else if (msg.type === "file:saved") {
          setDirty((prev) => {
            if (!prev.has(msg.path)) return prev;
            const next = new Set(prev);
            next.delete(msg.path);
            return next;
          });
          // The terminal is a real shell in the same working tree, so a save is a
          // decent moment to notice files it created. Cheap, and it keeps the
          // explorer from going stale over a half-hour drill.
          void getTree()
            .then(setTree)
            .catch(() => undefined);
        }
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

  const markDirty = useCallback((path: string) => {
    setDirty((prev) => (prev.has(path) ? prev : new Set(prev).add(path)));
  }, []);

  const onCursor = useCallback(
    (line: number, column: number) => setCursor({ line, column }),
    [],
  );

  return (
    <div className="shell">
      <div className="stage">
        <ActivityRail
          view={sidebar}
          onSelect={setSidebar}
          onOpenThemes={() => setPicking(true)}
          changeCount={git?.files.length ?? 0}
        />

        <PanelGroup
          direction="horizontal"
          className="workbench"
          autoSaveId="drill-h"
        >
          {sidebar && (
            <>
              <Panel defaultSize={17} minSize={10} maxSize={34} order={1}>
                {sidebar === "explorer" ? (
                  <Explorer
                    tree={tree}
                    activePath={activePath}
                    dirty={dirty}
                    onOpen={openFile}
                    taskPath={taskPath}
                  />
                ) : (
                  <SourceControl
                    status={git}
                    activePath={activePath}
                    onOpen={openFile}
                  />
                )}
              </Panel>
              <PanelResizeHandle className="handle" />
            </>
          )}

          <Panel defaultSize={50} minSize={26} order={2}>
            {/* Editor over terminal: you read the file, then you act on it, and
                reading top-to-bottom is the order the work happens in. */}
            <PanelGroup direction="vertical" autoSaveId="drill-v">
              <Panel defaultSize={52} minSize={15}>
                <Suspense fallback={<EditorLoading />}>
                  <EditorPanel
                    open={openFiles}
                    activePath={activePath}
                    dirty={dirty}
                    theme={theme}
                    taskPath={taskPath}
                    send={send}
                    onActivate={setActivePath}
                    onClose={closeFile}
                    onDirty={markDirty}
                    onCursor={onCursor}
                  />
                </Suspense>
              </Panel>
              <PanelResizeHandle className="handle" />
              <Panel defaultSize={48} minSize={18}>
                <TerminalPanel
                  send={send}
                  onMessage={onMessage}
                  connected={connected}
                  theme={theme}
                />
              </Panel>
            </PanelGroup>
          </Panel>

          <PanelResizeHandle className="handle" />

          <Panel defaultSize={34} minSize={22} order={3}>
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
                <button
                  className="tab"
                  role="tab"
                  aria-selected={side === "argo"}
                  onClick={() => setSide("argo")}
                >
                  argo
                </button>
                <span className="grow" />
                <span>{meta?.title ?? ""}</span>
              </header>
              <div className="body">
                {side === "answers" ? (
                  <AnswersPanel
                    tasks={tasks}
                    state={state}
                    onGraded={onGraded}
                  />
                ) : side === "help" ? (
                  <HelpPanel meta={meta} deps={deps} />
                ) : (
                  <ArgoWidget app={argo} />
                )}
              </div>
            </section>
          </Panel>
        </PanelGroup>
      </div>

      <StatusBar
        state={state}
        total={tasks.length}
        connected={connected}
        themeLabel={themeById(theme).label}
        onOpenThemes={() => setPicking(true)}
        cursor={activePath ? cursor : null}
        language={activePath ? languageFor(activePath) : null}
      />

      {picking && (
        <ThemePicker
          current={theme}
          onPreview={setTheme}
          onCommit={(id) => {
            setTheme(id);
            saveTheme(id);
            setPicking(false);
          }}
          onCancel={() => setPicking(false)}
        />
      )}
    </div>
  );
}

/** The editor panel's own chrome, so the layout does not jump when Monaco lands. */
function EditorLoading(): ReactNode {
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
