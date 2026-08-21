/**
 * Bundle Monaco instead of fetching it.
 *
 * `@monaco-editor/react` loads the editor from cdn.jsdelivr.net by default. That
 * works on a laptop and fails silently in the pod: the drill runs in a private
 * subnet behind one ALB, so the editor panel would spin forever with nothing in
 * the server log to explain it. Pointing the loader at the npm package makes
 * Monaco part of the image, which is also what "the drill never depends on the
 * internet" already means everywhere else in this repo.
 *
 * The worker is wired here for the same reason - Vite needs to be told, or the
 * editor falls back to running the language services on the main thread and every
 * keystroke stutters.
 */
/*
 * Imported piece by piece, not as the `monaco-editor` barrel. The barrel pulls in
 * every language Monaco ships - abap, solidity, freemarker - and takes the bundle
 * from about 800 KB to 3.9 MB, all of it baked into a public image to edit one
 * YAML file. `editor.all` is the widgets (find, folding, suggestions); the one
 * contribution below is the only grammar this drill needs.
 */
import * as monaco from "monaco-editor/esm/vs/editor/editor.api";
import "monaco-editor/esm/vs/editor/editor.all.js";
import "monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution.js";
import { loader } from "@monaco-editor/react";
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";

declare global {
  interface Window {
    MonacoEnvironment?: monaco.Environment;
  }
}

// YAML has no language service in Monaco core, only tokenisation, so the generic
// editor worker is the only one this app needs.
window.MonacoEnvironment = {
  getWorker: () => new EditorWorker(),
};

loader.config({ monaco });

/** The console's own palette, so the editor is not a light rectangle in a dark tool. */
export const DRILL_DARK = "drill-dark";

monaco.editor.defineTheme(DRILL_DARK, {
  base: "vs-dark",
  inherit: true,
  rules: [
    { token: "comment", foreground: "9aa5b1", fontStyle: "italic" },
    { token: "string", foreground: "9ece6a" },
    { token: "number", foreground: "e0af68" },
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
});

monaco.editor.defineTheme("drill-light", {
  base: "vs",
  inherit: true,
  rules: [],
  colors: {
    "editor.background": "#eef1f5",
    "editor.foreground": "#1a2330",
  },
});

export { monaco };
