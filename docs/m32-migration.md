# M32 migration: `0.28.0` to `0.29.0`

M32 is the direct upgrade from M31:

```text
0.28.0 -> 0.29.0
```

The package identity, control file, managed-worker version check, Docker
defaults, lockfile, and release workflow all use `0.29.0`.

## Before upgrading

1. Finish or record the M31 release qualification that applies to the source
   installation.
2. Take a normal PostgreSQL backup.
3. Preview the declarations that will be created or replaced.
4. Confirm that the role running the migration can resolve condition views and
   typed action functions.

## During the upgrade

Install the `0.29.0` extension files and run the normal PostgreSQL extension
update. The upgrade must preserve existing names, match history, policy scope,
durable work, and compatibility wrappers. It must not execute business work as
part of catalog migration.

After the extension update, use the one coordinator:

```sql
SELECT pgreact.run();
```

Then inspect `pgreact.rules`, `pgreact.matches`, `pgreact.work`, and
`pgreact.health`. A blocked finding is safer than silently treating an
incompatible source as empty.

## Rollback

Do not downgrade extension files in place. Roll back by restoring the backup or
the tested infrastructure image, then reconcile before allowing new work.
Rollback execution evidence is a release gate and is not claimed by this
documentation-only lane.
