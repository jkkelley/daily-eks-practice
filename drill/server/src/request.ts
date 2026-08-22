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
import type { IdlePolicyView } from "@drill/shared";
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
  /**
   * The idle limit the laptop is enforcing, if any. Rendered here, enforced there.
   *
   * These ride `drill-request` rather than being configured in the pod because the
   * laptop is where the clock actually runs, and a second copy of a number that
   * decides whether to destroy an environment is a number that can disagree with
   * itself. One writer, one source.
   */
  idleTimeoutSeconds?: number;
  idleAction?: "warn" | "destroy";
  idleWarnSeconds?: number;
}

/** The idle fields, or undefined when the laptop is not enforcing a limit. */
export function idlePolicyOf(
  req: DrillRequest | undefined,
): IdlePolicyView | undefined {
  if (!req || typeof req.idleTimeoutSeconds !== "number") return undefined;
  if (!(req.idleTimeoutSeconds > 0)) return undefined;
  return {
    timeoutSeconds: req.idleTimeoutSeconds,
    action: req.idleAction === "destroy" ? "destroy" : "warn",
    // The fallback mirrors drill-watch.py's `default_warn`: a third of the limit,
    // capped at two minutes. The watcher always publishes an explicit value, so
    // this only fires against a hand-written request - but two different answers
    // to "how long is the banner up" is exactly the kind of quiet disagreement
    // that makes a countdown untrustworthy.
    warnSeconds:
      typeof req.idleWarnSeconds === "number" && req.idleWarnSeconds > 0
        ? Math.min(req.idleWarnSeconds, req.idleTimeoutSeconds)
        : Math.max(1, Math.min(120, Math.floor(req.idleTimeoutSeconds / 3))),
  };
}

/** Are two policies the same? Used to avoid a mirror write per poll tick. */
export function samePolicy(
  a: IdlePolicyView | undefined,
  b: IdlePolicyView | undefined,
): boolean {
  if (!a || !b) return a === b;
  return (
    a.timeoutSeconds === b.timeoutSeconds &&
    a.action === b.action &&
    a.warnSeconds === b.warnSeconds
  );
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
    // Carried through with the same "unusable is absent" rule as everything
    // else here. A half-written idle policy must never become a real one: the
    // absent case is "no limit", which is the safe answer, and a malformed
    // number silently becoming a limit is how a cluster disappears.
    ...(typeof r.idleTimeoutSeconds === "number" &&
    Number.isFinite(r.idleTimeoutSeconds)
      ? { idleTimeoutSeconds: r.idleTimeoutSeconds }
      : {}),
    ...(r.idleAction === "warn" || r.idleAction === "destroy"
      ? { idleAction: r.idleAction }
      : {}),
    ...(typeof r.idleWarnSeconds === "number" &&
    Number.isFinite(r.idleWarnSeconds)
      ? { idleWarnSeconds: r.idleWarnSeconds }
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
  /**
   * Fired when the idle policy changes, independently of `onRequest`.
   *
   * It has to be a separate callback, because the two travel on the same object
   * and change for completely different reasons. `onRequest` fires on a NEW
   * SESSION and converges the whole drill; retuning the idle limit does not touch
   * the session id, so folding it into that comparison would either miss every
   * policy change or converge the drill every time the user restarted their
   * watcher with a different number. Both are wrong, in opposite directions.
   */
  onPolicy?: (policy: IdlePolicyView | undefined) => void | Promise<void>;
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
  let lastPolicy: IdlePolicyView | undefined;
  let sawPolicy = false;

  const tick = async (): Promise<void> => {
    if (stopped) return;
    try {
      const req = await readRequest(reader, namespace);

      // Policy first, and unconditionally on the request being readable. A
      // session change should not be a prerequisite for the countdown being
      // right, and the policy is also how the GUI learns the limit was CLEARED -
      // which it must, or it counts down to a teardown nobody will perform.
      if (opts.onPolicy) {
        const policy = idlePolicyOf(req);
        if (!sawPolicy || !samePolicy(policy, lastPolicy)) {
          sawPolicy = true;
          lastPolicy = policy;
          await opts.onPolicy(policy);
        }
      }

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
