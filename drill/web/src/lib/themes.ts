/**
 * The theme set.
 *
 * These are original rather than ports of Monokai, Solarized and friends. Two
 * reasons, and the second is the real one. The image is public, so bundling
 * somebody else's theme file means reading their licence first. And a drill that
 * ships its own named palettes is a nicer easter egg than one that ships a
 * shorter version of the list every editor already has.
 *
 * A theme carries two halves. `editor` is Monaco's own theme data. `chrome` is
 * the handful of CSS variables the surrounding console reads, so picking Ember
 * does not leave a warm editor sitting in a cold blue shell - which is exactly
 * how it looks if you retheme only the editor, and it looks broken rather than
 * mixed.
 */
import type { monaco as Monaco } from "./monaco.ts";

type MonacoNS = typeof Monaco;

/**
 * The chrome variables, named individually rather than as a Record<string, string>.
 *
 * A Record makes every lookup `string | undefined` under noUncheckedIndexedAccess,
 * which is noise at each use site - and, worse, it lets a typo'd `--acent` compile
 * and simply not paint. Spelling them out means adding a variable is a type error
 * in every theme that has not got one yet, which is exactly the reminder you want.
 */
export interface ChromeVars {
  "--bg": string;
  "--panel": string;
  "--panel-2": string;
  "--border": string;
  "--fg": string;
  "--dim": string;
  "--accent": string;
  "--good": string;
  "--warn": string;
  "--bad": string;
  "--code-bg": string;
  "--rule": string;
  "--glow": string;
}

export interface DrillTheme {
  id: string;
  label: string;
  /** Shown next to the name in the picker, the way VS Code groups light and dark. */
  kind: "dark" | "light";
  editor: {
    base: "vs" | "vs-dark";
    rules: Array<{ token: string; foreground?: string; fontStyle?: string }>;
    colors: Record<string, string>;
  };
  /** CSS custom properties the console chrome reads. Names match theme.css. */
  chrome: ChromeVars;
  /** The eight ANSI colours, for xterm. Everything else is derived from `chrome`. */
  ansi: {
    black: string;
    red: string;
    green: string;
    yellow: string;
    blue: string;
    magenta: string;
    cyan: string;
    white: string;
  };
}

/** The palette this repo already had, in PRACTICE_ANSWERS.html. The default. */
const DRILL_DARK: DrillTheme = {
  id: "drill-dark",
  label: "Drill Dark",
  kind: "dark",
  editor: {
    base: "vs-dark",
    rules: [
      { token: "comment", foreground: "9aa5b1", fontStyle: "italic" },
      { token: "string", foreground: "9ece6a" },
      { token: "number", foreground: "e0af68" },
      { token: "keyword", foreground: "bb9af7" },
      { token: "type", foreground: "7aa2f7" },
      { token: "key", foreground: "7aa2f7" },
    ],
    colors: {
      "editor.background": "#0d1117",
      "editor.foreground": "#e6e6e6",
      "editorLineNumber.foreground": "#3a4354",
      "editorLineNumber.activeForeground": "#7aa2f7",
      "editorCursor.foreground": "#7aa2f7",
      "editor.selectionBackground": "#7aa2f733",
      "editor.lineHighlightBackground": "#171c26",
      "editorIndentGuide.background1": "#1f2634",
      "editorIndentGuide.activeBackground1": "#2a3140",
      "editorWidget.background": "#171c26",
      "editorWidget.border": "#2a3140",
      "scrollbarSlider.background": "#2a3140aa",
    },
  },
  chrome: {
    "--bg": "#10141a",
    "--panel": "#171c26",
    "--panel-2": "#1c222e",
    "--border": "#2a3140",
    "--fg": "#e6e6e6",
    "--dim": "#9aa5b1",
    "--accent": "#7aa2f7",
    "--good": "#9ece6a",
    "--warn": "#e0af68",
    "--bad": "#f7768e",
    "--code-bg": "#0d1117",
    "--rule": "rgba(255,255,255,0.05)",
    "--glow": "rgba(122,162,247,0.16)",
  },
  ansi: {
    black: "#1c222e",
    red: "#f7768e",
    green: "#9ece6a",
    yellow: "#e0af68",
    blue: "#7aa2f7",
    magenta: "#bb9af7",
    cyan: "#7dcfff",
    white: "#e6e6e6",
  },
};

