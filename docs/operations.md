# Operate pg-react

[How-to guides](how-to/index.md) · [Troubleshooting](troubleshooting.md)

A useful operational habit is to ask three questions separately: is the policy state correct, is the worker healthy, and is durable work progressing? In the **0.46.0 core profile**, managed workers normally coordinate each configured database and execute eligible work in the background. Public views let you inspect that activity without reading or changing private catalogs, and stable rule names let you perform the common recovery operations without finding internal identifiers.

The examples use the first tutorial's `manual-review-required` rule. Replace that name with the authorized target you are investigating. Use an operator role for administrative actions, and collect a read-only baseline before deciding whether a mutation is needed.

## Establish a healthy baseline

```sql
SELECT pgreact.doctor();
SELECT pgreact_api.managed_status();
SELECT code, severity, blocking, target, message, hint
FROM pgreact.health
ORDER BY blocking DESC, severity, code, target;

SELECT pgreact.status('manual-review-required');
```

A healthy installation has no blocking health finding, a doctor state of `ready`, and a configured managed process reporting `ready` after its poll. Preserve the full finding when something is wrong: its code, target, message, hint, and details explain more than the top-level state alone. `pgreact.run()` is useful when you deliberately want coordination, but it can create work and should not be added to an otherwise read-only incident or upgrade snapshot.

## Inspect a backlog or failed work

Start with durable work and its attempts. This query keeps the public work identity and the attempt's complete status and error details together, so a retry wait does not look like an unexplained missing task.

```sql
SELECT w.kind, w.name, w.version, w.work_id, w.state,
       w.claimable, w.updated_at,
       a.attempt_no, a.status AS attempt_status,
       a.error_code, a.error_message
FROM pgreact.work AS w
LEFT JOIN pgreact.attempts AS a
  ON w.kind = 'rule' AND a.episode_id::text = w.work_id
WHERE w.name = 'manual-review-required'
ORDER BY w.updated_at DESC NULLS LAST, w.work_id, a.attempt_no;
```

The join relates rule work to rule attempts; other work families have their own public projections. `claimable` is an observation at query time, not a reservation. `updated_at` is an activity timestamp and may be `NULL` for pre-0.43.3 history whose transition time was not recorded. Neither field proves that an external system received an effect.

| Observation | What to inspect next |
| --- | --- |
| No match and no work | Query the condition relation, applicability, and target status. |
| Active match but no new activation work | Check bootstrap behavior and whether the key is in an existing generation. |
| Pending work with no attempts | Check managed status, blocking findings, permissions, and claim eligibility. |
| `LEASED` work | Determine whether the owning worker is still executing before considering lease recovery. |
| `RETRY_WAIT` | Read the failed attempt and configured backoff; allow the due retry to become eligible. |
| Terminal failure | Repair the cause, assess replay safety, and requeue deliberately. |
| `COMPLETED` work but an unexpected application result | Inspect the consequence's application writes and its idempotency model. |

## Diagnose a worker or backlog

Check the worker configuration in the affected database, not only in the server you happen to be connected to. The database must be listed, the role must be able to connect and perform worker operations, and both libraries must have been preloaded at PostgreSQL startup.

```sql
SELECT current_database();
SHOW shared_preload_libraries;
SHOW pg_react.databases;
SHOW pg_react.worker_role;
SHOW pg_react.poll_interval_ms;
SHOW pg_react.batch_size;
SHOW pg_react.max_pending_jobs;
SELECT pgreact_api.managed_status();
```

Correct the named prerequisite, then restart PostgreSQL if you changed preload libraries, the database list, or the worker role. Poll interval, batch size, and the pending threshold are reloadable. At the pending-job threshold, the managed worker continues draining existing work while delaying additional coordination, so raising the threshold without understanding slow or failing consequences may only increase the backlog. Use the [configuration reference](reference/configuration.md) for exact bounds.

If managed status reports `state = error`, read its `detail`. A blocked coordination result can coexist with progress on independent work. Repair the reported barrier or source, then verify that a later successful cycle clears the error and that the relevant work continues progressing. Starting a second coordinator for the same database is not a recovery procedure.

## Requeue a terminal rule episode

Read the attempts first and repair the consequence, dependency, or permission that caused the failure. A terminal item is different from a retry that is already waiting for its scheduled backoff. Requeueing can execute the effect again, so establish that the database effect is idempotent and that any external consumer will deduplicate the stable delivery identity.

Identify the exact terminal episode in the public work view. A work ID identifies one execution episode; it is different from the order's business key, even if both happen to be numbers. Inspect the query result and its corresponding attempts before choosing an item:

```sql
SELECT w.work_id, w.state, w.updated_at
FROM pgreact.work AS w
WHERE w.kind = 'rule'
  AND w.name = 'manual-review-required'
  AND w.state IN ('FAILED', 'CANCELLED', 'WITHDRAWN')
ORDER BY w.updated_at DESC NULLS LAST, w.work_id;
```

In `psql`, enter the selected public work ID at the prompt, then requeue it together with its rule name:

```sql
\prompt 'Public work ID to requeue: ' failed_work_id
SELECT pgreact.requeue_episode('manual-review-required', :'failed_work_id');
```

The alternative numeric call is `pgreact.requeue_episode(episode_id::bigint)`, where `episode_id` is the same public work ID. Do not substitute the semantic key or a private UUID. After requeueing, observe the work and its new attempt, and verify the application result rather than stopping at a successful function return.

## Recover an expired lease

First establish that the previous worker can no longer execute the item and that its lease is actually expired. A slow live worker is not a stale worker. After resolving that uncertainty, sweep by the stable rule name:

```sql
SELECT pgreact.sweep_expired_leases('manual-review-required');
```

The function returns the number of recovered items and covers authorized `ACTIVE`, `PAUSED`, and `DRAINING` versions of that rule, including old work left by a replacement. A missing, ambiguous, or unauthorized name fails closed. Re-query health and work afterward, then confirm the item becomes pending or reaches its expected terminal state.

## Pause and resume one rule

A per-rule pause is useful during a controlled policy change, but it is not a global stop for the database worker. Inspect the rule and its work before pausing, and understand whether old work should drain or be cancelled as part of a replacement.

```sql
SELECT name, version, state
FROM pgreact.rules
WHERE name = 'manual-review-required';

SELECT pgreact.pause_rule('manual-review-required');
```

Before resuming, resolve drift and recovery findings and inspect the resulting state. Resume through the public operation, then verify both health and progress:

```sql
SELECT * FROM pgreact.health WHERE blocking;
SELECT pgreact.resume_rule('manual-review-required');
SELECT pgreact.status('manual-review-required');
```

For backup, restore, or package updates, stop the managed database worker using the [backup procedure](backup-restore.md#stop-managed-work). Pausing one rule does not stop every declaration or work family.

## Replace or remove a policy

Use [Changing policies safely](changing-policies.md) to compare and preview a replacement, including the old-work decision for executable command work. Prefer the ordinary reviewed declaration path for new code; UUID-oriented `pgreact.replace_rule` remains a compatibility interface with its own contract. Do not change a live condition or consequence underneath the recorded deployment and then treat the drift finding as routine noise.

To remove an ordinary target, first inspect its status and work, decide how existing work should be handled, and call `pgreact.remove(name, preconditions)` with the required plan. For a small disposable example with no blocking work, `SELECT pgreact.remove('manual-review-required');` removes the named deployment. Keep application-table cleanup separate: removing a rule is not an instruction to erase the business data or the tasks it previously created.

## Recover after drift or restore

Inspect `SOURCE_DRIFT`, `CONSEQUENCE_DRIFT`, and `BARRIER` findings before taking action. Restore the exact expected public object or deploy an authorized replacement. Reconciliation is a deliberate mutation, so use it only after the worker is stopped where required and the intended recovery result is understood.

For a standalone rule whose recovery plan calls for current-state reconciliation, the names-first form is:

```sql
SELECT pgreact.reconcile_rule('manual-review-required', 'STATE_ONLY');
```

`STATE_ONLY` restores current rule state without requesting missing lifecycle effects. `pgreact.prepare_recovery()` establishes broader recovery barriers and is not a routine health check. Policy sets, derivation programs, temporal declarations, and other advanced families require their own owning recovery operations; reconciling one rule does not complete a database recovery. Follow [Backup and restore](backup-restore.md), then verify doctor, health, target state, work, attempts, and application results before resuming.

## Retain evidence deliberately

Retention is opt-in and uses the public `pgreact_api.retention_configure`, `retention_apply`, and `retention_remove` operations. Choose a retention policy around the evidence you need for support, audit, and recovery, and test it against a verified backup before applying it. Deleted evidence can affect how much of a later explanation is available; it does not become current truth again merely because a retained snapshot describes it.

The [advanced learning guide](explanation/advanced-use.md) explains the relationship between current evidence, causal paths, and retained snapshots. Consult the exact retention contract indexed in [History](history.md) before changing a production retention policy.
