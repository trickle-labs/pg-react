# M39 migration: `0.35.0` to `0.36.0`

M39 is a qualification-only extension update. Back up the database, install
the `0.36.0` files, and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.36.0';
```

The update keeps the M34, M35, M36, M37, and M38 functions and their return
types. It adds no table, no option, and no durable evidence store. The
`0.35.0 -> 0.36.0` migration is intentionally metadata-only.

There is no in-place downgrade. To roll back, restore a verified `0.35.0`
backup and use the `0.35.0` extension files. Do not run an old extension script
against a live `0.36.0` database.
