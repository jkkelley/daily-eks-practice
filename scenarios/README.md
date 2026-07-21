# scenarios/

One card per drill, written like the tickets an engineer actually picks up.
Print one with `make scenario N=04`, do the work, grade yourself with `make check N=04`.
Answers live in the sealed key (`make serve-answers`) - try before peeking.

| #   | Drill                     | Practises                                                   |
| --- | ------------------------- | ----------------------------------------------------------- |
| 01  | Lay of the land           | kubectl + console fluency, nodes, namespaces                |
| 02  | Scale the app             | replicas, drift vs GitOps, metrics-server, HPA              |
| 03  | Rolling update + rollback | image bumps, rollout mechanics, revert strategies           |
| 04  | Load balancing            | ALB controller, NLB Service, ALB Ingress, target groups     |
| 05  | DNS                       | CoreDNS, resolv.conf, search domains, external-dns/Route53  |
| 06  | Storage                   | EBS CSI, StorageClasses, PVC expansion, S3 via IRSA         |
| 07  | Observability             | Prometheus, PromQL, Grafana dashboards                      |
| 08  | CloudWatch                | control-plane logs, Logs Insights, Container Insights, cost |
| 09  | GitOps                    | Argo CD, private repos, drift, auto-sync + self-heal        |
| 10  | Break/fix                 | crashloops, probes, OOM, Pending, selectors                 |
| 11  | RDS day-2                 | network path, security groups, password rotation, drift     |
| 12  | CI terraform              | GitHub Actions, OIDC, gated applies                         |

Rotation that works: 01 → 02 → 03 the first week, then one card a day in any order.
Most cards are 30-60 minutes - spin up (`make up`, ~15 min), drill, `make down`.
Costs while up: roughly $0.15-0.25/hour with the default config; the cost notes on each card flag anything extra.
