/**
 * The one place in this repo that imports `@kubernetes/client-node`.
 *
 * Everything above this file takes a `K8sReader` and is tested against a fake, so
 * the generated client's surface - which changed wholesale between 0.x and 1.x and
 * will change again - is contained in one file with no logic in it. When the next
 * rewrite lands, exactly this needs editing.
 *
 * Read-only on purpose. The drill's ServiceAccount is `cluster-admin` because
 * scenario 10's break/fix needs it, but nothing the GUI does on the user's behalf
 * goes through here: the terminal is where the cluster gets changed, and a widget
 * that could mutate would let a task be passed without running the command it is
 * about. Same rule as the source control view.
 */
import {
  AppsV1Api,
  CoreV1Api,
  CustomObjectsApi,
  KubeConfig,
} from "@kubernetes/client-node";

/** Enough of an Argo `Application` to point at one. */
export interface CustomObjectRef {
  group: string;
  version: string;
  namespace: string;
  plural: string;
  name: string;
}

/** The two numbers that decide whether a Deployment is up. */
export interface DeploymentSnapshot {
  replicas: number;
  ready: number;
}

/**
 * Three reads, and a shared convention that is the whole reason this is an
 * interface rather than a class.
 *
 * `undefined` means the object is NOT THERE, which is a normal state - Argo has not
 * been told about the app yet, the Deployment has not been created. A thrown error
 * means something is WRONG, and the two must never be collapsed: a 403 rendered as
 * "absent" sends the reader looking at Argo when the problem is their RBAC.
 */
export interface K8sReader {
  readCustomObject(ref: CustomObjectRef): Promise<unknown | undefined>;
  readDeployment(
    name: string,
    namespace: string,
  ): Promise<DeploymentSnapshot | undefined>;
  /** How many ready addresses the Service's Endpoints carries. */
  readEndpoints(name: string, namespace: string): Promise<number | undefined>;
}

/**
 * The API server's status code, dug out of whatever the client threw.
 *
 * 1.x throws `ApiException` with `.code`, older shapes used `.statusCode` or
 * `.response.statusCode`, and a network failure has none of them. Reading all three
 * rather than importing `ApiException` keeps this working across the version bump
 * that is coming, and a wrong guess here costs a 404 misread as an outage.
 */
function statusOf(err: unknown): number | undefined {
  if (typeof err !== "object" || err === null) return undefined;
  const e = err as Record<string, unknown>;
  if (typeof e.code === "number") return e.code;
  if (typeof e.statusCode === "number") return e.statusCode;
  const response = e.response as Record<string, unknown> | undefined;
  if (response && typeof response.statusCode === "number")
    return response.statusCode;
  return undefined;
}

/** Sink for the shared 404-is-absent / 403-is-a-message rule. */
async function read<T>(
  what: string,
  serviceAccount: string,
  fn: () => Promise<T>,
): Promise<T | undefined> {
  try {
    return await fn();
  } catch (err) {
    const status = statusOf(err);
    if (status === 404) return undefined;
    if (status === 403)
      throw new Error(
        `the drill ServiceAccount (${serviceAccount}) cannot read ${what} - it should be bound to cluster-admin`,
      );
    throw err instanceof Error ? err : new Error(String(err));
  }
}

/**
 * A reader backed by the pod's own ServiceAccount.
 *
 * `loadFromCluster` reads the projected token, the CA bundle and the API host from
 * the paths kubelet mounts, so this only works inside a pod. Outside one it throws,
 * which is why `createReader` below is the entry point the server actually uses:
 * running on a laptop with no cluster must degrade to "no Argo here" rather than
 * refusing to start, or `make -f Makefile.test drill-dev` stops working.
 */
export function clusterReader(serviceAccount = "drill"): K8sReader {
  const kc = new KubeConfig();
  kc.loadFromCluster();
  const custom = kc.makeApiClient(CustomObjectsApi);
  const apps = kc.makeApiClient(AppsV1Api);
  const core = kc.makeApiClient(CoreV1Api);

  return {
    readCustomObject: (ref) =>
      read(`${ref.plural}.${ref.group}`, serviceAccount, () =>
        custom.getNamespacedCustomObject(ref),
      ),

    readDeployment: (name, namespace) =>
      read(`deployment ${namespace}/${name}`, serviceAccount, async () => {
        const d = await apps.readNamespacedDeployment({ name, namespace });
        return {
          // `.spec.replicas` defaults to 1 when unset, and `.status.readyReplicas`
          // is ABSENT rather than 0 while nothing is ready - which is exactly the
          // state this is asked about most often.
          replicas: d.spec?.replicas ?? 1,
          ready: d.status?.readyReplicas ?? 0,
        };
      }),

    readEndpoints: (name, namespace) =>
      read(`endpoints ${namespace}/${name}`, serviceAccount, async () => {
        const ep = await core.readNamespacedEndpoints({ name, namespace });
        return (ep.subsets ?? []).reduce(
          (total, subset) => total + (subset.addresses?.length ?? 0),
          0,
        );
      }),
  };
}

/**
 * A reader if we are in a cluster, and `undefined` if we are not.
 *
 * The server treats `undefined` as "these panels report unavailable", which is what
 * keeps the Vite dev path working with no Kubernetes anywhere. Silent by design:
 * on a laptop this is the expected case, not a warning.
 */
export function createReader(
  env: NodeJS.ProcessEnv = process.env,
): K8sReader | undefined {
  if (!env.KUBERNETES_SERVICE_HOST) return undefined;
  try {
    return clusterReader(env.DRILL_SERVICE_ACCOUNT ?? "drill");
  } catch {
    return undefined;
  }
}
