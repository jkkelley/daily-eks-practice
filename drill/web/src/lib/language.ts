/**
 * Extension-to-grammar mapping, kept in its own module ON PURPOSE.
 *
 * It is a pure string function, but it lived in monaco.ts and App.tsx imports
 * it for the status bar - which quietly pulled the whole of Monaco into the
 * entry chunk and undid the lazy loading entirely. The entry bundle went from
 * 473 KB to 3.7 MB and nothing failed; the build output was the only sign.
 * Anything the shell needs from the editor's world belongs here, not there.
 *
 * The grammars themselves are registered in monaco.ts. Adding one means adding
 * an import there AND a case here.
 */
/**
 * Which grammar to use for a path.
 *
 * Monaco can infer this from the file extension on its own, but only for
 * languages whose contribution has been imported, and it has no opinion about
 * extensionless files. Naming the mapping here keeps it next to the imports
 * above, so adding a grammar and forgetting to route to it is one file's problem.
 */
export function languageFor(path: string): string {
  const name = path.split("/").pop() ?? path;
  if (/^Containerfile|^Dockerfile/i.test(name)) return "dockerfile";
  if (/^Makefile/i.test(name)) return "shell";
  const ext = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1) : "";
  switch (ext.toLowerCase()) {
    case "yaml":
    case "yml":
      return "yaml";
    case "json":
    case "lock":
      return "json";
    case "md":
      return "markdown";
    case "sh":
    case "bash":
    case "zsh":
      return "shell";
    case "py":
      return "python";
    case "tf":
    case "tfvars":
    case "hcl":
      return "hcl";
    // Monaco ships no TOML grammar. ini is close enough to be useful on
    // config.example.toml and much better than no highlighting at all.
    case "toml":
    case "ini":
    case "cfg":
    case "conf":
      return "ini";
    default:
      return "plaintext";
  }
}
