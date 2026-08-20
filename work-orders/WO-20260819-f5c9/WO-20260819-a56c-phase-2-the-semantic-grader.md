---
{
  "id": "WO-20260819-a56c",
  "slug": "phase-2-the-semantic-grader",
  "title": "Phase 2: the semantic grader",
  "type": "feature",
  "status": "in-progress",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-20",
  "created_at": "2026-08-19T19:31:40-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-2-the-semantic-grader",
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
    "WO-20260819-11df"
  ],
  "blocks": [
    "WO-20260819-ca7c",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-a56c - Phase 2: the semantic grader

## Problem

Nothing decides whether an answer is right. String equality is the wrong instrument: 'k get po -n practice' and 'kubectl get pods --namespace practice' are the same command, and a drill that marks one wrong teaches typing rather than Kubernetes. This ticket builds the grader as pure functions over strings and files - no cluster, no AWS, no network - so it is testable before anything can call it. Implements Phase 2, Tasks 2.1 through 2.4 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- the drill/ TypeScript workspace: package.json, tsconfig.base.json, drill/shared and drill/server, all installed and tested inside Podman
- alias expansion (k -> kubectl, po -> pods, and the rest of the table)
- semantic command parsing producing ParsedCommand, so flag order and short or long form do not change the verdict
- grading and hints across the three grader kinds: command, file and prose
- the shared types Verdict, SessionState, Attempt and DependencyStatus in @drill/shared, defined once here and consumed unchanged by Phase 5
- running Phase 1's invalid-TOML fixtures through drill/server/src/grader/answers.ts, so the two validators cannot drift
- drill-install, drill-test and drill-build targets in Makefile.test

**Out - non-goals**

- any UI - the GUI is the Phase 5 ticket
- the PTY, the websocket, or anything that talks to a cluster or the network
- grading in Python - the grader runs inside the pod's Node process and shipping a Python runtime in the image would buy nothing
- running npm install on the host - it runs in Podman, always

## Acceptance criteria


- [x] `AC-H1` *(human)* 'k get po -n x' and 'kubectl get pods --namespace x' produce the same verdict
  - observed `2026-08-20` Pinned as a test and run: 'ok 25 - AC-H1: the alias form and the spelled-out form get the same verdict' in drill/server/src/grader/index.test.ts. It grades 'k get po -n x' and 'kubectl get pods --namespace x' against one accept rule and asserts deepEqual on the two Verdict objects, not just on passed - so the message and the hint have to agree too. Both pass. Two different strings, one verdict, which is the whole argument for parsing instead of string-matching.
- [x] `AC-H2` *(human)* reordering flags, or swapping a short flag for its long form, does not change the verdict
  - observed `2026-08-20` Pinned as a test and run: 'ok 26 - AC-H2: flag order and short-or-long form do not change the verdict'. Five spellings of the same correct answer all pass - '-n' before and after the verb, '-n' vs '--namespace' vs '--namespace=', deploy/x vs deployment/x vs 'deployment x'. The same test then does it for a WRONG answer, because equivalence has to hold on failure too or a near miss is still being graded by spelling: three spellings of the same missing-namespace mistake return deepEqual verdicts, all passed=false. Also covered structurally by 'ok 28 - flag order does not change the parse' and 'ok 30 - space form is equivalent to slash form'.
- [x] `AC-H3` *(human)* every invalid fixture from the Phase 1 ticket is rejected by the TypeScript validator with the same failure the Python validator gives
  - observed `2026-08-20` All ten fixtures in tests/fixtures/answers-invalid/ are rejected by drill/server/src/grader/answers.ts, and rejected with a byte-identical message to scripts/answers.py. Ran both validators over the directory and diffed the output: ten lines each, identical, e.g. 'unknown-grader.toml: tasks[0] (id 1): unknown grader ..vibes.., expected one of (..command.., ..file.., ..prose..)' from both sides. Pinned by 'ok 11 - every invalid fixture is rejected here too', which asserts per fixture that the message names the file AND matches the specific rule that fixture breaks, and asserts the fixture directory and the expectation table list the same ten files, so adding a fixture without an expectation is a red test. Getting here needed four rules the plan's validator was missing - it accepted command-accept-without-verb, empty-title, hint-without-text and unknown-grader on the first run. No fixture and no line of scripts/answers.py was changed.
- [x] `AC-H4` *(human)* a wrong answer returns a hint that names what was actually wrong, not a generic failure
  - observed `2026-08-20` Ran nine wrong answers against the REAL scenario 03 tasks loaded from scenarios/answers/03.toml. Eight name the mistake: forgot -n -> 'The app is not in the default namespace. Every command in this drill needs -n practice-app.' (hint missing-namespace); asked about pods -> 'Rollout history belongs to the Deployment that owns them, not to the pods.' (wrong-resource); wrong deployment -> 'Right idea, wrong object: expected practice-app-frontend.'; wrong namespace -> 'Wrong namespace: you used default, the app lives in practice-app.'; a single curl -> 'One curl proves nothing - the whole question is whether any request in a stream fails.' (no-loop); prose without the numbers -> no-numbers; prose without the pod status -> no-signature; untouched values.yaml -> 'values.yaml still says 1.27-alpine.' (unchanged). The ninth, 'helm list -A' against a rollout task, gets the generic message on purpose - inventing a hint for an unrelated command is worse than admitting none applies, and 'ok 18 - an unrelated command fails without inventing a hint' pins that. Every hint text came from [[tasks.hints]] in 03.toml; none was invented here. Regression-pinned by 'ok 49 - 03..s authored hints fire on the mistakes they were written for'.
- [x] `AC-H5` *(human)* npm install and the whole test run happen inside Podman, and no node_modules directory appears on the host
  - observed `2026-08-20` Observed from a clean slate rather than assumed. Ran 'make -f Makefile.test drill-clean' to delete the Podman volume and the mountpoint, then confirmed 'find . -name node_modules' returned nothing anywhere in the repo. Ran drill-install and drill-test: both are podman run invocations of docker.io/node:22-alpine, npm was never executed on the host, and 49/49 tests ran in the container. Re-ran the same find afterwards: exactly one path, ./drill/node_modules, containing 0 entries. It is the mountpoint for the named volume daily-eks-practice-drill-node-modules, which is where all 10 installed packages actually live, so the dependency tree is not on the host filesystem at all. This needed a deviation from the plan, which mounts the repo into the container read-write and lets npm install write node_modules straight into it - that satisfies 'npm install ran in a container' but not 'no node_modules appears on the host', and it did put six package directories on the host when tried.

## Test plan

```sh
make -f Makefile.test drill-install drill-test, which runs the workspace test suite inside Podman. The grader has no fixtures outside the repo and needs no cluster, so this is the complete proof for this ticket.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

- `2026-08-20` Definition of done, both suites run to completion on this branch. 'make -f Makefile.test test' exits 0 - terraform fmt and validate, helm lint in Podman, the history scrubber, and answers-check including gen-answers --check, tests/test_answers.py 21 passed and tests/test_gen_answers.py 12 passed. 'make -f Makefile.test drill-install drill-test' exits 0 with 49 tests, 49 pass, 0 fail. drill-typecheck and drill-build are clean too, from a tree with no dist and no node_modules. No scenario card, no check.sh outcome check and no PRACTICE_ANSWERS.html was touched, so the card/check/answers agreement is unchanged and answers-check proves it. helm/practice-app/values.yaml is still 1.27-alpine, and there is now a test that fails if anybody pre-solves it: 'ok 48 - 03..s file task is not pre-solved in the committed defaults'. Zero AWS calls, no cluster, nothing billed.
- `2026-08-20` One more Task 2.1 defect, found while wiring Task 2.4's imports. With the plan's tsconfigs, 'make -f Makefile.test drill-typecheck' fails on a fresh clone: server's 'tsc --noEmit' resolves @drill/shared through the package's types field to shared/dist/index.d.ts, which does not exist until something builds it, and dist/ is git-ignored. Observed TS2307 'Cannot find module @drill/shared or its corresponding type declarations' on the first run after deleting dist. Pointing types at src instead just moves the error to TS6305, because the project reference redirects source back to the unbuilt output. Fixed in drill/package.json: the root typecheck script builds @drill/shared first, then typechecks every workspace. Verified by deleting both dist directories and both tsbuildinfo files and running drill-typecheck clean. Worth knowing for Phase 5, which adds a third workspace against the same reference.
- `2026-08-20` Recorded so Phase 5 does not treat it as a bug: two of the ten hint keys plan Task 2.4 lists cannot fire from this grader, by construction rather than by omission. 'uncommitted' (03 task 2) means the file is correct but was never committed, which needs the workspace's git state. 'only-imperative' (03 task 5) means the submission PASSED and was the imperative half of a two-part answer, which needs the session's earlier attempts. A grader that is a pure function of one submission has neither. Both hints stay authored in the TOML and are documented at hintFor() in drill/server/src/grader/index.ts, waiting for a caller that can supply the context - Phase 5's server or Phase 6's watcher. The other eight all fire and are tested.
- `2026-08-20` SECOND defect, and the one that would have shipped an ungradeable drill. scenarios/answers/03.toml task 4 accepts verb = 'curl-loop' and task 5 accepts verb = 'git-revert', but the parser plan Task 2.3 specifies never emits either label: a shell loop parses as tool 'shell' verb 'while', and git revert as tool 'git' verb 'revert'. Plan Task 2.3's interface section asserts the shell-keyword handling 'is what lets the curl-loop accept rule in scenario 03 task 4 work', which is not true of its own code. Observed by grading 03's own model answers: 'while true; do curl ...; done' and 'git revert <commit> && git push' both came back 'Not what this task is asking for'. Two of the six tasks in the only ported scenario were unpassable. Third consequence: task 4's authored 'no-loop' hint could never fire, because a bare curl matches no rule verb, so the single most likely wrong answer got the generic failure AC-H4 forbids. Fixed in the parser, not the answers file: commandVerbs() returns the labels a command answers to - 'revert' plus 'git-revert' for a non-kubectl tool, 'while' plus 'curl-loop' for a loop, and the bare verb for kubectl, which is the unqualified default. The matcher accepts a rule naming any of them, and a '<tool>-loop' rule whose body command was run once fires no-loop. An accept rule has no 'tool' key, so the qualified verb is the only place that information can live; the convention is now documented in drill/README.md.
- `2026-08-20` Task 2.4 done. 47/47 tests pass (plan Task 2.4 Step 5 predicts 36 across the three files it writes; the extra 11 are the conformance and scenario-03 tests). Two plan defects, both found by running the step rather than reading it. FIRST, plan Task 2.4 Step 3's validate() enforces four of the ten rules scripts/answers.py enforces. Ran Step 6's fixture sweep against it and four of the ten invalid fixtures were ACCEPTED: command-accept-without-verb.toml, empty-title.toml, hint-without-text.toml, unknown-grader.toml. That is the exact drift AC-H3 and the fixture directory exist to catch. Rewrote validate() to mirror scripts/answers.py rule for rule and message for message, and to take 'unknown' rather than a pre-cast AnswerSet, since a validator that trusts its input type is not validating. Neither answers.py nor any fixture was touched.
- `2026-08-20` Task 2.3 done, 22/22 tests pass across aliases and parse, which is the count plan Task 2.3 Step 4 predicts. One plan defect: Step 3's parse.ts does not compile under the tsconfig Task 2.1 Step 2 mandates. Ran the plan's exact lines through tsc 5.9 with strict + noUncheckedIndexedAccess + exactOptionalPropertyTypes and got three TS2412 errors, all the same root cause - it assigns a possibly-undefined value straight onto an optional property ('out.namespace = ... as string | undefined', 'out.namespace = undefined', 'out.name = name' from a destructured split). exactOptionalPropertyTypes means 'namespace?: string' does not accept undefined; absent and present-but-undefined are different, and absent is the honest encoding of 'the user named no namespace'. Fixed by assigning through a local and only setting the property when there is a value. Runtime behaviour is identical, so the plan's own tests still pass unchanged. This is invisible unless typecheck is actually run: 'npm test' alone passes, because node strips types without checking them.
- `2026-08-20` Plan Task 2.2 Step 5 was right about the user's rc and missed a second divergence. Confirmed at ~/.zshrc:138 that 'alias kd=$'kubectl describe'0' carries a stray trailing 0, so kd really expands to 'kubectl describe0'. Not encoded - the grader's table is correct and the rc is not. ALSO, ~/.zshrc:141 says "alias kp='kubectl proxy'" while the plan's table says kp -> 'kubectl port-forward'. Mirrored the rc, because the table's documented job is to expand what the user's muscle memory types the way their own shell would expand it. Nothing depends on the old value: scenario 03 task 4's accept rule matches a spelled-out 'kubectl port-forward' and its model answer writes it in full.
- `2026-08-20` Task 2.2 done, 9/9 tests pass. One plan defect, invisible on reading, caught by running it. Plan Task 2.2 Step 1's test 'tolerates leading and repeated whitespace' asserts expandAliases(' kgp -n practice-app') === 'kubectl get pods -n practice-app', with no leading spaces, but Step 3's implementation captures the indentation as a group and re-emits it: '${lead}${replacement}${tail}'. Ran the plan's exact function in node:22-alpine and it returned ' kubectl get pods -n practice-app', so the plan's own test fails against the plan's own code. Fixed the implementation, not the test: an expansion rewrites the head of the line, so re-indenting the replacement invents whitespace the user did not type, and parseCommand trims anyway. A line that does not expand still comes back byte-identical, indentation included, which is what the empty-input test pins.
- `2026-08-20` Not a defect, recorded so it is not re-litigated: the plan lists 'web' in drill/package.json workspaces although drill/web does not exist until Phase 5. Tested both ways - npm treats a workspace entry as a glob and silently ignores one that matches nothing, so the install is clean either way. Kept 'web' in the list, because dropping it means Phase 5 has to remember to add it back and the failure mode if it forgets is a silently unlinked workspace rather than an error.
- `2026-08-20` Task 2.1 done. Five deviations from plan Task 2.1, all found by running it. (1) NODE_IMAGE is node:22-alpine, not node:20-alpine: the plan's own test command 'node --test --experimental-strip-types' needs type stripping, which arrived in Node 22.6, and test-runner glob patterns, which arrived in Node 21. On node:20 nothing in Phase 2 can run at all. (2) The container mounts the repo ROOT at /repo with -w /repo/drill, not drill/ at /app. This is the fix plan Task 2.4 Step 6 already prescribes for its own path resolution; applying it once up front is cheaper than applying it after two tasks of tests are written against the other layout. (3) tsconfig.base.json gained allowImportingTsExtensions plus rewriteRelativeImportExtensions. Observed: 'tsc -b' fails with TS5096 'Option allowImportingTsExtensions can only be used when either noEmit or emitDeclarationOnly is set'. The tests import './aliases.ts' with the extension because Node type-stripping requires it, so the pair of flags is what lets the same source both run under node --test and compile to dist/ for the Phase 5 image. (4) typescript ^5.6.0 -> ^5.9.0 and @types/node ^20 -> ^22, because rewriteRelativeImportExtensions is TS 5.7+. (5) node_modules is a named Podman volume (daily-eks-practice-drill-node-modules) mounted over drill/node_modules rather than a directory in the bind mount, so the dependency tree never lands on the host. Verified: with a plain bind mount, npm install writes 6 host-visible package directories into drill/node_modules; with the volume the host has an empty mountpoint and nothing else. Added a drill-clean target to drop the volume.

## Outcome

_Written by `work-order close`. Empty until then._
