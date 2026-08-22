/**
 * The startup dependency chain, as a list the help panel can render.
 *
 * A drill has an order of operations - cluster git serves the repo, Argo CD reads
 * it, the app appears - and for the first minute or two of a session the honest
 * answer to "why is nothing happening" is "link two of three is still coming up".
 * Without this the user reads that as a broken drill and starts debugging the
 * scenario instead of waiting fifteen seconds.
 *
 * Every state here is derived from Kubernetes, not remembered. There is no state
 * machine and nothing is cached, so a dependency that goes away is reported as gone
 * rather than as whatever it last was.
 */
import type { DependencyStatus } from "@drill/shared";
import type { K8sReader } from "./k8s.ts";

export interface DepsOptions {
  gitNamespace: string;
  gitService: string;
  argoNamespace: string;
  argoDeployment: string;
  appNamespace: string;
  appDeployment: string;
  /** The Argo `Application`, which is how "told about" is distinguished from "made". */
  appName: string;
}

/**
 * Where the platform actually puts these, matching `cluster-git.tf` and the Argo
 * install. Options rather than constants because scenario 07 adds Grafana and
 * because a test that has to stand up the real names is a test about strings.
 */
export const DEFAULT_DEPS: DepsOptions = {
  gitNamespace: "git",
  gitService: "git-server",
  argoNamespace: "argocd",
  argoDeployment: "argocd-server",
  appNamespace: "practice-app",
  appDeployment: "practice-app-frontend",
  appName: "practice-app",
};

/**
 * Run one probe, and turn any failure into a reportable state.
 *
 * This panel is a diagnostic, and the moment it needs to work is the moment
 * something is broken. An unhandled throw would blank the status view exactly when
 * it is being read, so a failing probe reports `absent` and puts the error where
 * the detail goes.
 */
async function probe(
  name: DependencyStatus["name"],
  fn: () => Promise<DependencyStatus>,
): Promise<DependencyStatus> {
  try {
    return await fn();
  } catch (err) {
    return {
      name,
      state: "absent",
      detail: err instanceof Error ? err.message : String(err),
    };
  }
}

async function clusterGit(
  reader: K8sReader,
  o: DepsOptions,
): Promise<DependencyStatus> {
  const deployment = await reader.readDeployment(o.gitService, o.gitNamespace);
  if (!deployment)
    return {
      name: "cluster-git",
      state: "absent",
      detail: `no ${o.gitService} Deployment in ${o.gitNamespace} - is enable_cluster_git set?`,
    };

  // Endpoints rather than readyReplicas, because the readiness probe is what
  // enforces the .seeded marker. A pod that is running but unseeded has no
  // endpoint, and Argo cloning a half-served repo SUCCEEDS against a broken state -
  // which is worse than failing.
  const endpoints =
    (await reader.readEndpoints(o.gitService, o.gitNamespace)) ?? 0;
  if (endpoints > 0)
    return {
      name: "cluster-git",
      state: "ready",
      detail: `serving on ${o.gitService}.${o.gitNamespace}`,
    };

  return {
    name: "cluster-git",
    state: "starting",
    detail:
      "the pod is up but the repo is not seeded yet - run `make git-seed`",
  };
}

async function argocd(
  reader: K8sReader,
  o: DepsOptions,
): Promise<DependencyStatus> {
  const deployment = await reader.readDeployment(
    o.argoDeployment,
    o.argoNamespace,
  );
  if (!deployment)
    return {
      name: "argocd",
      state: "absent",
      detail: `no ${o.argoDeployment} Deployment in ${o.argoNamespace}`,
    };
  if (deployment.ready >= 1)
    return { name: "argocd", state: "ready", detail: "reconciling every 10s" };
  return {
    name: "argocd",
    state: "starting",
    detail: `${deployment.ready}/${deployment.replicas} replicas ready`,
  };
}

async function practiceApp(
  reader: K8sReader,
  o: DepsOptions,
): Promise<DependencyStatus> {
  const deployment = await reader.readDeployment(
    o.appDeployment,
    o.appNamespace,
  );

  if (deployment) {
    if (deployment.ready >= 1 && deployment.ready >= deployment.replicas)
      return {
        name: "practice-app",
        state: "ready",
        detail: `${deployment.ready}/${deployment.replicas} replicas ready`,
      };
    return {
      name: "practice-app",
      state: "starting",
      detail: `${deployment.ready}/${deployment.replicas} replicas ready`,
    };
  }

  // No Deployment. The question is now whether anything has been ASKED to make one,
  // and only the Argo Application can answer it. "Argo knows, Kubernetes has not
  // caught up" is the normal first ninety seconds of a drill; "nothing has been told
  // to create this" is a broken Application. They look identical from the Deployment
  // alone, and telling the user the app is missing while Argo is creating it sends
  // them to debug something that is working.
  const application = await reader.readCustomObject({
    group: "argoproj.io",
    version: "v1alpha1",
    namespace: o.argoNamespace,
    plural: "applications",
    name: o.appName,
  });

  if (application)
    return {
      name: "practice-app",
      state: "waiting",
      detail: "Argo has the Application; the Deployment has not appeared yet",
    };

  return {
    name: "practice-app",
    state: "absent",
    detail: `no ${o.appDeployment} Deployment and no ${o.appName} Application`,
  };
}

/**
 * Just enough of the server's configuration to answer the dependency question.
 *
 * Narrow on purpose. Both the HTTP route and the websocket's ten-second push need
 * this answer, and they live either side of `server.ts` -> `ws.ts`, so a shared
 * helper that took `ServerDeps` would close an import cycle. Taking three fields
 * instead means the helper lives down here where neither of them is.
 */
export interface DepsSource {
  reader?: K8sReader;
  argoNamespace: string;
  argoAppName: string;
}

/** What the panel says when there is no Kubernetes API to ask - the laptop case. */
function noCluster(): DependencyStatus[] {
  return (["cluster-git", "argocd", "practice-app"] as const).map((name) => ({
    name,
    state: "absent" as const,
    detail: "no Kubernetes API reachable from here",
  }));
}

/** The one answer both the route and the socket push serve. */
export async function resolveDependencies(
  src: DepsSource,
): Promise<DependencyStatus[]> {
  if (!src.reader) return noCluster();
  return checkDependencies(src.reader, {
    ...DEFAULT_DEPS,
    argoNamespace: src.argoNamespace,
    appName: src.argoAppName,
  });
}

export async function checkDependencies(
  reader: K8sReader,
  o: DepsOptions = DEFAULT_DEPS,
): Promise<DependencyStatus[]> {
  // Concurrent, and in the order they come up in. The list is rendered directly, so
  // its order is the story it tells: git serves, Argo reads, the app appears.
  return Promise.all([
    probe("cluster-git", () => clusterGit(reader, o)),
    probe("argocd", () => argocd(reader, o)),
    probe("practice-app", () => practiceApp(reader, o)),
  ]);
}
