/** Everything the server needs, from the environment, with no hidden defaults for paths. */
export interface ServerOptions {
  port: number;
  host: string;
  webRoot: string;
  answersDir: string;
  workspaceDir: string;
  scenario: string;
}

/**
 * 8090 on purpose: `make argo-ui` holds 8080 and `make grafana-ui` holds 3000, and
 * colliding with either during local development is a confusing five minutes.
 */
export const DEFAULT_PORT = 8090;

export function loadConfig(env: NodeJS.ProcessEnv): ServerOptions {
  const required = (key: string): string => {
    const value = env[key];
    if (!value)
      throw new Error(
        `${key} is not set - the drill server needs an explicit path, not a guess`,
      );
    return value;
  };

  // Number("nonsense") is NaN, and Fastify listens on a random free port when it
  // gets one. The pod would come up healthy, the Service would find nothing behind
  // it, and the symptom would be a hanging browser with nothing in the logs.
  const port =
    env.DRILL_PORT === undefined ? DEFAULT_PORT : Number(env.DRILL_PORT);
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new Error(
      `DRILL_PORT is ${JSON.stringify(env.DRILL_PORT)}, which is not a port number`,
    );
  }

  return {
    port,
    host: env.DRILL_HOST ?? "0.0.0.0",
    webRoot: required("DRILL_WEB_ROOT"),
    answersDir: required("DRILL_ANSWERS_DIR"),
    workspaceDir: required("DRILL_WORKSPACE"),
    scenario: required("DRILL_SCENARIO"),
  };
}
