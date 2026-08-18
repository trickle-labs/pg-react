# v1 upgrade runbook

Supported direct paths are:

```text
0.26.0 -> 1.0.0-rc.N
0.26.0 -> 1.0.0
```

The qualification lane also checks the adjacent path
`0.27.0 -> 0.28.0 -> 0.29.0 -> 0.30.0 -> 1.0.0-rc.N`.

## Observe

Stop workers, verify the exact release checksum, confirm the support tuple,
and take a tested physical backup. Inspect `pgreact.health` and resolve
blocking findings before changing the extension.

## Upgrade

Install the candidate files and run only:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.30.0';
```

An extension update must not invoke user actions, create outbox effects,
activate policy scope, or fabricate lifecycle transitions. If reconciliation
is required, it establishes an explicit barrier and the operator runs the
documented reconciliation operation afterward.

## Verify

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_react';
SELECT * FROM pgreact.health;
SELECT * FROM pgreact.rules ORDER BY name;
SELECT pgreact.run();
```

Preserve valid durable state, including active and inactive matches,
generations, revisions, decisions, policy supports, work, attempts, outbox
rows, drift evidence, and recovery metadata. There is no in-place downgrade;
restore the verified backup instead.
