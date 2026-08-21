import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TerminalSession } from "./pty.ts";

const settle = (ms = 400) => new Promise((r) => setTimeout(r, ms));

test("a PTY echoes what is written to it", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-echo",
    logPath: join(dir, "pty.log"),
    shell: "/bin/sh",
  });
  let seen = "";
  term.onData((c) => {
    seen += c;
  });
  term.write("echo hello-drill\n");
  await settle(800);
  assert.match(seen, /hello-drill/);
  term.dispose();
});

test("output is teed to the log file", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const logPath = join(dir, "pty.log");
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-log",
    logPath,
    shell: "/bin/sh",
  });
  term.write("echo persisted-line\n");
  await settle(800);
  term.dispose();
  assert.match(await readFile(logPath, "utf8"), /persisted-line/);
});

test("replay returns the log tail so a pod restart keeps scrollback", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const logPath = join(dir, "pty.log");
  const first = new TerminalSession({
    cwd: dir,
    sessionName: "test-replay",
    logPath,
    shell: "/bin/sh",
  });
  first.write("echo before-restart\n");
  await settle(800);
  first.dispose();

  const second = new TerminalSession({
    cwd: dir,
    sessionName: "test-replay",
    logPath,
    shell: "/bin/sh",
  });
  assert.match(await second.replay(), /before-restart/);
  second.dispose();
});

test("replay is capped so a long drill does not blow up the first frame", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const logPath = join(dir, "pty.log");
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-cap",
    logPath,
    shell: "/bin/sh",
  });
  term.write("yes drill-filler | head -50000\n");
  await settle(2500);
  const tail = await term.replay();
  assert.ok(
    tail.length <= 256 * 1024,
    `replay was ${tail.length} bytes, cap is 256KB`,
  );
  // The cap has to be doing work for that assertion to mean anything.
  const written = (await readFile(logPath)).length;
  assert.ok(
    written > 256 * 1024,
    `the log was only ${written} bytes, so nothing was truncated and the cap was never tested`,
  );
  term.dispose();
});

test("resize does not throw", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-resize",
    logPath: join(dir, "pty.log"),
    shell: "/bin/sh",
  });
  assert.doesNotThrow(() => term.resize(120, 40));
  term.dispose();
});

test("replay on a fresh session with no log is empty, not an error", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const term = new TerminalSession({
    cwd: dir,
    sessionName: "test-fresh",
    logPath: join(dir, "nope.log"),
    shell: "/bin/sh",
  });
  assert.equal(await term.replay(), "");
  term.dispose();
});

// --- the production path -------------------------------------------------------
//
// Every test above overrides `shell`, so none of them runs tmux. The default is
// what ships in the pod, and the failure mode of leaving it unexercised is a
// blank terminal in front of the user with the drill already started.

const tmuxSessions = (): string =>
  execFileSync("tmux", ["ls"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  });

test("the default shell really is tmux, and the session outlives the browser", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const name = "drill-test-detach";
  const first = new TerminalSession({
    cwd: dir,
    sessionName: name,
    logPath: join(dir, "pty.log"),
  });
  first.write("echo before-disconnect\n");
  await settle(1200);
  assert.match(
    tmuxSessions(),
    new RegExp(name),
    "tmux is not running the shell",
  );

  // A browser disconnect drops the local handle. tmux keeps the shell.
  first.dispose();
  await settle(400);
  assert.match(
    tmuxSessions(),
    new RegExp(name),
    "disposing the handle killed the tmux session - a refresh would lose the drill",
  );

  // Reconnecting attaches to the same session rather than starting a new shell,
  // so what was on the screen is still on the screen.
  const second = new TerminalSession({
    cwd: dir,
    sessionName: name,
    logPath: join(dir, "pty.log"),
  });
  let seen = "";
  second.onData((c) => {
    seen += c;
  });
  await settle(1500);
  assert.match(seen, /before-disconnect/, "tmux did not redraw the old pane");
  second.dispose();
  execFileSync("tmux", ["kill-session", "-t", name], { stdio: "ignore" });
});

test("a command that outlives the disconnect is still running on reattach", async () => {
  const dir = await mkdtemp(join(tmpdir(), "drill-pty-"));
  const name = "drill-test-longrun";
  const first = new TerminalSession({
    cwd: dir,
    sessionName: name,
    logPath: join(dir, "pty.log"),
  });
  // A rollout watch is the real case: it prints for a while and you should not
  // have to restart it because your laptop slept.
  first.write(
    `(for i in 1 2 3 4 5 6; do echo tick-$i; sleep 1; done) > ${dir}/ticks.txt\n`,
  );
  await settle(1500);
  first.dispose();

  await settle(3000);
  const ticks = await readFile(join(dir, "ticks.txt"), "utf8");
  assert.match(
    ticks,
    /tick-4/,
    "the command died with the browser handle instead of surviving in tmux",
  );
  execFileSync("tmux", ["kill-session", "-t", name], { stdio: "ignore" });
});
