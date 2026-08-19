# Backlog

Ideas and improvements that popped up but aren't blocking.
Pull one when you want to extend the playground.

- Scenario idea: EKS version upgrade drill (exists as its own dedicated repo - link it here instead of duplicating).
- Scenario idea: NetworkPolicy day - lock practice-app down namespace-to-namespace.
- Scenario idea: Karpenter instead of the managed node group / cluster autoscaler.
- Consider `manage_master_user_password` (Secrets Manager) for RDS to practise the managed-rotation path.
- Grafana dashboard-as-code (provisioned dashboard for the practice app) instead of click-ops in scenario 07.
- Optional VPC endpoints toggle exercise: kill the NAT gateway and make the cluster still work.
- An Argo CD app-of-apps layout once there is more than one chart.
- Per-scenario answer capture: a lightweight way to log the commands/output you actually used for each task while drilling live (separate from the sealed `PRACTICE_ANSWERS.html`), so you have your own history to review later.
- Interactive per-scenario "testing pod": `make scenario N=NN` execs you into (or spins up) a scenario-scoped pod in-cluster you can work from, potentially with progressive hints and a place to record your answers as you go, instead of just printing the card to your terminal.
