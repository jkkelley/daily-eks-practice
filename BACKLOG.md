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
- Easter eggs for people who actually read the code: undocumented commands, hidden flags, and alternate paths that only turn up if you go looking.
  The first one is an off-menu way to tear the whole drill down from the terminal, mirroring the GUI's exit-and-teardown button.
- Explorer context menu, the way Cursor and VS Code have one: right-click a file for Copy Path, Copy Relative Path, Reveal, Rename, Delete, and Open in Integrated Terminal.
  The path copy is the one that earns its keep - you grab a path out of the tree so you can `cd` there and run something against it, and today a right-click in the explorer gets you the *browser's* menu instead of ours, which is worse than having no menu at all.
  "Open in Integrated Terminal" is the interesting one here, because our terminal is a real tmux shell in the pod: it would `cd` the running session rather than spawning anything.
  Wants `preventDefault` on `contextmenu`, a small positioned menu component, and `navigator.clipboard.writeText` - which needs a secure context, so it works on the ALB over HTTPS and needs a `document.execCommand` fallback on plain http during local preview.
- Reload an open editor buffer when the file changes underneath it.
  The terminal is a real shell in the same working tree, so `git checkout`, `git revert` or a stray `>` redirect all change files the editor already has open, and Monaco keeps showing the stale copy until you close and reopen the tab.
  VS Code watches and reloads (or marks the buffer conflicted when it is dirty), and the same is wanted here - scenario 03 task 5 is `git revert && git push`, which is exactly a case where the file changes from the terminal while the editor has it open.
