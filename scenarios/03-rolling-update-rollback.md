# 03 - Rolling update + rollback

**Time:** ~30 min. **Needs:** cluster up, app deployed.

Ticket: "Bump the frontend nginx to the next minor. Ship it with zero downtime, then practise the oh-no path: roll it back."

## Tasks

1. Using `kubectl`, find the frontend Deployment's current image tag and its rollout history (namespace `practice-app`, deployment `practice-app-frontend`).
2. Bump the frontend image tag in `helm/practice-app/values.yaml` (e.g. `1.27-alpine` → `1.28-alpine`) and deploy.
3. Watch the rolling update live: old pods draining, new pods becoming ready.
   What is the default surge/unavailable behaviour of a Deployment?
4. Curl the app in a loop during the rollout - did any request fail?
5. Roll back to the previous version two ways: `kubectl rollout undo`, and the GitOps way (revert the commit / values change).
   When would the first way bite you in a GitOps shop?
6. Bonus: set a bad tag (`1.99-alpine`), deploy, and watch what a stuck rollout looks like. Fix it.

## Success criteria (`make check N=03`)

- Frontend Deployment is fully rolled out (no unavailable replicas).
- Rollout history shows ≥2 revisions.
- The running image tag matches what `values.yaml` says (GitOps truth restored).
