import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCommand, normaliseResource, commandVerbs } from "./parse.ts";

test("flag order does not change the parse", () => {
  const a = parseCommand("kubectl get deploy -n practice-app");
  const b = parseCommand("kubectl -n practice-app get deployment");
  assert.equal(a.verb, b.verb);
  assert.equal(a.resource, b.resource);
  assert.equal(a.namespace, b.namespace);
  assert.equal(a.resource, "deployment");
  assert.equal(a.namespace, "practice-app");
});

test("slash form splits into resource and name", () => {
  const p = parseCommand(
    "kubectl -n practice-app rollout undo deploy/practice-app-frontend",
  );
  assert.equal(p.verb, "rollout-undo");
  assert.equal(p.resource, "deployment");
  assert.equal(p.name, "practice-app-frontend");
  assert.equal(p.namespace, "practice-app");
});

test("space form is equivalent to slash form", () => {
  const slash = parseCommand(
    "kubectl rollout history deploy/practice-app-frontend -n practice-app",
  );
  const space = parseCommand(
    "kubectl rollout history deployment practice-app-frontend -n practice-app",
  );
  assert.equal(slash.verb, space.verb);
  assert.equal(slash.resource, space.resource);
  assert.equal(slash.name, space.name);
  assert.equal(slash.verb, "rollout-history");
});

test("aliases are expanded before parsing", () => {
  const p = parseCommand("kgp -n practice-app");
  assert.equal(p.tool, "kubectl");
  assert.equal(p.verb, "get");
  assert.equal(p.resource, "pod");
  assert.equal(p.namespace, "practice-app");
});

test("--namespace long form is recognised", () => {
  assert.equal(
    parseCommand("kubectl get pods --namespace practice-app").namespace,
    "practice-app",
  );
  assert.equal(
    parseCommand("kubectl get pods --namespace=practice-app").namespace,
    "practice-app",
  );
});

test("-A sets allNamespaces and leaves namespace undefined", () => {
  const p = parseCommand("kubectl get pods -A");
  assert.equal(p.allNamespaces, true);
  assert.equal(p.namespace, undefined);
});

test("missing namespace is undefined, not a guess", () => {
  assert.equal(parseCommand("kubectl get pods").namespace, undefined);
});

test("flags are captured with and without values", () => {
  const p = parseCommand("kubectl get deploy -o wide --watch");
  assert.equal(p.flags["-o"], "wide");
  assert.equal(p.flags["--watch"], true);
});

test("git commands parse as tool git", () => {
  const p = parseCommand("git revert abc123");
  assert.equal(p.tool, "git");
  assert.equal(p.verb, "revert");
});

test("a while loop parses as shell", () => {
  const p = parseCommand(
    "while true; do curl -so /dev/null localhost:8081; sleep .3; done",
  );
  assert.equal(p.tool, "shell");
  assert.equal(p.verb, "while");
});

test("raw is preserved exactly", () => {
  const raw = "kubectl   get   pods   -n practice-app";
  assert.equal(parseCommand(raw).raw, raw);
});

test("resource normalisation covers the common short forms", () => {
  assert.equal(normaliseResource("deploy"), "deployment");
  assert.equal(normaliseResource("deployments"), "deployment");
  assert.equal(normaliseResource("po"), "pod");
  assert.equal(normaliseResource("svc"), "service");
  assert.equal(normaliseResource("ing"), "ingress");
  assert.equal(normaliseResource("widget"), "widget");
});

test("empty input does not throw", () => {
  const p = parseCommand("");
  assert.equal(p.tool, "");
  assert.equal(p.verb, "");
});

test("a kubectl command's only verb label is its verb", () => {
  assert.deepEqual(commandVerbs(parseCommand("kubectl get pods")), ["get"]);
});

test("a non-kubectl command also answers to a tool-qualified label", () => {
  // scenarios/answers/03.toml task 5 writes its accept rule as verb = "git-revert",
  // because an accept rule has no `tool` key to qualify a bare "revert" with.
  assert.deepEqual(commandVerbs(parseCommand("git revert abc123")), [
    "revert",
    "git-revert",
  ]);
});

test("a loop answers to <body>-loop, which is how 03 task 4 is written", () => {
  const verbs = commandVerbs(
    parseCommand(
      "while true; do curl -so /dev/null localhost:8081; sleep .3; done",
    ),
  );
  assert.deepEqual(verbs, ["while", "curl-loop"]);
});

test("a for loop over curl is the same label as a while loop over curl", () => {
  assert.ok(
    commandVerbs(
      parseCommand("for i in $(seq 1 100); do curl localhost:8081; done"),
    ).includes("curl-loop"),
  );
});

test("a loop with no recognisable body gets no loop label", () => {
  assert.deepEqual(commandVerbs(parseCommand("while true; done")), ["while"]);
});

test("empty input has no verb labels", () => {
  assert.deepEqual(commandVerbs(parseCommand("")), []);
});
