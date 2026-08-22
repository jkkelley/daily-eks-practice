/**
 * The warning the learner sees before the environment stands itself down.
 *
 * This surface is not decoration. The `SHUT IT DOWN` path gets a gate from the
 * learner typing DESTROY and the server re-checking it; the idle path
 * structurally cannot have that, because its whole premise is that nobody is at
 * the keyboard. This banner, and the fact that any keystroke clears it, is what
 * stands in for that gate. A countdown nobody can see is not a warning.
 *
 * It is a banner rather than a modal on purpose: a modal would have to be
 * dismissed, and the correct way to dismiss this one is to go back to work. It
 * must never sit between the learner and the terminal that resets it.
 */
import type { IdleView } from "../lib/idle.ts";
import { clockDuration, humanDuration } from "../lib/idle.ts";

interface Props {
  idle: IdleView;
  scenario: string | undefined;
}

export function IdleBanner({ idle, scenario }: Props) {
  const armed = idle.action === "destroy";
  const resume = `make scenario N=${scenario ?? "NN"}`;

  return (
    <div
      className={`idlebanner${armed ? " armed" : ""}`}
      role="status"
      aria-live="polite"
    >
      <div className="idlebanner-clock">{clockDuration(idle.secondsLeft)}</div>
      <div className="idlebanner-body">
        <strong>
          {armed
            ? "This cluster is about to self-terminate."
            : "This cluster would self-terminate about now."}
        </strong>
        <span>
          No keystroke for{" "}
          {humanDuration(idle.timeoutSeconds - idle.secondsLeft)} of the{" "}
          {humanDuration(idle.timeoutSeconds)} idle limit.{" "}
          {armed ? (
            <>
              Your progress is saved and outlives the cluster -{" "}
              <em>I'll be back</em>: <code>{resume}</code>
            </>
          ) : (
            <>
              Set <code>DRILL_IDLE_ACTION=destroy</code> to give this teeth.
            </>
          )}
        </span>
      </div>
      {/* The instruction, last and plainest, because it is the only thing on this
          banner the learner has to act on. */}
      <div className="idlebanner-hint">Type anything to reset the clock</div>
    </div>
  );
}
