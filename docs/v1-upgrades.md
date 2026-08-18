# Historical M4 upgrade record

> This file documents the old `0.1.1` transition. The current M33 runbook is
> [`v1-upgrade.md`](v1-upgrade.md).

The only supported catalog upgrade into v1 is pg-react `0.1.0` to `0.1.1`. The install script and `0.1.0--0.1.1` migration are immutable release artifacts. Skipped versions, downgrades, hand-edited catalogs, and upgrades that also change PostgreSQL, pg_trickle, OS, or architecture are unsupported.

## Preflight

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;
SELECT * FROM pgreact.health_check();
```

Before proceeding:

- Confirm PostgreSQL 18.3, pg_trickle 0.81.0, and pg-react 0.1.0. The protocol compatibility function is installed by 0.1.1 and is checked after upgrade.
- Resolve health errors and make a verified physical cluster backup using the [backup guide](v1-backup-restore.md).
- Stop all pg-react workers and refresh schedulers. This is the shortest supported 0.1.0 upgrade path because recovery barriers are introduced by 0.1.1.
- Install the `0.1.1` extension files from the verified release artifact on every database server.

## Upgrade the database

Run the extension upgrade by itself with stop-on-error behavior:

```sh
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION pg_react UPDATE TO '0.1.1'"
```

Reapply the explicit role grants from the [security guide](v1-security.md); `0.1.1` revokes the former `PUBLIC` access.

Then enter recovery and rebuild transient local identities. Run these statements in autocommit mode so the barriers are committed before reconciliation:

```sql
SELECT pgreact.prepare_recovery();
SELECT * FROM pgreact.rebuild_transient_metadata();
SELECT rule_name, rule_version_id FROM pgreact.rules ORDER BY rule_name;
```

For every listed version:

```sql
SELECT pgreact.reconcile_rule('RULE_VERSION_UUID'::uuid, 'STATE_ONLY');
SELECT pgreact.sweep_expired_leases('RULE_VERSION_UUID'::uuid);
```

Complete the gate before restarting workers:

```sql
SELECT extversion = '0.1.1' AS extension_ok
FROM pg_extension WHERE extname = 'pg_react';
SELECT pgreact.worker_protocol_compatible(1) AS worker_ok;
SELECT * FROM pgreact.health_check();
SELECT pgreact.metrics();
```

Require `extension_ok` and `worker_ok` to be true and no error health rows. Retain the backup until a normal refresh, claim, consequence, and inspection cycle completes.

Rolling replacement of protocol-1 worker processes is allowed only while `pgreact.worker_protocol_compatible(1)` remains true. A future protocol mismatch requires stopped claims and a coordinated extension/worker upgrade; it is not covered by v1.

If `ALTER EXTENSION` fails, its transaction rolls back. If a later verification fails, keep workers stopped, preserve the database for diagnosis, and follow the [troubleshooting guide](v1-troubleshooting.md); restore the verified backup rather than attempting a downgrade.
