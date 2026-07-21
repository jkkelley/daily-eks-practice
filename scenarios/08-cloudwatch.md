# 08 - CloudWatch: control-plane logs + Container Insights

**Time:** ~45 min. **Needs:** cluster up.
**Cost note:** CloudWatch ingestion is $0.50/GB - the audit log stream in particular is chatty. Turn things on, look around, turn them OFF the same day.

Ticket: "Security wants API audit visibility and the platform team wants node/pod metrics in CloudWatch, because that's where the org's alerting lives. Wire both up, then figure out what it would cost to leave on."

## Tasks

1. Turn on control-plane logging: set `enabled_cluster_log_types = ["api", "audit"]` in `scripts/config.toml`, `make apply`.
2. Find the new log group in CloudWatch. What is its retention? Change it to 1 day.
3. In Logs Insights, find your own `kubectl` actions in the audit log (filter by your user/role and a verb like `create`).
4. Add the `amazon-cloudwatch-observability` add-on to `managed_addons` in the config and apply.
   It will need node permissions - figure out what's missing from the node role and why the pods tell you so.
5. Once Container Insights is flowing, open the console's Container Insights view: find your cluster, drill node → pod → container.
6. Compare what you get here vs what Prometheus/Grafana gave you in scenario 07. When would you pay for this instead?
7. Clean up: remove the add-on and set `enabled_cluster_log_types = []`, apply, and confirm the log groups stop growing (delete them by hand).

## Success criteria (`make check N=08`)

- Cluster logging currently OFF again (cost hygiene) - the check verifies the config matches reality.
- You found at least one of your own audit events today.
- No `/aws/containerinsights/*` log group still ingesting.
