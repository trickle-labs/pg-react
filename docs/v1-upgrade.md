# v1 upgrade runbook

`0.38.0` is the current qualified release. Its documented adjacent update is
`0.37.0 -> 0.38.0`. Use only source and target pairs that have a versioned
migration script and automated qualification.

The managed worker coordinates extension versions `0.31.0` through `0.38.0`,
`1.0.0-rc.N`, and `1.0.0`.

Every procedure follows:

```text
observe -> diagnose -> repair prerequisite -> invoke public operation -> verify
```

## Upgrade policy

- Install only a published package/image with verified checksum.
- Use only a source/target pair named by that release's qualification record.
- Stop managed workers before package or extension changes.
- Take and test a physical backup before the update.
- The extension update itself must not run business work, consequences, or
  external delivery.
- Pre-resume verification is read-only and never calls `pgreact.run()`.
- Reconciliation, when required, is a separate intentional repair after
  read-only verification.
- Rollback is restore-based; there is no supported in-place downgrade.

## 1. Observe the source system

1. **Observe**

   ```sql
   SELECT current_setting('server_version') AS postgres_version;
   SELECT extname, extversion
   FROM pg_extension
   WHERE extname IN ('pg_trickle', 'pg_react')
   ORDER BY extname;
   SHOW shared_preload_libraries;
   SHOW pg_react.databases;
   SELECT pgreact_api.managed_status();
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, severity, code, target;
   ```

2. **Diagnose** — verify the source version is explicitly qualified for the
   intended target and resolve every blocking environment, drift,
   applicability, work, or recovery finding.
3. **Repair prerequisite** — repair public dependencies and confirm the exact
   target artifact, migration, support tuple, checksum, and rollback backup
   from the release record.
4. **Invoke public operation** — none yet; observation is read-only.
5. **Verify** — archive the transcript with the change record.

## 2. Stop managed workers and back up

There is no global SQL pause façade.

1. **Observe**

   ```sql
   SHOW pg_react.databases;
   SELECT pgreact_api.managed_status();
   SELECT * FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   ```

2. **Diagnose** — decide whether safe work should drain and record any
   at-least-once external delivery exposure.
3. **Repair prerequisite** — make consumers idempotent and resolve terminal
   work that must not be carried into the update.
4. **Invoke public operation** — remove the database from
   `pg_react.databases`, restart PostgreSQL, and take/test the physical backup.
   To stop all configured database workers:

   ```sql
   ALTER SYSTEM SET pg_react.databases = '';
   ```

5. **Verify**

   ```sql
   SHOW pg_react.databases;
   SELECT pgreact_api.managed_status();
   ```

The managed process must be absent before package or extension files change.

## 3. Capture the read-only baseline

1. **Observe**

   ```sql
   SELECT * FROM pgreact.rules ORDER BY name, version;
   SELECT * FROM pgreact.matches ORDER BY name, activation_id;
   SELECT * FROM pgreact.decisions ORDER BY name, version_no;
   SELECT * FROM pgreact.policy_sets ORDER BY name;
   SELECT kind, name, version, work_id, state, claimable, updated_at
   FROM pgreact.work
   ORDER BY kind, name, work_id;
   SELECT execution_id, episode_id, attempt_no, started_at, finished_at,
          status, error_code, error_message, event_kind, name
   FROM pgreact.attempts
   ORDER BY execution_id;
   ```

2. **Diagnose** — identify the durable state and critical targets that must
   agree after the update.
3. **Repair prerequisite** — stop if the baseline is already blocked or
   unexplained.
4. **Invoke public operation** — none; these queries are read-only.
5. **Verify** — save complete output, not only row counts.

## 4. Apply only a qualified update

1. **Observe** — inspect the release's exact migration files, package checksum,
   source/target test result, and rollback instructions.
2. **Diagnose** — if the release does not explicitly qualify the installed
   source version, there is no supported path.
3. **Repair prerequisite** — install the exact target files while workers
   remain stopped.
