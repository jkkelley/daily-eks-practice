/**
 * Mirroring the live session into the `drill-state` ConfigMap.
 *
 * This is one half of a two-object contract, and the halves are separate because
 * **each object has exactly one writer**:
 *
 *   drill-state    written HERE, by the server.       Read by scripts/drill-watch.py.
 *   drill-request  written by the laptop.             Read by request.ts.
 *
 * A single ConfigMap with two authors races on `resourceVersion` and drops a
 * write, and the write it drops is a task the learner just passed. Two objects
 * cost one extra `kubectl get` and make the race structurally impossible.
 *
 * The ConfigMap survives pod restarts, which is the failure that matters, and
 * dies with the cluster, which is correct - the drill dies with the cluster
 * anyway, and the durable copy is the bundle on the learner's laptop.
 */
import type { SessionState } from "@drill/shared";
import type { K8sStateWriter } from "./integrations/k8s.ts";

export const STATE_CONFIGMAP = "drill-state";
export const STATE_KEY = "state.json";

/**
 * A ConfigMap is capped at 1 MiB by the API server, which rejects the WHOLE
 * object when it is exceeded. 900 KiB leaves room for metadata and for the
 * base64 inflation of anything non-ASCII a learner typed into an answer.
 */
export const MAX_STATE_BYTES = 900 * 1024;

export interface StateStore {
  save(state: SessionState): Promise<void>;
}

/**
 * Fit the state under the cap by dropping the OLDEST attempts, and say so.
 *
 * `attempts` is append-only by design and therefore unbounded. Six tasks will
 * never come close; a stuck client retrying, a submit loop, or a very long
 * multi-scenario session can. Without a guard the failure is the worst shape
 * available: every write from that moment on is rejected, the ConfigMap silently
 * stops advancing, the watcher keeps faithfully saving the last good state, and
 * the learner's progress stops being recorded with no symptom at all until they
 * try to resume.
 *
 * Oldest first is the right end to drop. A resume needs where you got to, and the
 * `only-imperative` nudge reads recent passes - neither cares what you typed forty
 * minutes ago. The count is kept because a save file that quietly is not the whole
 * story is exactly the failure mode this project has been bitten by three times
 * now: the vacuous AC-H5 pass, the truncated git bundle, and `undefined` collapsing
 * into "not committed".
 */
export function fitToConfigMap(state: SessionState): {
  payload: SessionState;
  encoded: string;
} {
  let dropped = 0;
  let attempts = state.attempts;

  const encode = (a: typeof attempts, n: number): string =>
    JSON.stringify({
      ...state,
      attempts: a,
      ...(n > 0 ? { attemptsDropped: n } : {}),
    });

  let encoded = encode(attempts, dropped);
  while (
    Buffer.byteLength(encoded, "utf8") > MAX_STATE_BYTES &&
    attempts.length > 0
  ) {
    // Halve rather than shift one at a time: a 1 MiB overflow is thousands of
    // attempts, and re-encoding the whole state per attempt is quadratic on the
    // exact path that is already under pressure.
    const drop = Math.max(1, Math.floor(attempts.length / 2));
    attempts = attempts.slice(drop);
    dropped += drop;
    encoded = encode(attempts, dropped);
  }

  return { payload: JSON.parse(encoded) as SessionState, encoded };
}

export function createStateStore(
  writer: K8sStateWriter,
  namespace: string,
): StateStore {
  return {
    async save(state) {
      const { encoded } = fitToConfigMap(state);
      await writer.writeConfigMap(STATE_CONFIGMAP, namespace, {
        [STATE_KEY]: encoded,
      });
    },
  };
}

/**
 * Save without letting a save failure become the caller's problem.
 *
 * Called from `POST /api/submit`. The learner answered correctly; whether we
 * managed to mirror that is our problem, not theirs, and failing the submit
 * would mark a right answer wrong because of an API blip. Logged, not swallowed
 * silently - "not saved" must still be visible to whoever is reading the pod log.
 */
export async function saveQuietly(
  store: StateStore | undefined,
  state: SessionState,
  log: (message: string) => void = console.error,
): Promise<void> {
  if (!store) return;
  try {
    await store.save(state);
  } catch (e) {
    log(
      `drill-state: could not mirror the session (${
        e instanceof Error ? e.message : String(e)
      }) - the drill continues, but progress is not being saved to the laptop`,
    );
  }
}
