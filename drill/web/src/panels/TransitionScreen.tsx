/**
 * What you look at while a scenario is being swapped underneath you, and what
 * you land on when a run ends.
 *
 * ---- THE TRANSITION SCREEN IS NOT A SPINNER ------------------------------
 *
 * `/api/deps` already models the startup chain as `DependencyStatus[]` - one
 * entry each for cluster git, Argo CD and the app, each `ready`, `starting`,
 * `waiting` or `absent`. That is exactly the list of things being waited on, so
 * the loading screen IS that chain, rendered large, with the real state of each
 * link.
 *
 * It is the cheapest honest thing available and it beats a spinner on both
 * counts. It entertains, because something is visibly happening and it is the
 * truth. And when a switch is slow it already says WHICH link is slow, so "the
 * drill is stuck" arrives with its own diagnosis attached instead of as a bug
 * report.
 */
import type { DependencyStatus, SessionState } from "@drill/shared";

const STEPS: { name: DependencyStatus["name"]; label: string }[] = [
  { name: "cluster-git", label: "publishing your work to cluster git" },
  { name: "argocd", label: "Argo CD picking up the change" },
  { name: "practice-app", label: "rolling the application" },
];

export function TransitionScreen({
  state,
  deps,
  targetTitle,
}: {
  state: SessionState;
  deps: DependencyStatus[];
  targetTitle?: string;
}) {
  const target = state.target ?? "";
  const byName = new Map(deps.map((d) => [d.name, d]));

  return (
    <div className="overlay" role="status" aria-live="polite">
      <div className="menu">
        <header>
          <h2>LOADING SCENARIO {target}</h2>
        </header>
        {targetTitle && <p className="menu-scenario">{targetTitle}</p>}

        <ul className="menu-steps">
          {STEPS.map((step) => {
            const d = byName.get(step.name);
            const status = d?.state ?? "waiting";
            return (
              <li key={step.name}>
                <span className={`dot ${status}`} />
                <span className="step-label">{step.label}</span>
                <span className="step-state">{status}</span>
                {/* The detail is the diagnosis. It is the difference between
                    "still waiting" and "waiting, because the git server has no
                    endpoints yet" - and the second one tells you whether to keep
                    waiting or go and look. */}
                {d?.detail && <span className="step-detail">{d.detail}</span>}
              </li>
            );
          })}
        </ul>

        <p className="menu-note">
          Your previous session was saved before anything here started - that
          ordering is deliberate, and it is why switching is safe.
        </p>
      </div>
    </div>
  );
}

/**
 * The game-over screen. Shown when a run has ended and the cluster is still up.
 *
 * It always offers a way back in, because the browser is the only interface and
 * nothing the GUI does may strand the learner outside it. The cost line is here
 * rather than anywhere else because this is the screen somebody is looking at
 * when they decide whether they are finished for the day.
 */
export function GameOver({
  state,
  passed,
  total,
  onPick,
  onReplay,
}: {
  state: SessionState;
  passed: number;
  total: number;
  onPick: () => void;
  onReplay: () => void;
}) {
  const destroying = state.phase === "destroy-requested";
  const minutes = elapsedMinutes(state);

  return (
    <div
      className="overlay"
      role="dialog"
      aria-modal="true"
      aria-label="Session ended"
    >
      <div className="menu">
        <header>
          <h2>{destroying ? "TEARING DOWN" : "SESSION ENDED"}</h2>
        </header>

        <p className="menu-scenario">
          scenario {state.scenario} &middot; {passed}/{total || "-"} passed
          {minutes !== null && <> &middot; {minutes} min</>}
        </p>

        {destroying ? (
          <>
            <p>
              The teardown is running on your laptop, in the terminal you
              started the drill from. It counts down for ten seconds and{" "}
              <kbd>ctrl-c</kbd> aborts it.
            </p>
            <p className="menu-note">
              This page will stop responding when the cluster goes. That is
              expected, not a crash.
            </p>
          </>
        ) : (
          <>
            <p>
              Saved to <code>drill-progress/{state.scenario}/</code> on your
              laptop. It is a real <code>git bundle</code> - you can clone it
              straight out if you ever want the work without the drill.
            </p>
            <div className="menu-actions">
              <button className="btn" onClick={onReplay}>
                replay {state.scenario}
              </button>
              <button className="btn" onClick={onPick}>
                pick another scenario
              </button>
            </div>
            <p className="menu-note">
              Done for the day? The cluster is still up and still billing about
              $0.10/hr. On your laptop: <code>make down</code>.
            </p>
          </>
        )}
      </div>
    </div>
  );
}

function elapsedMinutes(state: SessionState): number | null {
  const start = Date.parse(state.startedAt);
  const end = state.endedAt ? Date.parse(state.endedAt) : Date.now();
  if (Number.isNaN(start) || Number.isNaN(end) || end < start) return null;
  return Math.max(1, Math.round((end - start) / 60_000));
}
