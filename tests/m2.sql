\set ON_ERROR_STOP on

CREATE SCHEMA m2;
CREATE TABLE m2.facts (id bigint PRIMARY KEY, value integer NOT NULL, enabled boolean NOT NULL DEFAULT true);
CREATE TABLE m2.actions (kind text NOT NULL, activation_id uuid NOT NULL, revision bigint NOT NULL, value integer, PRIMARY KEY (kind, activation_id, revision));
CREATE TABLE m2.outbox (idempotency_key text PRIMARY KEY, envelope jsonb NOT NULL);
CREATE SEQUENCE m2.flaky_attempt;
CREATE VIEW m2.enabled_fact AS SELECT id, value FROM m2.facts WHERE enabled;

CREATE FUNCTION m2.activate(context pgreact.activation_context, match m2.enabled_fact)
RETURNS void LANGUAGE SQL AS $$
  INSERT INTO m2.actions VALUES ('ACTIVATE', (context).activation_id, (context).revision, (match).value)
  ON CONFLICT DO NOTHING
$$;
CREATE FUNCTION m2.change(context pgreact.activation_context, old_match m2.enabled_fact, new_match m2.enabled_fact)
RETURNS void LANGUAGE SQL AS $$
  INSERT INTO m2.actions VALUES ('CHANGE', (context).activation_id, (context).revision, (new_match).value)
$$;
CREATE FUNCTION m2.deactivate(context pgreact.activation_context, match m2.enabled_fact)
RETURNS void LANGUAGE SQL AS $$
  INSERT INTO m2.actions VALUES ('DEACTIVATE', (context).activation_id, (context).revision, (match).value)
$$;
CREATE FUNCTION m2.flaky(context pgreact.activation_context, match m2.enabled_fact)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF nextval('m2.flaky_attempt') = 1 THEN RAISE EXCEPTION 'retry me'; END IF;
  INSERT INTO m2.actions VALUES ('FLAKY', (context).activation_id, (context).revision, (match).value);
END $$;
CREATE FUNCTION m2.enqueue(context pgreact.activation_context, envelope jsonb)
RETURNS void LANGUAGE SQL AS $$
  INSERT INTO m2.outbox VALUES ((context).idempotency_key, envelope)
$$;

SELECT pgreact.create_rule(
  'm2-lifecycle', 'm2.enabled_fact'::regclass, ARRAY['id'], 'COMMAND',
  'm2.activate(pgreact.activation_context,m2.enabled_fact)'::regprocedure,
  'm2.deactivate(pgreact.activation_context,m2.enabled_fact)'::regprocedure,
  'm2.change(pgreact.activation_context,m2.enabled_fact,m2.enabled_fact)'::regprocedure,
  'SEED_CURRENT', ARRAY['value'], 10, 'm2', ARRAY['id']
) AS lifecycle_version \gset

