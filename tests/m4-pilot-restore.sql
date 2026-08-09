\set ON_ERROR_STOP on

DO $$
DECLARE snapshot pilot.pre_restore%ROWTYPE;
BEGIN
  SELECT * INTO STRICT snapshot FROM pilot.pre_restore;
  IF snapshot.rule_count <> (SELECT count(*) FROM pgreact_internal.rule_versions)
     OR snapshot.activation_count <> (SELECT count(*) FROM pgreact_internal.activation_state)
     OR snapshot.activation_ids <> (SELECT string_agg(activation_id::text, ',' ORDER BY activation_id) FROM pgreact_internal.activation_state)
     OR snapshot.event_count <> (SELECT count(*) FROM pgreact_internal.lifecycle_events)
     OR snapshot.idempotency_keys <> (SELECT string_agg(idempotency_key, ',' ORDER BY idempotency_key) FROM pgreact_internal.agenda)
     OR snapshot.agenda_count <> (SELECT count(*) FROM pgreact_internal.agenda)
     OR snapshot.execution_count <> (SELECT count(*) FROM pgreact_internal.executions)
     OR snapshot.pending_count <> (SELECT count(*) FROM pgreact_internal.agenda WHERE state = 'PENDING')
     OR snapshot.action_count <> (SELECT count(*) FROM pilot.actions)
     OR snapshot.operational_settings <> (SELECT to_jsonb(s) FROM pgreact_internal.operational_settings s) THEN
    RAISE EXCEPTION 'pg-react durable state changed during physical recovery';
  END IF;
END $$;

SELECT max_claims = 7 AND max_lease_seconds = 120
       AND fairness_window = interval '17 seconds' AND max_pending_per_rule = 77 AS configured_operations_restored
FROM pgreact_internal.operational_settings \gset
\if :configured_operations_restored
\else
  SELECT 1 / 0;
\endif

SELECT version_id AS pilot_version FROM pilot.pre_restore \gset
SELECT match_name AS pilot_match
FROM pgreact_internal.rule_versions WHERE rule_version_id = :'pilot_version'::uuid \gset

SELECT pgreact.prepare_recovery() = 1 AS recovery_barriered \gset
\if :recovery_barriered
\else
  SELECT 1 / 0;
\endif

DO $$
BEGIN
  BEGIN
    PERFORM * FROM pgreact.claim_episode((SELECT version_id FROM pilot.pre_restore), 'm4-too-early', 30);
    RAISE EXCEPTION 'claim unexpectedly resumed before reconciliation';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'pg-react claims are blocked%' THEN RAISE; END IF;
  END;
END $$;

SELECT rebuilt_rules = 1 AND blocked_rules = 0 AS metadata_rebuilt
FROM pgreact.rebuild_transient_metadata() \gset
\if :metadata_rebuilt
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.reconcile_rule(:'pilot_version'::uuid, 'STATE_ONLY') >= 0 AS reconciled \gset
\if :reconciled
\else
  SELECT 1 / 0;
\endif
SELECT count(*) = 0 AS barriers_cleared FROM pgreact_internal.rule_barriers \gset
\if :barriers_cleared
\else
  SELECT 1 / 0;
\endif
SELECT count(*) = 0 AS healthy FROM pgreact.health_check() WHERE severity = 'ERROR' \gset
\if :healthy
\else
  SELECT 1 / 0;
\endif

SELECT episode_id, lease_token FROM pgreact.claim_episode(:'pilot_version'::uuid, 'm4-restored', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm4-restored', :'lease_token'::uuid) = 'COMPLETED' AS restored_claim_completed \gset
\if :restored_claim_completed
\else
  SELECT 1 / 0;
\endif
SELECT count(*) = 3 AS all_pre_backup_actions_completed FROM pilot.actions \gset
\if :all_pre_backup_actions_completed
\else
  SELECT 1 / 0;
\endif

INSERT INTO pilot.facts VALUES (4, false);
SELECT pgreact.begin_refresh(:'pilot_version'::uuid, 40004);
BEGIN; SELECT pgreact.refresh_rule(:'pilot_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'pilot_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT action = 'DIFFERENTIAL' AS restored_refresh_was_differential
FROM pgtrickle.pgt_refresh_history h
JOIN pgtrickle.pgt_stream_tables s USING (pgt_id)
WHERE format('%I.%I', s.pgt_schema, s.pgt_name) = :'pilot_match'
ORDER BY h.refresh_id DESC LIMIT 1 \gset
\if :restored_refresh_was_differential
\else
  SELECT 1 / 0;
\endif
SELECT count(*) = 1 AS restored_refresh_queued
FROM pgreact_internal.agenda WHERE rule_version_id = :'pilot_version'::uuid AND state = 'PENDING' \gset
\if :restored_refresh_queued
\else
  SELECT 1 / 0;
\endif
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'pilot_version'::uuid, 'm4-post-restore', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm4-post-restore', :'lease_token'::uuid) = 'COMPLETED' AS post_restore_claim_completed \gset
\if :post_restore_claim_completed
\else
  SELECT 1 / 0;
\endif
SELECT count(*) = 4 AND count(*) FILTER (WHERE fact_id = 4) = 1 AS all_actions_completed
FROM pilot.actions \gset
\if :all_actions_completed
\else
  SELECT 1 / 0;
\endif

SELECT 'M4 physical backup and recovery passed' AS result;
