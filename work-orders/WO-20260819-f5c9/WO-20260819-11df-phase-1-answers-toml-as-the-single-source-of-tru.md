---
{
  "id": "WO-20260819-11df",
  "slug": "phase-1-answers-toml-as-the-single-source-of-tru",
  "title": "Phase 1: answers TOML as the single source of truth",
  "type": "feature",
  "status": "in-review",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-20",
  "created_at": "2026-08-19T19:30:53-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": "feat/phase-1-answers-toml-as-the-single-source-of-tru",
  "pr": 14,
  "merge_sha": null,
  "closed": null,
  "approval": {
    "via": "lavish",
    "at": "2026-08-19"
  },
  "evidence": null,
  "surfaces": [],
  "depends_on": [],
  "blocks": [
    "WO-20260819-a56c",
    "WO-20260819-f5c9"
  ]
}
---

# WO-20260819-11df - Phase 1: answers TOML as the single source of truth

## Problem

scenarios/03-*.md, PRACTICE_ANSWERS.html and scenario_testing/check.sh agree only because somebody remembered to keep them in step, and nothing detects it when they stop agreeing. Grading cannot be built on a hand-maintained HTML file. This ticket makes scenario 03's answer block generated from a machine-readable TOML that both the Python renderer and the TypeScript grader read, so drift becomes impossible for 03 while the other eleven pass through untouched. Implements Phase 1, Tasks 1.1 and 1.2 of `docs/superpowers/plans/2026-08-19-scenario-drill-sessions.md`, which is the authority for every step. The plan argues from `docs/superpowers/specs/2026-08-19-scenario-drill-sessions-design.md`; the two agree and neither is to be re-litigated. The plan's `## Global Constraints` section binds this ticket in full and is not restated here.

## Scope

**In**

- scenarios/answers/03.toml carrying schema, scenario, title, time, needs, ticket and a non-empty tasks list
- scripts/answers.py - load(), available(), AnswersError, and the validator
- scripts/gen-answers.py - mixed mode: 03 rendered from TOML, the other eleven passed through byte-identically
- an answers-gen target in the Makefile
- a fixture set of deliberately-invalid TOML, shared with the Phase 2 ticket so the two validators cannot drift silently

**Out - non-goals**

- grading - the grader is the Phase 2 ticket and lives in TypeScript
- porting scenarios other than 03 to TOML
- editing any of the eleven hand-written answer blocks, whose byte-identity is the proof this works
- changing the rendered look of PRACTICE_ANSWERS.html

## Acceptance criteria


- [x] `AC-H1` *(human)* pure passthrough mode reproduces the committed PRACTICE_ANSWERS.html byte for byte
  - observed `2026-08-20` Observed on both baselines. Against the pre-generation committed file (a5d48ee~1): gen.generate(base, []) == base is True. Against the current committed file: gen.generate(HTML, []) == HTML is True, 22695 bytes. Asserted continuously by tests/test_gen_answers.py::test_passthrough_is_identical, which is in make -f Makefile.test test via the answers-check target.
- [x] `AC-H2` *(human)* mixed mode regenerates the 03 block from TOML and leaves all eleven other blocks byte-identical
  - observed `2026-08-20` Observed against the pre-generation baseline, where 03 genuinely changed: generate(base, ['03']) leaves all eleven non-03 blocks byte-identical (True) while the 03 block does change (True). split() finds exactly ['01'..'12'] and round-trips byte-for-byte. The written diff was 21 insertions / 21 deletions, entirely inside PRACTICE_ANSWERS.html lines 195-227, read by hand: every command and every fact from the hand-written block survives into the TOML-rendered one, and the block gains per-task headings 1-6 matching the card plus task 1's jsonpath image query, task 2's commit step and task 4's port-forward. Asserted by test_mixed_leaves_others_untouched and test_head_and_tail_survive_generation.
- [x] `AC-H3` *(human)* every file in the invalid-TOML fixture set raises AnswersError with a message naming both the file and the problem
  - observed `2026-08-20` All ten fixtures in tests/fixtures/answers-invalid/ raise AnswersError, each message naming the file path and the problem, e.g. 'tests/fixtures/answers-invalid/file-without-key.toml: tasks[0] (id 1): a file task needs a non-empty key' and 'tests/fixtures/answers-invalid/duplicate-task-id.toml: duplicate task id 1'. Printed all ten and read them. tests/test_answers.py reports 'answers: 21 passed, 0 failed' with one PASS line per fixture.
