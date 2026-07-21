# 02 - Scale the app

**Time:** ~30 min. **Needs:** cluster up, app deployed.

Ticket: "We need more frontend capacity for a promo tomorrow morning. Bump the frontend to 4 replicas. While you're in there, set up autoscaling so we stop doing this by hand."

## Tasks

1. Scale the frontend Deployment to 4 replicas imperatively (`kubectl`), watch the pods spread.
2. Now do it the _right_ way: change `helm/practice-app/values.yaml`, commit, and let Argo CD (or helm) roll it out.
   Notice what Argo CD thinks about your step-1 imperative change.
3. Verify metrics-server works: get live CPU/memory for the frontend pods.
4. Enable the HPA in the chart values (min 2, max 5, 50% CPU target) and deploy it.
5. Generate load against the frontend service and watch the HPA scale up, then back down.
6. Bonus: what happens if you set replicas in values.yaml AND the HPA is on? Who wins?

## Success criteria (`make check N=02`)

- Frontend HPA exists with min 2 / max 5.
- Frontend Deployment currently has ≥2 ready replicas.
- You watched at least one scale event happen (`kubectl get events` shows it).
