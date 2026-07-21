# 11 - RDS day-2: connect, inspect, rotate

**Time:** ~45 min. **Needs:** cluster up with `enable_rds = true`, app deployed.

Ticket: "Quarterly security review: prove nobody can reach the practice DB from outside the VPC, rotate the app's DB password, and know the restore story."

## Tasks

1. From your laptop, try to connect to the RDS endpoint (`make output` → `rds_endpoint`). It must fail. Explain exactly which two settings make it fail.
2. From inside the cluster, connect properly: run a `postgres:16-alpine` pod and `psql` in using the `practice-db` secret values. Poke around `guestbook`.
3. Map the network path: pod → node ENI → DB security group rule. Find the exact SG rule that allows it and what it references (hint: not a CIDR).
4. In the RDS console: instance class, storage, single-AZ vs multi-AZ, backup retention. What did this repo trade away for cost, and what would you change for prod?
5. Rotate the password the hands-on way:
   - change the master password in RDS (console or CLI),
   - update the `practice-db` secret to match,
   - bounce the backend and prove the app still works.
     What breaks in what order if you do those steps backwards? (You may find out by accident. That's the lesson.)
6. Terraform drift check: you just changed the password outside terraform. Run `make plan` - what does it want to do, and why is that fine (or not) here?
7. Bonus: `guestbook` got a bad row (someone wrote SQL by hand, classic). Practise a surgical DELETE via psql - with a SELECT first, like you mean it.

## Success criteria (`make check N=11`)

- RDS instance is not publicly accessible.
- Backend pods are healthy and the app reads/writes the DB (post-rotation).
- The `practice-db` secret and the live DB password agree.
