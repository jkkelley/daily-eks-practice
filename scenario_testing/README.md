# scenario_testing/

Outcome checks for the daily drills - this is how you grade yourself.

```bash
make check N=03        # did I actually finish scenario 03?
```

`check.sh` inspects the **live cluster** (kubectl, plus aws/gh CLI where relevant) against each scenario's success criteria.
It is read-only: it never creates, edits, or deletes anything (the one exception is scenario 05, which runs a throwaway `--rm` busybox pod to prove DNS works).
A failing check tells you what is missing; the scenario card tells you how to get there; the sealed answer key (`make serve-answers`) tells you exactly how, but only open it after trying.

These checks are for the human doing the drills.
Repo-level validation - terraform fmt/validate, the ministack mock-AWS plan, helm lint in Podman - lives in `tests/` and `Makefile.test`, costs $0, and needs no cluster.

## First-pass workflow for an untested scenario card

Cards get written before anyone actually drills them, so the first real run through a card is also a proofread pass.
Use this workflow so the habit doesn't need re-explaining to the next agent on the next card.

1. Branch as `practice/scenario-N` off `main` before starting.
2. Work the tasks in order, running the real commands against the live cluster.
   If a task's wording is ambiguous about mechanism (kubectl vs console) or target (namespace, resource name), fix the card in place - match the specificity level scenario 01/02 already use (name the tool, name the resource, don't hand over the exact command).
3. Some tasks require flipping a committed default on to exercise the drill (an image tag, an HPA toggle, a replica count).
   That is expected - `CLAUDE.md` bans pre-solved defaults, so the flip only ever lives on the practice branch, never on `main`.
   Flip it, test it, then flip it back to the `main` default before the branch is done - commit the flip and the flip-back as separate small commits (`test: scenario-N-questionM, flip X to Y` / `... flipped back`) so the history shows the exercise happened without polluting the final diff.
4. If a wording fix changes what the task is actually asking (not just clarity), update `PRACTICE_ANSWERS.html` and `scenario_testing/check.sh` to match - see the repo's Definition of Done in `CLAUDE.md`.
5. The PR that comes out of a first-pass run should net out to: card wording fixes, any check.sh/answers updates from #4, and nothing else - no stray toggled defaults.
