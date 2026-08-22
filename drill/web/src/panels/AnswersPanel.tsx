import { useState } from "react";
import type { SessionState, Verdict } from "@drill/shared";
import { submit, type PublicTask } from "../lib/api.ts";

interface Props {
  tasks: PublicTask[];
  state: SessionState | null;
  onGraded: (v: Verdict) => void;
}

/**
 * The drill as a ladder rather than a form.
 *
 * A form asks "what is your answer"; a ladder shows where you are in a run you are
 * partway through, which is the thing you want to know every time you look back at
 * this panel. Rungs are click-to-open so the panel stays readable at six tasks and
 * would still be readable at twenty.
 */
export function AnswersPanel({ tasks, state, onGraded }: Props) {
  const [open, setOpen] = useState<string | null>(null);
  const current = state?.currentTaskId ?? tasks[0]?.id;
  const shown = open ?? current;

  return (
    <ol className="ladder">
      {tasks.map((task, i) => {
        const done = state?.passed.includes(task.id) ?? false;
        const isCurrent = task.id === current;
        const cls = ["rung", done && "done", isCurrent && "current"]
          .filter(Boolean)
          .join(" ");
        return (
          <li key={task.id} className={cls}>
            <span className="node" />
            <button
              className="head"
              aria-expanded={shown === task.id}
              onClick={() => setOpen(shown === task.id ? "" : task.id)}
            >
              <span className="idx">{String(i + 1).padStart(2, "0")}</span>
              <span className="prompt">{task.prompt}</span>
              <span className="kind">{task.grader}</span>
            </button>
            {shown === task.id && (
              <TaskDetail task={task} onGraded={onGraded} passed={done} />
            )}
          </li>
        );
      })}
    </ol>
  );
}

function TaskDetail({
  task,
  onGraded,
  passed,
}: {
  task: PublicTask;
  onGraded: (v: Verdict) => void;
  passed: boolean;
}) {
  const [answer, setAnswer] = useState("");
  const [verdict, setVerdict] = useState<Verdict | null>(null);
  const [busy, setBusy] = useState(false);

  // A file task is graded from the workspace, so there is nothing to type: the
  // proof is that the file really changed, which a text box cannot give.
  const fileGraded = task.grader === "file";

  const go = async () => {
    setBusy(true);
    try {
      const v = await submit(task.id, answer);
      setVerdict(v);
      onGraded(v);
    } catch (e) {
      setVerdict({
        taskId: task.id,
        passed: false,
        message: (e as Error).message,
      });
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="detail">
      <div className="field">
        {fileGraded ? (
          <p
            className="prompt"
            style={{ flex: "1 1 auto", margin: 0, alignSelf: "center" }}
          >
            Graded from <code className="mono">{task.path}</code> in the
            workspace.
          </p>
        ) : (
          <textarea
            className="answer"
            rows={task.grader === "prose" ? 3 : 1}
            spellCheck={false}
            placeholder={
              task.grader === "command"
                ? "the command you ran"
                : "in your own words"
            }
            value={answer}
            onChange={(e) => setAnswer(e.target.value)}
            onKeyDown={(e) => {
              // Enter submits a one-line command; prose needs its newlines.
              if (
                e.key === "Enter" &&
                !e.shiftKey &&
                task.grader === "command"
              ) {
                e.preventDefault();
                void go();
              }
            }}
          />
        )}
        <button
          className="btn"
          disabled={busy || (!fileGraded && answer.trim() === "")}
          onClick={() => void go()}
        >
          {busy ? "grading" : passed ? "check again" : "check"}
        </button>
      </div>
      {verdict && <VerdictLine verdict={verdict} />}
    </div>
  );
}

/**
 * A wrong answer is never just a red mark.
 *
 * The hint is the product, so it gets the space and the rule. And a hint can ride
 * on a PASS - scenario 03's `only-imperative` is exactly that, because `kubectl
 * rollout undo` is the right rollback and Argo CD is still about to undo it.
 * Rendering that as a failure would teach the opposite of the truth.
 */
function VerdictLine({ verdict }: { verdict: Verdict }) {
  return (
    <div className={`verdict ${verdict.passed ? "passed" : "failed"}`}>
      <span className="label">
        {verdict.passed ? "pass" : "not yet"}
        {verdict.hint && <span className="hintkey"> · {verdict.hint}</span>}
      </span>
      {verdict.message}
    </div>
  );
}
