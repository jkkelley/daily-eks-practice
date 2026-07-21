# 10 - Break/fix drills

**Time:** ~60 min. **Needs:** cluster up, app deployed. Best run after 01-03.

No ticket today - today YOU are the incident.
Each drill: break it, observe exactly how it presents (status, events, logs), fix it, write one line in your notes about how you'd recognise it next time.
`kubectl get events --sort-by=.lastTimestamp -n practice-app` is your friend throughout.

## Drills

1. **CrashLoopBackOff** - point the backend's `PGRST_DB_URI` at a wrong secret key or bogus host (edit the deployment live). Diagnose from `describe` + logs, then fix.
2. **Stuck rollout / bad probe** - set the frontend readinessProbe path to `/nope` and roll. Why does the app stay up? What is the rollout waiting for? Fix it.
3. **ImagePullBackOff** - set a nonexistent image tag. Find the exact error message source (which component reported it?). Fix.
4. **OOMKilled** - drop the backend memory limit to `16Mi`. Watch the restarts, read the `lastState` in `describe`. Fix.
5. **Pending forever** - request `cpu: "8"` for one pod. Read the scheduler's event message word by word - it tells you the exact reason. Fix.
6. **Node pressure** - cordon a node and delete the pods on it. Where do they go? Uncordon. Now drain it properly and note the difference.
7. **Service selector typo** - edit the frontend Service selector to a wrong label. The pods are Ready but the app is down - prove the break with `kubectl get endpoints`. Fix.
8. If Argo CD auto-heal is on from scenario 09: which of the above did it silently fix behind your back? Check its history.

## Success criteria (`make check N=10`)

- Everything healthy again: all deployments in `practice-app` fully available, zero pods in a bad state.
- Recent restart counts are stable (no ongoing crash loops).
- Your notes file has 7 one-liners you'll actually remember.
