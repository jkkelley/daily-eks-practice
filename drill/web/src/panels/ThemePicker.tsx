import { useEffect, useMemo, useRef, useState } from "react";
import { THEMES } from "../lib/themes.ts";

interface Props {
  current: string;
  onPreview: (id: string) => void;
  onCommit: (id: string) => void;
  onCancel: () => void;
}

/**
 * The theme picker, shaped like VS Code's quick pick.
 *
 * It previews as you arrow through, and only commits on Enter or a click - which
 * is the behaviour that makes choosing a theme feel like trying one on rather
 * than filling in a form. Escape puts back whatever you started with.
 *
 * There is deliberately no global keyboard shortcut to open this. The terminal
 * next to it is a real shell, and stealing a chord from a shell the learner is
 * being taught to use would be a genuinely bad trade for an easter egg. It opens
 * from the rail, or from the theme name in the status bar.
 */
export function ThemePicker({ current, onPreview, onCommit, onCancel }: Props) {
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(() =>
    Math.max(
      0,
      THEMES.findIndex((t) => t.id === current),
    ),
  );
  const inputRef = useRef<HTMLInputElement>(null);
  const started = useRef(current);

  const matches = useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? THEMES.filter((t) => t.label.toLowerCase().includes(q)) : THEMES;
  }, [query]);

  useEffect(() => inputRef.current?.focus(), []);

  // Preview whatever is highlighted, so arrowing down repaints the console.
  useEffect(() => {
    const hit = matches[Math.min(index, matches.length - 1)];
    if (hit) onPreview(hit.id);
  }, [index, matches, onPreview]);

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setIndex((i) => Math.min(i + 1, matches.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setIndex((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      const hit = matches[Math.min(index, matches.length - 1)];
      if (hit) onCommit(hit.id);
    } else if (e.key === "Escape") {
      e.preventDefault();
      onPreview(started.current);
      onCancel();
    }
  };

  return (
    <div
      className="quick-backdrop"
      onMouseDown={() => {
        onPreview(started.current);
        onCancel();
      }}
    >
      <div
        className="quick"
        role="dialog"
        aria-label="Select colour theme"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <input
          ref={inputRef}
          className="quick-input"
          placeholder="Select Colour Theme (up and down to preview)"
          value={query}
          spellCheck={false}
          onChange={(e) => {
            setQuery(e.target.value);
            setIndex(0);
          }}
          onKeyDown={onKeyDown}
        />
        <ul className="quick-list">
          {matches.map((theme, i) => (
            <li key={theme.id}>
              <button
                className={`quick-row ${i === Math.min(index, matches.length - 1) ? "on" : ""}`}
                onMouseEnter={() => setIndex(i)}
                onClick={() => onCommit(theme.id)}
              >
                <span className="swatch">
                  <i style={{ background: theme.chrome["--panel"] }} />
                  <i style={{ background: theme.chrome["--accent"] }} />
                  <i style={{ background: theme.chrome["--good"] }} />
                </span>
                <span className="quick-label">{theme.label}</span>
                <span className="grow" />
                <span className="quick-kind">{theme.kind} themes</span>
              </button>
            </li>
          ))}
          {matches.length === 0 && (
            <li>
              <p className="quick-none">no theme matches that</p>
            </li>
          )}
        </ul>
      </div>
    </div>
  );
}
