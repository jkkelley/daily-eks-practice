---
{
  "id": "WO-20260819-98da",
  "slug": "phase-3-terraform-the-in-cluster-git-server-argo",
  "title": "Phase 3: Terraform - the in-cluster git server Argo CD reads",
  "type": "feature",
  "status": "in-progress",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-20",
  "created_at": "2026-08-19T19:31:41-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-3-terraform-the-in-cluster-git-server-argo",
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


- [x] `AC-H1` *(human)* on kind, Argo CD clones and syncs from http://git-server.git.svc.cluster.local/repo.git, and the Application reports sync status OutOfSync with empty .status.conditions rather than Unknown
  - observed `2026-08-20` Observed on kind via 'make -f Makefile.test cluster-git-test', final run exit 0, 13 passed / 0 failed. Argo Application cluster-git-acceptance reported sync status OutOfSync with .status.conditions empty, and rendered all five practice-app resources (ConfigMap, 2x Service, 2x Deployment). The repoURL is git://git-server.git.svc.cluster.local/repo.git rather than the http:// the criterion names, because the http:// form was measured to fail - see AC-H3.
- [x] `AC-H2` *(human)* kubectl get endpoints in namespace git shows no endpoints until .seeded exists, and endpoints appear only after seeding
  - observed `2026-08-20` Observed in the same run. Before seeding: pod PHASE=Running READY=false and 'kubectl get endpoints -n git git-server' returned no addresses. After scripts/git-seed.py wrote the .seeded marker, the same command returned 10.244.0.6:9418. The gate is an exec readinessProbe on 'test -f /repos/repo.git/.seeded', so no endpoint can exist before the bundle lands.
- [x] `AC-H3` *(human)* if the acceptance test lands below rung 2 of the fallback ladder it is reported to the user before the Argo Application is repointed, because rungs 3 to 5 change cluster_git_url
  - observed `2026-08-20` The ladder was entered and landed on rung 3, below rung 2, and was reported to the user BEFORE Task 3.3 repointed anything. Rung 1 measured: 'failed to list refs: unexpected EOF' from Argo, and 'fatal: dumb http transport does not support shallow capabilities' from git clone --depth 1. Rung 2 measured blocked: no public image carries both a CGI host and git-http-backend (alpine/git neither, bitnami/git backend only, httpd:2.4-alpine apache only). User was shown all three options with the evidence and chose to proceed on rung 3, with Gitea as the fallback if it fought back. cluster_git_url changed to git:// accordingly.
- [x] `AC-H4` *(human)* terraform fmt -check and validate pass, and a ministack plan was attempted and its result reported
  - observed `2026-08-20` 'make -f Makefile.test fmt-check validate' passes (both envs/dev and bootstrap-oidc report 'Success! The configuration is valid'). 'make -f Makefile.test ministack' was attempted and SUCCEEDED: 'Plan: 58 to add, 0 to change, 0 to destroy', with all four kubectl_manifest.git_* resources planned to create and outputs rendering cluster_git_url=git://git-server.git.svc.cluster.local/repo.git, cluster_git_namespace=git, cluster_git_deployment=git-server, cluster_git_container=git, cluster_git_repo_path=/repos/repo.git. Full static suite 'make -f Makefile.test test' exits 0.
- [x] `AC-H5` *(human)* no new variable anywhere in the change carries a default, and every value is present in scripts/config.example.toml
  - observed `2026-08-20` 'grep -rn "default[[:space:]]*=" terraform/modules/*/variables.tf terraform/envs/dev/variables.tf' returns no output (exit 1). All three new values are documented in scripts/config.example.toml: enable_cluster_git in the platform toggles block, drill_ingress_group_name and drill_allowed_cidrs in a new drill platform block with the security warning about the unauthenticated terminal. The user's own git-ignored scripts/config.toml still lacks them and was NOT edited - it is recorded as a blocker in CONTEXT_STATE.md with the three lines to add.

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

- `2026-08-20` PR #19 opened: https://github.com/jkkelley/daily-eks-practice/pull/19. CONTEXT_STATE.md ships inside it per the close-out flow. All five acceptance criteria evidenced. Verification: static suite exit 0, ministack 'Plan: 58 to add', cluster-git-test 13 passed / 0 failed from a fresh kind cluster, drill 58 pass / 0 fail, typecheck clean. No real AWS touched. Outstanding for the user: scripts/config.toml needs enable_cluster_git, drill_ingress_group_name and drill_allowed_cidrs adding to [common] before any real make plan.
- `2026-08-20` Task 3.2 Step 7 verdict: RUNG 1 FAILS, RUNG 2 IS BLOCKED, RUNG 3 PROVEN on kind. Rung 1 (dumb HTTP, static nginx) is dead, failing exactly as the plan predicted. Argo: 'failed to list refs: unexpected EOF'. nginx serves the static info/refs as Content-Type application/octet-stream, which go-git cannot parse as a smart-HTTP pkt-line advertisement. The real git binary CAN clone it, but 'git clone --depth 1' returns 'fatal: dumb http transport does not support shallow capabilities' - the plan's predicted string verbatim - and --depth 1 is what Argo uses. Rung 2 (git http-backend CGI) is not reachable without building a custom image. Verified by inspection: alpine/git has no git-http-backend, no git-daemon, no httpd, not even the busybox httpd applet; bitnami/git has git-http-backend and git-daemon but no CGI host; httpd:2.4-alpine has apache but no git. No public image carries both. Building one needs GHCR publishing infrastructure that does not exist until Phase 5, and write:packages is not granted yet. Rung 3 (git daemon, git:// scheme) is PROVEN end to end on kind with image bitnami/git: endpoints empty before .seeded and populated after; bundle 443833 bytes sent and 443833 landed; git ls-remote OK; git clone --depth 1 OK; git push OK with --enable=receive-pack (scenario 03's model answer is 'git revert && git push', so push is required); Argo Application reports sync status OutOfSync with EMPTY .status.conditions and rendered all 5 practice-app resources. Two traps found while proving it. (1) bitnami/git ships /srv as a SYMLINK to /var/srv, so mounting the PVC at /srv puts it somewhere other than the path says - mount at /repos instead. (2) git refuses to serve a repo whose owner uid differs from the running uid ('detected dubious ownership'); with runAsUser/fsGroup 1001 on both init and main container the repo is created 1001:1001 and it is a non-issue, but a root-created repo served by a non-root daemon fails read AND write. This changes cluster_git_url from http://git-server.git.svc.cluster.local/repo.git to git://git-server.git.svc.cluster.local/repo.git, which is why AC-H3 gates Task 3.3 on reporting it. Reported to the user, awaiting the rung decision.
- `2026-08-20` Task 3.1 done. Three variables threaded config.example.toml -> envs/dev -> modules/stack -> modules/platform, no defaults (grep for 'default =' across the variables.tf files is empty). fmt-check + validate pass. Plan defect found and fixed: Step 11 says to call resolve_auto_cidrs() immediately after merged is validated, which is BEFORE the --print early return. Observed: 'bootstrap.py dev --print aws_profile' logged 'drill_allowed_cidrs auto resolved to your current public /32' - an unrelated key lookup doing an HTTPS round trip. Makefile:32-33 runs two --print calls via $(shell ...) on every single target, so every make command would pay two lookups and stall 10s each offline. Fixed with needs_auto_cidrs(rest), 5 new tests. Also added Makefile.test 'script-tests' because nothing was running tests/test_*.py outside answers-check.

## Outcome

_Written by `work-order close`. Empty until then._
