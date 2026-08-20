/**
 * Shell alias expansion, run before any command is parsed.
 *
 * Without this, a correct answer typed the way the user actually types it
 * ("kgp -n practice-app") grades as wrong, which teaches nothing except that
 * the grader is brittle. The table mirrors the aliases in the user's shell rc.
 */

export const ALIASES: Readonly<Record<string, string>> = Object.freeze({
  k: "kubectl",
  kg: "kubectl get",
  kgp: "kubectl get pods",
  kgn: "kubectl get nodes",
  kgs: "kubectl get svc",
  kd: "kubectl describe",
  kl: "kubectl logs",
  kaf: "kubectl apply -f",
  // The rc says `kubectl proxy`, not `kubectl port-forward`. Mirrored deliberately:
  // the table's job is to expand what the user's muscle memory types the way their
  // own shell would expand it, not the way a drill task wishes it were spelled.
  kp: "kubectl proxy",
});

// Deliberately NOT mirrored: the rc's `alias kd='kubectl describe'0` carries a stray
// trailing 0, so `kd` really expands to `kubectl describe0`. That is a bug in the rc,
// and encoding it here would teach the typo instead of the command.

/** Guard against a cyclic table. Real expansion never needs more than one round. */
const MAX_ROUNDS = 8;

/**
 * Expand the leading word if it is an alias, leaving the rest byte-identical.
 *
 * Only the first word is considered, matching how shells expand aliases, so a
 * literal "kgp" appearing later in the command (a pod name, a jsonpath) is safe.
 *
 * Indentation in front of the alias is dropped, because an expansion rewrites the
 * head of the line and re-indenting the replacement would be inventing whitespace
 * the user did not type. A line that expands to nothing comes back byte-identical,
 * indentation included.
 */
export function expandAliases(command: string): string {
  let current = command;
  for (let round = 0; round < MAX_ROUNDS; round++) {
    const match = /^\s*(\S+)(.*)$/s.exec(current);
    if (!match) return current;
    const [, head, tail] = match as unknown as [string, string, string];
    const replacement = ALIASES[head];
    if (replacement === undefined) return current;
    const next = `${replacement}${tail}`;
    if (next === current) return current;
    current = next;
  }
  return current;
}