- [x] `AC-H4` *(human)* the validated shape is documented where Phase 2 can implement against it: the three grader kinds command, file and prose, and the keys each one carries
  - observed `2026-08-20` Documented in two places that sit next to what they describe. tests/fixtures/answers-invalid/README.md carries the full validated shape as tables - top level, the keys every task carries, and one table per grader kind (command: non-empty accept array, each entry needing a verb with resource/namespace/name/flags optional; file: path, key, accept_pattern all non-empty; prose: non-empty must_include list of non-empty strings) - plus a fixture-to-rule map and the statement that the TypeScript validator in drill/server/src/grader/answers.ts is held to the same directory. The same table is repeated in scripts/answers.py's module docstring next to the code that enforces it.

## Test plan

```sh
python3 tests/test_answers.py and python3 tests/test_gen_answers.py - plain scripts with a main() returning an exit code, matching the style of tests/scrub-git-identity.sh. This repo has no test runner dependency and does not gain one here. Then make -f Makefile.test test.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

- `2026-08-20` Task 1.2 complete (commit f5c0f46). tests/test_gen_answers.py was run failing first: FileNotFoundError on scripts/gen-answers.py, exit 1. Final state: 12 passed, 0 failed; make -f Makefile.test test exits 0 (fmt-check, validate for envs/dev and bootstrap-oidc, helm lint in Podman, history-scrubber, answers-check). Zero AWS calls, no cluster. THREE DEVIATIONS FROM THE PLAN, all found by executing it: 1. Plan Task 1.2 Step 1's test_mixed_leaves_others_untouched asserted changed == ['03'], which Step 6 makes unsatisfiable. Once the committed HTML IS the generated output, regenerating 03 is a no-op, so changed is [] and the test fails with the nonsense message 'generating 03 also changed: []'. The plan's own Step 6 breaks the plan's own Step 1. Reworded the assertion to the contract it was protecting - no non-03 block changed - and verified it still has teeth by feeding it a doctored document with block 02 altered, which it correctly flags. Added test_generation_is_idempotent alongside, because a non-idempotent generator would leave --check permanently red. AC-H2 was then evidenced against the pre-generation baseline (a5d48ee~1), where 03 genuinely does change, so the weaker-looking assertion is not hiding anything. 2. Plan Task 1.2 Step 6's verification command does not work in this repo: it curls http://localhost:8000 but scripts/serve-answers.sh picks a RANDOM port in 8000-8998 unless PORT is set, and serves the document at /PRACTICE_ANSWERS.html rather than /, so the given command would have hit a directory listing and printed 0 instead of 1. Ran it with PORT=8123 against the real script and the real file path: exactly 1 <details>, it is 03, head/seal and tail script both present, zero leakage from other scenarios. 3. Added .prettierignore, which the plan does not mention. The user's global agent hook runs npx prettier --write on every Write/Edit outside work-orders/, and the generated 03 block is not prettier-stable - verified by running prettier over the generated output, which re-wraps every <h3> and <p> in the 03 block while leaving the other eleven blocks and the head/tail untouched. Without the ignore, any agent that touched PRACTICE_ANSWERS.html would make gen-answers.py --check, and therefore make -f Makefile.test test, fail until someone ran make answers-gen. Verified the ignore holds: prettier --write on the file leaves its sha256 unchanged. Known fidelity note, not fixed on purpose: the hand-written 03 block used inline <code> spans (rollout undo, ImagePullBackOff) and the generated block does not, because TOML prose is plain text and is HTML-escaped. Restoring that would mean inventing a markup convention in the TOML that the TypeScript grader would then have to strip, which is a design decision beyond this ticket. The page's styling, structure and the other eleven blocks are unchanged. Not done here because it is out of scope: values.yaml still says 1.27-alpine, so scenario 03 is not pre-solved. Card, scenario_testing/check.sh and PRACTICE_ANSWERS.html agree - check.sh's 03 case was not touched and its three assertions still map to the card's three success criteria and to TOML tasks 1, 2 and 5.
- `2026-08-20` Task 1.1 complete (commit a5d48ee). tests/test_answers.py was run failing first: ModuleNotFoundError: No module named 'answers', exit 1. After scenarios/answers/03.toml and scripts/answers.py it reports 'answers: 21 passed, 0 failed' - 11 for the loader plus 10 for the invalid-TOML conformance fixtures. Added tests/fixtures/answers-invalid/README.md documenting the validated shape (the three grader kinds and their keys) as the Phase 2 contract; the same table lives in scripts/answers.py's module docstring next to the code that enforces it. No plan deviations in Task 1.1.

## Outcome

_Written by `work-order close`. Empty until then._
