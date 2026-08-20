/**
 * Parse a command into a canonical shape so grading compares meaning, not text.
 *
 * `kubectl get deploy -n practice-app` and `kubectl -n practice-app get deployment`
 * are the same command. A regex says they are different. This says they are the same,
 * which is the difference between grading understanding and grading typing.
 */
import { expandAliases } from "./aliases.ts";

export interface ParsedCommand {
  /** kubectl, git, helm, curl, shell, or whatever led the line. */
  tool: string;
  /** get, describe, rollout-history, revert, while... */
  verb: string;
  resource?: string;
  name?: string;
  namespace?: string;
  allNamespaces: boolean;
  flags: Record<string, string | true>;
  /** The input, byte for byte, for showing back to the user. */
  raw: string;
}

const RESOURCE_ALIASES: Readonly<Record<string, string>> = Object.freeze({
  deploy: "deployment",
  deployments: "deployment",
  deployment: "deployment",
  po: "pod",
  pods: "pod",
  pod: "pod",
  svc: "service",
  services: "service",
  service: "service",
  ns: "namespace",
  namespaces: "namespace",
  namespace: "namespace",
  cm: "configmap",
  configmaps: "configmap",
  configmap: "configmap",
  sts: "statefulset",
  statefulsets: "statefulset",
  statefulset: "statefulset",
  ds: "daemonset",
  daemonsets: "daemonset",
  daemonset: "daemonset",
  ing: "ingress",
  ingresses: "ingress",
  ingress: "ingress",
  rs: "replicaset",
  replicasets: "replicaset",
  replicaset: "replicaset",
  no: "node",
  nodes: "node",
  node: "node",
  hpa: "horizontalpodautoscaler",
  pvc: "persistentvolumeclaim",
  secrets: "secret",
  secret: "secret",
});

/** kubectl verbs whose meaning needs their second word. */
const TWO_WORD_VERBS = new Set([
  "rollout",
  "config",
  "auth",
  "create",
  "api-resources",
]);

/** Shell keywords that mean "this is a loop or a control structure, not a tool call". */
const SHELL_KEYWORDS = new Set(["while", "for", "until", "if"]);

/** Flags that take a value as the next word rather than after an `=`. */
const VALUE_FLAGS = new Set([
  "-n",
  "--namespace",
  "-o",
  "--output",
  "-l",
  "--selector",
  "-f",
  "--filename",
  "-c",
  "--container",
]);

export function normaliseResource(word: string): string {
  return RESOURCE_ALIASES[word.toLowerCase()] ?? word.toLowerCase();
}

export function parseCommand(input: string): ParsedCommand {
  const raw = input;
  const expanded = expandAliases(input).trim();
  const out: ParsedCommand = {
    tool: "",
    verb: "",
    allNamespaces: false,
    flags: {},
    raw,
  };
  if (!expanded) return out;

  const words = expanded.split(/\s+/);
  const first = words[0] ?? "";

  if (SHELL_KEYWORDS.has(first)) {
    out.tool = "shell";
    out.verb = first;
    return out;
  }

  out.tool = first;
  const rest = words.slice(1);

  // First pass: pull out flags, leaving positional words behind.
  const positional: string[] = [];
  for (let i = 0; i < rest.length; i++) {
    const word = rest[i] ?? "";
    if (!word.startsWith("-")) {
      positional.push(word);
      continue;
    }
    const eq = word.indexOf("=");
    if (eq > 0) {
      out.flags[word.slice(0, eq)] = word.slice(eq + 1);
      continue;
    }
    if (VALUE_FLAGS.has(word) && i + 1 < rest.length) {
      out.flags[word] = rest[i + 1] ?? "";
      i++;
      continue;
    }
    out.flags[word] = true;
  }

  // Assigned through a local rather than straight onto the optional property:
  // exactOptionalPropertyTypes means `namespace?: string` will not accept undefined,
  // and "absent" is the honest encoding of "the user named no namespace".
  const ns = out.flags["-n"] ?? out.flags["--namespace"];
  if (typeof ns === "string") out.namespace = ns;
  out.allNamespaces =
    out.flags["-A"] === true || out.flags["--all-namespaces"] === true;

  // Second pass: verb, resource, name from the positional words.
  const verbWord = positional[0] ?? "";
  const secondWord = positional[1];
  if (TWO_WORD_VERBS.has(verbWord) && secondWord) {
    out.verb = `${verbWord}-${secondWord}`;
    positional.splice(0, 2);
  } else {
    out.verb = verbWord;
    positional.splice(0, 1);
  }

  const target = positional[0];
  if (target) {
    if (target.includes("/")) {
      const [res, name] = target.split("/", 2);
      out.resource = normaliseResource(res ?? "");
      if (name) out.name = name;
    } else {
      out.resource = normaliseResource(target);
      const name = positional[1];
      if (name) out.name = name;
    }
  }

  return out;
}
