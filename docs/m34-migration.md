# M34 migration: `0.30.0` to `0.31.0`

> [!NOTE]
> Versioned `0.30.0 -> 0.31.0` migration record. It is not an RC or GA
> upgrade path. Use [`v1-upgrade.md`](v1-upgrade.md) for current guidance.

M34 is an additive read-only comparison release.

```text
0.30.0 -> 0.31.0
```

Take the normal backup and verify the package checksum first. Then install the
`0.31.0` extension files and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.31.0';
```

The update adds comparison functions only. It does not run a comparison,
deploy a declaration, refresh a rule, create work, or advance the frontier.
Afterward, run `pgreact.doctor()` and compare a proposal before deployment.

There is no in-place downgrade. Restore the verified `0.30.0` backup if a
rollback is required.
