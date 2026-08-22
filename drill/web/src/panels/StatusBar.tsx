import type { SessionState } from "@drill/shared";

interface Props {
  state: SessionState | null;
  total: number;
  connected: boolean;
  themeLabel: string;
  onOpenThemes: () => void;
  /** Absent when nothing is open in the editor. */
  cursor: { line: number; column: number } | null;
  language: string | null;
  /** Opens the pause menu. Shipped inert in Phase 5; live since Phase 6. */
  onExit: () => void;
}

export function StatusBar({
  state,
  total,
  connected,
  themeLabel,
  onOpenThemes,
  cursor,
  language,
  onExit,
}: Props) {
  const passed = state?.passed.length ?? 0;
  return (
    <footer className="statusbar">
      <span className="brand">daily-eks-practice</span>
      <span className="sep" />
      <span>
        scenario <strong>{state?.scenario ?? "--"}</strong>
      </span>
      <span className="sep" />
      <span>
        session <strong>{state?.sessionId ?? "--"}</strong>
      </span>
      <span className="sep" />
      <span>
        <strong>
          {passed}/{total || "-"}
        </strong>{" "}
        passed
      </span>

      <span className="grow" />

      {/* The right-hand cluster is the editor's, the way it is in VS Code. It is
          most of what makes a page read as an IDE rather than as a text box, and
          it costs one cursor listener. */}
      {cursor && (
        <>
          <span>
            Ln {cursor.line}, Col {cursor.column}
          </span>
          <span className="sep" />
          <span>Spaces: 2</span>
          <span className="sep" />
          <span>UTF-8</span>
          <span className="sep" />
        </>
      )}
      {language && (
        <>
          <span>{language}</span>
          <span className="sep" />
        </>
      )}
      <button className="btn quiet" onClick={onOpenThemes} title="Change theme">
        {themeLabel}
      </button>
      <span className="sep" />
      <span className={connected ? "dot live" : "dot absent"} />
      <span>{connected ? "connected" : "reconnecting"}</span>
      <span className="sep" />
      {/* Not styled as a primary action, because it is a way OUT of a thing you
          came here to do. It is no longer inert: Phase 6 put the pause menu
          behind it, and Escape opens the same menu. */}
      <button
        className="btn quiet"
        onClick={onExit}
        title="Pause: restart, switch scenario, quit, or tear it down (Esc)"
      >
        exit
      </button>
    </footer>
  );
}
