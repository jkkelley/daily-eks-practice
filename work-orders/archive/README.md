# Work-order archive

Written by `work-order.sh` the first time a ticket is archived into a year that had no
explainer yet. One level down only: what is inside each year is that year's own README.

A ticket arrives here two ways, and only these two:

- `work-order.sh close` - the work shipped. It refuses unless `gh` reports the pull
  request `MERGED` and it can read a merge commit, so every file it files here carries a
  `merge_sha` that exists in `main`.
- `work-order.sh cancel` - the work was abandoned. No branch, no PR, no merge commit;
  the `Outcome` block says why and what superseded it, if anything did.

Nothing here is edited, ever. A closed ticket that turns out to be wrong is reopened with
`work-order.sh reopen`, or it becomes a new ticket.

| Year | Archived in |
|---|---|
| [2026](2026/README.md) | Tickets archived during 2026 |

Active tickets, and the lifecycle a ticket passes through to get here, are one level up in
[../README.md](../README.md).
