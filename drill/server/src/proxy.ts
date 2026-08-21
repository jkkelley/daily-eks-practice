/**
 * Reverse proxy for the full Argo CD and Grafana UIs.
 *
 * The native widget answers "what is Argo doing right now", which is what a drill
 * needs 95% of the time. The other 5% is scenario 07, where the question is a
 * Grafana dashboard and no widget is going to substitute for the real thing. Rather
 * than send the user to a second hostname behind a second ALB rule, the drill
 * proxies both under its own origin.
 *
 * ---- BUILT NOW, EXERCISED WHEN SCENARIO 07 IS PORTED -----------------------
 *
 * Nothing in the shipped scenarios frames either upstream yet, and that is why this
 * file stops where it does. Serving an app under a subpath needs Grafana's
 * `root_url` plus `serve_from_sub_path`, and Argo CD's `server.rootpath`. Both are
 * Helm values already under our control, and both are version-sensitive enough to be
 * worth verifying against the charts that are actually installed rather than
 * remembered. Scenario 07 is what installs those charts. Do not do subpath surgery
 * now for a scenario that does not exist yet - the failure mode is a blank iframe
 * plus an afternoon, and it is the same afternoon whether it is spent now or then.
 */
import type { FastifyInstance } from "fastify";
import httpProxy from "@fastify/http-proxy";

export interface ProxyUpstreams {
  /** e.g. http://argocd-server.argocd.svc.cluster.local */
  argo?: string;
  /** e.g. http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local */
  grafana?: string;
}

/**
 * Both upstreams refuse to be framed by default, and both do it with headers rather
 * than with a status code - so without this the iframe renders as a blank rectangle,
 * the network tab shows a clean 200, and the only clue is a console message in the
 * frame you cannot open. Strip the legacy header, and remove `frame-ancestors` from
 * CSP while leaving the rest of the policy alone.
 */
function unframe(headers: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(headers)) {
    const name = key.toLowerCase();
    if (name === "x-frame-options") continue;
    if (
      (name === "content-security-policy" ||
        name === "content-security-policy-report-only") &&
      typeof value === "string"
    ) {
      const kept = value
        .split(";")
        .filter((d) => !d.trim().toLowerCase().startsWith("frame-ancestors"))
        .join(";")
        .trim();
      if (kept) out[key] = kept;
      continue;
    }
    out[key] = value;
  }
  return out;
}

/**
 * Mount whichever upstreams are configured, and only those.
 *
 * An unconfigured proxy that answers with a connection error is worse than a route
 * that is not there: it reads as a broken integration rather than an absent one.
 */
export async function registerProxy(
  app: FastifyInstance,
  upstreams: ProxyUpstreams,
): Promise<void> {
  const mounts: Array<[string, string]> = [];
  if (upstreams.argo) mounts.push(["/argo", upstreams.argo]);
  if (upstreams.grafana) mounts.push(["/grafana", upstreams.grafana]);

  for (const [prefix, upstream] of mounts) {
    await app.register(httpProxy, {
      upstream,
      prefix,
      // Both UIs upgrade to a websocket - Argo for the app tree, Grafana for live
      // panels - and a proxy that only forwards HTTP shows a UI that loads and then
      // never updates, which is the hardest kind of broken to notice.
      websocket: true,
      replyOptions: {
        rewriteHeaders: (headers) =>
          unframe(headers as Record<string, unknown>) as typeof headers,
      },
    });
  }
}
