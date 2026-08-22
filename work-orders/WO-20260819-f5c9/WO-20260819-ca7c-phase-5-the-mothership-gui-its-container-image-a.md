---
{
  "id": "WO-20260819-ca7c",
  "slug": "phase-5-the-mothership-gui-its-container-image-a",
  "title": "Phase 5: the mothership GUI, its container image, and the first visual",
  "type": "feature",
  "status": "done",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-21",
  "created_at": "2026-08-19T19:32:20-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-5-the-mothership-gui-its-container-image-a",
  "pr": 27,
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
- [x] `AC-H2` *(human)* Tasks 5.4 and 5.5 are expanded from interface level into full step-by-step tasks only after that review, because they depend on what the user says when they see it
  - observed `2026-08-21` Plan Tasks 5.4 and 5.5 expanded from interface level into full step-by-step tasks in docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md, commit f61a947, AFTER the review rather than before it. 5.4 went from 5 steps to 8 and gained a K8sReader seam so the generated Kubernetes client is contained in one file; 5.5 went from 8 steps to 9 and gained enable_drill_gui and drill_gui_tag, a static .containerignore test, and a leading list of the five things that fail silently. Both carry a 'what the review changed' note. The plan's self-review section was updated so it no longer claims 5.4 and 5.5 are interface-level.
- [x] `AC-H3` *(human)* the built image is inspected and contains no scripts/config.toml and no .kubeconfig file, proving the deny-by-default .containerignore holds after the build context widened to the repo root
  - observed `2026-08-21` Checked against the BUILT image, not the .containerignore file. 'podman run --rm --entrypoint /bin/sh localhost/drill-gui:dev -c ls' reports No such file or directory for /app/scripts/config.toml and /app/.kubeconfig-daily-eks-practice, and /app/scripts, /app/terraform, /app/work-orders, /app/docs and /app/.git are all absent. A find across the whole filesystem for config.toml, .kubeconfig*, *.tfstate, *.tfvars.json and *.pem returns only the ca-certificates bundle. scenarios/answers/03.toml IS present, where the grader reads it. Re-asserted from a clean cluster by tests/drill-gui-kind.sh assertion 1. Also guarded statically by tests/test_containerignore.py (16 assertions), which was mutation-tested: removing the leading bare '*' fails 8 of 16, and adding '!scripts/' fails exactly the two config assertions.
- [x] `AC-H4` *(human)* the pod comes up on kind and serves the terminal, the editor and both panels
  - observed `2026-08-21` bash tests/drill-gui-kind.sh from a torn-down cluster: 21 passed, 0 failed, exit 0. The pod reached Ready; the init container cloned cluster git into the PVC; the workspace holds .git and helm and nothing else; origin is git://git-server.git.svc.cluster.local/repo.git and ls-remote answers, so it is a real clone rather than a copy. All seven API routes answer 200 - /healthz, /api/session, /api/tasks, /api/tree, /api/git/status, /api/deps, /api/argo. /api/deps returned a LIVE Kubernetes read through the cluster-admin ServiceAccount: cluster-git ready 'serving on git-server.git', argocd and practice-app correctly absent since neither is installed on kind. Driven in headless Chrome over CDP through a port-forward: explorer, editor, terminal, tasks, card and argo tabs all render; 'whoami && hostname' printed pilot / drill, 'git remote -v' printed the cluster-git URL, and 'kubectl get ns' listed all seven namespaces from inside the pod.
- [x] `AC-H5` *(human)* no imagePullSecret exists anywhere in the deployment, because the GHCR package is public
  - observed `2026-08-21` kubectl -n practice-drill get pod <pod> -o jsonpath='{.spec.imagePullSecrets}' returns empty, asserted against a pod known to exist - the harness aborts rather than reporting this if no pod is present, because the first version of the assertion passed against a missing pod. No imagePullSecret appears anywhere in drill-gui.tf: the ServiceAccount has none, the pod spec has none, and the GHCR package is public by design because the repo is public and PRACTICE_ANSWERS.html is already committed to it, so the image holds nothing not already readable.

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

- `2026-08-21` Task 5.4 and 5.5 shipped in f61a947 (plan expansion), 1ad02d6 (Argo widget, proxy, home directory), 835cb55 (image, deployment, callsign), 6045d32 (kind harness). Design decisions worth not re-litigating: the Argo widget reads the Application CRD through the Kubernetes API rather than Argo's REST API, because .status already carries sync, health, revision and the resource tree and the pod's ServiceAccount can read it - going through Argo would mean a token, an account and a rotation for a status read. integrations/k8s.ts is the ONLY file importing @kubernetes/client-node, so the generated client's churn is contained in ~60 lines with no logic; everything above takes a K8sReader and is tested against a fake. deps.ts keeps 'waiting' distinct from 'absent' because 'Argo knows, Kubernetes has not caught up' is the normal first ninety seconds of a drill. The proxy is built and deliberately unexercised. From the review: the workspace moved to ~/practice-app (a directory INSIDE the home, so dotfiles land outside the git tree), the host is named drill, and the account is 'pilot' renameable with 'callsign' - which rewrites the passwd entry for its own uid rather than aliasing whoami, so whoami, id, ps and ls -l all agree. That needs write permission on /etc/passwd, which is a real relaxation that buys an attacker nothing here because the terminal it describes is already cluster-admin.
- `2026-08-21` RETRO, interview-ready. The through-line of Phase 5 is that a green test suite sat on top of an unusable product, repeatedly, and every single defect was found by running the thing and looking at it. Tasks 5.1-5.3 produced nine of those. Tasks 5.4-5.5 produced four more, and the pattern held exactly: (1) tmux does its own ${...} expansion and has no :- default syntax, so 'set -g default-command "${SHELL:-/bin/sh} -l"' was a parse error - and a tmux parse error discards the WHOLE config, so the green status bar the file exists to turn off came back, in a change whose entire purpose was the prompt. Caught by a screenshot, not a test. (2) The kind harness used 'kubectl --context' with no KUBECONFIG; this project's kubeconfig is repo-local by design, so every assertion failed with a message about the context rather than the cluster. (3) Worse, and the one worth telling: AC-H5 PASSED against a pod that did not exist, because grepping for an absent field on an absent resource returns nothing and 'nothing' reads as 'no imagePullSecret'. A vacuous pass is more dangerous than a failure - it is the assertion nobody re-reads. It now aborts when the pod is missing. (4) 'test files must not reach dist/' had been true and unnoticed since Task 2.1; the fix is two tsconfigs, because typecheck and emit genuinely want different file sets. The generalisable lesson: assertions must be able to distinguish 'the thing is correct' from 'the thing is not there', and so must code - the readCommitted seam has the same shape, where undefined means NOT KNOWN and must never come to mean NOT COMMITTED, or a learner who did everything right fails a task about committing because git blipped.
- `2026-08-21` BLOCKED ON THE USER, and unchanged in substance since the Phase 5 hydration prompt, but now measured. scripts/config.toml exists and is dated 2026-08-19, which predates Phase 4, and contains ZERO drill keys. Six are missing: enable_cluster_git, drill_ingress_group_name and drill_allowed_cidrs from Phases 3 and 4, plus enable_drill_gui, drill_gui_image and drill_gui_tag from this ticket. Any real 'make plan' fails on all six with 'No value for required variable'. This did NOT block Phase 5: bootstrap.py gained DAILY_EKS_CONFIG so the /usr/bin/zsh sandboxes plan from scripts/config.example.toml, which is correct on its own terms because ministack and kind have no AWS, no ALB and a locally loaded image, so every value that identifies the operator is inert there. The user was asked and declined to have the file edited on their behalf; drill_allowed_cidrs in particular is the only control in front of an unauthenticated cluster-admin terminal and should be set deliberately. Nothing is provisioned and nothing is billing, so this bites at the next real apply, not before.
- `2026-08-21` CARRIED AC-H3 FROM WO-20260819-1fea IS STILL NOT MET, and now there is a concrete reason rather than 'no Ingress ships yet'. That criterion asks for a plan showing one ALB across three Ingresses. Two things block it. First, only ONE Ingress exists: the drill GUI's. Argo CD's and Grafana's join the group when scenario 07 is ported, so 'across three' cannot be observed from anything that exists today. Second, and more interesting, the drill Ingress's yaml_body is UNKNOWN AT PLAN TIME - it interpolates aws_security_group.drill_alb[0].id, which does not exist until apply, so terraform show -json reports it in after_unknown and the group.name annotation is not readable from a plan at all. Verified against the real ministack plan. What CAN be stated: the annotation is statically present in drill-gui.tf, its value comes from drill_ingress_group_name, terraform creates no aws_lb resources itself (the controller does, from the Ingress), and exactly one source-restricted security group is planned. Do not tick AC-H3 off that - it is evidence for the wiring, not for one-ALB-across-three. It becomes observable at the first real apply with two or more group members.
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
