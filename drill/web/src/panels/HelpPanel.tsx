import type { DependencyStatus } from "@drill/shared";
import type { ScenarioMeta } from "../lib/api.ts";

interface Props {
  meta: ScenarioMeta | null;
  deps: DependencyStatus[];
}

/**
 * The card, and what the environment is doing.
 *
 * The dependency list is here rather than hidden behind a spinner because
 * "waiting on Argo" should be readable rather than mysterious - the most
 * demoralising minute of a drill is the one where nothing is happening and
 * nothing says why.
 */
export function HelpPanel({ meta, deps }: Props) {
  return (
    <div className="doc">
      {meta ? (
        <>
          <h3>the ticket</h3>
          <p>{meta.ticket}</p>

          <h3>scenario</h3>
          <dl className="meta">
            <dt>id</dt>
            <dd className="mono">{meta.scenario}</dd>
            <dt>title</dt>
            <dd>{meta.title}</dd>
            <dt>time</dt>
            <dd>{meta.time}</dd>
            <dt>needs</dt>
            <dd>{meta.needs}</dd>
          </dl>
        </>
      ) : (
        <p className="dim">loading the card</p>
      )}

      <h3>environment</h3>
      {deps.length === 0 ? (
        <p style={{ color: "var(--dim)" }}>
          Nothing is reporting yet. The dependency watcher arrives with the Argo
          CD widget.
        </p>
      ) : (
        <ul className="deps">
          {deps.map((d) => (
            <li key={d.name}>
              <span className={`dot ${d.state}`} />
              <span className="name">{d.name}</span>
              <span className="detail">{d.detail}</span>
            </li>
          ))}
        </ul>
      )}

      <h3>working here</h3>
      <p>
        The terminal is a real shell in the cluster, with <code>kubectl</code>,{" "}
        <code>git</code> and <code>helm</code> on <code>PATH</code>. It is a{" "}
        <code>tmux</code> session, so closing this tab does not kill what you
        were running.
      </p>
      <p>
        The editor writes straight to the workspace. Saving is not deploying -{" "}
        <code>git commit</code> is what Argo CD can see, and that gap is most of
        what this drill is about.
      </p>
      <p>
        Your <code>origin</code> is the git server inside this cluster. A push
        here never reaches your GitHub account, which is what makes{" "}
        <code>git revert &amp;&amp; git push</code> a safe thing to practise.
      </p>
    </div>
  );
}
