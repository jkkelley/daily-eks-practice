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

## Why TypeScript on both ends

The websocket carries a real protocol - terminal bytes, resize events, grader verdicts, file saves, sync status - and the two ends are written months apart.
Shared types turn a protocol mismatch into a compile error.

`@drill/shared` is types-only.
Nothing in it survives to runtime, so `@drill/server` imports it with `import type` and Node never has to resolve the package.
