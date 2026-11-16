# Back up and restore pg-react

[How-to guides](how-to/index.md) · [Operations](operations.md)

A useful pg-react backup preserves more than source tables. It needs the PostgreSQL state, the exact extension and runtime artifacts, the configuration that starts managed workers, the declarations that define your policies, and the deduplication state of any external consumers. This guide describes the recovery boundary for the **0.46.0 core profile** and the checks to perform before allowing restored work to execute.

## Keep the recovery assets together

Retain the PostgreSQL, pg_trickle, and pg-react package identities and checksums alongside your backup and required WAL. Record preload settings, the configured database list, worker-role configuration, role mappings, and the recovery target or timeline. Keep version-controlled declaration specifications, condition views, consequence functions, and application/reference data so that you can reconstruct the intended policy rather than relying on private catalog rows as a portable configuration format.

External consumers need their own durable deduplication state and recovery position. A delivery may have reached a remote system before the PostgreSQL recovery point you choose, so restoring the database can make that delivery eligible again. The external boundary remains at least once after recovery, even when all local database state is restored consistently.

## Stop managed work

Record the effective worker configuration and current work before a planned restore or upgrade:

```sql
SHOW pg_react.databases;
SELECT pgreact_api.managed_status();
SELECT kind, name, version, work_id, state, claimable, updated_at
FROM pgreact.work
ORDER BY kind, name, work_id;
```

Remove the affected database from `pg_react.databases` and restart PostgreSQL. To stop all configured pg-react workers through an administrator-managed setting, the SQL form is:

```sql
ALTER SYSTEM SET pg_react.databases = '';
```

The setting requires a PostgreSQL restart; a reload is insufficient. If your deployment manages configuration through an image, operator, or external configuration system, change that authoritative configuration instead. Stop any external compatibility worker or delivery process as required by the recovery plan, and verify that the managed process is absent before proceeding. A per-rule pause does not stop every worker or declaration family.

For a planned stopped-cluster backup, quiesce application writes while PostgreSQL is still running with managed workers disabled, then capture the read-only baseline below. This keeps source and application rows stable between the baseline and the backup. Next, stop PostgreSQL through your normal service-management process and copy its data using your backup procedure. Restart PostgreSQL with managed workers still disabled before executing later SQL verification or extension-update commands. Retain the recorded configuration so you can restore the intended database list later.

## Capture a read-only baseline

Store full results for the policies and application outcomes that matter, not only counts. The following queries establish an extension-side baseline without coordinating new work:

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_react', 'pg_trickle')
ORDER BY extname;
SELECT pgreact.doctor();
SELECT * FROM pgreact.health ORDER BY blocking DESC, code, target;
SELECT * FROM pgreact.rules ORDER BY name, version;
SELECT * FROM pgreact.matches ORDER BY name, activation_id;
SELECT * FROM pgreact.decisions ORDER BY name, version_no;
SELECT * FROM pgreact.policy_sets ORDER BY name;
SELECT * FROM pgreact.work ORDER BY kind, name, work_id;
SELECT execution_id, episode_id, attempt_no, status, error_code, error_message
FROM pgreact.attempts ORDER BY execution_id;
```

Also capture the application result tables and the source or target identities needed for your recovery test. Generated timestamps and new post-recovery activity may legitimately differ, so decide in advance which durable facts, lifecycle identities, and effects must agree.

## Restore physical state or promote a standby

Restore the complete PostgreSQL cluster with the matching binaries, extension SQL, configuration, and WAL using your established physical-backup or point-in-time recovery procedure. Keep managed work disabled while PostgreSQL recovery or standby promotion is in progress. After the server is primary, verify `pg_is_in_recovery()` is false, confirm both extension versions, and inspect doctor, health, managed status, and the saved public-state baseline.

A recovery barrier is a request for explicit reconciliation, not an instruction to delete a catalog row. When the recovery plan or diagnostics requires it, establish recovery barriers through `pgreact.prepare_recovery()` and reconcile each affected object through its owning public operation. For a standalone rule, the names-first current-state repair is:

```sql
SELECT pgreact.reconcile_rule('manual-review-required', 'STATE_ONLY');
```

`STATE_ONLY` repairs current rule state without requesting missing lifecycle effects. `prepare_recovery()` affects a broader scope, so invoking it and repairing one rule does not complete the recovery of policy sets, derivation programs, or temporal declarations. Use each adopted family's exact recovery contract, indexed in the [advanced API guide](reference/advanced-apis.md), and leave work stopped until all required targets are reconciled and understood.

## Distinguish crash restart from explicit recovery

After a routine process or server crash, PostgreSQL restarts configured managed workers and durable work remains available. First inspect health, work, and attempts, and allow ordinary restart recovery to complete. Do not introduce broad recovery barriers with `prepare_recovery()` merely because a process restarted; use it when diagnostics or the tested recovery plan calls for explicit reconciliation.

For an expired lease, prove that the former worker can no longer execute the item before sweeping it. Then use the names-first lease recovery procedure in [Operations](operations.md#recover-an-expired-lease). A worker that is slow but still alive is a different situation from an abandoned lease.

## Rebuild logically from application data and declarations

A portable logical recovery plan restores application and reference data, recreates condition and consequence definitions, and rebuilds policies from retained declaration specifications through public APIs. It does not treat a dump of live `pgreact_internal` or `pgreact_runtime` tables as a supported portable reconstruction. Validate the declaration replay against the target package and inspect its bootstrap behavior before resuming work.

A new deployment with `SEED_CURRENT` seeds current matches rather than replaying every historical activation. If your application requires reconstruction of review tasks or other effects, plan and test that migration explicitly. Preserve external deduplication state independently, since rebuilding a declaration does not tell a remote consumer which deliveries it has already accepted.

## Verify before resuming

Re-run the read-only baseline and inspect every critical target with `pgreact.status(name)` and the relevant public views. Resolve unexpected drift, barriers, missing declarations, or mismatched extension versions while workers are still stopped. Restore the intended managed database list and worker role, restart PostgreSQL as required, then observe new work and attempts and verify the application outcomes.

For rollback from the qualified 0.46.0 update, restore the verified 0.45.0 backup with its matching runtime and dependency artifacts. There is no supported in-place downgrade in this procedure. Rehearse the complete restore on a disposable copy before relying on the backup for an incident.
