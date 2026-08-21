# argocd/

Argo CD glue for the GitOps scenarios.

Nothing in here is applied automatically.
`make app-deploy` runs `scripts/gen-argocd-app.py`, which reads your `origin` git remote and writes `argocd/generated/practice-app.yaml` (git-ignored, so no personal repo URL is ever committed).
That Application points Argo CD at `helm/practice-app` on `main`, and **its sync policy follows its source**.

When cluster git is on, Argo reads `git://git-server.git.svc.cluster.local/repo.git` and sync is **automated**.
That is the drill loop: the learner edits an image tag in the browser, commits and pushes, and watches the rollout in the same browser.
There is no Sync button in the drill UI for anyone to press.

When cluster git is off, Argo reads GitHub and sync stays **manual**, exactly as it always did.
That is the path `scenarios/09-gitops-argocd.md` runs on, and pressing Sync, watching drift, and turning on auto-sync + self-heal are its exercises - task 5 in particular.
Emitting automated sync there would pre-solve the scenario and make `make check N=09` pass without the learner doing anything.

`selfHeal` is off on both paths.
It reverts drift on everything the Application manages, so it would stomp any scenario whose exercise is an imperative `kubectl` change.
It is turned on per-scenario, by the session, for the scenarios that ask for it.

Because this repo is private, Argo CD cannot pull it until you register credentials (a GitHub PAT or deploy key) in the Argo CD UI or CLI.
That registration is deliberately part of the scenario, and the credentials live only inside your cluster - never in this repo.
