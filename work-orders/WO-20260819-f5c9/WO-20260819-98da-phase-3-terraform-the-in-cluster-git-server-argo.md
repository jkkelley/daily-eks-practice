---
{
  "id": "WO-20260819-98da",
  "slug": "phase-3-terraform-the-in-cluster-git-server-argo",
  "title": "Phase 3: Terraform - the in-cluster git server Argo CD reads",
  "type": "feature",
  "status": "ready",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:31:41-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": null,
  "pr": null,
  "merge_sha": null,
  "closed": null,
  "approval": {
    "via": "lavish",
    "at": "2026-08-19"
  },
  "evidence": null,
  "surfaces": [],
  "depends_on": [
    "WO-20260819-844f"
  ],
  "blocks": [
    "WO-20260819-1fea",
    "WO-20260819-7840",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-98da - Phase 3: Terraform - the in-cluster git server Argo CD reads

## Problem

Argo CD reads GitHub today, which needs a credential in the cluster and egress to github.com from a private subnet. The drill must never contact github.com: everything Argo reads should come from the local repo by way of the cluster. This ticket stands up a permanent in-cluster git server as the only source Argo CD ever reads, seeded by streaming a git bundle in from the laptop. Self-contained is not simulated - the server runs genuine git and Argo does a genuine clone and sync; only the location of the remote changes. Implements Phase 3, Tasks 3.1 through 3.3, and the '## The self-contained git rule' section of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- three new config values threaded scripts/config.example.toml -> envs/dev -> modules/stack -> the target module, every one declared with no default
- the git server in namespace git: bare repo, an init container that runs git init --bare and nothing else
- the .seeded readiness gate, so the Service has zero endpoints until the bundle has landed and Argo retries cleanly instead of syncing a half-served repo
- make git-seed, streaming git bundle create - --all into the pod over kubectl exec
- scripts/gen-argocd-app.py generating from cluster_git_url rather than from the user's git remote
- the Argo CD Application repointed at http://git-server.git.svc.cluster.local/repo.git
- the kind acceptance test that proves Argo can actually clone it, and the ranked five-rung fallback ladder if it cannot

**Out - non-goals**

- deleting or changing scripts/argo-repo.py - it is kept because scenarios/09-gitops-argocd.md teaches manual PAT-and-UI repo registration and that lesson ships today; the drill simply never calls it
- any Terraform variable with a default value
- any real AWS call
- putting a GitHub credential in the cluster, on any path the drill takes
- rung 5 of the fallback ladder as a silent landing spot - dropping Argo entirely stops teaching GitOps and is a decision for the user, not the implementer

## Acceptance criteria


- [ ] `AC-H1` *(human)* on kind, Argo CD clones and syncs from http://git-server.git.svc.cluster.local/repo.git, and the Application reports sync status OutOfSync with empty .status.conditions rather than Unknown
- [ ] `AC-H2` *(human)* kubectl get endpoints in namespace git shows no endpoints until .seeded exists, and endpoints appear only after seeding
- [ ] `AC-H3` *(human)* if the acceptance test lands below rung 2 of the fallback ladder it is reported to the user before the Argo Application is repointed, because rungs 3 to 5 change cluster_git_url
- [ ] `AC-H4` *(human)* terraform fmt -check and validate pass, and a ministack plan was attempted and its result reported
- [ ] `AC-H5` *(human)* no new variable anywhere in the change carries a default, and every value is present in scripts/config.example.toml

## Test plan

```sh
make -f Makefile.test test for fmt and validate, make -f Makefile.test ministack for the plan, then the kind acceptance test: bring up the sandbox, install Argo CD, apply the git server, seed it with a bundle, and assert the Application's sync status and conditions. All $0.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
