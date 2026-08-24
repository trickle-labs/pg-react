# M20 upgrade

Install the `0.17.0` extension files, then run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.17.0';
```

The supported direct path is `0.16.0 -> 0.17.0`. Existing declarations are
unchanged. The populated executable path is `tests/m20-upgrade-before.sql`
followed by `tests/m20-upgrade-after.sql` through `tests/m20.sh complete`.
