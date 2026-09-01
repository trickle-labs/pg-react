# Upgrade to pg-react 0.40.0

M43 upgrades the extension from `0.39.0` to `0.40.0`.

1. Back up the database.
2. Install the `0.40.0` library, control file, SQL files, and worker image.
3. Run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.40.0';
```

The adjacent upgrade is `0.39.0 -> 0.40.0`. Existing declarations, stored
digests, snapshots, comparison results, lifecycle state, work, and retention
state are not rewritten. M43 adds one read-only function and its role grant.

There is no in-place downgrade. Restore a verified `0.39.0` backup to roll
back. The qualification script checks a populated upgrade and rollback copy.
