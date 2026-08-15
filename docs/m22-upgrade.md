# M22 upgrade

Install the `0.19.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.19.0';
```

The supported direct path is `0.18.0 -> 0.19.0`. The migration creates the
provenance catalog, installs maintenance triggers, backfills existing supports,
and leaves the M21 retention policy and current derived truth unchanged.
The populated executable path is `tests/m22-upgrade-before.sql` followed by
`tests/m22-upgrade-after.sql` through `tests/m22.sh complete`.
