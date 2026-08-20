---
{
  "id": "WO-20260819-ca7c",
  "slug": "phase-5-the-mothership-gui-its-container-image-a",
  "title": "Phase 5: the mothership GUI, its container image, and the first visual",
  "type": "feature",
  "status": "ready",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:32:20-05:00",
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
    "WO-20260819-844f",
    "WO-20260819-a56c"
  ],
  "blocks": [
    "WO-20260819-7840",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-ca7c - Phase 5: the mothership GUI, its container image, and the first visual

## Problem

The drill has no surface. Grading exists but there is nowhere to type, nowhere to edit, and nothing to look at. This ticket builds the single long-lived in-cluster pod that serves a terminal, a Monaco editor, an answers panel and a help panel - the only surface the user ever works from. Because the terminal lives in the GUI, the grader observes what the user actually runs and there is no submission form. The quality bar is explicit: this should feel like a tool someone chose, not a form someone was given. Implements Phase 5, Tasks 5.1 through 5.5 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- the Fastify server, static hosting and the websocket
- the PTY, tmux, and scrollback that survives a server restart
- the React shell - xterm.js, Monaco, the answers panel and the help panel
- the Argo CD widget and the reverse proxy, designed and stubbed here, genuinely exercised only when scenario 07 is ported
- the container image and the in-cluster deployment, including the cluster-admin service account and the Ingress that joins the shared group
- a deny-by-default .containerignore: '*' first, then explicit allows for drill/ and scenarios/answers/

**Out - non-goals**

- session lifecycle, the sync watcher and the Makefile handover - those are the Phase 6 ticket
- any real AWS call
- a private GHCR package or an imagePullSecret - the package is public, because the repo is public and the answer key is already committed to it, so the image holds nothing new
- buildx or multi-arch - single-arch amd64
- creating a personal access token; the missing scope is added with gh auth refresh -h github.com -s write:packages, which is interactive and must be printed for the user to run

## Acceptance criteria


- [ ] `AC-H1` *(human)* the UI is served from a Vite dev server in Podman on a probed port in 30000+ and shown to the user at Task 5.3, and the ticket stops there until they have looked at it
- [ ] `AC-H2` *(human)* Tasks 5.4 and 5.5 are expanded from interface level into full step-by-step tasks only after that review, because they depend on what the user says when they see it
- [ ] `AC-H3` *(human)* the built image is inspected and contains no scripts/config.toml and no .kubeconfig file, proving the deny-by-default .containerignore holds after the build context widened to the repo root
- [ ] `AC-H4` *(human)* the pod comes up on kind and serves the terminal, the editor and both panels
- [ ] `AC-H5` *(human)* no imagePullSecret exists anywhere in the deployment, because the GHCR package is public

## Test plan

```sh
make -f Makefile.test drill-test drill-build for the workspace; the Vite preview in Podman on a probed port for the visual review; then deploy the built image to the kind sandbox and drive the terminal, the editor and both panels by hand. The image-contents assertion runs against the built image, not against the build context.
```

## Assumptions

1. The user has run gh auth refresh -h github.com -s write:packages before Task 5.5. It is interactive and blocks on a browser one-time code, so it cannot be run by an agent - print it and wait.

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
