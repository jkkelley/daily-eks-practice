# 07 - Observability: Prometheus + Grafana

**Time:** ~60 min. **Needs:** cluster up with `enable_monitoring = true`, app deployed.

Ticket: "We got paged last night and had no graphs. Stand up dashboards for the practice app and know your way around PromQL before the next incident."

## Tasks

1. Port-forward Grafana (`make grafana-ui`) and log in (password: `make output` → `grafana_admin_password`).
2. Tour the built-in dashboards: find node CPU/memory, pod restarts, and API server latency.
3. Port-forward Prometheus itself and run raw PromQL:
   - CPU per pod in `practice-app`: `rate(container_cpu_usage_seconds_total{namespace="practice-app"}[5m])`
   - restarts: `kube_pod_container_status_restarts_total{namespace="practice-app"}`
   - frontend replicas vs desired: `kube_deployment_status_replicas_available{deployment=~".*frontend"}`
4. Why do those `kube_*` metrics exist at all? Find the component that exports them.
5. Build a small Grafana dashboard for the app: replicas, CPU, memory, network in/out. Save it.
6. Generate load (reuse scenario 02's loop) and watch it land on your dashboard.
7. Bonus: create an alert rule that fires when frontend available replicas < 2, and trip it.

## Success criteria (`make check N=07`)

- Prometheus and Grafana pods are ready in `monitoring`.
- Prometheus is successfully scraping targets in `practice-app`'s namespace (or at least kube-state-metrics knows about its pods).
- You wrote at least three PromQL queries from memory today.
