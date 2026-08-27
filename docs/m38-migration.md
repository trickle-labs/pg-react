# M38 migration: `0.34.0` to `0.35.0`

M38 is an additive extension update. Back up the database, install the
`0.35.0` extension files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.35.0';
```

The update keeps the M34, M35, M36, and M37 functions. It adds opt-in
`why_changed` evidence to their existing result JSON. It adds no table and does
not change a relational return type.

There is no in-place downgrade. To roll back, restore a verified `0.34.0`
backup. Do not run an old extension script against a live `0.35.0` database.
