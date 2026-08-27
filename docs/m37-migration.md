# M37 migration: `0.33.0` to `0.34.0`

M37 is an additive extension update. Back up the database, install the
`0.34.0` extension files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.34.0';
```

The update adds `pgreact.backtest()` and `pgreact.backtest_results()`. It does
not rewrite source tables or existing pg-react state. M34 comparison, M35
hypothetical changes, and M36 replay remain available.

There is no in-place downgrade. To roll back, restore a verified `0.33.0`
backup. Do not run an old extension script against a live `0.34.0` database.
