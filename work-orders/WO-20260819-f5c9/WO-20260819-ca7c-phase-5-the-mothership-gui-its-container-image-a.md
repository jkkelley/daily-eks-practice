---
{
  "id": "WO-20260819-ca7c",
  "slug": "phase-5-the-mothership-gui-its-container-image-a",
  "title": "Phase 5: the mothership GUI, its container image, and the first visual",
  "type": "feature",
  "status": "in-progress",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-21",
  "created_at": "2026-08-19T19:32:20-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-5-the-mothership-gui-its-container-image-a",
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


- [x] `AC-H1` *(human)* the UI is served from a Vite dev server in Podman on a probed port in 30000+ and shown to the user at Task 5.3, and the ticket stops there until they have looked at it
  - observed `2026-08-21` Served from Vite in Podman on a probed port (make -f Makefile.test drill-dev, port 57290 this run) and driven in a real headless Chrome over CDP. Screenshots captured of the tasks view, the card view and a graded run. Typing 'git log --oneline' in the browser terminal reached the shell and printed '625fb78 (HEAD -> master) preview workspace'. Submitting 'kubectl -n practice-app rollout undo deploy/practice-app-frontend' on task 5 returned a PASS carrying the only-imperative hint, and the status row moved to 1/6 PASSED. NOT YET SEEN BY THE USER - the ticket is held here, which is the second half of this criterion.
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

- `2026-08-21` AC-H1 IS NOW FULLY SATISFIED. The evidence recorded earlier covered the serve-and-show half only and said the user had not looked yet. They have now reviewed the GUI and approved it - 'I love it and approve' - and asked for the IDE upgrade and the source control view, both of which shipped. AC-H2 is therefore unblocked: Tasks 5.4 and 5.5 may now be expanded from interface level. Re-evidencing AC-H1 is refused by design, so this note is the record.
- `2026-08-21` Framing correction from the user, recorded because the code comments had the weaker half of it. Filtering the workspace is about SIMULATION FIDELITY, not secrecy. They are explicit that a learner can go and read the repo whenever they like and that this is fine. The value is that the environment looks like an environment: a real working tree holds the application you are deploying, not the curriculum that set the task, not the grader marking it, not the tickets that built the trainer. Seeding all of that makes it obvious you are sitting inside somebody's project repo. scripts/git-seed.py and CONTEXT_STATE now say this.
- `2026-08-21` Two items parked in BACKLOG.md rather than built: an explorer context menu (right-click for Copy Path / Copy Relative Path / Open in Integrated Terminal - the user's own workflow is grabbing a path to cd to, and today a right-click gets the browser's menu instead of ours), and reloading an open editor buffer when the file changes underneath it, which the terminal does routinely via git checkout and git revert.
- `2026-08-21` DEFECT FOUND IN PHASE 3, fixed here because Phase 5 is what surfaced it and Task 5.5 would have inherited it. scripts/git-seed.py seeded cluster git with 'git bundle create --all', i.e. the WHOLE repo. The workspace is a clone of cluster git and the terminal is a real shell in it, so the learner's ls and cat reached scenarios/answers/*.toml - the answer key - plus docs/ (the plan), drill/ (the grader source) and work-orders/. DRILL_PATHS = ['helm'] now, built with git archive HEAD so prefixes survive and Argo's path: helm/practice-app still resolves. Two tests in tests/test_git_seed.py assert the answer key is absent and that Argo's path still exists. drill/dev.sh mirrors it. Explicitly NOT a security boundary: the repo is public and PRACTICE_ANSWERS.html is committed to it. The goal is not tripping over the answers mid-drill.
- `2026-08-21` Source control view added to the rail, per the user's go-ahead: GET /api/git/status, a branch header, changes grouped staged/unstaged, a count badge on the rail icon, and the saved-is-not-deployed nudge. It reports and does not act - no stage, unstage or commit buttons, because those commands ARE scenario 03's model answer. Polls every 3s because commits happen in the terminal and there is no event to subscribe to.
- `2026-08-21` Answered for the record, because it came up at the review and the plan never states it: the drill has GitOps CD and NO CI. Real git daemon, real push, real Argo clone and sync, real Helm render, real rollout - only WHOSE repo the remote is is simulated. Nothing builds: no test stage, no image build, no gates, and the app is public upstream images where a deploy is a Helm value pointing at a tag that already exists. A simulated CI - Jenkins in the cluster, a pipeline firing on push - exists nowhere in the plan and is new scope with its own scenarios. Also settled: write:packages was granted, and it only ever bought the push-from-the-laptop path since CI publishes with GITHUB_TOKEN.
- `2026-08-21` Task 5.3 review feedback from the user, 2026-08-21. Verdict on the shell: approved, no UI tweaks wanted. One change requested: the editor panel becomes an IDE - a file tree so the learner can explore and play with the whole repo, multi-file editing, and a theme picker as an easter egg. Explicitly NOT wanted: extensions, LSP, debugging, or anything else heavyweight. Two decisions recorded in CONTEXT_STATE with their fallbacks: the IDE is Monaco plus our own workbench rather than a hosted code-server (fallback: code-server on /ide through Task 5.4's proxy), and the layout is an activity rail on the far left with tasks and card staying right (fallback: the two-view toggle). Reframe that settled it: Monaco IS VS Code's editor, so what was missing was never the editor, only the furniture around it.
- `2026-08-21` Still blocked on the user, unchanged from the Phase 5 hydration prompt: scripts/config.toml needs enable_cluster_git, drill_ingress_group_name and drill_allowed_cidrs before any real plan, and 'gh auth refresh -h github.com -s write:packages' is interactive and must be run by them. Neither bites before Task 5.5.
- `2026-08-21` AC-H1 is evidenced for the serve-and-show half only. The user has not looked at it yet, so the ticket stays in-progress at Task 5.3 and AC-H2, H3, H4 and H5 are all untouched: H2 waits on the review, H3 and H5 need the deployment from 5.5, H4 needs the image on kind.
- `2026-08-21` Carried forward, unchanged: AC-H3 from WO-20260819-1fea (one ALB across three Ingresses) is still unobservable - no Ingress ships until Task 5.5. The GradeContext obligation from CONTEXT_STATE is DONE: accepted comes from SessionState.attempts and committed arrives through an injected readCommitted seam that Task 5.5 fills with a git-backed reader. The workspace-is-a-git-clone rule is not yet implementable either; it lands with the PVC in Task 5.5. Protocol addition: ServerMessage gains file:saved, so the editor's saved indicator means the server wrote the file. Two new server routes beyond the plan's list, both needed by 5.3: GET /api/scenario for the card panel and GET /api/file for Monaco, the latter jailed by workspace.ts along with file:save.
- `2026-08-21` Tasks 5.1-5.3 shipped in 86776dd, 69565f0, f35c707. Stopped at 5.3 for the user's review, per AC-H1. 107 tests pass; typecheck, build and the static suite are green. Nine defects fixed in the plan's own text or code, each found by running it: node-pty cannot install on any stock node image (the plan's Debian fallback fails identically, so Makefile.test now builds drill/Containerfile.build); a session-state test asserted against a shared server four earlier tests had submitted to; loadConfig turned a bad DRILL_PORT into NaN and Fastify would listen on a random port; the pty log path was derived as workspaceDir/../pty, which in the pod resolves off the PVC; openLog was async so the shell's first output missed the log; dispose ended the log stream before killing the PTY; the terminal's first resize was sent before the socket opened and silently dropped, which left the terminal BLANK while tmux was healthy; tmux's attach redraw was lost because the ws route subscribes after constructing the session; and WebglAddon draws nothing at all under software rendering.

## Outcome

_Written by `work-order close`. Empty until then._
