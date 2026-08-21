# drill - the in-cluster drill GUI

The mothership.
One long-lived pod that serves the terminal, the editor, the answers panel and the help panel, and is the only surface a drill is run from.

## Layout

| Workspace | What                                                                                                                  |
| --------- | --------------------------------------------------------------------------------------------------------------------- |
| `shared/` | The websocket protocol types. Imported by both ends, so a mismatch is a compile error rather than a runtime surprise. |
| `server/` | Fastify. Serves the built web app, the PTY websocket, the grader, and the reverse proxy to Argo CD and Grafana.       |
| `web/`    | React + Vite. xterm.js terminal, Monaco editor, answers and help panels.                                              |

## Running it

Node never runs on the host - everything goes through Podman, per `.claude/skills/container-sandbox/SKILL.md`.

```bash
make -f Makefile.test drill-install    # npm install, in a container
make -f Makefile.test drill-test       # unit tests, in a container
make -f Makefile.test drill-typecheck  # tsc --noEmit, in a container
make -f Makefile.test drill-build      # tsc -b to dist/, in a container
make -f Makefile.test drill-dev        # the GUI, in a container, on a probed port
make -f Makefile.test drill-clean      # drop the node_modules volume and the image
```

`drill-dev` runs `drill/dev.sh`, which starts **both** halves in one container: the
Fastify server on loopback:8090 and Vite on 5173, with Vite proxying `/api` and
`/ws` to the server.
The plan pointed `API_PROXY_TARGET` at `host.containers.internal:8090`, which
assumes the server is running on the laptop - it never is, because npm does not
run on the host in this repo.

Its workspace is a scratch git repo under `/tmp` in the container, seeded from
`helm/practice-app/values.yaml`.
It is deliberately not a mount of the working tree: the editor panel autosaves,
and nothing in a preview should be able to write to the repo.

### Where the dependencies live

`node_modules` is a **named Podman volume**, `daily-eks-practice-drill-node-modules`, mounted over `drill/node_modules`.
The dependency tree therefore never lands on the host filesystem; all that appears there is an empty mountpoint directory that Podman creates.
`package-lock.json` is a real file in the repo and is committed.

The container mounts the **repo root** at `/repo` and works in `/repo/drill`, not `drill/` at `/app`.
The grader's conformance tests read `scenarios/answers/` and `tests/fixtures/answers-invalid/`, both of which live above `drill/`, so a `drill/`-only mount cannot see them.

### Why the image is built rather than pulled

The base is `node:22-alpine`.
The tests are TypeScript and are executed directly, with no build step, by Node's own test runner: `node --test --experimental-strip-types 'src/**/*.test.ts'`.
Type stripping arrived in Node 22.6 and glob patterns in the test runner arrived in Node 21, so Node 20 can run neither.
`tsc` still compiles the same sources to `dist/` for the Phase 5 container image, which is what `drill-build` proves.

The image `Makefile.test` actually runs is `localhost/daily-eks-practice-drill-node:22-alpine`, built from `drill/Containerfile.build` by the `drill-node-image` target that every other `drill-*` target depends on.
It is the base plus `python3 make g++ tmux` and nothing else.

`node-pty` is the reason.
It ships **no** `linux-x64` prebuild: its install script is `node scripts/prebuild.js || node-gyp rebuild`, and on Linux the first half reports `Rebuilding because directory prebuilds/linux-x64 does not exist` and falls straight through to a source build.
So no stock `node` image can install this workspace on any Linux base - `node:22-alpine` and `node:22-bookworm-slim` both fail identically with `Could not find any Python installation to use`.
Moving to Debian does not fix it, because the missing thing was never the libc.

Staying on Alpine keeps one libc across the toolchain.
`node-pty` is a native module and the drill GUI's runtime image is Alpine, and a `.node` built against glibc cannot be loaded by a musl runtime.

`tmux` is in the image because `TerminalSession`'s production path spawns `tmux new-session -A`, and a suite that only ever passes `shell: "/bin/sh"` would leave that path unexercised until it failed in front of the user.

The build is cached, so the dependency costs about a second per invocation.
`drill-clean` drops the image along with the `node_modules` volume, so a change to `Containerfile.build` is picked up either way.

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

## The GUI

Four panels: editor over terminal on the left, tasks and card behind tabs on the right, a status row underneath.
The palette is lifted verbatim from `PRACTICE_ANSWERS.html` so the drill and the answer key read as one product.

Three things in `web/` are decisions rather than defaults, and undoing them breaks something that is not obvious:

**Monaco is bundled, not fetched.**
`@monaco-editor/react` loads the editor from `cdn.jsdelivr.net` by default, which works on a laptop and hangs forever in a private subnet.
`web/src/lib/monaco.ts` points the loader at the npm package.
It also imports `editor.api` plus one language contribution rather than the `monaco-editor` barrel - the barrel pulls in every grammar Monaco ships, from abap to solidity, and takes the bundle from about 800 KB to 3.9 MB.
The editor panel is lazy-loaded so Monaco lands in its own chunk after the console has painted.

**There is no `WebglAddon`.**
It was tried and removed. Under software rendering it creates a context, throws nothing, never fires `onContextLoss`, and draws nothing at all - a completely blank terminal with no error anywhere.
A GPU-blocklisted browser, a VM or a remote desktop can all land there, and this is the surface the whole drill is run from.
xterm's default DOM renderer is correct everywhere and fast enough to watch a rollout.

**The terminal re-sends its size when the socket opens.**
`useDrillSocket`'s `send` drops anything written to a socket that is not `OPEN`, and the `ResizeObserver` fires on mount - before the websocket has connected.
So the one message that mattered most was the one guaranteed to be thrown away: the PTY stayed at the 120x32 it was spawned with, tmux redrew a 32-row screen into a 23-row terminal, and the prompt landed in a row nothing displayed.
The terminal looked blank while the session behind it was perfectly healthy.

## Why TypeScript on both ends

The websocket carries a real protocol - terminal bytes, resize events, grader verdicts, file saves, sync status - and the two ends are written months apart.
Shared types turn a protocol mismatch into a compile error.

`@drill/shared` is types-only.
Nothing in it survives to runtime, so `@drill/server` imports it with `import type` and Node never has to resolve the package.
