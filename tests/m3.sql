\set ON_ERROR_STOP on

CREATE SCHEMA m3;
CREATE TABLE m3.facts (id bigint PRIMARY KEY, value integer NOT NULL, enabled boolean NOT NULL DEFAULT true);
CREATE TABLE m3.actions (activation_id uuid PRIMARY KEY, value integer NOT NULL);
CREATE VIEW m3.active_fact AS SELECT id, value FROM m3.facts WHERE enabled;
CREATE VIEW m3.backpressure_fact AS SELECT id, value FROM m3.facts WHERE enabled AND id >= 500;
CREATE FUNCTION m3.activate(context pgreact.activation_context, match m3.active_fact)
RETURNS void LANGUAGE SQL AS $$
  INSERT INTO m3.actions VALUES ((context).activation_id, (match).value) ON CONFLICT DO NOTHING
$$;
CREATE FUNCTION m3.activate_backpressure(context pgreact.activation_context, match m3.backpressure_fact)
RETURNS void LANGUAGE SQL AS $$
  INSERT INTO m3.actions VALUES ((context).activation_id, (match).value) ON CONFLICT DO NOTHING
$$;

CREATE ROLE pgreact_admin NOLOGIN;
CREATE ROLE m3_operator LOGIN IN ROLE pgreact_admin;
CREATE ROLE m3_reader LOGIN;
CREATE ROLE m3_intruder LOGIN;
GRANT USAGE ON SCHEMA pgreact TO m3_operator, m3_reader, m3_intruder;
GRANT EXECUTE ON FUNCTION pgreact.configure_operations(integer, integer, interval, integer) TO m3_operator;
GRANT SELECT ON pgreact.operational_status TO m3_reader;
GRANT EXECUTE ON FUNCTION pgreact.pause_rule(uuid) TO m3_intruder;
GRANT EXECUTE ON FUNCTION pgreact.begin_refresh(uuid, bigint), pgreact.refresh_rule(uuid),
    pgreact.clear_refresh_barrier(uuid) TO m3_intruder;
GRANT SELECT ON pgreact.rules TO m3_intruder;

SET SESSION AUTHORIZATION m3_operator;
SELECT pgreact.configure_operations(20, 60, interval '1 second', 1000);
RESET SESSION AUTHORIZATION;

SELECT pgreact.create_rule(
  'm3-pilot', 'm3.active_fact'::regclass, ARRAY['id'], 'COMMAND',
  'm3.activate(pgreact.activation_context,m3.active_fact)'::regprocedure,
  NULL, NULL, 'SEED_CURRENT', ARRAY['value'], 0, 'pilot', ARRAY['id']
) AS pilot_version \gset
SELECT pgreact.configure_agenda_group('pilot', 1);

