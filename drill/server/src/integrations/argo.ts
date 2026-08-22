/**
 * Argo CD's `Application`, read through the Kubernetes API rather than through
 * Argo's own REST API.
 *
 * The CRD's `.status` already carries sync state, health, the synced revision and
 * the full resource tree, and the drill pod's ServiceAccount can read it. Going
 * through Argo's API instead would mean a bearer token, an account to create, a
 * credential to rotate and a second network hop - all to read a status. Same
 * reasoning that put cluster git behind `git daemon`: fewer credentials beats more
 * features when the feature is a status read.
 *
 * This file is a mapper and nothing else. There is deliberately no cache: the widget
 * polls, a `get` on one CRD is a single etcd read, and a cache is a way to show a
 * stale sync state during exactly the fifteen seconds the drill is about.
 */
import type { K8sReader } from "./k8s.ts";

/** One row of the resource tree, in Argo's own vocabulary. */
export interface ArgoResource {
  kind: string;
  name: string;
  namespace?: string;
  /** Argo's sync status for this resource. `Unknown` when it has not reconciled yet. */
  status: string;
  /** Absent for resources Argo does not health-check, which is most of them. */
  health?: string;
}

export interface ArgoApplication {
  /** False means Argo has no such Application - a normal state, not an error. */
  present: boolean;
  name: string;
  namespace: string;
  /** `Synced`, `OutOfSync`, `Unknown`. Argo's string, never normalised. */
  sync: string;
  /** `Healthy`, `Progressing`, `Degraded`, `Missing`, `Unknown`. */
  health: string;
  /** Whatever `targetRevision` resolved to - a sha, or a branch or tag name. */
  revision: string;
  /** The same thing, fit for a narrow column. */
  revisionShort: string;
  /** Argo's health message, when it has one. Usually the useful half. */
  message?: string;
  resources: ArgoResource[];
}

const UNKNOWN = "Unknown";

/**
 * Shorten a revision for display, but only when it is a sha.
 *
 * `revision` is whatever `targetRevision` resolved to, which for a branch or a tag
 * is a name. Chopping `release-2026-08` to `release` would be a lie about what is
 * deployed, so only a full-length hex sha is truncated.
 */
export function shortRevision(revision: string): string {
  return /^[0-9a-f]{40}$/.test(revision) ? revision.slice(0, 7) : revision;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function obj(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null
    ? (value as Record<string, unknown>)
    : {};
}

function mapResources(raw: unknown): ArgoResource[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((entry) => {
    const r = obj(entry);
    const health = str(obj(r.health).status);
    return {
      kind: str(r.kind) ?? UNKNOWN,
      name: str(r.name) ?? "",
      ...(str(r.namespace) ? { namespace: str(r.namespace) as string } : {}),
      // A resource Argo has seen but not yet reconciled carries no status at all.
      // Dropping it would make the tree shorter than the application, which reads
      // as "that resource does not exist".
      status: str(r.status) ?? UNKNOWN,
      ...(health ? { health } : {}),
    };
  });
}

/** The empty answer, so "no Application" and "no cluster" render identically. */
export function absentApplication(
  name: string,
  namespace: string,
): ArgoApplication {
  return {
    present: false,
    name,
    namespace,
    sync: UNKNOWN,
    health: UNKNOWN,
    revision: "",
    revisionShort: "",
    resources: [],
  };
}

export async function getApplication(
  reader: K8sReader,
  name: string,
  namespace: string,
): Promise<ArgoApplication> {
  const raw = await reader.readCustomObject({
    group: "argoproj.io",
    version: "v1alpha1",
    namespace,
    plural: "applications",
    name,
  });

  if (raw === undefined) return absentApplication(name, namespace);

  // Argo creates the object and fills `.status` a moment later, so every field
  // below can legitimately be missing on a brand new Application.
  const status = obj(obj(raw).status);
  const sync = obj(status.sync);
  const health = obj(status.health);
  const revision = str(sync.revision) ?? "";
  const message = str(health.message);

  return {
    present: true,
    name,
    namespace,
    sync: str(sync.status) ?? UNKNOWN,
    health: str(health.status) ?? UNKNOWN,
    revision,
    revisionShort: shortRevision(revision),
    ...(message ? { message } : {}),
    resources: mapResources(status.resources),
  };
}
