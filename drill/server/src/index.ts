/**
 * Entry point. Configuration comes from the environment, the server comes from
 * `server.ts`, and this file does nothing but join them and handle shutdown.
 *
 * Nothing imports this - the tests build a server directly - so it is safe for it
 * to listen at module scope.
 */
import { loadConfig } from "./config.ts";
import { createServer } from "./server.ts";

export const VERSION = "0.0.0";

const opts = loadConfig(process.env);
const app = await createServer(opts);

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
