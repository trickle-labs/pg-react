# Upgrade to pg-react 0.39.0

M42 upgrades the extension from `0.38.0` to `0.39.0`.

1. Back up the database.
2. Install the `0.39.0` library, control file, SQL files, and worker.
3. Run the upgrade by itself:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.39.0';
```

Existing declarations keep their normalized form and store no snapshots unless
they add `evidence_snapshot`. Existing M41 explanations keep their output.
Snapshots use ordinary PostgreSQL tables, transactions, backups, and restore.

To roll back, stop clients, restore the verified `0.38.0` backup, install the
`0.38.0` files, and check:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_react';
```

The expected value after restore is `0.38.0`. Do not use an in-place downgrade.
