# drill - the in-cluster drill GUI

The mothership.
One long-lived pod that serves the terminal, the editor, the answers panel and the help panel, and is the only surface a drill is run from.

## Layout

| Workspace | What                                                                                                                  |
| --------- | --------------------------------------------------------------------------------------------------------------------- |
| `shared/` | The websocket protocol types. Imported by both ends, so a mismatch is a compile error rather than a runtime surprise. |
| `server/` | Fastify. Serves the built web app, the PTY websocket, the grader, and the reverse proxy to Argo CD and Grafana.       |
| `web/`    | React + Vite. xterm.js terminal, Monaco editor, answers and help panels. Built in Phase 5; it does not exist yet.     |

## Running it

Node never runs on the host - everything goes through Podman, per `.claude/skills/container-sandbox/SKILL.md`.

```bash
make -f Makefile.test drill-install    # npm install, in a container
make -f Makefile.test drill-test       # unit tests, in a container
make -f Makefile.test drill-typecheck  # tsc --noEmit, in a container
make -f Makefile.test drill-build      # tsc -b to dist/, in a container
make -f Makefile.test drill-clean      # drop the node_modules volume
```

### Where the dependencies live

`node_modules` is a **named Podman volume**, `daily-eks-practice-drill-node-modules`, mounted over `drill/node_modules`.
The dependency tree therefore never lands on the host filesystem; all that appears there is an empty mountpoint directory that Podman creates.
`package-lock.json` is a real file in the repo and is committed.

The container mounts the **repo root** at `/repo` and works in `/repo/drill`, not `drill/` at `/app`.
The grader's conformance tests read `scenarios/answers/` and `tests/fixtures/answers-invalid/`, both of which live above `drill/`, so a `drill/`-only mount cannot see them.

### Why the image is `node:22-alpine`

The tests are TypeScript and are executed directly, with no build step, by Node's own test runner: `node --test --experimental-strip-types 'src/**/*.test.ts'`.
Type stripping arrived in Node 22.6 and glob patterns in the test runner arrived in Node 21, so Node 20 can run neither.
`tsc` still compiles the same sources to `dist/` for the Phase 5 container image, which is what `drill-build` proves.

## The grader

`server/src/grader/` is pure functions over strings and files.
It has no cluster, no AWS, no network and no PTY, which is why the whole of it is testable before anything exists to call it.

| File      | What                                                                                          |
| --------- | --------------------------------------------------------------------------------------------- |
| `aliases` | Expands the leading shell alias, mirroring the user's rc, before anything is parsed.          |
| `parse`   | Turns a command line into a canonical shape, so flag order and short forms do not matter.     |
| `answers` | Loads and validates `scenarios/answers/*.toml`. The TypeScript half of a two-language schema. |
| `index`   | The three graders (command, file, prose) and the hint dispatch.                               |

### How an accept rule matches

An `[[tasks.accept]]` rule carries a `verb` and no `tool`, so a command answers to more than one verb label and a rule matches if it names any of them.
`commandVerbs()` in `parse.ts` is the whole convention:

| You typed                                       | Labels it answers to   | Why                                                                                         |
| ----------------------------------------------- | ---------------------- | ------------------------------------------------------------------------------------------- |
| `kubectl -n practice-app rollout undo deploy/x` | `rollout-undo`         | kubectl is the unqualified default - a drill task is about kubectl unless it says otherwise |
| `git revert abc123`                             | `revert`, `git-revert` | a bare `revert` has no tool on it, so the rule qualifies the verb                           |
| `while true; do curl localhost:8081; done`      | `while`, `curl-loop`   | the loop's body is the point of the task, not the keyword                                   |

Write the qualified form in the answers file.
`verb = "git-revert"` and `verb = "curl-loop"` are what scenario 03 uses, and a rule naming a verb no command can produce makes the task silently ungradeable.

### Hints, and the two that need context

A failure names the misconception: the grader classifies _how_ the answer was wrong and looks up the `[[tasks.hints]]` entry whose `when` matches.
Eight keys need nothing but the submission - `missing-namespace`, `wrong-namespace`, `wrong-resource`, `wrong-name`, `no-loop`, `unchanged`, and whichever hint a prose task lists first.

Two need a fact the submission cannot carry, and take it from the optional `GradeContext` third argument:

| Key               | Needs                          | Supply                                                                      |
| ----------------- | ------------------------------ | --------------------------------------------------------------------------- |
| `uncommitted`     | the file as cluster git has it | `gradeFile(task, workspaceContent, { committed })`                          |
| `only-imperative` | this session's earlier passes  | `gradeCommand(task, submitted, { accepted })`, from `SessionState.attempts` |

Every field of `GradeContext` is optional and a missing one means "not known", never "false" - a grader must never punish a caller for context it could not get.
Omit `committed` and commit state is simply not graded.

`only-imperative` is the one hint that fires on a **correct** answer: `passed` stays `true` and the nudge rides along in `hint`, because `kubectl rollout undo` really is the right rollback and Argo CD really is about to put the bad version back.

`scenario-03.test.ts` asserts that every hint key authored in `03.toml` has a trigger that fires it, so a hint cannot be added to the curriculum and left dead.

### The validator is one of two

`scripts/answers.py::_validate()` and `server/src/grader/answers.ts::validate()` enforce the same rules on the same files, because Python renders the answers and TypeScript grades them.
`tests/fixtures/answers-invalid/` is ten files, one per rule, that both must reject and reject **for the same stated reason**.
If you add a rule to one, add it to the other and add a fixture, in the same commit.

## Why TypeScript on both ends

The websocket carries a real protocol - terminal bytes, resize events, grader verdicts, file saves, sync status - and the two ends are written months apart.
Shared types turn a protocol mismatch into a compile error.

`@drill/shared` is types-only.
Nothing in it survives to runtime, so `@drill/server` imports it with `import type` and Node never has to resolve the package.
