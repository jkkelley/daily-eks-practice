/**
 * The activity rail.
 *
 * It is the single cheapest thing that makes a page read as an IDE rather than as
 * a text box with a sidebar - which is why it is here even though it holds two
 * icons. Both do something: there are no placeholder buttons, because a rail of
 * icons where four of six are dead is worse than a rail of two that work.
 */
interface Props {
  explorerOpen: boolean;
  onToggleExplorer: () => void;
  onOpenThemes: () => void;
}

export function ActivityRail({
  explorerOpen,
  onToggleExplorer,
  onOpenThemes,
}: Props) {
  return (
    <nav className="rail" aria-label="views">
      <button
        className={`rail-btn ${explorerOpen ? "on" : ""}`}
        onClick={onToggleExplorer}
        title={explorerOpen ? "Hide the explorer" : "Show the explorer"}
        aria-pressed={explorerOpen}
      >
        <FilesIcon />
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
