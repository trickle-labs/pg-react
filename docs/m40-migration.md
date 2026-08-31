# M40 migration

The migration is from `0.36.0` to `0.37.0`. Back up the database before
upgrading. Install the `0.37.0` extension files,
then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.37.0';
```

The update adds functions and replaces the body of the public three-argument
`pgreact.explain` wrapper. Calls without `why_not`, and calls with
`why_not: false`, continue through the earlier implementation.

There is no in-place downgrade. To roll back, stop the application, restore a
verified `0.36.0` backup, and confirm:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'pg_react';
```

The expected value after restore is `0.36.0`. M40 does not change source rows,
existing runtime state, work, or external effects during an explanation call.
