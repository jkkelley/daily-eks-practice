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
  /**
   * A ConfigMap's `data`, for the laptop's half of the two-object contract.
   *
   * Reading `drill-request` is how the server learns that `make scenario N=06`
   * happened, or that the watcher finished restoring a saved session. It is a
   * read, so it belongs on the reader - the WRITE side is `K8sStateWriter`, and
   * the two are separate types on purpose.
   */
  readConfigMap(
    name: string,
    namespace: string,
  ): Promise<Record<string, string> | undefined>;
}

/**
 * Writing the server's OWN state back. A separate interface, on purpose.
 *
 * `K8sReader` above says nothing the GUI does on the user's behalf mutates, and
 * that rule is what stops a widget from passing a task the learner never
 * performed - the same rule that keeps stage and commit buttons off the source
 * control view. The server mirroring its own session into a ConfigMap is not an
 * action on the user's behalf; it is the process's own bookkeeping.
 *
 * A distinct type is what makes that distinction checkable rather than a comment
 * somebody has to believe. A panel that takes a `K8sReader` cannot be handed a
 * writer, and a lifecycle route that takes a `K8sStateWriter` cannot be handed a
 * reader. If these were methods on one interface, "read-only" would be a
 * convention, and conventions are what this file exists to stop relying on.
 */
export interface K8sStateWriter {
  writeConfigMap(
    name: string,
    namespace: string,
    data: Record<string, string>,
  ): Promise<void>;
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

    readConfigMap: (name, namespace) =>
      read(`configmap ${namespace}/${name}`, serviceAccount, async () => {
        const cm = await core.readNamespacedConfigMap({ name, namespace });
        // `data` is absent rather than `{}` on a ConfigMap with no keys, and an
        // empty ConfigMap is a real state here - the laptop creates it before it
        // has anything to put in it. `{}` and "not there" must stay different.
        return cm.data ?? {};
      }),
  };
}

/**
 * A ConfigMap writer backed by the pod's own ServiceAccount.
 *
 * Read, then replace, and create on 404. A blind create fails on the second write
 * and a blind replace fails on the first, and both failures look like "the cluster
 * is broken" rather than like the ordinary lifecycle they actually are.
 *
 * Only `data` is replaced - labels and anything else on the object survive, so a
 * ConfigMap that Terraform or a future controller also annotates does not get its
 * metadata stripped every ten seconds.
 */
export function clusterWriter(serviceAccount = "drill"): K8sStateWriter {
  const kc = new KubeConfig();
  kc.loadFromCluster();
  const core = kc.makeApiClient(CoreV1Api);

  return {
    async writeConfigMap(name, namespace, data) {
      const existing = await read(
        `configmap ${namespace}/${name}`,
        serviceAccount,
        () => core.readNamespacedConfigMap({ name, namespace }),
      );

      if (existing === undefined) {
        await core.createNamespacedConfigMap({
          namespace,
          body: { metadata: { name, namespace }, data },
        });
        return;
      }

      await core.replaceNamespacedConfigMap({
        name,
        namespace,
        body: { ...existing, data },
      });
    },
  };
}

/**
 * A writer if we are in a cluster, and `undefined` if we are not.
 *
 * Same shape and same reason as `createReader`: on a laptop there is no cluster,
 * `make -f Makefile.test drill-dev` still has to work, and a server that refused
 * to start without somewhere to mirror its state would trade a working local
 * development path for a feature nobody can use locally anyway.
 */
export function createWriter(
  env: NodeJS.ProcessEnv = process.env,
): K8sStateWriter | undefined {
  if (!env.KUBERNETES_SERVICE_HOST) return undefined;
  try {
    return clusterWriter(env.DRILL_SERVICE_ACCOUNT ?? "drill");
  } catch {
    return undefined;
  }
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
