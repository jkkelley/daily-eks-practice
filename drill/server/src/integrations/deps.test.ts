import { test } from "node:test";
import assert from "node:assert/strict";
import { checkDependencies, DEFAULT_DEPS } from "./deps.ts";
import type { DeploymentSnapshot, K8sReader } from "./k8s.ts";

/**
 * A cluster described as a lookup table.
 *
 * Deliberately keyed by `ns/name` rather than mocking method calls, because every
 * assertion below is about what the STATE OF THE CLUSTER maps to, and a fake that
 * makes you think about call order gets in the way of reading that.
 */
function fake(world: {
  deployments?: Record<string, DeploymentSnapshot>;
  endpoints?: Record<string, number>;
  application?: unknown;
  throws?: string;
}): K8sReader {
  return {
    readDeployment: async (name, namespace) => {
      const key = `${namespace}/${name}`;
      if (world.throws === key) throw new Error("boom: " + key);
      return world.deployments?.[key];
    },
    readEndpoints: async (name, namespace) =>
      world.endpoints?.[`${namespace}/${name}`],
    readCustomObject: async () => world.application,
  };
}

const D = (replicas: number, ready: number): DeploymentSnapshot => ({
  replicas,
  ready,
});

const byName = (list: Awaited<ReturnType<typeof checkDependencies>>) =>
  Object.fromEntries(list.map((d) => [d.name, d]));

test("a fully-up cluster reports all three ready", async () => {
  const deps = byName(
    await checkDependencies(
      fake({
        deployments: {
          "git/git-server": D(1, 1),
          "argocd/argocd-server": D(1, 1),
          "practice-app/practice-app-frontend": D(2, 2),
        },
        endpoints: { "git/git-server": 1 },
      }),
      DEFAULT_DEPS,
    ),
  );

  assert.equal(deps["cluster-git"]?.state, "ready");
  assert.equal(deps["argocd"]?.state, "ready");
  assert.equal(deps["practice-app"]?.state, "ready");
});

test("the three entries always come back, in the order they start in", async () => {
  // The panel renders this list directly. A dependency that vanishes when it is
  // absent is a dependency the reader cannot see is the problem.
  const list = await checkDependencies(fake({}), DEFAULT_DEPS);
  assert.deepEqual(
    list.map((d) => d.name),
    ["cluster-git", "argocd", "practice-app"],
  );
  assert.deepEqual(
    list.map((d) => d.state),
    ["absent", "absent", "absent"],
  );
});

test("cluster git with a running pod but no endpoints is starting, not ready", async () => {
  // This is the readiness probe doing its job: the repo has no .seeded marker yet,
  // so the Service has no endpoints and Argo would clone a half-served repo. The
  // danger was never that Argo errors - it is that Argo SUCCEEDS against one.
  const deps = byName(
    await checkDependencies(
      fake({
        deployments: { "git/git-server": D(1, 1) },
        endpoints: { "git/git-server": 0 },
      }),
      DEFAULT_DEPS,
    ),
  );
  assert.equal(deps["cluster-git"]?.state, "starting");
  assert.match(deps["cluster-git"]?.detail ?? "", /seed/i);
});

test("argo with zero ready replicas is starting", async () => {
  const deps = byName(
    await checkDependencies(
      fake({ deployments: { "argocd/argocd-server": D(1, 0) } }),
      DEFAULT_DEPS,
    ),
  );
  assert.equal(deps["argocd"]?.state, "starting");
});

test("an app Argo knows about but Kubernetes has not created yet is WAITING, not absent", async () => {
  // The distinction this whole function exists for. "Argo has been told, the
  // Deployment does not exist yet" is the normal first ninety seconds of a drill.
  // "Nothing has been told to create this" is a broken Application. Collapsing them
  // makes the panel say the app is missing while Argo is actively creating it.
  const deps = byName(
    await checkDependencies(
      fake({ application: { metadata: { name: "practice-app" } } }),
      DEFAULT_DEPS,
    ),
  );
  assert.equal(deps["practice-app"]?.state, "waiting");
});

test("an app with no Deployment and no Application is absent", async () => {
  const deps = byName(await checkDependencies(fake({}), DEFAULT_DEPS));
  assert.equal(deps["practice-app"]?.state, "absent");
});

test("a partially rolled out app is starting, and says how far", async () => {
  const deps = byName(
    await checkDependencies(
      fake({
        deployments: { "practice-app/practice-app-frontend": D(3, 1) },
      }),
      DEFAULT_DEPS,
    ),
  );
  assert.equal(deps["practice-app"]?.state, "starting");
  assert.match(deps["practice-app"]?.detail ?? "", /1\/3/);
});

test("one dependency throwing does not take the other two down", async () => {
  // This panel is a diagnostic, and the moment it needs to work is the moment
  // something is broken. An unhandled throw here means the status view goes blank
  // exactly when it is being read.
  const deps = byName(
    await checkDependencies(
      fake({
        throws: "git/git-server",
        deployments: { "argocd/argocd-server": D(1, 1) },
      }),
      DEFAULT_DEPS,
    ),
  );
  assert.equal(deps["argocd"]?.state, "ready");
  assert.equal(deps["cluster-git"]?.state, "absent");
  assert.match(deps["cluster-git"]?.detail ?? "", /boom/);
});

test("every entry carries a detail, because a bare state is not a diagnostic", async () => {
  const list = await checkDependencies(fake({}), DEFAULT_DEPS);
  for (const dep of list) {
    assert.ok(
      dep.detail.length > 0,
      `${dep.name} came back with an empty detail`,
    );
  }
});
