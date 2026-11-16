# Upgrade the core extension

[How-to guides](how-to/index.md) · [Backup and restore](backup-restore.md)

This procedure covers the qualified adjacent core upgrade **0.45.0 → 0.46.0**. It changes installed extension behavior, not just a policy declaration, so managed work must be stopped and the rollback backup must be verified first. The repository also includes 0.46.1 and 0.46.2 maintenance SQL and separately versioned integration releases; their presence does not make every source-to-target pair part of this qualified procedure. Check [Versions and release identity](reference/release-identity.md) before choosing a target.

## 1. Confirm the source and target

Run these checks in every affected database and retain the results with the change record:

```sql
SELECT current_setting('server_version') AS postgres_version;
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;
SHOW shared_preload_libraries;
SHOW pg_react.databases;
SELECT pgreact_api.managed_status();
SELECT pgreact.doctor();
SELECT * FROM pgreact.health ORDER BY blocking DESC, code, target;
```

The source for this procedure is pg-react `0.45.0`; the target profile is PostgreSQL `18.3`, pg_trickle `0.108.0`, and pg-react `0.46.0`. Obtain the exact target artifacts and checksums from the [0.46.0 release](https://github.com/trickle-labs/pg-react/releases/tag/v0.46.0) and read its [migration record](v0.46.0-migration.md). If the installed source or dependency tuple differs, choose a separately qualified migration instead of applying this command by analogy.

## 2. Stop workers and make the rollback concrete

Use [Stop managed work](backup-restore.md#stop-managed-work) to remove the affected database from the worker list and restart PostgreSQL, and stop external compatibility workers. Quiesce application writes while PostgreSQL is still running with those workers disabled, then capture the [read-only baseline](backup-restore.md#capture-a-read-only-baseline) for declarations, matches, decisions, policy sets, work, attempts, and important application results. Do not call `pgreact.run()` while recording it; that would introduce new coordinated work into the verification step.

Next, stop PostgreSQL and take the verified stopped-cluster physical backup described in your deployment's recovery procedure. Retain the matching 0.45.0 artifact, configuration, roles, and external deduplication position so rollback is a restorable state rather than an assumed inverse SQL operation. Install the target files while the server is stopped as required by your package procedure, then start PostgreSQL with managed workers still disabled before applying the SQL update in the next step.

## 3. Install the target files and apply the update

Install the verified 0.46.0 extension files alongside the existing 0.45.0 files while workers remain stopped. Configure the target runtime's trigger CDC, disabled pg_trickle scheduler, explicit pg-react coordination, and `READ COMMITTED` isolation as recorded in the [support matrix](support-matrix.md). In each affected database, run the explicit target update:

```sql
ALTER EXTENSION pg_react UPDATE TO '0.46.0';
```

Changing a container image or `PG_REACT_INIT_VERSION` does not perform this update for an existing database. The initializer is for a fresh data directory. Likewise, a plain `ALTER EXTENSION pg_react UPDATE` follows the installed default rather than documenting the target you intended, so use the explicit version in this procedure.

## 4. Verify before allowing work

Recheck versions, settings, health, and the full saved public state while the worker remains disabled:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;
SHOW pg_trickle.cdc_mode;
SHOW pg_trickle.enabled;
SHOW pg_trickle.differential_max_change_ratio;
SHOW default_transaction_isolation;
SELECT pgreact.doctor();
SELECT * FROM pgreact.health ORDER BY blocking DESC, code, target;
SELECT kind, name, version, work_id, state, claimable, updated_at
FROM pgreact.work ORDER BY kind, name, work_id;
```

Compare the complete declaration, lifecycle, work, and application snapshots with the baseline. Some old agenda rows may have `updated_at = NULL` because their transition time was not historically recorded; do not manufacture a timestamp or interpret it as newly created work. Keep workers stopped if a version, barrier, source identity, or critical outcome differs from the migration's expected result.

Reconciliation, if required by the migration or recovery findings, is a separate intentional repair after this read-only verification. Use the owning public operation and the [recovery procedure](backup-restore.md), then verify again. Updating the extension should not be used as a way to execute business consequences.

## 5. Resume and monitor

Restore the intended `pg_react.databases` and worker-role configuration and restart PostgreSQL where required. Check managed status after its first poll, then inspect work, attempts, and the application outcomes that depend on the upgraded system. Existing JSON-preconditions calls and specialized compatibility APIs remain available within their documented boundaries.

If verification fails, restore the verified backup and its matching artifacts. Do not mix extension SQL, runtime binaries, or pg_trickle versions across a rollback, and do not attempt an unqualified in-place downgrade. [Backup and restore](backup-restore.md) describes the evidence to retain and the external-delivery implications.
