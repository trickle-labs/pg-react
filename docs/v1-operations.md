# v1 operations

Every procedure follows the same order:

```text
observe -> diagnose -> repair the prerequisite -> invoke the public operation -> verify
```

Use public SQL only. Never update a `pgreact_internal` or `pgreact_runtime`
table.

| Situation | Observe | Public repair |
| --- | --- | --- |
| Coordinator is blocked | `SELECT * FROM pgreact.health` | repair the reported source, action, or recovery prerequisite, then `SELECT pgreact.run()` |
| Rule replacement | `pgreact.status('name')`, `pgreact.preview(...)` | deploy the fresh named declaration with the recorded preview |
| Failed work | `pgreact.work`, `pgreact.attempts`, `pgreact.explain('name')` | repair the action, then use the documented requeue operation |
| Source/action drift | `pgreact.health`, `pgreact.explain('name')` | restore the exact object or deploy an explicit replacement |
| Restart or restore | `pgreact.health`, extension version, worker status | enter the recovery barrier, reconcile, verify, then resume workers |
| Retention | `pgreact.work`, `pgreact.attempts` | run the public retention operation after its retention policy check |

Installation, roles, backup/restore, upgrade, troubleshooting, and removal
are separate runbooks so an operator can follow the relevant task without
learning private catalog details.

## Runbook index

The packaged qualification record covers these exact tasks:

1. install the extension;
2. configure the four least-privilege roles;
3. make the first production deployment;
4. replace a rule safely;
5. replace a policy set;
6. diagnose a paused or blocked rule;
7. diagnose an action failure;
8. handle retry exhaustion;
9. repair source drift;
10. repair action drift;
11. repair applicability drift;
12. recover after a database restart;
13. recover from a failed extension upgrade;
14. restore a physical backup;
15. promote a supported standby;
16. reconcile an explicit recovery barrier;
17. apply retention;
18. remove the extension where the support matrix allows it.

Each task uses only public SQL and records the same
`observe -> diagnose -> repair prerequisite -> invoke -> verify` transcript.
