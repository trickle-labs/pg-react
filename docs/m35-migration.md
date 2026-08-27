# M35 migration: `0.31.0` to `0.32.0`

Back up the database and verify the package checksum before upgrading.

```text
0.31.0 -> 0.32.0
```

Install the `0.32.0` extension files and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.32.0';
```

The update adds the four-argument hypothetical comparison overloads and their
finding registry. It does not run a simulation, write a source table, deploy a
declaration, create work, or advance the frontier. Run `pgreact.doctor()` after
the upgrade, then review a change through `pgreact.compare()`.

There is no in-place downgrade. Restore the verified `0.31.0` backup if you
need to roll back.
