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
 * Imported piece by piece, not as the `monaco-editor` barrel. The barrel pulls in
 * every language Monaco ships - abap, solidity, freemarker - and takes the bundle
 * from about 800 KB to 3.9 MB, all of it baked into a public image to read a
 * handful of YAML files. `editor.all` is the widgets; the contributions below are
 * the grammars this repo actually contains.
 */
import * as monaco from "monaco-editor/esm/vs/editor/editor.api";
import "monaco-editor/esm/vs/editor/editor.all.js";

// One import per file type the learner can open in THIS repo. Adding a grammar
// costs a few KB; adding the barrel costs three megabytes.
import "monaco-editor/esm/vs/basic-languages/yaml/yaml.contribution.js";
import "monaco-editor/esm/vs/basic-languages/markdown/markdown.contribution.js";
import "monaco-editor/esm/vs/basic-languages/shell/shell.contribution.js";
import "monaco-editor/esm/vs/basic-languages/python/python.contribution.js";
import "monaco-editor/esm/vs/basic-languages/hcl/hcl.contribution.js";
import "monaco-editor/esm/vs/basic-languages/dockerfile/dockerfile.contribution.js";
import "monaco-editor/esm/vs/basic-languages/ini/ini.contribution.js";
import "monaco-editor/esm/vs/language/json/monaco.contribution";

import { loader } from "@monaco-editor/react";
import EditorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import JsonWorker from "monaco-editor/esm/vs/language/json/json.worker?worker";
import { registerThemes } from "./themes.ts";

declare global {
  interface Window {
    MonacoEnvironment?: monaco.Environment;
  }
}

// JSON is the only language here with a real service behind it - the rest are
// tokenisers and need nothing but the generic worker. Without this switch, JSON
// silently runs its service on the main thread and every keystroke in
// package-lock.json stutters.
window.MonacoEnvironment = {
  getWorker: (_id, label) =>
    label === "json" ? new JsonWorker() : new EditorWorker(),
};

loader.config({ monaco });
registerThemes(monaco);

export { monaco };
