/** Everything the server needs, from the environment, with no hidden defaults for paths. */
export interface ServerOptions {
  port: number;
  host: string;
  webRoot: string;
  answersDir: string;
  workspaceDir: string;
  /**
   * Where the PTY log is teed, and deliberately NOT derived from workspaceDir.
   *
   * It has to be on the same PVC as the workspace, or a pod restart replays
   * nothing, and it has to be OUTSIDE the workspace, or it shows up in the
   * learner's `git status` in a drill whose whole subject is committing. Both
   * constraints are about where the volume is mounted, which is a deployment fact
   * this process cannot see, so it is asked for rather than guessed.
   */
  logDir: string;
  /**
   * Passed to `tmux -f`. Optional, and absent means tmux's own defaults, which
   * work - they are just loud. Not required the way the paths above are, because
   * a missing theme is a cosmetic problem and a missing workspace is not.
   */
  tmuxConf?: string;
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
    logDir: required("DRILL_LOG_DIR"),
    ...(env.DRILL_TMUX_CONF ? { tmuxConf: env.DRILL_TMUX_CONF } : {}),
    scenario: required("DRILL_SCENARIO"),
  };
}
