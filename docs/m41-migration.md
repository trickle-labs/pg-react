# M41 migration

M41 upgrades the extension from `0.37.0` to `0.38.0`. Back up the database,
install the matching `0.38.0` extension files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.38.0';
```

The migration creates no tables and writes no retained explanation evidence.
It installs the bounded `causal_path` adapter and keeps ordinary explanation
and M40 `why_not` requests unchanged.

To roll back, stop clients, restore the verified `0.37.0` backup, install the
`0.37.0` files, and verify:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_react';
```

The expected value after restore is `0.37.0`. Do not attempt an in-place
downgrade.