const DRILL_LIGHT: DrillTheme = {
  id: "drill-light",
  label: "Drill Light",
  kind: "light",
  editor: {
    base: "vs",
    rules: [
      { token: "comment", foreground: "5b6673", fontStyle: "italic" },
      { token: "string", foreground: "2b6b1f" },
      { token: "number", foreground: "8a5300" },
      { token: "key", foreground: "2f5fd0" },
    ],
    colors: {
      "editor.background": "#ffffff",
      "editor.foreground": "#1a2330",
      "editorLineNumber.foreground": "#b3bcc7",
      "editorLineNumber.activeForeground": "#2f5fd0",
      "editor.lineHighlightBackground": "#f0f3f7",
      "editor.selectionBackground": "#2f5fd028",
    },
  },
  chrome: {
    "--bg": "#f7f8fa",
    "--panel": "#ffffff",
    "--panel-2": "#f0f3f7",
    "--border": "#d8dee6",
    "--fg": "#1a2330",
    "--dim": "#5b6673",
    "--accent": "#2f5fd0",
    "--good": "#3d7a1f",
    "--warn": "#a06400",
    "--bad": "#c0392b",
    "--code-bg": "#eef1f5",
    "--rule": "rgba(0,0,0,0.05)",
    "--glow": "rgba(47,95,208,0.14)",
  },
  ansi: {
    black: "#d8dee6",
    red: "#c0392b",
    green: "#3d7a1f",
    yellow: "#a06400",
    blue: "#2f5fd0",
    magenta: "#8250a8",
    cyan: "#0f7c93",
    white: "#1a2330",
  },
};

/** Warm dark. Phosphor-adjacent without tipping into novelty. */
const EMBER: DrillTheme = {
  id: "ember",
  label: "Ember",
  kind: "dark",
  editor: {
    base: "vs-dark",
    rules: [
      { token: "comment", foreground: "8a7a68", fontStyle: "italic" },
      { token: "string", foreground: "d7a65b" },
      { token: "number", foreground: "e8875a" },
      { token: "keyword", foreground: "e8875a" },
      { token: "type", foreground: "f0b849" },
      { token: "key", foreground: "f0b849" },
    ],
    colors: {
      "editor.background": "#17120e",
      "editor.foreground": "#eadfd3",
      "editorLineNumber.foreground": "#4a3c30",
      "editorLineNumber.activeForeground": "#f0b849",
      "editorCursor.foreground": "#f0b849",
      "editor.selectionBackground": "#f0b84930",
      "editor.lineHighlightBackground": "#1f1813",
      "editorWidget.background": "#1f1813",
      "editorWidget.border": "#3a2e24",
    },
  },
  chrome: {
    "--bg": "#120e0b",
    "--panel": "#1f1813",
    "--panel-2": "#271e18",
    "--border": "#3a2e24",
    "--fg": "#eadfd3",
    "--dim": "#a3907c",
    "--accent": "#f0b849",
    "--good": "#a8b45a",
    "--warn": "#e8875a",
    "--bad": "#e2564a",
    "--code-bg": "#17120e",
    "--rule": "rgba(255,220,180,0.05)",
    "--glow": "rgba(240,184,73,0.18)",
  },
  ansi: {
    black: "#271e18",
    red: "#e2564a",
    green: "#a8b45a",
    yellow: "#f0b849",
    blue: "#e8875a",
    magenta: "#d08a9c",
    cyan: "#c9a86a",
    white: "#eadfd3",
  },
};

/** Cold, high-contrast, nearly black. For people who turn the brightness down. */
const DEEP: DrillTheme = {
  id: "deep",
  label: "Deep",
  kind: "dark",
  editor: {
    base: "vs-dark",
    rules: [
      { token: "comment", foreground: "4d6570", fontStyle: "italic" },
      { token: "string", foreground: "5ad1b0" },
      { token: "number", foreground: "6fb3e0" },
      { token: "keyword", foreground: "8f7fd4" },
      { token: "type", foreground: "42c5d9" },
      { token: "key", foreground: "42c5d9" },
    ],
    colors: {
      "editor.background": "#05090d",
      "editor.foreground": "#cfe0e6",
      "editorLineNumber.foreground": "#25333d",
      "editorLineNumber.activeForeground": "#42c5d9",
      "editorCursor.foreground": "#42c5d9",
      "editor.selectionBackground": "#42c5d930",
      "editor.lineHighlightBackground": "#0b131a",
      "editorWidget.background": "#0b131a",
      "editorWidget.border": "#1b2a33",
    },
  },
  chrome: {
    "--bg": "#03070a",
    "--panel": "#0b131a",
    "--panel-2": "#101c24",
    "--border": "#1b2a33",
    "--fg": "#cfe0e6",
    "--dim": "#6b8590",
    "--accent": "#42c5d9",
    "--good": "#5ad1b0",
    "--warn": "#d9b04a",
    "--bad": "#e2607a",
    "--code-bg": "#05090d",
    "--rule": "rgba(180,230,255,0.045)",
    "--glow": "rgba(66,197,217,0.18)",
  },
  ansi: {
    black: "#101c24",
    red: "#e2607a",
    green: "#5ad1b0",
    yellow: "#d9b04a",
    blue: "#42c5d9",
    magenta: "#8f7fd4",
    cyan: "#6fb3e0",
    white: "#cfe0e6",
  },
};

