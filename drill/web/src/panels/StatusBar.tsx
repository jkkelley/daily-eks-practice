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
}

export function StatusBar({
  state,
  total,
  connected,
  themeLabel,
  onOpenThemes,
  cursor,
  language,
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
      {/* Deliberately not styled as a primary action, and deliberately still inert.
          Ending a session - saving progress, then teardown - is the Phase 6 ticket
          and an explicit non-goal here. It has its place in the layout now so the
          layout does not move later, and it says so rather than pretending. */}
      <button
        className="btn quiet"
        disabled
        title="Ending a session lands with the session lifecycle. Until then: make down"
      >
        exit
      </button>
    </footer>
  );
}
