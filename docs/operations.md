# Operations

The current release is pg-react `0.43.3`. PostgreSQL-managed workers normally
poll each configured database. A deliberate cycle is useful in a tutorial or
operator check:

```sql
SELECT pgreact.run();
SELECT pgreact.status('review-orders');
SELECT pgreact.explain('review-orders');
```

Use stable names for normal recovery. The lease sweep resolves every
authorized `ACTIVE`, `PAUSED`, and `DRAINING` version for the rule name:

```sql
SELECT pgreact.sweep_expired_leases('review-orders');
SELECT pgreact.reconcile_rule('review-orders', 'STATE_ONLY');
SELECT pgreact.requeue_episode('review-orders', '42');
```

Requeue only terminal work after inspecting it. External effects are at least
once, so consumers must deduplicate by a stable idempotency key. A missing,
ambiguous, changed, or unauthorized name fails closed without exposing a
private identifier.

## Diagnose a worker or backlog

Check the managed process, blocking findings, and work states together:

```sql
SELECT pgreact_api.managed_status();
SELECT * FROM pgreact.health ORDER BY blocking DESC, severity, code;
SELECT kind, name, work_id, state, claimable, updated_at
FROM pgreact.work
ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
```

`claimable` is advisory: another transaction can claim work after the read.
For pre-0.43.3 agenda rows, `updated_at` can be NULL because the historical
transition time was not recorded.

If the worker is absent or unhealthy, check `shared_preload_libraries`,
`pg_react.databases`, `pg_react.worker_role`, and the worker role's database
privileges. Restart PostgreSQL after correcting a preload, database-list, or
worker-role setting. Do not start a second coordinator for the same database.

For `LEASED` work, confirm that the worker no longer runs before sweeping the
expired lease. The name sweep covers old draining versions as well as the
current version:

```sql
SELECT pgreact.sweep_expired_leases('<rule-name>');
```

For changed source, consequence, or dispatcher definitions, inspect the failed
attempt, repair through the authorized replacement workflow, and requeue only
after confirming that the external consumer deduplicates delivery:

```sql
SELECT pgreact.requeue_episode('<work-id>');
```

If managed status reports `state = error` with a blocked runtime detail,
repair the reported barrier or source and run the authorized reconciliation
path. A later successful cycle clears the managed error detail; job progress
made during a blocked coordination result remains visible in `pgreact.work`.

## Recover after drift or restore

Inspect `SOURCE_DRIFT`, `CONSEQUENCE_DRIFT`, and `BARRIER` findings before
repairing a source, consequence, permission, or recovery condition. Restore
the exact public object or deploy a reviewed replacement. Use
`pgreact.prepare_recovery()` and the documented reconcile operation only after
workers are stopped and the recovery plan is complete. Verify
`pgreact.doctor()`, `pgreact.health`, and the affected public state before
resuming workers.

For retention, configure and apply the public retention operations only after
testing a verified backup. Retention is irreversible except through restore.