INSERT INTO m3.facts SELECT i, i::integer FROM generate_series(1, 128) AS i;
SELECT pgreact.begin_refresh(:'pilot_version'::uuid, 30001);
BEGIN; SELECT pgreact.refresh_rule(:'pilot_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'pilot_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT count(*) = 128 AS burst_is_delta_proportional FROM pgreact_internal.agenda
WHERE rule_version_id = :'pilot_version'::uuid AND state = 'PENDING' \gset
\if :burst_is_delta_proportional
\else
  \quit 1
\endif

SELECT * FROM pgreact.claim('m3-worker-a', 1, interval '30 seconds', ARRAY['pilot']) \gset
SELECT :'episode_id' <> '' AS first_group_lease \gset
\if :first_group_lease
\else
  \quit 1
\endif
SELECT count(*) = 0 AS group_budget_holds FROM pgreact.claim('m3-worker-b', 1, interval '30 seconds', ARRAY['pilot']) \gset
\if :group_budget_holds
\else
  \quit 1
\endif
SELECT pgreact.execute_claimed_episode(:episode_id::bigint, 'm3-worker-a', :'lease_token'::uuid) = 'COMPLETED' AS completed \gset
\if :completed
\else
  \quit 1
\endif

SELECT pg_sleep(1.1);
SELECT pgreact.create_rule('m3-high', 'm3.backpressure_fact'::regclass, ARRAY['id'], 'COMMAND',
  'm3.activate_backpressure(pgreact.activation_context,m3.backpressure_fact)'::regprocedure,
  NULL, NULL, 'SEED_CURRENT', ARRAY['value'], 99, 'high') AS high_version \gset
INSERT INTO m3.facts VALUES (500, 500);
SELECT pgreact.begin_refresh(:'high_version'::uuid, 30002);
BEGIN; SELECT pgreact.refresh_rule(:'high_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'high_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT rule_version_id = :'pilot_version'::uuid AS fairness_prevents_starvation
FROM pgreact.claim('m3-fair', 1, interval '30 seconds', ARRAY['pilot', 'high']) \gset
\if :fairness_prevents_starvation
\else
  \quit 1
\endif

SELECT EXISTS (SELECT 1 FROM pgreact.prune_payloads(clock_timestamp())) AS payload_pruned \gset
\if :payload_pruned
\else
  \quit 1
\endif
SELECT count(*) = 1 AS retention_audited FROM pgreact_internal.retention_audits \gset
\if :retention_audited
\else
  \quit 1
\endif
SELECT old_bindings IS NULL AND new_bindings IS NULL AS payload_removed
FROM pgreact_internal.agenda WHERE episode_id = :episode_id \gset
\if :payload_removed
\else
  \quit 1
\endif

SELECT count(*) AS pending_before_rebuild FROM pgreact_internal.agenda WHERE rule_version_id = :'pilot_version'::uuid \gset
UPDATE pgreact_internal.rule_versions SET source_view_oid = 0, match_relid = NULL WHERE rule_version_id = :'pilot_version'::uuid;
SELECT set_config('m3.pilot_version', :'pilot_version', false);
DO $$
BEGIN
  BEGIN
    PERFORM pgreact.reconcile_rule(current_setting('m3.pilot_version')::uuid, 'STATE_ONLY');
    RAISE EXCEPTION 'reconciliation unexpectedly ran without a committed barrier';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'reconciliation requires a committed claim barrier%' THEN RAISE; END IF;
  END;
END $$;
SELECT pgreact.prepare_recovery() >= 1 AS recovery_barriered \gset
\if :recovery_barriered
\else
  \quit 1
\endif
SELECT rebuilt_rules >= 2 AS oid_metadata_rebuilt FROM pgreact.rebuild_transient_metadata() \gset
\if :oid_metadata_rebuilt
\else
  \quit 1
\endif
SELECT source_view_oid <> 0 AND match_relid IS NOT NULL AS pilot_metadata_rebuilt
FROM pgreact_internal.rule_versions WHERE rule_version_id = :'pilot_version'::uuid \gset
\if :pilot_metadata_rebuilt
\else
  \quit 1
\endif
SELECT count(*) = :pending_before_rebuild::bigint AS state_preserved FROM pgreact_internal.agenda WHERE rule_version_id = :'pilot_version'::uuid \gset
\if :state_preserved
\else
  \quit 1
\endif
SELECT pgreact.reconcile_rule(:'pilot_version'::uuid, 'STATE_ONLY') >= 0 AS reconciliation_after_recovery \gset
\if :reconciliation_after_recovery
\else
  \quit 1
\endif

SELECT pgreact.worker_protocol_compatible(1) AND NOT pgreact.worker_protocol_compatible(2) AS worker_protocol_checked \gset
\if :worker_protocol_checked
\else
  \quit 1
\endif
SELECT pgreact.metrics() ? 'agenda_by_state' AND pgreact.metrics() ? 'oldest_eligible_age_seconds' AS metrics_available \gset
\if :metrics_available
\else
  \quit 1
\endif

SET SESSION AUTHORIZATION m3_intruder;
SELECT set_config('m3.pilot_version', :'pilot_version', false);
DO $$
BEGIN
  PERFORM pgreact.pause_rule(current_setting('m3.pilot_version')::uuid);
  RAISE EXCEPTION 'intruder unexpectedly paused pilot rule';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE 'only the rule owner or pgreact_admin%' THEN RAISE; END IF;
END $$;
DO $$
BEGIN
  BEGIN
    PERFORM pgreact.begin_refresh(current_setting('m3.pilot_version')::uuid, 39999);
    RAISE EXCEPTION 'intruder unexpectedly began a refresh';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'only the rule owner or pgreact_admin%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM pgreact.refresh_rule(current_setting('m3.pilot_version')::uuid);
    RAISE EXCEPTION 'intruder unexpectedly refreshed a rule';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'only the rule owner or pgreact_admin%' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM pgreact.clear_refresh_barrier(current_setting('m3.pilot_version')::uuid);
    RAISE EXCEPTION 'intruder unexpectedly cleared a refresh barrier';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'only the rule owner or pgreact_admin%' THEN RAISE; END IF;
  END;
END $$;
RESET SESSION AUTHORIZATION;
SELECT NOT has_schema_privilege('m3_reader', 'pgreact_internal', 'USAGE')
  AND NOT has_table_privilege('m3_reader', 'pgreact_internal.agenda', 'SELECT') AS private_catalog_hidden \gset
\if :private_catalog_hidden
\else
  \quit 1
\endif

SELECT pgreact.configure_operations(20, 60, interval '1 second', 1);
SELECT pgreact.create_rule('m3-backpressure', 'm3.backpressure_fact'::regclass, ARRAY['id'], 'COMMAND',
  'm3.activate_backpressure(pgreact.activation_context,m3.backpressure_fact)'::regprocedure,
  NULL, NULL, 'SEED_CURRENT', ARRAY['value'], 0, 'backpressure') AS pressure_version \gset
INSERT INTO m3.facts VALUES (501, 501), (502, 502);
SELECT pgreact.begin_refresh(:'pressure_version'::uuid, 30003);
SELECT set_config('m3.pressure_version', :'pressure_version', false);
DO $$
DECLARE rejected boolean := false;
BEGIN
  BEGIN
    PERFORM pgreact.refresh_rule(current_setting('m3.pressure_version')::uuid);
    SET CONSTRAINTS ALL IMMEDIATE;
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'pg-react backpressure%' THEN RAISE; END IF;
    rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'backpressure refresh unexpectedly succeeded'; END IF;
END $$;
SELECT count(*) = 0 AS no_partial_backpressure_work FROM pgreact_internal.agenda
WHERE rule_version_id = :'pressure_version'::uuid \gset
\if :no_partial_backpressure_work
\else
  \quit 1
\endif

SELECT 'M3 operational RC checks passed' AS result;
