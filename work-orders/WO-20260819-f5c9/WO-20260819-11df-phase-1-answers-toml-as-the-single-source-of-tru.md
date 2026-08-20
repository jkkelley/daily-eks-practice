---
{
  "id": "WO-20260819-11df",
  "slug": "phase-1-answers-toml-as-the-single-source-of-tru",
  "title": "Phase 1: answers TOML as the single source of truth",
  "type": "feature",
  "status": "ready",
  "priority": "p1",
  "created": "2026-08-19",
  "updated": "2026-08-19",
  "created_at": "2026-08-19T19:30:53-05:00",
  "parent": "WO-20260819-f5c9",
  "branch": null,
  "pr": null,
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


- [ ] `AC-H1` *(human)* pure passthrough mode reproduces the committed PRACTICE_ANSWERS.html byte for byte
- [ ] `AC-H2` *(human)* mixed mode regenerates the 03 block from TOML and leaves all eleven other blocks byte-identical
- [ ] `AC-H3` *(human)* every file in the invalid-TOML fixture set raises AnswersError with a message naming both the file and the problem
- [ ] `AC-H4` *(human)* the validated shape is documented where Phase 2 can implement against it: the three grader kinds command, file and prose, and the keys each one carries

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

## Outcome

_Written by `work-order close`. Empty until then._
