# v1 backup and restore

The qualified recovery model covers crash restart, supported standby
promotion, physical restore, and reconciliation. Logical restore means
restoring application/reference data and rebuilding declarations from durable
specifications; it does **not** mean dumping and restoring live private
pg-react catalogs.

Local database consequences are transactional. External delivery is at least
once: an effect may have been delivered before the selected recovery point and
may be delivered again afterward. Consumers must deduplicate stable delivery
identities.

Every procedure follows:

```text
observe -> diagnose -> repair prerequisite -> invoke public operation -> verify
```

## Recovery assets

Retain together:

- the exact PostgreSQL, pg_trickle, and pg-react packages/images and checksums;
- `postgresql.conf`, preload settings, `pg_react.databases`, and role mapping;
- the physical backup, WAL, timeline, and recovery target;
- durable application/reference data;
- durable rule, decision, and policy-set declaration specifications;
- consequence/outbox consumer deduplication state;
- a read-only pre-recovery transcript from public views.

## Stop managed work

There is no global SQL pause/resume façade.

1. **Observe**

   ```sql
   SHOW pg_react.databases;
   SELECT pgreact_api.managed_status();
   SELECT * FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   ```

2. **Diagnose** — record every configured database and whether work is pending,
   leased, or terminal.
3. **Repair prerequisite** — let safe local work drain or document why it must
   remain for recovery. Ensure external consumers are idempotent.
4. **Invoke public operation** — remove the database from
   `pg_react.databases` and restart PostgreSQL. To stop all configured workers:

   ```sql
   ALTER SYSTEM SET pg_react.databases = '';
   ```

   A PostgreSQL restart is required; reload is insufficient.
5. **Verify**

   ```sql
   SHOW pg_react.databases;
   SELECT pgreact_api.managed_status();
   ```

The managed process for the database must be absent before restore, promotion,
or reconciliation begins.

## Crash restart

1. **Observe** — record extension version, `pgreact.doctor()`,
   `pgreact.health`, managed status, work, and attempts.
2. **Diagnose** — distinguish a clean process restart from storage recovery or
   a changed timeline. A simple crash restart is qualified to preserve durable
   runtime state.
3. **Repair prerequisite** — repair PostgreSQL/WAL and any source or
   consequence finding before allowing work.
4. **Invoke public operation** — start PostgreSQL. Its managed worker restarts
   automatically for configured databases.
5. **Verify**

   ```sql
   SELECT extversion FROM pg_extension WHERE extname = 'pg_react';
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, code;
   SELECT pgreact_api.managed_status();
   SELECT * FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   ```

Do not run `prepare_recovery()` for a routine crash restart unless diagnostics
or the recovery plan requires explicit reconciliation.

## Physical backup and PITR restore

Use the supported PostgreSQL physical-backup/PITR procedure for the tested
platform. Restore the complete cluster state, configuration, extension
binaries, and required WAL; do not copy extension tables independently.

1. **Observe** — capture the recovery target/timeline and this read-only state:

   ```sql
   SELECT extversion FROM pg_extension WHERE extname = 'pg_react';
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.rules ORDER BY name, version;
   SELECT * FROM pgreact.matches ORDER BY name, activation_id;
   SELECT * FROM pgreact.decisions ORDER BY name, version_no;
   SELECT * FROM pgreact.policy_sets ORDER BY name;
   SELECT * FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   SELECT execution_id, episode_id, started_at, finished_at,
          status, error_code, error_message
   FROM pgreact.attempts
   ORDER BY started_at, execution_id;
   ```

2. **Diagnose** — choose a recovery point that accounts separately for local
   commits, outbox rows, and external deliveries.
3. **Repair prerequisite** — stop managed workers, restore the exact supported
   package/configuration, and finish PostgreSQL recovery.
4. **Invoke public operation** — after `pg_is_in_recovery()` is false, run
   read-only diagnostics. If recovery certainty requires barriers, perform the
   advanced repair:

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

   `STATE_ONLY` repairs current rule state without requesting missing
   lifecycle effects. `prepare_recovery()` creates barriers broadly, so repeat
   the repair for every affected standalone rule and use each advanced
   declaration family's owning public reconcile operation.
5. **Verify** — repeat the public-view transcript, confirm doctor/health are
   clean, and confirm each critical `pgreact.status(name)` is ready or
   authoritative before resuming workers.

If verification fails, preserve the restored state for diagnosis or restore a
different verified recovery point. Never delete a barrier directly.

## Standby promotion

Managed work must not run on a physical standby.

1. **Observe**

   ```sql
   SELECT pg_is_in_recovery();
   SELECT pgreact.doctor();
   SELECT pgreact_api.managed_status();
   ```