/** Warm light, for daylight and for screenshots that end up in a document. */
const PAPER: DrillTheme = {
  id: "paper",
  label: "Paper",
  kind: "light",
  editor: {
    base: "vs",
    rules: [
      { token: "comment", foreground: "8a7f6d", fontStyle: "italic" },
      { token: "string", foreground: "3f6b34" },
      { token: "number", foreground: "9a5b18" },
      { token: "keyword", foreground: "8a4b7a" },
      { token: "key", foreground: "2c5c8a" },
    ],
    colors: {
      "editor.background": "#faf6ee",
      "editor.foreground": "#33302a",
      "editorLineNumber.foreground": "#c4bbaa",
      "editorLineNumber.activeForeground": "#2c5c8a",
      "editor.lineHighlightBackground": "#f2ece0",
      "editor.selectionBackground": "#2c5c8a22",
    },
  },
  chrome: {
    "--bg": "#f4efe4",
    "--panel": "#faf6ee",
    "--panel-2": "#f2ece0",
    "--border": "#ded4c2",
    "--fg": "#33302a",
    "--dim": "#7a7264",
    "--accent": "#2c5c8a",
    "--good": "#3f6b34",
    "--warn": "#9a5b18",
    "--bad": "#a8402f",
    "--code-bg": "#f2ece0",
    "--rule": "rgba(60,45,20,0.05)",
    "--glow": "rgba(44,92,138,0.14)",
  },
  ansi: {
    black: "#ded4c2",
    red: "#a8402f",
    green: "#3f6b34",
    yellow: "#9a5b18",
    blue: "#2c5c8a",
    magenta: "#8a4b7a",
    cyan: "#1f6b73",
    white: "#33302a",
  },
};

export const THEMES: DrillTheme[] = [
  DRILL_DARK,
  DRILL_LIGHT,
  EMBER,
  DEEP,
  PAPER,
];

export const DEFAULT_THEME = DRILL_DARK.id;

const STORAGE_KEY = "drill-theme";

export function registerThemes(monaco: MonacoNS): void {
  for (const theme of THEMES) {
    monaco.editor.defineTheme(theme.id, {
      base: theme.editor.base,
      inherit: true,
      rules: theme.editor.rules,
      colors: theme.editor.colors,
    });
  }
}

/** Paint the chrome. Monaco is told separately, by the editor component. */
export function applyChrome(theme: DrillTheme): void {
  const root = document.documentElement;
  for (const [name, value] of Object.entries(theme.chrome)) {
    root.style.setProperty(name, value);
  }
  root.dataset.theme = theme.kind;
}

/**
 * The xterm palette for a theme.
 *
 * xterm's `options.theme` is live-settable, so the terminal rethemes in place and
 * the tmux attachment behind it is never touched. Leaving it out was worse than it
 * sounds: a warm console with one cold blue rectangle in the middle of it does not
 * read as a mixed palette, it reads as a panel that failed to load.
 */
export function terminalTheme(theme: DrillTheme) {
  const { chrome, ansi } = theme;
  return {
    background: chrome["--panel"],
    foreground: chrome["--fg"],
    cursor: chrome["--accent"],
    cursorAccent: chrome["--panel"],
    selectionBackground: `${chrome["--accent"]}33`,
    ...ansi,
    brightBlack: chrome["--dim"],
  };
}

export const themeById = (id: string): DrillTheme =>
  THEMES.find((t) => t.id === id) ?? DRILL_DARK;

/** A theme is the one preference worth remembering; nothing else here persists. */
export function loadSavedTheme(): string {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    return saved && THEMES.some((t) => t.id === saved) ? saved : DEFAULT_THEME;
  } catch {
    return DEFAULT_THEME;
  }
}

export function saveTheme(id: string): void {
  try {
    localStorage.setItem(STORAGE_KEY, id);
  } catch {
    /* private browsing; the theme just does not stick */
  }
}