4. **Invoke public operation** — run only the exact extension-update command
   published with the qualified target release:

   ```sql
   ALTER EXTENSION pg_react UPDATE TO '1.0.0-rc.1';
   ```

5. **Verify** — confirm the command completed without invoking user
   consequences or creating external delivery.

## 5. Pre-resume read-only verification

1. **Observe**

   ```sql
   SELECT extname, extversion
   FROM pg_extension
   WHERE extname IN ('pg_trickle', 'pg_react')
   ORDER BY extname;
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, severity, code, target;
   SELECT * FROM pgreact.rules ORDER BY name, version;
   SELECT * FROM pgreact.matches ORDER BY name, activation_id;
   SELECT * FROM pgreact.decisions ORDER BY name, version_no;
   SELECT * FROM pgreact.policy_sets ORDER BY name;
   SELECT kind, name, version, work_id, state, claimable, updated_at
   FROM pgreact.work
   ORDER BY kind, name, work_id;
   SELECT execution_id, episode_id, attempt_no, started_at, finished_at,
          status, error_code, error_message, event_kind, name
   FROM pgreact.attempts
   ORDER BY execution_id;
   SELECT to_regprocedure(
     'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)');
   SELECT to_regprocedure(
     'pgreact.compare_results(pgreact_api.declaration,pgreact_api.target,jsonb)');
   ```

2. **Diagnose** — compare the full output with the saved baseline. New
   barriers must be explained by the qualified migration.
3. **Repair prerequisite** — if version, state, or public surface differs from
   the release record, keep workers stopped and restore or escalate.
4. **Invoke public operation** — none. In particular, do **not** call
   `pgreact.run()` as upgrade verification.
5. **Verify** — repeat until the read-only transcript is accepted.

## 6. Reconcile only when the qualified migration requires it

Reconciliation is an intentional mutation, separate from verification.

1. **Observe**

   ```sql
   SELECT * FROM pgreact.health
   WHERE details ->> 'source_code' = 'BARRIER' OR blocking;
   ```

2. **Diagnose** — identify each barrier and its source/consequence/key
   prerequisite.
3. **Repair prerequisite** — restore every public dependency while managed
   workers remain stopped.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.reconcile_rule(
     (SELECT rule_version_id
      FROM pgreact.rules
      WHERE name = '<affected-standalone-rule>'
      ORDER BY created_at DESC
      LIMIT 1),
     'STATE_ONLY');
   ```

   Call `pgreact.prepare_recovery()` first only when the qualified migration
   or recovery plan explicitly requires new recovery barriers. It creates
   barriers broadly; advanced declaration families require their owning public
   reconcile operation.
5. **Verify** — rerun the complete read-only verification section. Do not use
   `run()` to prove upgrade safety.

## 7. Resume and monitor

1. **Observe** — confirm read-only verification is clean and any required
   reconciliation is complete.
2. **Diagnose** — confirm the target runtime package supports its installed
   extension version and no blocker remains.
3. **Repair prerequisite** — restore the saved database list and worker role
   configuration.
4. **Invoke public operation**

   ```sql
   ALTER SYSTEM SET pg_react.databases = '<comma-separated-databases>';
   ```

   Restart PostgreSQL.
5. **Verify**

   ```sql
   SELECT pgreact_api.managed_status();
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health WHERE blocking;
   SELECT * FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   ```

Monitor attempts and external deduplication through the release's rollback
window.

## Rollback

1. **Observe** — preserve the failed-upgrade diagnostics and post-update
   storage state.
2. **Diagnose** — determine the last verified physical recovery point and
   account for external effects delivered after it.
3. **Repair prerequisite** — stop managed workers and select the matching
   PostgreSQL/pg_trickle/pg-react packages, configuration, backup, and WAL.
4. **Invoke public operation** — restore the verified physical backup/PITR
   target; do not attempt an in-place extension downgrade.
5. **Verify** — follow [Backup and restore](v1-backup-restore.md), including
   barriers, reconciliation, public-view verification, and at-least-once
   external-effect handling.
