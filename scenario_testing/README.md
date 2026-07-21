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
