# v1 operations

> Historical record for the prepared v1 candidate. Use current
> [Operations](operations.md) for pg-react `0.43.0`.

This is the current production runbook for extension `0.42.0`. Use public SQL
only. Never update `pgreact_internal` or `pgreact_runtime`.

For grouped policy changes, follow the validate-preview-deploy workflow in
[the M53 package reference](m53-api-reference.md).

Every procedure follows:

```text
observe -> diagnose -> repair prerequisite -> invoke public operation -> verify
```

The PostgreSQL-managed runtime is primary. PostgreSQL starts one managed worker
for each database in `pg_react.databases`; it polls automatically and restarts
after a crash. `pg-reactd` is a compatibility path, not the normal runtime.

## Operational surfaces

| Classification | Surface | Purpose |
| --- | --- | --- |
| Ordinary | `pgreact.doctor()`, `pgreact.doctor(name)` | Environment-wide or target diagnostics |
| Ordinary | `pgreact.health` | Relational blocking and warning findings |
| Ordinary | `pgreact.status(name)` | Target state, including policy applicability state |
| Ordinary | `pgreact.explain(name, subject)` | Explain target or subject state; add `why_not` or `causal_path` for a bounded answer |
| Ordinary | `pgreact.run()` | Explicitly perform a coordination/execution cycle |
| Ordinary | `pgreact.rules`, `matches`, `decisions`, `policy_sets`, `work`, `attempts` | Current public state |
| Administrative | `pgreact_api.managed_status()` | Managed-worker configuration, heartbeat, state, and detail |
| Advanced | `pgreact.pause_rule(uuid\|text)`, `resume_rule(uuid\|text)` | Pause or resume one rule |
| Advanced | `pgreact.replace_rule(...)`, `remove_rule(uuid)` | Legacy rule-version management |
| Advanced | `pgreact.reconcile_rule(uuid, text)`, `prepare_recovery()` | Explicit recovery barriers and repair |
| Advanced | `pgreact.sweep_expired_leases(uuid)`, `requeue_episode(bigint)` | Lease and terminal-work repair |
| Advanced administrative | `pgreact_api.retention_configure/apply/remove` | Opt-in retention |

There is no generic retry, pause, or resume façade. Prefer a stable rule name
for the text overloads that exist. UUID-only operations obtain the UUID from a
public view.

## Establish the baseline

1. **Observe**

   ```sql
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, severity, code, target;
   SELECT pgreact_api.managed_status();
   SELECT * FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   ```

2. **Diagnose** — `doctor().state = 'ready'`, no blocking health row, and a
   managed process in `ready` state are healthy. A null process, `configured =
   false`, stale heartbeat, or `state = 'error'` needs runtime/configuration
   repair.
3. **Repair prerequisite** — repair the reported PostgreSQL, pg_trickle,
   preload, role, source, consequence, applicability, or recovery condition.
4. **Invoke public operation** — no mutation is required for a healthy
   baseline. Use `pgreact.run()` only when an explicit cycle is intended.
5. **Verify** — repeat the queries and record the result with the incident or
   change.

## Managed worker is absent or unhealthy

1. **Observe**

   ```sql
   SHOW shared_preload_libraries;
   SHOW pg_react.databases;
   SHOW pg_react.worker_role;
   SELECT pgreact_api.managed_status();
   SELECT pgreact.doctor();
   ```

2. **Diagnose** — confirm the current database is listed, the configured role
    can connect and has worker privileges, and both `pg_trickle` and `pg_react`
    are preloaded. The runtime coordinates extension versions `0.31.0` through
    `0.42.0`, `1.0.0-rc.N`, and `1.0.0`.
3. **Repair prerequisite** — correct the postmaster settings or worker role.
   Changes to `pg_react.databases` and `pg_react.worker_role` require a
   PostgreSQL restart.
4. **Invoke public operation** — restart PostgreSQL with the supported service
   manager. Do not start a second coordinator for the same database.
5. **Verify**

   ```sql
   SELECT pgreact_api.managed_status();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, code;
   ```

## Inspect backlog and failed work

1. **Observe**

   ```sql
   SELECT kind, name, version, work_id, state, claimable, updated_at
   FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;

   SELECT execution_id, episode_id, attempt_no, worker_id,
          started_at, finished_at, status, error_code, error_message,
          event_kind, name
   FROM pgreact.attempts
   ORDER BY started_at DESC, execution_id DESC;
   ```

2. **Diagnose** — distinguish pending backlog, terminal rule episodes, decision
   work, a stale lease, and an active recovery barrier. Use
   `pgreact.explain(name)` for the affected target.
3. **Repair prerequisite** — restore the exact source or consequence, fix
   permissions, make an external consumer idempotent, or remove the reported
   barrier cause before replay.
4. **Invoke public operation** — let the managed worker poll, or deliberately
   run:

   ```sql
   SELECT pgreact.run();
   ```

5. **Verify** — re-query both public views and confirm new attempts have the
   expected full status/error output.

## Requeue terminal rule work

`pgreact.requeue_episode(bigint)` is advanced. It accepts terminal rule
episodes; it is not a generic retry façade. Replaying an external consequence
can deliver again, so external delivery remains at least once.

