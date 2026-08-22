/**
 * The laptop's half of the two-object contract: which scenario to converge to.
 *
 *   drill-state    written by the server.   Read by scripts/drill-watch.py.
 *   drill-request  written by the laptop.   Read HERE.
 *
 * Two objects, one writer each, because a single ConfigMap with two authors races
 * on `resourceVersion` and the write it loses is a task the learner just passed.
 *
 * ---- WHY THIS POLLS, WHEN drill-watch.py WATCHES -------------------------
 *
 * The asymmetry is deliberate and is not an oversight.
 *
 * `drill-watch.py` is on the far side of a network from the API server, where a
 * watch is genuinely better and is also the primitive every controller is built
 * from - keeping the tool that teaches Kubernetes built out of Kubernetes is
 * worth something on its own.
 *
 * This runs INSIDE the cluster, microseconds from the API, where a `get` on one
 * small object costs nothing and a watch buys reconnects, bookmarks and `410
 * Gone` handling to get wrong. A watch that silently stops delivering is exactly
 * the failure that makes a scenario switch hang forever with nothing in any log,
 * and this project has already been bitten twice by silent-drop bugs of that
 * family: the websocket resize sent before OPEN, and tmux's first burst dumped
 * before anything had subscribed.
 */
import type { K8sReader } from "./integrations/k8s.ts";

export const REQUEST_CONFIGMAP = "drill-request";
export const REQUEST_KEY = "request.json";

/** What the laptop asks for. Written by `scripts/scenario.py` and by the watcher. */
export interface DrillRequest {
  scenario: string;
  /**
   * The laptop's session id, which is also the save-file directory name.
   *
   * This, not `scenario`, is what says a request is NEW. Restarting scenario 03
   * asks for the same scenario and a different session, and a comparison on
   * scenario alone would silently ignore every restart.
   */
  sessionId: string;
  requestedAt?: string;
  /** Informational: the bundle the laptop restored from, if it restored one. */
  restoredFrom?: string;
}

/**
 * Parse the ConfigMap's data, and answer `undefined` for anything unusable.
 *
 * Unusable covers absent, empty, malformed JSON and structurally-wrong JSON, and
 * they are folded together on purpose. The caller's only sensible response to any
 * of them is identical - keep running the session you already have - and a
 * distinction with no different behaviour behind it is a branch waiting to be got
 * wrong. A half-written request must never take a live drill down.
 */
export function parseRequest(
  data: Record<string, string> | undefined,
): DrillRequest | undefined {
  const raw = data?.[REQUEST_KEY];
  if (!raw) return undefined;
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return undefined;
  }
  if (typeof parsed !== "object" || parsed === null) return undefined;
  const r = parsed as Record<string, unknown>;
  if (typeof r.scenario !== "string" || !r.scenario) return undefined;
  if (typeof r.sessionId !== "string" || !r.sessionId) return undefined;
  return {
    scenario: r.scenario,
    sessionId: r.sessionId,
    ...(typeof r.requestedAt === "string"
      ? { requestedAt: r.requestedAt }
      : {}),
    ...(typeof r.restoredFrom === "string"
      ? { restoredFrom: r.restoredFrom }
      : {}),
  };
}

export async function readRequest(
  reader: K8sReader,
  namespace: string,
): Promise<DrillRequest | undefined> {
  return parseRequest(await reader.readConfigMap(REQUEST_CONFIGMAP, namespace));
}

export interface RequestWatchOptions {
  intervalMs?: number;
  /** Injected so the test does not have to wait two seconds per assertion. */
  onError?: (e: unknown) => void;
}

/**
 * Poll `drill-request` and call `onRequest` when the session id changes.
 *
 * Returns a stop function. `seed` is the session id already running, so the
 * request that STARTED this session does not immediately fire as a new one.
 *
 * An API error is reported and then ignored. The drill is running, the learner is
 * mid-task, and a transient read failure is not a reason to do anything at all -
 * the next tick is two seconds away.
 */
export function watchRequest(
  reader: K8sReader,
  namespace: string,
  seed: string | undefined,
  onRequest: (req: DrillRequest) => void | Promise<void>,
  opts: RequestWatchOptions = {},
): () => void {
  let last = seed;
  let stopped = false;

  const tick = async (): Promise<void> => {
    if (stopped) return;
    try {
      const req = await readRequest(reader, namespace);
      if (req && req.sessionId !== last) {
        last = req.sessionId;
        await onRequest(req);
      }
    } catch (e) {
      (opts.onError ?? console.error)(e);
    }
  };

  const timer = setInterval(() => void tick(), opts.intervalMs ?? 2_000);
  // Node keeps the process alive for a pending timer, and this one never
  // resolves. The server has a listening socket holding it open anyway, so this
  // only changes whether a test that forgets to stop the watcher hangs forever.
  timer.unref?.();
  void tick();

  return () => {
    stopped = true;
    clearInterval(timer);
  };
}
