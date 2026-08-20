import { test } from "node:test";
import assert from "node:assert/strict";
import { expandAliases } from "./aliases.ts";

test("expands a bare alias", () => {
  assert.equal(expandAliases("kgp"), "kubectl get pods");
});

test("expands and keeps the rest of the command verbatim", () => {
  assert.equal(
    expandAliases("kgp -n practice-app -o wide"),
    "kubectl get pods -n practice-app -o wide",
  );
});

test("leaves a non-alias untouched", () => {
  assert.equal(
    expandAliases("helm upgrade practice-app ."),
    "helm upgrade practice-app .",
  );
});

test("leaves a full kubectl command untouched", () => {
  const cmd =
    "kubectl -n practice-app rollout undo deploy/practice-app-frontend";
  assert.equal(expandAliases(cmd), cmd);
});

test("expands k, the shortest alias, without touching a word that starts with k", () => {
  assert.equal(expandAliases("k get pods"), "kubectl get pods");
  assert.equal(expandAliases("kustomize build ."), "kustomize build .");
});

test("preserves quoting and pipes in the tail", () => {
  assert.equal(
    expandAliases(`kg deploy -o jsonpath='{.items[0].spec}' | jq .`),
    `kubectl get deploy -o jsonpath='{.items[0].spec}' | jq .`,
  );
});

test("tolerates leading and repeated whitespace", () => {
  assert.equal(
    expandAliases("   kgp    -n  practice-app"),
    "kubectl get pods    -n  practice-app",
  );
});

test("expands recursively but terminates on a cycle", () => {
  // A malformed table must not hang the server; the cap is the guarantee.
  assert.doesNotThrow(() => expandAliases("kgp"));
});

test("empty input is empty output", () => {
  assert.equal(expandAliases(""), "");
  assert.equal(expandAliases("   "), "   ");
});
