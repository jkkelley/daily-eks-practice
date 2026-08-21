import type { SessionState } from "@drill/shared";

interface Props {
  state: SessionState | null;
  total: number;
  connected: boolean;
  theme: "dark" | "light";
  onToggleTheme: () => void;
}

export function StatusBar({
  state,
  total,
  connected,
  theme,
  onToggleTheme,
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
      <span className={connected ? "dot live" : "dot absent"} />
      <span>{connected ? "connected" : "reconnecting"}</span>
      <span className="sep" />
      <button className="btn quiet" onClick={onToggleTheme}>
        {theme === "dark" ? "light" : "dark"}
      </button>
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
