---
{
  "id": "WO-20260820-0425",
  "slug": "compass-md-staleness-check-in-the-static-suite",
  "title": "COMPASS.md staleness check in the static suite",
  "type": "chore",
  "status": "draft",
  "priority": "p2",
  "created": "2026-08-20",
  "updated": "2026-08-20",
  "created_at": "2026-08-20T19:08:24-05:00",
  "parent": null,
  "branch": null,
  "pr": null,
  "merge_sha": null,
  "closed": null,
  "approval": null,
  "evidence": null,
  "surfaces": [],
  "depends_on": [],
  "blocks": []
}
---

# WO-20260820-0425 - COMPASS.md staleness check in the static suite

## Problem

CLAUDE.md now says COMPASS.md staleness is a defect of the same severity as a failing test, but nothing checks it, so the only thing standing between the north star and a lie is that every future agent remembers a rule. The failure mode is silent: a pointer row keeps naming a path that moved months ago and a reader trusts it. This adds the mechanical check the rule implies. It also enforces the 100-line cap from the project-scaffold standard, which is what stops COMPASS drifting from a router into a second CONTEXT_STATE.

## Scope

**In**

- a checker at tests/compass-check.sh, wired into 'make -f Makefile.test test'
- every path in a COMPASS.md pointer row must exist; brace expansions like terraform/modules/{vpc,eks} and globs like scenarios/answers/*.toml must be expanded before the check, not reported as missing
- the 100-line hard cap

**Out - non-goals**

- checking that the DIAGRAM matches reality - no mechanical check can do that, and pretending otherwise is worse than admitting the gap
- any change to COMPASS.md's content; this ticket only adds the guard
- a skill - a rule plus a checker is the right weight for this, and a skill would add a maintenance surface for something that fires a few times a year

## Acceptance criteria


- [ ] `AC-H1` *(human)* make -f Makefile.test test fails when a COMPASS.md pointer row names a path that does not exist
- [ ] `AC-H2` *(human)* it passes on the current COMPASS.md, including the brace-expansion and glob rows that a naive checker reports as missing
- [ ] `AC-H3` *(human)* it fails when COMPASS.md exceeds 100 lines

## Test plan

```sh
Write the failing test first: point a row at a deleted path and watch the suite go red, then implement. Verify the brace and glob rows specifically, because a naive implementation flags both and would be committed green only by deleting the rows it could not parse.
```

## Assumptions

_none_

## Open questions

_none_

## Notes

_Newest first. Appended only by `work-order note` - never by hand._

## Outcome

_Written by `work-order close`. Empty until then._