1. **Observe**

   ```sql
   SELECT w.*, a.started_at, a.finished_at, a.status,
          a.error_code, a.error_message
   FROM pgreact.work AS w
   LEFT JOIN pgreact.attempts AS a
     ON a.episode_id::text = w.work_id
   WHERE w.kind = 'rule' AND w.state IN ('FAILED', 'CANCELLED', 'WITHDRAWN')
   ORDER BY w.updated_at DESC NULLS LAST, a.attempt_no DESC;
   ```

2. **Diagnose** — identify the failed consequence and confirm that retry is
   safe and deduplicated.
3. **Repair prerequisite** — repair the consequence or dependency first.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.requeue_episode(<work_id>::bigint);
   ```

5. **Verify** — confirm the work becomes pending, then observe a new complete
   attempt through `pgreact.attempts`.

## Recover an expired lease

1. **Observe**

   ```sql
   SELECT * FROM pgreact.health
   WHERE details ->> 'source_code' = 'STALE_LEASE';
   SELECT * FROM pgreact.work WHERE kind = 'rule' AND state = 'LEASED';
   ```

2. **Diagnose** — verify that the owning worker is no longer executing the
   episode. Do not sweep a merely slow live worker.
3. **Repair prerequisite** — restore worker health or wait until the lease is
   actually expired.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.sweep_expired_leases(
       (SELECT rule_version_id
        FROM pgreact.rules
        WHERE name = '<rule-name>'
        ORDER BY created_at DESC
        LIMIT 1));
   ```

5. **Verify** — the stale-lease finding disappears and the work is pending or
   subsequently completed.

## Pause and resume one rule

Pause/resume is an advanced rule operation, not a global runtime control.

1. **Observe**

   ```sql
   SELECT name, version, state FROM pgreact.rules WHERE name = '<rule-name>';
   SELECT * FROM pgreact.work WHERE kind = 'rule' AND name = '<rule-name>';
   ```

2. **Diagnose** — decide whether existing work must drain and whether a
   recovery barrier or drift finding would prevent resumption.
