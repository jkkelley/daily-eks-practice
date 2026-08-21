/**
 * The activity rail.
 *
 * It is the single cheapest thing that makes a page read as an IDE rather than as
 * a text box with a sidebar. Every icon does something: there are no placeholder
 * buttons, because a rail where half the icons are dead is worse than a short one
 * where none are.
 *
 * Clicking the active view collapses the sidebar, exactly as VS Code does, which
 * is how you get the editor's width back on a small screen.
 */
export type SidebarView = "explorer" | "scm";

interface Props {
  view: SidebarView | null;
  onSelect: (view: SidebarView | null) => void;
  onOpenThemes: () => void;
  /** Badged on the source-control icon, the way VS Code counts pending changes. */
  changeCount: number;
}

export function ActivityRail({
  view,
  onSelect,
  onOpenThemes,
  changeCount,
}: Props) {
  const toggle = (next: SidebarView) => onSelect(view === next ? null : next);

  return (
    <nav className="rail" aria-label="views">
      <button
        className={`rail-btn ${view === "explorer" ? "on" : ""}`}
        onClick={() => toggle("explorer")}
        title={view === "explorer" ? "Hide the explorer" : "Explorer"}
        aria-pressed={view === "explorer"}
      >
        <FilesIcon />
      </button>
      <button
        className={`rail-btn ${view === "scm" ? "on" : ""}`}
        onClick={() => toggle("scm")}
        title="Source control - what git has, and has not, seen"
        aria-pressed={view === "scm"}
      >
        <BranchIcon />
        {changeCount > 0 && <span className="rail-badge">{changeCount}</span>}
      </button>
      <button
        className="rail-btn"
        onClick={onOpenThemes}
        title="Change the colour theme"
      >
        <PaletteIcon />
      </button>
    </nav>
  );
}

/* Stroked, 24px, 1.4 weight - drawn to sit with the rest of the console rather
   than lifted from an icon set with its own opinions about line weight. */

function FilesIcon() {
  return (
    <svg viewBox="0 0 24 24" width="21" height="21" aria-hidden="true">
      <path
        d="M13.5 3.5H7A1.5 1.5 0 0 0 5.5 5v14A1.5 1.5 0 0 0 7 20.5h10a1.5 1.5 0 0 0 1.5-1.5V8.5z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <path
        d="M13.5 3.5V8.5h5"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
    </svg>
  );
}

function BranchIcon() {
  return (
    <svg viewBox="0 0 24 24" width="21" height="21" aria-hidden="true">
      <circle
        cx="7"
        cy="5.5"
        r="2.2"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
      />
      <circle
        cx="7"
        cy="18.5"
        r="2.2"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
      />
      <circle
        cx="17"
        cy="5.5"
        r="2.2"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
      />
      <path
        d="M7 7.7v8.6M17 7.7v1.8a4 4 0 0 1-4 4h-2.8"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  );
}

function PaletteIcon() {
  return (
    <svg viewBox="0 0 24 24" width="21" height="21" aria-hidden="true">
      <path
        d="M12 3.5a8.5 8.5 0 0 0 0 17c1.1 0 1.8-.8 1.8-1.7 0-.5-.2-.9-.5-1.2-.3-.3-.5-.7-.5-1.1 0-.9.8-1.7 1.7-1.7h1.3a4.7 4.7 0 0 0 4.7-4.7C20.5 6.4 16.7 3.5 12 3.5Z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <circle cx="8" cy="10" r="1.2" fill="currentColor" />
      <circle cx="12" cy="7.6" r="1.2" fill="currentColor" />
      <circle cx="16" cy="10" r="1.2" fill="currentColor" />
    </svg>
  );
}