INSERT INTO m2.facts VALUES (1, 10);
SELECT pgreact.begin_refresh(:'lifecycle_version'::uuid, 20001);
BEGIN; SELECT pgreact.refresh_rule(:'lifecycle_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'lifecycle_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'lifecycle_version'::uuid, 'm2-a', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm2-a', :'lease_token'::uuid) = 'COMPLETED' AS activated \gset
\if :activated
\else
  \quit 1
\endif

UPDATE m2.facts SET value = 11 WHERE id = 1;
SELECT pgreact.begin_refresh(:'lifecycle_version'::uuid, 20002);
BEGIN; SELECT pgreact.refresh_rule(:'lifecycle_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'lifecycle_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'lifecycle_version'::uuid, 'm2-b', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm2-b', :'lease_token'::uuid) = 'COMPLETED' AS changed \gset
\if :changed
\else
  \quit 1
\endif

UPDATE m2.facts SET enabled = false WHERE id = 1;
SELECT pgreact.begin_refresh(:'lifecycle_version'::uuid, 20003);
BEGIN; SELECT pgreact.refresh_rule(:'lifecycle_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'lifecycle_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'lifecycle_version'::uuid, 'm2-c', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm2-c', :'lease_token'::uuid) = 'COMPLETED' AS deactivated \gset
\if :deactivated
\else
  \quit 1
\endif
SELECT count(*) = 3 AS lifecycle_payloads FROM m2.actions WHERE kind IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE') \gset
\if :lifecycle_payloads
\else
  \quit 1
\endif

SELECT pgreact.create_rule('m2-flaky', 'm2.enabled_fact'::regclass, ARRAY['id'], 'COMMAND',
  'm2.flaky(pgreact.activation_context,m2.enabled_fact)'::regprocedure,
  NULL, NULL, 'SEED_CURRENT', ARRAY['value'], 0, 'm2', NULL, 2, 1, 1, 1
) AS flaky_version \gset
UPDATE m2.facts SET enabled = true WHERE id = 1;
SELECT pgreact.begin_refresh(:'flaky_version'::uuid, 20004);
BEGIN; SELECT pgreact.refresh_rule(:'flaky_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'flaky_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'flaky_version'::uuid, 'm2-d', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm2-d', :'lease_token'::uuid) = 'RETRY_WAIT' AS retry_wait \gset
\if :retry_wait
\else
  \quit 1
\endif
SELECT pg_sleep(1.1);
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'flaky_version'::uuid, 'm2-e', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm2-e', :'lease_token'::uuid) = 'COMPLETED' AS retry_completed \gset
\if :retry_completed
\else
  \quit 1
\endif

SELECT pgreact.create_rule('m2-outbox', 'm2.enabled_fact'::regclass, ARRAY['id'], 'COMMAND', NULL,
  NULL, NULL, 'SEED_CURRENT', ARRAY['value'], 0, 'm2'
) AS outbox_version \gset
SELECT pgreact.bind_outbox_consequence(:'outbox_version'::uuid, 'ACTIVATE',
  'm2.enqueue(pgreact.activation_context,jsonb)'::regprocedure);
INSERT INTO m2.facts VALUES (2, 20);
SELECT pgreact.begin_refresh(:'outbox_version'::uuid, 20005);
BEGIN; SELECT pgreact.refresh_rule(:'outbox_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'outbox_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'outbox_version'::uuid, 'm2-outbox', 30) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm2-outbox', :'lease_token'::uuid) = 'COMPLETED' AS outbox_completed \gset
\if :outbox_completed
\else
  \quit 1
\endif
SELECT count(*) = 1 AS outbox_atomic FROM m2.outbox \gset
\if :outbox_atomic
\else
  \quit 1
\endif

-- Multi-item claims are only reservations: every item still uses its own lease
-- and execution transaction.  A stale token must never complete reclaimed work.
INSERT INTO m2.facts VALUES (3, 30), (4, 40);
SELECT pgreact.begin_refresh(:'lifecycle_version'::uuid, 20006);
BEGIN; SELECT pgreact.refresh_rule(:'lifecycle_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'lifecycle_version'::uuid); SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE m2_claims AS
  SELECT * FROM pgreact.claim('m2-batch', 2, interval '2 seconds', ARRAY['m2']);
SELECT count(*) = 2 AND count(DISTINCT episode_id) = 2 AS multi_claimed FROM m2_claims \gset
\if :multi_claimed
\else
  \quit 1
\endif
SELECT pgreact.heartbeat_episode(episode_id, 'm2-batch', lease_token, interval '2 seconds') IS NOT NULL AS heartbeated
FROM m2_claims LIMIT 1 \gset
\if :heartbeated
\else
  \quit 1
\endif
SELECT pgreact.execute_claimed_episode(episode_id, 'm2-batch', lease_token) = 'COMPLETED' AS batch_one
FROM m2_claims LIMIT 1 \gset
\if :batch_one
\else
  \quit 1
\endif

INSERT INTO m2.facts VALUES (5, 50);
SELECT pgreact.begin_refresh(:'lifecycle_version'::uuid, 20007);
BEGIN; SELECT pgreact.refresh_rule(:'lifecycle_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'lifecycle_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'lifecycle_version'::uuid, 'm2-stale', 1) \gset
SELECT set_config('m2.stale_episode', :'episode_id', false), set_config('m2.stale_token', :'lease_token', false);
SELECT pg_sleep(1.1);
SELECT pgreact.sweep_expired_leases(:'lifecycle_version'::uuid) >= 1 AS reclaimed \gset
\if :reclaimed
\else
  \quit 1
\endif
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'lifecycle_version'::uuid, 'm2-fresh', 30) \gset
SELECT set_config('m2.fresh_episode', :'episode_id', false), set_config('m2.fresh_token', :'lease_token', false);
DO $$
BEGIN
  PERFORM pgreact.execute_claimed_episode(current_setting('m2.stale_episode')::bigint, 'm2-stale', current_setting('m2.stale_token')::uuid);
  RAISE EXCEPTION 'stale worker unexpectedly completed reclaimed work';
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT LIKE 'lease is no longer valid%' THEN RAISE; END IF;
END $$;
SELECT pgreact.execute_claimed_episode(current_setting('m2.fresh_episode')::bigint, 'm2-fresh', current_setting('m2.fresh_token')::uuid) = 'COMPLETED' AS fresh_completed \gset
\if :fresh_completed
\else
  \quit 1
\endif

SELECT pgreact.reconcile_rule(:'lifecycle_version'::uuid, 'STATE_ONLY') >= 0 AS reconciliation_audited \gset
\if :reconciliation_audited
\else
  \quit 1
\endif
SELECT count(*) >= 1 AS reconciliation_recorded FROM pgreact_internal.reconciliation_audit
WHERE rule_version_id = :'lifecycle_version'::uuid AND status = 'COMPLETED' \gset
\if :reconciliation_recorded
\else
  \quit 1
\endif

CREATE VIEW m2.enabled_fact_v2 AS SELECT id, value FROM m2.facts WHERE enabled;
SELECT pgreact.create_rule('m2-replacement', 'm2.enabled_fact'::regclass, ARRAY['id']) AS replacement_old \gset
SELECT pgreact.replace_rule(:'replacement_old'::uuid, 'm2.enabled_fact_v2'::regclass, ARRAY['id'],
  NULL, 'SEED_CURRENT', NULL, NULL, 'DRAIN_OLD') IS NOT NULL AS replacement_works \gset
\if :replacement_works
\else
  \quit 1
\endif

SELECT 'M2 lifecycle, retry, and outbox checks passed' AS result;
