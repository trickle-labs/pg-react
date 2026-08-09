\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA pilot;
CREATE TABLE pilot.facts (id bigint PRIMARY KEY, should_fail boolean NOT NULL DEFAULT false);
CREATE TABLE pilot.actions (activation_id uuid PRIMARY KEY, fact_id bigint NOT NULL);
CREATE VIEW pilot.active_fact AS SELECT id, should_fail FROM pilot.facts;
CREATE FUNCTION pilot.act(context pgreact.activation_context, match pilot.active_fact)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pilot.facts WHERE id = (match).id AND should_fail) THEN
    RAISE EXCEPTION 'M4 injected pilot failure';
  END IF;
  INSERT INTO pilot.actions VALUES ((context).activation_id, (match).id) ON CONFLICT DO NOTHING;
END $$;

SELECT pgreact.create_rule(
  name => 'm4-pilot', definition => 'pilot.active_fact'::regclass,
  key_columns => ARRAY['id'], on_activate => 'pilot.act(pgreact.activation_context,pilot.active_fact)'::regprocedure,
  max_attempts => 1
) AS pilot_version \gset

-- Install and normal operation.
INSERT INTO pilot.facts VALUES (1, false);
SELECT pgreact.begin_refresh(:'pilot_version'::uuid, 40001);
BEGIN; SELECT pgreact.refresh_rule(:'pilot_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'pilot_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'pilot_version'::uuid, 'm4-normal', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm4-normal', :'lease_token'::uuid) = 'COMPLETED' AS normal_completed \gset
\if :normal_completed
\else
  SELECT 1 / 0;
\endif

-- Inject a durable failure, correct its cause, and recover the same episode.
INSERT INTO pilot.facts VALUES (2, true);
SELECT pgreact.begin_refresh(:'pilot_version'::uuid, 40002);
BEGIN; SELECT pgreact.refresh_rule(:'pilot_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'pilot_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id AS failed_episode, lease_token AS failed_lease
FROM pgreact.claim_episode(:'pilot_version'::uuid, 'm4-failure', 30) \gset
SELECT pgreact.execute_claimed_episode(:failed_episode, 'm4-failure', :'failed_lease'::uuid) = 'FAILED' AS failure_recorded \gset
\if :failure_recorded
\else
  SELECT 1 / 0;
\endif
UPDATE pilot.facts SET should_fail = false WHERE id = 2;
SELECT pgreact.requeue_episode(:failed_episode);
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'pilot_version'::uuid, 'm4-recovery', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm4-recovery', :'lease_token'::uuid) = 'COMPLETED' AS failure_recovered \gset
\if :failure_recovered
\else
  SELECT 1 / 0;
\endif

-- Leave committed work pending across a physical backup and recovery.
INSERT INTO pilot.facts VALUES (3, false);
SELECT pgreact.begin_refresh(:'pilot_version'::uuid, 40003);
BEGIN; SELECT pgreact.refresh_rule(:'pilot_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'pilot_version'::uuid); SELECT pgreact.release_refresh_lock();

SELECT pgreact.configure_operations(7, 120, interval '17 seconds', 77);
CREATE TABLE pilot.pre_restore AS
SELECT :'pilot_version'::uuid AS version_id,
       (SELECT count(*) FROM pgreact_internal.rule_versions) AS rule_count,
       (SELECT count(*) FROM pgreact_internal.activation_state) AS activation_count,
       (SELECT string_agg(activation_id::text, ',' ORDER BY activation_id) FROM pgreact_internal.activation_state) AS activation_ids,
       (SELECT count(*) FROM pgreact_internal.lifecycle_events) AS event_count,
       (SELECT string_agg(idempotency_key, ',' ORDER BY idempotency_key) FROM pgreact_internal.agenda) AS idempotency_keys,
       (SELECT count(*) FROM pgreact_internal.agenda) AS agenda_count,
       (SELECT count(*) FROM pgreact_internal.executions) AS execution_count,
       (SELECT count(*) FROM pgreact_internal.agenda WHERE state = 'PENDING') AS pending_count,
       (SELECT count(*) FROM pilot.actions) AS action_count,
       (SELECT to_jsonb(s) FROM pgreact_internal.operational_settings s) AS operational_settings;

SELECT 'M4 pilot install, operation, failure, and recovery passed' AS result;
