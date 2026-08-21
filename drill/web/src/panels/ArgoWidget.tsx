import type { ArgoApplication } from "../lib/api.ts";

interface Props {
  app: ArgoApplication | null;
}

/**
 * What Argo CD is doing, right now, next to the terminal where you did it.
 *
 * This panel is scenario 03 task 5 in its entirety. You run
 * `kubectl rollout undo`, the pods roll back, and it looks like you fixed it -
 * and then Argo notices, marks the app `OutOfSync`, and puts the bad version
 * straight back. The `only-imperative` hint says that in words. This says it in a
 * way that is harder to argue with, because you watch it happen.
 *
 * Styled as this application rather than as an iframe of Argo. An iframe would be
 * less work and would carry Argo's own chrome, its own fonts and its own theme into
 * the middle of a console that has five of them - and it would need the reverse
 * proxy up, which the widget deliberately does not depend on.
 *
 * Read-only, and that is the same rule the source control view follows: the terminal
 * is where the cluster gets changed. A sync button here would let scenario 03 be
 * passed without ever running the command it is about.
 */
export function ArgoWidget({ app }: Props) {
  if (!app) {
    return (
      <div className="doc">
        <p className="dim">reading the Application</p>
      </div>
    );
  }

  if (!app.present) {
    return (
      <div className="doc">
        <h3>argo cd</h3>
        <p className="dim">
          No <code>{app.name}</code> Application in <code>{app.namespace}</code>
          .
        </p>
        <p className="dim">
          Outside a cluster - a Vite preview, say - that is expected: this panel
          reads the Kubernetes API, and there is not one here. Inside a cluster
          it means Argo has not been told about the app yet.
        </p>
      </div>
    );
  }

  return (
    <div className="doc">
      <h3>argo cd</h3>

      <ul className="deps">
        <li>
          <span className={`dot ${syncState(app.sync)}`} />
          <span className="name">sync</span>
          <span className="detail">{app.sync}</span>
        </li>
        <li>
          <span className={`dot ${healthState(app.health)}`} />
          <span className="name">health</span>
          <span className="detail">{app.health}</span>
        </li>
        <li>
          <span className="dot waiting" />
          <span className="name">revision</span>
          {/* The full sha stays in the title, because "which commit is live" is a
              question you eventually want to paste an answer to. */}
          <span className="detail mono" title={app.revision}>
            {app.revisionShort || "none yet"}
          </span>
        </li>
      </ul>

      {app.message && <p className="argo-message">{app.message}</p>}

      {app.sync === "OutOfSync" && (
        // The teachable moment, spelled out at the moment it is true rather than
        // in a paragraph of the card nobody re-reads mid-drill.
        <p className="argo-nudge">
          Argo has seen a difference between the cluster and the repo, and it is
          going to close it - by changing the <strong>cluster</strong>. If you
          fixed something with <code>kubectl</code>, this is the countdown to it
          being undone.
        </p>
      )}

      <h3>resources</h3>
      {app.resources.length === 0 ? (
        <p className="dim">Argo has not reconciled any resources yet.</p>
      ) : (
        <ul className="argo-tree">
          {app.resources.map((r) => (
            <li key={`${r.kind}/${r.namespace ?? ""}/${r.name}`}>
              <span className={`dot ${syncState(r.status)}`} />
              <span className="argo-kind">{r.kind}</span>
              <span className="argo-name" title={r.name}>
                {r.name}
              </span>
              <span className={`argo-health ${healthTone(r.health)}`}>
                {r.health ?? ""}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/**
 * Map Argo's words onto the four dot states the console already uses.
 *
 * Reusing the vocabulary rather than inventing colours is what keeps this readable
 * across all five themes - a widget with its own hardcoded green looks broken in
 * four of them.
 */
function syncState(sync: string): string {
  if (sync === "Synced") return "ready";
  if (sync === "OutOfSync") return "starting";
  return "waiting";
}

function healthState(health: string): string {
  if (health === "Healthy") return "ready";
  if (health === "Progressing") return "starting";
  if (health === "Degraded" || health === "Missing") return "absent";
  return "waiting";
}

/**
 * Colour the health word, because "Degraded" is the one you must not scroll past.
 *
 * The row's dot already carries SYNC status, so health has no other signal - and
 * rendered in the same dim grey as "Healthy", a degraded resource reads as just
 * another row. Only the two that mean something get a tone; `Healthy` deliberately
 * does not, because thirty green words is the same as no green words.
 */
function healthTone(health: string | undefined): string {
  if (health === "Degraded" || health === "Missing") return "bad";
  if (health === "Progressing") return "warn";
  return "";
}
