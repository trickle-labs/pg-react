# M33 migration: `0.29.0` to `0.30.0`

> [!NOTE]
> Historical `0.29.0 -> 0.30.0` migration record. It is not an RC or GA
> upgrade path. Use [`v1-upgrade.md`](v1-upgrade.md) for current guidance.

M33 is a compatibility and qualification release. It does not add a new rule
language or change lifecycle meaning.

```text
0.29.0 -> 0.30.0
```

Before upgrading, stop workers, verify the candidate checksum, take a tested
backup, and resolve blocking `pgreact.health` findings. Install the exact
`0.30.0` extension files and run:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.30.0';
```

The update must not execute business actions, create outbox effects, activate
policy gating, or invent lifecycle transitions. Afterward run `doctor()`,
inspect the ordinary views, and perform the explicit reconciliation operation
only if a recovery finding requires it.

There is no in-place downgrade. Restore the verified pre-upgrade backup and
reconcile before allowing new work.