3. **Repair prerequisite** — repair drift/barriers and choose the old-work
   policy before replacement.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.pause_rule('<rule-name>');
   -- Later, only after blocking findings are clear:
   SELECT pgreact.resume_rule('<rule-name>');
   ```

5. **Verify**

   ```sql
   SELECT name, version, state FROM pgreact.rules WHERE name = '<rule-name>';
   SELECT * FROM pgreact.health WHERE blocking;
   ```

To stop all managed activity for backup, restore, or upgrade, remove the
database from `pg_react.databases` and restart PostgreSQL; per-rule pause is
not a substitute for stopping the database worker.

## Compare and replace safely

Installed `0.37.0` retains ordinary replacement preview and stale-digest
rejection, but not a successful names-first `pgreact.deploy()` replacement.
For rules, the currently qualified names-first cutover is the advanced
compatibility operation below. It drains old work; decisions do not yet have
an equivalently qualified names-first cutover.

1. **Observe**

   ```sql
   SELECT pgreact.status('manual-review-required');
   SELECT * FROM pgreact.rules WHERE name = 'manual-review-required';
   ```

2. **Diagnose** — validate the proposed source and ensure the target is the
   deployed object intended for replacement.
3. **Repair prerequisite** — fix validation, authorization, RLS, source drift,
   key, target, or evidence-limit failures.
4. **Invoke public operation** — compare first:

   ```sql
   WITH proposal AS (
     SELECT pgreact.rule(
       name => 'manual-review-required',
       condition => 'rule_def.high_value_risky_order_v2'::regclass,
       semantic_key => 'order_id'::name,
       kind => 'COMMAND',
       on_activate =>
         'rule_action.open_review_v2(pgreact.activation_context,rule_def.high_value_risky_order_v2)'::regprocedure
     ) AS declaration
   )
   SELECT pgreact.compare(
     declaration,
     pgreact_api.target('rule', 'manual-review-required'),
     '{"evidence_limit":100}'::jsonb
   )
   FROM proposal;
   ```

   Review `current`, `proposed`, `delta`, `lifecycle`, and `work`. A `partial`
   result has no continuation token; rerun with a higher `evidence_limit` up
   to `1000`. `compare_results()` exposes the same bounded comparison.

   After approval, pause and replace the rule by stable name:

   ```sql
   SELECT pgreact.pause_rule('manual-review-required');

   SELECT pgreact_api.replace_rule(
     'manual-review-required',
     'rule_def.high_value_risky_order_v2'::regclass,
     ARRAY['order_id']::name[],
     'rule_action'::name,
     'open_review_v2'::name,
     NULL::name,
     NULL::name
   );
   ```

   This compatibility surface is not the ordinary authoring API. Use it only
   for the tested rule cutover until names-first ordinary replacement is
   qualified. Deploy policy-set changes as a new immutable policy-set version;
   stop rather than inventing a decision cutover.

5. **Verify**

   ```sql
   SELECT pgreact.status('manual-review-required');
   SELECT * FROM pgreact.rules WHERE name = 'manual-review-required';
   SELECT * FROM pgreact.health WHERE blocking;
   ```

Comparison uses current authoritative facts only. It performs no deployment,
lifecycle mutation, durable work, attempt, consequence, external delivery, or
frontier advancement.

## Repair source, consequence, or applicability drift

1. **Observe**

   ```sql
   SELECT * FROM pgreact.health
   WHERE details ->> 'source_code'
         IN ('SOURCE_DRIFT', 'CONSEQUENCE_DRIFT', 'BARRIER');
   SELECT pgreact.doctor('<target-name>');
   SELECT pgreact.status('<target-name>');
   ```

2. **Diagnose** — source drift means the recorded source identity/shape no
   longer agrees; consequence drift means the exact function/dispatcher is
   missing or changed; applicability failures report a blocked policy target
   and a specific source/RLS/duplicate/incomplete/malformed/limit condition.
3. **Repair prerequisite** — restore the exact public object when that is the
   intended definition, or author and compare an explicit replacement. For
   applicability, restore a readable non-RLS source with complete, unique,
   correctly typed subjects within the supported bound.
4. **Invoke public operation** — deploy the reviewed replacement, or after
   repairing applicability deliberately run:

   ```sql
   SELECT pgreact.run();
   ```

5. **Verify** — `pgreact.status(name)` reports authoritative/ready state and
   the blocking finding is gone.

## Reconcile a recovery barrier

`prepare_recovery()` and `reconcile_rule()` are advanced recovery operations.
Use `STATE_ONLY` unless a separately reviewed recovery plan intentionally
permits missing-event emission.

1. **Observe**

   ```sql
   SELECT * FROM pgreact.health
   WHERE details ->> 'source_code' = 'BARRIER' OR blocking;
   SELECT name, rule_version_id, state FROM pgreact.rules ORDER BY name;
   ```

2. **Diagnose** — keep managed workers stopped and identify why current state
   cannot be trusted after restore, promotion, or repair.
3. **Repair prerequisite** — restore source and consequence objects,
   permissions, unique/non-null keys, and supported RLS state.
4. **Invoke public operation**

   ```sql
   SELECT pgreact.prepare_recovery();

   SELECT pgreact.reconcile_rule(
     (SELECT rule_version_id
      FROM pgreact.rules
      WHERE name = '<affected-standalone-rule>'
      ORDER BY created_at DESC
      LIMIT 1),
     'STATE_ONLY');
   ```

5. **Verify**

   ```sql
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, code;
   SELECT * FROM pgreact.matches ORDER BY name, activation_id;
   ```

`prepare_recovery()` barriers all eligible rules. Use it only with a complete
plan, repeat reconciliation for each affected standalone rule, and use the
owning public reconcile operation for advanced declaration families.

Resume managed workers only after read-only verification is clean. See
[Backup and restore](v1-backup-restore.md).

## Apply retention

Retention is advanced, operator-only, and disabled until explicitly
configured. It is irreversible except by restoring a backup.

1. **Observe**

   ```sql
   SELECT pgreact_api.retention_status();
   SELECT pgreact_api.retention_audit(100);
   ```

2. **Diagnose** — review protected rows, capabilities that would be lost, and
   the verified-backup boundary.
3. **Repair prerequisite** — take and test the required backup; choose all
   eight horizons; preview a past cutoff.
4. **Invoke public operation**

   ```sql
   SELECT pgreact_api.retention_configure(
     full_detail_horizon => interval '90 days',
     minimum_audit_horizon => interval '90 days',
     replay_horizon => interval '90 days',
     rollback_horizon => interval '90 days',
     deduplication_horizon => interval '90 days',
     explanation_horizon => interval '90 days',
     reconciliation_horizon => interval '90 days',
     recovery_horizon => interval '90 days',
     enabled => false
   );

   SELECT pgreact_api.retention_preview(
     clock_timestamp() - interval '180 days', 1000);

   SELECT pgreact_api.retention_configure(
     interval '90 days', interval '90 days', interval '90 days',
     interval '90 days', interval '90 days', interval '90 days',
     interval '90 days', interval '90 days', true);

   SELECT pgreact_api.retention_apply(
     clock_timestamp() - interval '180 days', 1000);
   ```

   Disable future application without restoring removed data:

   ```sql
   SELECT pgreact_api.retention_remove();
   ```

5. **Verify** — inspect `retention_status()` and `retention_audit(100)`;
   repeat bounded apply calls only when the result reports remaining eligible
   rows and the approved maintenance window remains open.

## Final operational verification

```sql
SELECT pgreact.doctor();
SELECT * FROM pgreact.health ORDER BY blocking DESC, severity, code, target;
SELECT pgreact_api.managed_status();
SELECT * FROM pgreact.rules ORDER BY name, version;
SELECT * FROM pgreact.work
ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
SELECT execution_id, episode_id, started_at, finished_at, status,
       error_code, error_message
FROM pgreact.attempts
ORDER BY started_at DESC, execution_id DESC;
```

Escalate and keep workers stopped when recovery provenance is uncertain, a
barrier cannot be reconciled through public operations, or rollback requires
the verified physical backup.
