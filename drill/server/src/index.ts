/**
 * Entry point. Configuration comes from the environment, the server comes from
 * `server.ts`, and this file does nothing but join them and handle shutdown.
 *
 * Nothing imports this - the tests build a server directly - so it is safe for it
 * to listen at module scope.
 */
import { loadConfig } from "./config.ts";
import { createServer } from "./server.ts";
import { createReader } from "./integrations/k8s.ts";

export const VERSION = "0.0.0";

const opts = loadConfig(process.env);

// `undefined` outside a cluster, which is the ordinary case for `drill-dev`. The
// Argo and dependency panels say so rather than the server refusing to start.
// Spread conditionally rather than passed as `reader: undefined`, because
// `exactOptionalPropertyTypes` draws the same distinction the code does: an absent
// reader and a reader that is explicitly nothing are not the same statement.
const reader = createReader(process.env);
const app = await createServer({ ...opts, ...(reader ? { reader } : {}) });

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