2. **Diagnose** — confirm the standby has reached the intended replay point and
   record possibly delivered external effects from the former primary.
3. **Repair prerequisite** — keep the managed database disabled on the standby
   and complete the supported PostgreSQL promotion.
4. **Invoke public operation** — after promotion:

   ```sql
   SELECT pg_is_in_recovery(); -- must be false
   SELECT pgreact.prepare_recovery();
   SELECT pgreact.reconcile_rule(
     (SELECT rule_version_id
      FROM pgreact.rules
      WHERE name = '<affected-standalone-rule>'
      ORDER BY created_at DESC
      LIMIT 1),
     'STATE_ONLY');
   ```

   Recover an actually expired lease only after proving the former worker can
   no longer execute:

   ```sql
   SELECT pgreact.sweep_expired_leases(
     (SELECT rule_version_id
      FROM pgreact.rules
      WHERE name = '<affected-standalone-rule>'
      ORDER BY created_at DESC
      LIMIT 1));
   ```

5. **Verify** — no standby/barrier/stale-lease finding remains; rules, matches,
   decisions, policy sets, work, and attempts agree with the promoted point.

## Logical restore by declaration replay

The proven logical model is:

```text
application/reference data + durable declaration specs
  -> fresh extensions and roles
  -> restore application objects/data
  -> reconstruct declarations
  -> validate/preview/deploy
  -> reconcile current state
  -> verify
```

Do not include `pgreact_internal` or `pgreact_runtime` in a portable dump. Do
not claim that live work, attempts, leases, or internal IDs survive logical
restore. Dump named application and durable-spec schemas instead, for example:

```sh
pg_dump --format=custom \
  --schema=app \
  --schema=policy_specs \
  --file=backups/app-and-policy-specs.dump \
  <database>
```

1. **Observe** — export durable declaration specifications and record expected
   public names/results from rules, decisions, policy sets, and source data.
2. **Diagnose** — identify which application/reference schemas, typed
   consequences, and declaration specs are required to reconstruct behavior.
3. **Repair prerequisite** — create a fresh supported database, install
   `pg_trickle` then `pg_react`, configure roles, and restore only the selected
   application/reference/spec schemas.
4. **Invoke public operation** — rebuild each declaration with the current
   public constructor, then validate/preview/deploy. For example:

   ```sql
   WITH proposal AS (
     SELECT pgreact.rule(
       name => 'risk.review-order',
       condition => 'app.review_orders'::regclass,
       semantic_key => 'order_id'::name
     ) AS declaration
   ), checked AS (
     SELECT declaration, pgreact.validate(declaration) AS validation,
            pgreact.preview(declaration) AS preview
     FROM proposal
   )
   SELECT pgreact.deploy(
     declaration,
     jsonb_build_object(
       'preview_digest', preview -> 'summary' ->> 'preview_digest')
   )
   FROM checked
   WHERE validation ->> 'state' <> 'attention';
   ```

   Rebuild decisions and policy sets from their durable specs in dependency
   order. With managed workers still stopped, repair applicability/source
   prerequisites and invoke `pgreact.run()` only as the intentional
   reconciliation step after declarations are deployed.
5. **Verify**

   ```sql
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health ORDER BY blocking DESC, code;
   SELECT * FROM pgreact.rules ORDER BY name, version;
   SELECT * FROM pgreact.matches ORDER BY name, activation_id;
   SELECT * FROM pgreact.decisions ORDER BY name, version_no;
   SELECT * FROM pgreact.policy_sets ORDER BY name;
   SELECT * FROM pgreact.work
   ORDER BY updated_at DESC NULLS LAST, kind, name, work_id;
   ```

Compare semantic names and application-visible results, not restored internal
UUIDs. Logical restore is supported only to this replay-and-reconcile scope.

## Resume managed work

1. **Observe** — doctor/health/status and the recovery transcript must be
   clean.
2. **Diagnose** — confirm no unresolved barrier, drift, RLS, stale lease, or
   unsafe external replay remains.
3. **Repair prerequisite** — complete the documented public repair or choose a
   different recovery point.
4. **Invoke public operation** — restore the saved comma-separated database
   list and restart PostgreSQL:

   ```sql
   ALTER SYSTEM SET pg_react.databases = '<comma-separated-databases>';
   ```

5. **Verify**

   ```sql
   SELECT pgreact_api.managed_status();
   SELECT pgreact.doctor();
   SELECT * FROM pgreact.health WHERE blocking;
   ```

Monitor new attempts and external deduplication until the recovery window is
closed.
