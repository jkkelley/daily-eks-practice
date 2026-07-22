# 09 - GitOps with Argo CD

**Time:** ~60 min. **Needs:** cluster up with `enable_argocd = true`, repo pushed to GitHub.

Ticket: "We're moving deploys to GitOps. Nobody runs helm by hand anymore - git is the source of truth, Argo CD is the deployer. Get the practice app under management and prove drift gets caught."

## Tasks

1. Open the Argo CD UI (`make argo-ui`, password printed for you). Change the admin password; delete the initial-admin secret like the login screen tells you to.
2. This repo is private, so Argo CD can't read it yet.
   Register the repo in Argo CD with a GitHub fine-grained PAT (contents: read-only) - UI or `argocd` CLI, your choice.
   Where do those credentials actually live now? Find the k8s object.
   (Daily shortcut once you've done it by hand: `make argo-repo` builds that same Secret from your `gh` CLI token - read `scripts/argo-repo.py` and confirm it creates exactly what you just made manually.)
3. `make app-deploy` - it generates the Application manifest from your git remote and applies it. Find the app in the UI: it's OutOfSync. Read the diff view until it makes sense, then Sync.
4. Drift drill: `kubectl scale deploy practice-app-frontend -n practice-app --replicas=1`.
   Watch Argo CD notice. Sync to heal it.
5. Turn on automated sync + self-heal (edit the Application - UI or the generator's output).
   Repeat the drift drill and watch it heal itself without you.
6. GitOps flow end to end: change the frontend replica count in `values.yaml`, commit, push, and watch the change land with zero kubectl.
7. Bonus: break the chart on purpose (bad YAML in a template), push, and see what Argo CD does with a failed sync. Revert.

## Success criteria (`make check N=09`)

- Argo CD is running and the `practice-app` Application exists.
- The Application reports Synced + Healthy.
- Automated sync with self-heal is enabled on it.
