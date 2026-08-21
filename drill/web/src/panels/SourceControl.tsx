import type { GitFile, GitStatus } from "../lib/api.ts";

interface Props {
  status: GitStatus | null;
  activePath: string | null;
  onOpen: (path: string) => void;
}

/**
 * What git makes of the workspace.
 *
 * This panel exists for one lesson. Scenario 03 task 2 is "edit the tag and
 * deploy", and the trap is that editing is not deploying: the editor saves to the
 * workspace, git has not seen it, and Argo CD is therefore never going to sync it.
 * Without this you find that out by waiting for a rollout that never comes.
 *
 * There is no stage button, no commit box and no sync button, and their absence is
 * the design. `git add && git commit` in the terminal IS scenario 03's model
 * answer - a button here would let the task be passed without ever running the
 * command it is about. This view reports; the terminal acts.
 */
export function SourceControl({ status, activePath, onOpen }: Props) {
  const staged = status?.files.filter((f) => f.staged) ?? [];
  const unstaged = status?.files.filter((f) => !f.staged) ?? [];

  return (
    <section className="panel">
      <header>
        <span>source control</span>
        <span className="grow" />
        {status?.branch && <span className="scm-branch">{status.branch}</span>}
      </header>
      <div className="body">
        {!status ? (
          <p className="empty">reading git</p>
        ) : !status.repo ? (
          <p className="empty">
            This workspace is not a git repository.
            <br />
            In a drill it is a clone of the cluster&apos;s git server.
          </p>
        ) : status.files.length === 0 ? (
          <p className="empty">
            Nothing to commit.
            <br />
            The workspace matches the last commit.
          </p>
        ) : (
          <>
            {/* Unstaged first. It is what you just did, and in this drill it is
                almost always the whole story. */}
            <Group
              label="changes"
              files={unstaged}
              activePath={activePath}
              onOpen={onOpen}
            />
            <Group
              label="staged changes"
              files={staged}
              activePath={activePath}
              onOpen={onOpen}
            />
            <p className="scm-nudge">
              Saved is not deployed. Argo CD syncs what is{" "}
              <strong>committed and pushed</strong>, so a change sitting here is
              a change the cluster cannot see.
            </p>
          </>
        )}
      </div>
    </section>
  );
}

function Group({
  label,
  files,
  activePath,
  onOpen,
}: {
  label: string;
  files: GitFile[];
  activePath: string | null;
  onOpen: (path: string) => void;
}) {
  if (files.length === 0) return null;
  return (
    <>
      <div className="scm-group">
        <span>{label}</span>
        <span className="scm-count">{files.length}</span>
      </div>
      <ul className="tree-list">
        {files.map((file) => (
          <li key={file.path}>
            <button
              className={`tree-row file ${file.path === activePath ? "active" : ""}`}
              style={{ paddingLeft: 12 }}
              onClick={() => onOpen(file.path)}
              title={file.from ? `${file.from} -> ${file.path}` : file.path}
            >
              <span className="tree-name">
                {file.path.split("/").pop()}
                <span className="scm-dir">
                  {file.path.includes("/")
                    ? ` ${file.path.slice(0, file.path.lastIndexOf("/"))}`
                    : ""}
                </span>
              </span>
              <span className={`scm-letter ${letterClass(file)}`}>
                {statusLetter(file)}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </>
  );
}

/** The single letter git itself would print, which is the one worth learning. */
function statusLetter(file: GitFile): string {
  if (file.untracked) return "U";
  const letter = file.staged ? file.index : file.worktree;
  return letter.trim() || "M";
}

function letterClass(file: GitFile): string {
  const letter = statusLetter(file);
  if (letter === "D") return "bad";
  if (letter === "U" || letter === "A") return "good";
  return "warn";
}
