/**
 * Entry point. Configuration comes from the environment, the server comes from
 * `server.ts`, and this file does nothing but join them and handle shutdown.
 *
 * Nothing imports this - the tests build a server directly - so it is safe for it
 * to listen at module scope.
 */
import { loadConfig } from "./config.ts";
import { createServer } from "./server.ts";
import { createReader, createWriter } from "./integrations/k8s.ts";
import { gitCommittedReader } from "./committed.ts";

export const VERSION = "0.0.0";

const opts = loadConfig(process.env);

// `undefined` outside a cluster, which is the ordinary case for `drill-dev`. The
// Argo and dependency panels say so rather than the server refusing to start.
// Spread conditionally rather than passed as `reader: undefined`, because
// `exactOptionalPropertyTypes` draws the same distinction the code does: an absent
// reader and a reader that is explicitly nothing are not the same statement.
const reader = createReader(process.env);

// The other half, and a deliberately different type: this one may write the
// `drill-state` ConfigMap and nothing else in the cluster. Absent outside a
// cluster, which means the session simply is not mirrored anywhere - the drill
// still runs, it is just not being saved, which is the correct behaviour on a
// laptop with no laptop-side watcher either.
const writer = createWriter(process.env);

// The GitOps half of the grader. Always wired: it answers `undefined` - "not known,
// so not graded" - whenever the workspace has no reachable remote, which is exactly
// the preview case. Leaving it out on a laptop and in on a pod would mean the drill
// grades differently in the two places it runs.
const readCommitted = gitCommittedReader({ workspaceDir: opts.workspaceDir });

const app = await createServer({
  ...opts,
  ...(reader ? { reader } : {}),
  ...(writer ? { writer } : {}),
  readCommitted,
});

// A pod gets SIGTERM and then 30 seconds. Closing Fastify first lets an in-flight
// submission finish instead of the browser seeing a dropped socket and the drill
// losing the verdict it was waiting on.
for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.once(signal, () => {
    void app.close().then(() => process.exit(0));
  });
}

await app.listen({ port: opts.port, host: opts.host });
console.log(`drill server listening on ${opts.host}:${opts.port}`);
