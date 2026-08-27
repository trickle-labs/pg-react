# M36 migration: `0.32.0` to `0.33.0`

Back up the database and verify the package checksum before upgrading.

```text
0.32.0 -> 0.33.0
```

Install the `0.33.0` extension files and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.33.0';
```

The update adds the read-only `pgreact.replay()` and
`pgreact.replay_results()` functions. It does not run a replay, read historical
source rows, deploy a declaration, create work, or advance a frontier.

There is no in-place downgrade. Restore the verified `0.32.0` backup if you
need to roll back.
