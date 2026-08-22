import { useEffect, useState, type ReactNode } from "react";
import type { TreeNode } from "../lib/api.ts";

interface Props {
  tree: TreeNode[];
  activePath: string | null;
  dirty: Set<string>;
  onOpen: (path: string) => void;
  /** The file the current task is graded from, badged so it is findable in a big tree. */
  taskPath: string | undefined;
}

/** Directories shallower than this start expanded. */
const OPEN_TO_DEPTH = 2;

/** Every directory path down to `depth`, for seeding the initial expansion. */
function shallowDirs(nodes: TreeNode[], depth = 0): string[] {
  if (depth >= OPEN_TO_DEPTH) return [];
  return nodes.flatMap((n) =>
    n.type === "dir"
      ? [n.path, ...shallowDirs(n.children ?? [], depth + 1)]
      : [],
  );
}

/**
 * The file explorer.
 *
 * A drill is one repository and the learner is meant to be able to wander round
 * it - that is the whole reason this exists, and it is why nothing here is scoped
 * to the file the task happens to name. The task's own file is badged rather than
 * isolated: findable in a tree of a hundred entries, still just one file among
 * them.
 */
export function Explorer({ tree, activePath, dirty, onOpen, taskPath }: Props) {
  // Expansion is tracked positively rather than as a set of collapsed paths. The
  // inverse reads fine until a default-collapsed directory needs to open, at
  // which point "not in the collapsed set" and "open" stop being the same thing.
  const [expanded, setExpanded] = useState<Set<string> | null>(null);

  // Seeded once, when the tree first arrives. A tree that greets you fully
  // collapsed makes you click three times to learn what the repo even contains;
  // one that expands everything buries the top level.
  useEffect(() => {
    if (tree.length > 0 && expanded === null) {
      setExpanded(new Set(shallowDirs(tree)));
    }
  }, [tree, expanded]);

  const toggle = (path: string) =>
    setExpanded((prev) => {
      const next = new Set(prev ?? []);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });

  const render = (nodes: TreeNode[], depth: number): ReactNode =>
    nodes.map((node) => {
      const pad = 6 + depth * 11;

      if (node.type === "dir") {
        const open = expanded?.has(node.path) ?? false;
        return (
          <li key={node.path}>
            <button
              className="tree-row dir"
              style={{ paddingLeft: pad }}
              onClick={() => toggle(node.path)}
              aria-expanded={open}
            >
              <Chevron open={open} />
              <span className="tree-name">{node.name}</span>
            </button>
            {open && node.children && node.children.length > 0 && (
              <ul className="tree-list">{render(node.children, depth + 1)}</ul>
            )}
          </li>
        );
      }

      return (
        <li key={node.path}>
          <button
            className={`tree-row file ${node.path === activePath ? "active" : ""}`}
            style={{ paddingLeft: pad + 14 }}
            onClick={() => onOpen(node.path)}
            title={node.path}
          >
            <span className="tree-name">{node.name}</span>
            {dirty.has(node.path) && (
              <span className="tree-dot" title="unsaved" />
            )}
            {node.path === taskPath && (
              <span
                className="tree-badge"
                title="the current task is graded from this file"
              >
                task
              </span>
            )}
          </button>
        </li>
      );
    });

  return (
    <section className="panel explorer">
      <header>
        <span>explorer</span>
        <span className="grow" />
        <span>workspace</span>
      </header>
      <div className="body">
        {tree.length === 0 ? (
          <p className="empty">the workspace is empty</p>
        ) : (
          <ul className="tree-list root">{render(tree, 0)}</ul>
        )}
      </div>
    </section>
  );
}

function Chevron({ open }: { open: boolean }) {
  return (
    <svg
      className={`chev ${open ? "open" : ""}`}
      viewBox="0 0 16 16"
      width="11"
      height="11"
      aria-hidden="true"
    >
      <path
        d="M6 4l4 4-4 4"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
