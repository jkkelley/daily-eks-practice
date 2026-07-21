# argocd/

Argo CD glue for the GitOps scenarios.

Nothing in here is applied automatically.
`make app-deploy` runs `scripts/gen-argocd-app.py`, which reads your `origin` git remote and writes `argocd/generated/practice-app.yaml` (git-ignored, so no personal repo URL is ever committed).
That Application points Argo CD at `helm/practice-app` on `main` with **manual** sync - pressing Sync, watching drift, and turning on auto-sync + self-heal are the exercises in `scenarios/09-gitops-argocd.md`.

Because this repo is private, Argo CD cannot pull it until you register credentials (a GitHub PAT or deploy key) in the Argo CD UI or CLI.
That registration is deliberately part of the scenario, and the credentials live only inside your cluster - never in this repo.
