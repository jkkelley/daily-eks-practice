import { test } from "node:test";
import assert from "node:assert/strict";
import { getApplication } from "./argo.ts";
import type { K8sReader } from "./k8s.ts";

/** A reader that answers the Application read and refuses everything else. */
function reader(answer: unknown | (() => never)): K8sReader {
  return {
    readCustomObject: async () => {
      if (typeof answer === "function") (answer as () => never)();
      return answer;
    },
    readDeployment: async () => undefined,
    readEndpoints: async () => undefined,
  };
}

const SHA = "9f2c1b4a7e5d3c8f0a6b2d4e1c9f7a3b5d8e0c2f";

function application(status: Record<string, unknown>): unknown {
  return { metadata: { name: "practice-app" }, status };
}

test("a synced healthy Application maps to Argo's own two words", async () => {
  const app = await getApplication(
    reader(
      application({
        sync: { status: "Synced", revision: SHA },
        health: { status: "Healthy" },
      }),
    ),
    "practice-app",
    "argocd",
  );

  assert.equal(app.present, true);
  assert.equal(app.sync, "Synced");
  assert.equal(app.health, "Healthy");
  assert.equal(app.revision, SHA);
});

test("a missing Application is a state, not an exception", async () => {
  // Argo not having been told about the app yet is normal for the first minute of
  // a drill. A throw here would take the whole right-hand panel down during exactly
  // the window the panel exists to narrate.
  const app = await getApplication(reader(undefined), "practice-app", "argocd");
  assert.equal(app.present, false);
  assert.equal(app.sync, "Unknown");
  assert.deepEqual(app.resources, []);
});

test("a 403 reaches the caller instead of rendering as an empty widget", async () => {
  // The ServiceAccount is cluster-admin, so a 403 means the binding is wrong. An
  // empty widget sends the reader to look at Argo, which is the wrong place.
  await assert.rejects(
    () =>
      getApplication(
        reader(() => {
          throw new Error(
            "the drill ServiceAccount (drill) cannot read applications.argoproj.io - it should be bound to cluster-admin",
          );
        }),
        "practice-app",
        "argocd",
      ),
    /ServiceAccount/,
  );
});

test("OutOfSync and Progressing survive the mapping unchanged", async () => {
  // Argo's vocabulary is what the learner types into `argocd app get`, so the
  // mapper must not normalise, lowercase or prettify it.
  const app = await getApplication(
    reader(
      application({
        sync: { status: "OutOfSync", revision: SHA },
        health: { status: "Progressing", message: "waiting for rollout" },
      }),
    ),
    "practice-app",
    "argocd",
  );
  assert.equal(app.sync, "OutOfSync");
  assert.equal(app.health, "Progressing");
  assert.equal(app.message, "waiting for rollout");
});

test("the resource tree is flattened, and a resource with no status is Unknown", async () => {
  const app = await getApplication(
    reader(
      application({
        sync: { status: "Synced", revision: SHA },
        health: { status: "Healthy" },
        resources: [
          {
            kind: "Deployment",
            name: "practice-app-frontend",
            namespace: "practice-app",
            status: "Synced",
            health: { status: "Healthy" },
          },
          // A resource Argo has seen but not yet reconciled carries no status at
          // all. Dropping it makes the tree shorter than the app, which reads as
          // "that resource does not exist".
          { kind: "Service", name: "practice-app-frontend" },
        ],
      }),
    ),
    "practice-app",
    "argocd",
  );

  assert.equal(app.resources.length, 2);
  assert.deepEqual(app.resources[0], {
    kind: "Deployment",
    name: "practice-app-frontend",
    namespace: "practice-app",
    status: "Synced",
    health: "Healthy",
  });
  assert.equal(app.resources[1]?.status, "Unknown");
  assert.equal(app.resources[1]?.health, undefined);
});

test("a 40-character revision is shortened for display and kept in full", async () => {
  // The panel is narrow. A full sha pushes the health column off the right edge,
  // and the short form is the one that matches what `git log --oneline` printed.
  const app = await getApplication(
    reader(application({ sync: { status: "Synced", revision: SHA } })),
    "practice-app",
    "argocd",
  );
  assert.equal(app.revision, SHA);
  assert.equal(app.revisionShort, SHA.slice(0, 7));
});

test("a tag revision is left alone rather than chopped to seven characters", async () => {
  // Argo's revision is whatever `targetRevision` resolved to, and for a branch or
  // tag that is a name. Truncating "main" to "main" is harmless; truncating
  // "release-2026-08" to "release" is a lie about what is deployed.
  const app = await getApplication(
    reader(
      application({ sync: { status: "Synced", revision: "release-2026-08" } }),
    ),
    "practice-app",
    "argocd",
  );
  assert.equal(app.revisionShort, "release-2026-08");
});

test("an Application with a bare .status still answers", async () => {
  // Argo creates the object and fills .status a moment later. Between the two, every
  // field the widget reads is missing.
  const app = await getApplication(
    reader(application({})),
    "practice-app",
    "argocd",
  );
  assert.equal(app.present, true);
  assert.equal(app.sync, "Unknown");
  assert.equal(app.health, "Unknown");
  assert.equal(app.revision, "");
});

test("the Application is looked up by the name and namespace it was asked for", async () => {
  let seen: unknown;
  const spy: K8sReader = {
    readCustomObject: async (ref) => {
      seen = ref;
      return application({ sync: { status: "Synced" } });
    },
    readDeployment: async () => undefined,
    readEndpoints: async () => undefined,
  };

  await getApplication(spy, "practice-app", "argocd");
  assert.deepEqual(seen, {
    group: "argoproj.io",
    version: "v1alpha1",
    namespace: "argocd",
    plural: "applications",
    name: "practice-app",
  });
});
