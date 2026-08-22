/**
 * The pause menu.
 *
 * `EXIT` is not one action, and that is the whole reason this exists rather than
 * a button. A learner who is done with scenario 03 wants one of several different
 * things - restart it because they made a mess, move to 06 because it clicked, go
 * back to 02 because it did not, stop for the day, or stop for the day AND stop
 * the bill - and a single destructive verb cannot tell which.
 *
 * All twelve scenarios are listed. The eleven with no answers TOML render
 * disabled and say why rather than being hidden, which is the same call Phase 5
 * made when it shipped this menu's own EXIT button disabled and honest. Hiding
 * them would conceal the shape of the curriculum and move the menu's geometry
 * under the learner every time one is ported.
 */
import { useEffect, useMemo, useState } from "react";
import type { SessionState } from "@drill/shared";
import type { GitStatus, ScenarioSlot } from "../lib/api.ts";

interface Props {
  state: SessionState | null;
  scenarios: ScenarioSlot[];
  passed: number;
  total: number;
  git: GitStatus | null;
  onResume: () => void;
  onRestart: () => void;
  onSwitch: (target: string) => void;
  onQuit: () => void;
  onDestroy: () => void;
}

export function PauseMenu({
  state,
  scenarios,
  passed,
  total,
  git,
  onResume,
  onRestart,
  onSwitch,
  onQuit,
  onDestroy,
}: Props) {
  const [selecting, setSelecting] = useState(false);
  const [confirmDestroy, setConfirmDestroy] = useState(false);
  const [typed, setTyped] = useState("");

  // Esc closes, everywhere except the destroy dialog, where it steps back one
  // level instead. A single Esc that dismissed the whole menu from inside a
  // confirmation is how you lose your place in a menu you opened deliberately.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      if (confirmDestroy) setConfirmDestroy(false);
      else if (selecting) setSelecting(false);
      else onResume();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [confirmDestroy, selecting, onResume]);

  const current = state?.scenario ?? "";
  const index = scenarios.findIndex((s) => s.id === current);
  const neighbour = (delta: number): ScenarioSlot | undefined =>
    index < 0 ? undefined : scenarios[index + delta];

  const next = neighbour(1);
  const previous = neighbour(-1);

  // Uncommitted work is NOT in the save file. The save file is a git bundle of
  // cluster git, so anything edited and not committed and pushed was never in it
  // and never could be. Saying so here is the difference between a documented
  // property and a nasty surprise, and it is the drill's own subject.
  const uncommitted = git?.files.length ?? 0;

  const warning = useMemo(
    () =>
      uncommitted > 0 ? (
        <p className="menu-warn">
          {uncommitted} uncommitted change{uncommitted === 1 ? "" : "s"} in your
          workspace. Your save file is what you have{" "}
          <strong>committed and pushed</strong> - anything else is lost when the
          scenario changes.
        </p>
      ) : null,
    [uncommitted],
  );

  if (confirmDestroy) {
    return (
      <Overlay label="Tear the environment down">
        <div className="menu danger">
          <header>
            <h2>SHUT IT DOWN</h2>
          </header>
          <p>
            This destroys <strong>this whole environment</strong>: the EKS
            control plane, the nodes, the NAT gateway, the load balancer, the
            database and every volume the drill made. It is how you stop paying.
          </p>
          <p className="menu-note">
            Your progress is already saved on your laptop and survives this. The
            teardown runs there, not in here, and you get ten seconds to abort
            it in the terminal you started the drill from.
          </p>
          <label className="menu-confirm">
            Type <code>DESTROY</code> to confirm
            <input
              autoFocus
              value={typed}
              spellCheck={false}
              autoComplete="off"
              onChange={(e) => setTyped(e.target.value)}
              placeholder="DESTROY"
            />
          </label>
          <div className="menu-actions">
            <button className="btn" onClick={() => setConfirmDestroy(false)}>
              cancel
            </button>
            {/* Disabled until it matches exactly - and the server checks it again,
                because a confirmation enforced only here is a suggestion. */}
            <button
              className="btn danger"
              disabled={typed !== "DESTROY"}
              onClick={onDestroy}
            >
              destroy it
            </button>
          </div>
        </div>
      </Overlay>
    );
  }

  if (selecting) {
    return (
      <Overlay label="Choose a scenario">
        <div className="menu wide">
          <header>
            <h2>SELECT SCENARIO</h2>
            <span className="grow" />
            <button className="btn quiet" onClick={() => setSelecting(false)}>
              back
            </button>
          </header>
          {warning}
          <ul className="menu-grid">
            {scenarios.map((s) => (
              <li key={s.id}>
                <button
                  className={`slot${s.current ? " current" : ""}`}
                  disabled={!s.ported || s.current}
                  onClick={() => onSwitch(s.id)}
                  title={
                    s.current
                      ? "you are here"
                      : s.ported
                        ? `drill scenario ${s.id}`
                        : "not ported to the drill format yet"
                  }
                >
                  <span className="slot-id">{s.id}</span>
                  <span className="slot-title">{s.title}</span>
                  <span className="slot-tag">
                    {s.current
                      ? "current"
                      : s.ported
                        ? "ready"
                        : "not ported yet"}
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </div>
      </Overlay>
    );
  }

  return (
    <Overlay label="Paused">
      <div className="menu">
        <header>
          <h2>PAUSED</h2>
          <span className="grow" />
          <span className="menu-scenario">
            scenario {current || "--"}
            {total > 0 && (
              <>
                {" "}
                &middot; {passed}/{total} passed
              </>
            )}
          </span>
        </header>

        {warning}

        <ul className="menu-list">
          <Entry label="RESUME" hint="back to the drill" onClick={onResume} />
          <Entry
            label="RESTART"
            hint="this scenario, fresh session"
            onClick={onRestart}
          />
          <Entry
            label="NEXT"
            hint={
              next
                ? `${next.id} - ${next.title}${next.ported ? "" : " · not ported yet"}`
                : "nothing after this one"
            }
            disabled={!next?.ported}
            onClick={() => next && onSwitch(next.id)}
          />
          <Entry
            label="PREVIOUS"
            hint={
              previous
                ? `${previous.id} - ${previous.title}${previous.ported ? "" : " · not ported yet"}`
                : "nothing before this one"
            }
            disabled={!previous?.ported}
            onClick={() => previous && onSwitch(previous.id)}
          />
          <Entry
            label="SELECT..."
            hint="pick any scenario"
            onClick={() => setSelecting(true)}
          />
          <Entry
            label="QUIT"
            hint="end the run, leave the cluster up"
            onClick={onQuit}
          />
          <Entry
            label="SHUT IT DOWN"
            hint="destroy the environment and stop the bill"
            danger
            onClick={() => {
              setTyped("");
              setConfirmDestroy(true);
            }}
          />
        </ul>

        <p className="menu-note">
          <kbd>Esc</kbd> resumes. The cluster bills about $0.10/hr while it is
          up, whatever this menu is showing.
        </p>
      </div>
    </Overlay>
  );
}

function Entry({
  label,
  hint,
  onClick,
  disabled,
  danger,
}: {
  label: string;
  hint: string;
  onClick: () => void;
  disabled?: boolean;
  danger?: boolean;
}) {
  return (
    <li>
      <button
        className={`menu-entry${danger ? " danger" : ""}`}
        disabled={disabled}
        onClick={onClick}
      >
        <span className="menu-label">{label}</span>
        <span className="menu-hint">{hint}</span>
      </button>
    </li>
  );
}

function Overlay({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="overlay" role="dialog" aria-modal="true" aria-label={label}>
      {children}
    </div>
  );
}
