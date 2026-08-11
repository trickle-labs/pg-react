\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA m6;

CREATE TABLE m6.facts (
    id bigint PRIMARY KEY,
    active boolean NOT NULL,
    should_fail boolean NOT NULL DEFAULT false
);

CREATE TABLE m6.effects (
    episode_id bigint PRIMARY KEY,
    fact_id bigint NOT NULL
);

CREATE VIEW m6.active_fact AS
SELECT id, should_fail FROM m6.facts WHERE active;

CREATE FUNCTION m6.apply_fact(context pgreact.activation_context, match m6.active_fact)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF match.should_fail THEN
        RAISE EXCEPTION 'intentional M6 failure for fact %', match.id USING ERRCODE = 'P6001';
    END IF;
    INSERT INTO m6.effects VALUES (context.episode_id, match.id);
END
$$;

SELECT pgreact.create_rule(
    name => 'm6-batch',
    definition => 'm6.active_fact'::regclass,
    key_columns => ARRAY['id'],
    kind => 'COMMAND',
    on_activate => 'm6.apply_fact(pgreact.activation_context,m6.active_fact)'::regprocedure,
    max_attempts => 1
) AS rule_version_id \gset
SELECT set_config('m6.rule_version_id', :'rule_version_id', false);

DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') NOT IN ('0.3.0', '0.4.0', '0.5.0', '0.6.0', '0.7.0')
       OR NOT pgreact.worker_protocol_compatible(1)
       OR NOT pgreact.worker_protocol_compatible(2)
       OR pgreact.worker_protocol_compatible(3) THEN
        RAISE EXCEPTION 'M6 extension or worker protocol compatibility changed';
    END IF;
    BEGIN
        PERFORM * FROM pgreact.claim_batch(
            current_setting('m6.rule_version_id')::uuid, 'ACTIVATE', 'm6-undeclared', 2
        );
        RAISE EXCEPTION 'undeclared batch claim unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'batch execution is not declared for rule version % event ACTIVATE' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM * FROM pgreact.claim_batch(
            current_setting('m6.rule_version_id')::uuid, 'ACTIVATE', 'm6-oversized', 33
        );
        RAISE EXCEPTION 'oversized batch claim unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'max_items must be between 2 and 32' THEN RAISE; END IF;
    END;
END
$$;

SELECT pgreact.declare_batch_safe(:'rule_version_id'::uuid, 'ACTIVATE');

DO $$
BEGIN
    BEGIN
        PERFORM pgreact.declare_batch_safe(current_setting('m6.rule_version_id')::uuid, 'ACTIVATE');
        RAISE EXCEPTION 'duplicate batch declaration unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'batch safety is already declared for rule version % event ACTIVATE' THEN RAISE; END IF;
    END;
    BEGIN
        DELETE FROM pgreact_internal.batch_declarations
        WHERE rule_version_id = current_setting('m6.rule_version_id')::uuid AND event_kind = 'ACTIVATE';
        RAISE EXCEPTION 'batch declaration deletion unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'batch-safe declarations are immutable; replace the rule version instead' THEN RAISE; END IF;
    END;
END
$$;

CREATE VIEW m6.outbox_fact AS SELECT id FROM m6.facts WHERE false;
CREATE FUNCTION m6.outbox_sink(context pgreact.activation_context, envelope jsonb)
RETURNS void LANGUAGE plpgsql AS 'BEGIN NULL; END';
SELECT pgreact.create_rule(
    name => 'm6-outbox', definition => 'm6.outbox_fact'::regclass,
    key_columns => ARRAY['id'], kind => 'COMMAND'
) AS outbox_version_id \gset
SELECT pgreact.bind_outbox_consequence(
    :'outbox_version_id'::uuid, 'ACTIVATE',
    'm6.outbox_sink(pgreact.activation_context,jsonb)'::regprocedure
);
SELECT set_config('m6.outbox_version_id', :'outbox_version_id', false);
DO $$
BEGIN
    BEGIN
        PERFORM pgreact.declare_batch_safe(current_setting('m6.outbox_version_id')::uuid, 'ACTIVATE');
        RAISE EXCEPTION 'outbox batch declaration unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'only DATABASE_TYPED consequences can be declared batch-safe' THEN RAISE; END IF;
    END;
END
$$;

INSERT INTO m6.facts (id, active) SELECT id, true FROM generate_series(1, 4) AS id;
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6101);
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT pgreact.refresh_rule(:'rule_version_id'::uuid);
COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();

CREATE TEMP TABLE success_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-success', 4);
SELECT batch_id::text AS success_batch_id FROM success_claim ORDER BY item_order LIMIT 1 \gset
CREATE TEMP TABLE success_result AS
SELECT * FROM pgreact.execute_claimed_batch(:'success_batch_id'::uuid, 'm6-success');

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(r) ORDER BY episode_id) INTO actual FROM success_result r;
    expected := '[
      {"episode_id":1,"status":"COMPLETED","error_code":null,"error_message":null},
      {"episode_id":2,"status":"COMPLETED","error_code":null,"error_message":null},
      {"episode_id":3,"status":"COMPLETED","error_code":null,"error_message":null},
      {"episode_id":4,"status":"COMPLETED","error_code":null,"error_message":null}
    ]'::jsonb;
    IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'successful batch output changed: %', actual; END IF;
    SELECT jsonb_agg(jsonb_build_object('episode_id', episode_id, 'fact_id', fact_id) ORDER BY episode_id)
      INTO actual FROM m6.effects;
    expected := '[
      {"episode_id":1,"fact_id":1},{"episode_id":2,"fact_id":2},
      {"episode_id":3,"fact_id":3},{"episode_id":4,"fact_id":4}
    ]'::jsonb;
    IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'successful effects changed: %', actual; END IF;
    SELECT jsonb_build_object(
        'state', state,
        'diagnostic_code', diagnostic_code,
        'items', items
    ) INTO actual FROM pgreact.batch_history((SELECT batch_id FROM success_claim ORDER BY item_order LIMIT 1));
    expected := '{
      "state":"COMPLETED","diagnostic_code":null,
      "items":[
        {"item_order":1,"episode_id":1,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
        {"item_order":2,"episode_id":2,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
        {"item_order":3,"episode_id":3,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
        {"item_order":4,"episode_id":4,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null}
      ]
    }'::jsonb;
    IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'successful batch history changed: %', actual; END IF;
    SELECT signature - ARRAY['consequence_digest', 'dispatcher_digest', 'dispatcher_identity']
      INTO actual FROM pgreact.batch_history((SELECT batch_id FROM success_claim ORDER BY item_order LIMIT 1));
    expected := '{
      "max_items":4,
      "execution_role":"postgres",
      "recheck_policy":"FRESH",
      "conflict_key_columns":null,
      "consequence_identity":"m6.apply_fact(pgreact.activation_context,m6.active_fact)"
    }'::jsonb;
    IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'public batch signature changed: %', actual; END IF;
    SELECT jsonb_build_object(
        'consequence_digest_is_sha256', (signature ->> 'consequence_digest') ~ '^[0-9a-f]{64}$',
        'dispatcher_digest_is_sha256', (signature ->> 'dispatcher_digest') ~ '^[0-9a-f]{64}$',
        'dispatcher_identity_is_exact', to_regprocedure(signature ->> 'dispatcher_identity') IS NOT NULL
    ) INTO actual FROM pgreact.batch_history((SELECT batch_id FROM success_claim ORDER BY item_order LIMIT 1));
    IF actual IS DISTINCT FROM '{
      "consequence_digest_is_sha256":true,
      "dispatcher_digest_is_sha256":true,
      "dispatcher_identity_is_exact":true
    }'::jsonb THEN RAISE EXCEPTION 'public batch fingerprints changed: %', actual; END IF;
END
$$;

INSERT INTO m6.facts VALUES (5, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6102);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token FROM pgreact.claim_episode(:'rule_version_id'::uuid, 'm6-default', 60) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm6-default', :'lease_token'::uuid) AS default_result \gset
SELECT :'default_result' = 'COMPLETED' AS default_completed \gset
\if :default_completed
\else
  \quit
\endif

INSERT INTO m6.facts VALUES (6, true, false), (7, true, true), (8, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6103);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE partial_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-partial', 3);
SELECT batch_id::text AS partial_batch_id FROM partial_claim ORDER BY item_order LIMIT 1 \gset
CREATE TEMP TABLE partial_result AS
SELECT * FROM pgreact.execute_claimed_batch(:'partial_batch_id'::uuid, 'm6-partial');

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(r) ORDER BY episode_id) INTO actual FROM partial_result r;
    expected := '[
      {"episode_id":6,"status":"COMPLETED","error_code":null,"error_message":null},
      {"episode_id":7,"status":"FAILED","error_code":"P6001","error_message":"intentional M6 failure for fact 7"},
      {"episode_id":8,"status":"COMPLETED","error_code":null,"error_message":null}
    ]'::jsonb;
    IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'partial batch output changed: %', actual; END IF;
    SELECT jsonb_build_object('state', state, 'diagnostic_code', diagnostic_code)
      INTO actual FROM pgreact.batch_history((SELECT batch_id FROM partial_claim ORDER BY item_order LIMIT 1));
    IF actual IS DISTINCT FROM '{"state":"PARTIAL","diagnostic_code":"ITEM_FAILURE"}'::jsonb THEN
        RAISE EXCEPTION 'partial batch history changed: %', actual;
    END IF;
    SELECT jsonb_agg(jsonb_build_object('episode_id', episode_id, 'fact_id', fact_id) ORDER BY episode_id)
      INTO actual FROM m6.effects;
    expected := '[
      {"episode_id":1,"fact_id":1},{"episode_id":2,"fact_id":2},
      {"episode_id":3,"fact_id":3},{"episode_id":4,"fact_id":4},
      {"episode_id":5,"fact_id":5},{"episode_id":6,"fact_id":6},
      {"episode_id":8,"fact_id":8}
    ]'::jsonb;
    IF actual IS DISTINCT FROM expected THEN RAISE EXCEPTION 'partial effects changed: %', actual; END IF;
END
$$;

INSERT INTO m6.facts VALUES (9, true, false), (10, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6104);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE paused_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-paused', 2);
SELECT batch_id::text AS paused_batch_id FROM paused_claim ORDER BY item_order LIMIT 1 \gset
DO $$
BEGIN
    BEGIN
        PERFORM pgreact.cancel_episode((SELECT episode_id FROM paused_claim ORDER BY item_order LIMIT 1));
        RAISE EXCEPTION 'leased batch episode cancellation unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'only unleased episodes can be cancelled' THEN RAISE; END IF;
    END;
END
$$;
SELECT pgreact.pause_rule(:'rule_version_id'::uuid);
CREATE TEMP TABLE paused_result AS
SELECT * FROM pgreact.execute_claimed_batch(:'paused_batch_id'::uuid, 'm6-paused');
SELECT pgreact.resume_rule(:'rule_version_id'::uuid);

DO $$
DECLARE item record; actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(r) ORDER BY episode_id) INTO actual FROM paused_result r;
    IF actual IS DISTINCT FROM '[
      {"episode_id":9,"status":"REJECTED","error_code":"INELIGIBLE_RULE_STATE","error_message":"batch rejected before consequence invocation"},
      {"episode_id":10,"status":"REJECTED","error_code":"INELIGIBLE_RULE_STATE","error_message":"batch rejected before consequence invocation"}
    ]'::jsonb THEN RAISE EXCEPTION 'paused rejection changed: %', actual; END IF;
    FOR item IN SELECT * FROM paused_claim ORDER BY item_order LOOP
        IF pgreact.execute_claimed_episode(item.episode_id, 'm6-paused', item.lease_token) <> 'COMPLETED' THEN
            RAISE EXCEPTION 'rejected batch lease was not reusable';
        END IF;
    END LOOP;
END
$$;

INSERT INTO m6.facts VALUES (11, true, false), (12, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6105);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE rollback_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-rollback', 2);
SELECT batch_id::text AS rollback_batch_id FROM rollback_claim ORDER BY item_order LIMIT 1 \gset
BEGIN;
SELECT * FROM pgreact.execute_claimed_batch(:'rollback_batch_id'::uuid, 'm6-rollback');
ROLLBACK;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object('state', state, 'items', items) INTO actual
    FROM pgreact.batch_history((SELECT batch_id FROM rollback_claim ORDER BY item_order LIMIT 1));
    IF actual IS DISTINCT FROM '{
      "state":"CLAIMED",
      "items":[
        {"item_order":1,"episode_id":11,"attempt_no":1,"outcome":null,"error_code":null,"error_message":null},
        {"item_order":2,"episode_id":12,"attempt_no":1,"outcome":null,"error_code":null,"error_message":null}
      ]
    }'::jsonb THEN RAISE EXCEPTION 'rollback batch state changed: %', actual; END IF;
END
$$;
SELECT * FROM pgreact.execute_claimed_batch(:'rollback_batch_id'::uuid, 'm6-rollback');

INSERT INTO m6.facts VALUES (13, true, false), (14, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6106);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE expired_claim AS
SELECT * FROM pgreact.claim_batch(
    :'rule_version_id'::uuid, 'ACTIVATE', 'm6-expired', 2, interval '1 second'
);
SELECT pg_sleep(1.1);
SELECT pgreact.sweep_expired_leases(:'rule_version_id'::uuid);

DO $$
DECLARE actual jsonb; item record;
BEGIN
    SELECT jsonb_build_object('state', state, 'diagnostic_code', diagnostic_code, 'items', items)
      INTO actual FROM pgreact.batch_history((SELECT batch_id FROM expired_claim ORDER BY item_order LIMIT 1));
    IF actual IS DISTINCT FROM '{
      "state":"REJECTED","diagnostic_code":"LEASE_EXPIRED",
      "items":[
        {"item_order":1,"episode_id":13,"attempt_no":1,"outcome":"REJECTED","error_code":"LEASE_EXPIRED","error_message":"batch lease expired before completion"},
        {"item_order":2,"episode_id":14,"attempt_no":1,"outcome":"REJECTED","error_code":"LEASE_EXPIRED","error_message":"batch lease expired before completion"}
      ]
    }'::jsonb THEN RAISE EXCEPTION 'expired batch history changed: %', actual; END IF;
    FOR item IN SELECT * FROM expired_claim ORDER BY item_order LOOP
        PERFORM pgreact.cancel_episode(item.episode_id);
    END LOOP;
END
$$;

INSERT INTO m6.facts VALUES (15, true, false), (16, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6107);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE stale_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-stale', 2);
SELECT batch_id::text AS stale_batch_id FROM stale_claim ORDER BY item_order LIMIT 1 \gset
DELETE FROM m6.facts WHERE id = 15;
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6108);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE stale_result AS
SELECT * FROM pgreact.execute_claimed_batch(:'stale_batch_id'::uuid, 'm6-stale');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(r) ORDER BY episode_id) INTO actual FROM stale_result r;
    IF actual IS DISTINCT FROM '[
      {"episode_id":15,"status":"REJECTED","error_code":"INELIGIBLE_EPISODE","error_message":"batch rejected before consequence invocation"},
      {"episode_id":16,"status":"REJECTED","error_code":"INELIGIBLE_EPISODE","error_message":"batch rejected before consequence invocation"}
    ]'::jsonb THEN RAISE EXCEPTION 'stale batch rejection changed: %', actual; END IF;
END
$$;

INSERT INTO m6.facts VALUES (17, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6109);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE singleton_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-singleton', 2);

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(c)), '[]'::jsonb) INTO actual FROM singleton_claim c;
    IF actual IS DISTINCT FROM '[]'::jsonb THEN RAISE EXCEPTION 'singleton batch was claimed: %', actual; END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'episode_id', episode_id, 'state', state, 'worker_id', worker_id,
        'attempt_count', attempt_count
    ) ORDER BY episode_id) INTO actual
    FROM pgreact.episodes WHERE episode_id = 17;
    IF actual IS DISTINCT FROM '[{"episode_id":17,"state":"PENDING","worker_id":null,"attempt_count":0}]'::jsonb THEN
        RAISE EXCEPTION 'singleton rollback changed the episode: %', actual;
    END IF;
END
$$;

INSERT INTO m6.facts VALUES (18, true, false), (19, true, false);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6110);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE structural_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-structural', 3);
SELECT batch_id::text AS structural_batch_id FROM structural_claim ORDER BY item_order LIMIT 1 \gset
SELECT set_config('m6.structural_batch_id', :'structural_batch_id', false);

CREATE TABLE m6.foreign_facts (id bigint PRIMARY KEY);
CREATE VIEW m6.foreign_active AS SELECT id FROM m6.foreign_facts;
CREATE FUNCTION m6.apply_foreign(context pgreact.activation_context, match m6.foreign_active)
RETURNS void LANGUAGE plpgsql AS 'BEGIN NULL; END';
SELECT pgreact.create_rule(
    name => 'm6-foreign', definition => 'm6.foreign_active'::regclass,
    key_columns => ARRAY['id'], kind => 'COMMAND',
    on_activate => 'm6.apply_foreign(pgreact.activation_context,m6.foreign_active)'::regprocedure
) AS foreign_version_id \gset
INSERT INTO m6.foreign_facts VALUES (20);
SELECT pgreact.begin_refresh(:'foreign_version_id'::uuid, 6111);
BEGIN; SELECT pgreact.refresh_rule(:'foreign_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'foreign_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id AS foreign_episode_id
FROM pgreact.episodes WHERE rule_version_id = :'foreign_version_id'::uuid \gset
SELECT set_config('m6.foreign_episode_id', :'foreign_episode_id', false);

CREATE FUNCTION m6.assert_rejection(expected_code text, expected_detail jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual jsonb; expected jsonb; target_batch uuid := current_setting('m6.structural_batch_id')::uuid;
BEGIN
    SELECT jsonb_build_object(
        'diagnostic_code', diagnostic_code, 'diagnostic', diagnostic, 'items', items
    ) INTO actual FROM pgreact.batch_history(target_batch);
    SELECT jsonb_build_object(
        'diagnostic_code', expected_code,
        'diagnostic', expected_detail || jsonb_build_object(
            'code', expected_code, 'message', 'batch rejected before consequence invocation'
        ),
        'items', jsonb_agg(jsonb_build_object(
            'item_order', i.item_order, 'episode_id', i.episode_id,
            'attempt_no', i.attempt_no, 'outcome', 'REJECTED',
            'error_code', expected_code,
            'error_message', 'batch rejected before consequence invocation'
        ) ORDER BY i.item_order)
    ) INTO expected
    FROM pgreact_internal.execution_batch_items i WHERE i.batch_id = target_batch;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION '% rejection diagnostic changed: %', expected_code, actual;
    END IF;
END
$$;

BEGIN;
UPDATE pgreact_internal.execution_batches SET max_items = 2
WHERE batch_id = :'structural_batch_id'::uuid;
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('OVERSIZED_OR_EMPTY', '{"items":3,"max_items":2}');
ROLLBACK;

BEGIN;
UPDATE pgreact_internal.execution_batches SET function_oid = dispatcher_oid
WHERE batch_id = :'structural_batch_id'::uuid;
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('MIXED_BINDING');
ROLLBACK;

BEGIN;
UPDATE pgreact_internal.execution_batches SET execution_role_oid = 0
WHERE batch_id = :'structural_batch_id'::uuid;
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('MIXED_ROLE');
ROLLBACK;

BEGIN;
UPDATE pgreact_internal.rule_versions SET state = 'DRAINING'
WHERE rule_version_id = :'rule_version_id'::uuid;
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('REPLACED');
ROLLBACK;

BEGIN;
UPDATE pgreact_internal.execution_batches SET conflict_key_columns = ARRAY['id']::name[]
WHERE batch_id = :'structural_batch_id'::uuid;
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('MIXED_CONFLICT_SCOPE');
ROLLBACK;

BEGIN;
ALTER TABLE pgreact_internal.execution_batches
DROP CONSTRAINT execution_batches_recheck_policy_check;
UPDATE pgreact_internal.execution_batches SET recheck_policy = 'STALE'
WHERE batch_id = :'structural_batch_id'::uuid;
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('MIXED_POLICY');
ROLLBACK;

BEGIN;
UPDATE pgreact_internal.execution_batch_items
SET episode_id = current_setting('m6.foreign_episode_id')::bigint
WHERE batch_id = :'structural_batch_id'::uuid AND item_order = 1;
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection(
    'MIXED_VERSION',
    jsonb_build_object('item_order', 1, 'episode_id', current_setting('m6.foreign_episode_id')::bigint)
);
ROLLBACK;

BEGIN;
UPDATE pgreact_internal.agenda SET event_kind = 'CHANGE'
WHERE episode_id = (SELECT episode_id FROM structural_claim WHERE item_order = 1);
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection(
    'MIXED_EVENT',
    jsonb_build_object('item_order', 1, 'episode_id', (SELECT episode_id FROM structural_claim WHERE item_order = 1))
);
ROLLBACK;

BEGIN;
UPDATE pgreact_internal.agenda SET conflict_key = 'same-conflict'
WHERE episode_id IN (SELECT episode_id FROM structural_claim WHERE item_order <= 2);
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('INCOMPATIBLE_CONFLICT', '{"conflict_key":"same-conflict"}');
ROLLBACK;

BEGIN;
ALTER TABLE pgreact_internal.batch_declarations DISABLE TRIGGER pgreact_batch_declaration_immutable;
DELETE FROM pgreact_internal.batch_declarations
WHERE rule_version_id = :'rule_version_id'::uuid AND event_kind = 'ACTIVATE';
SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');
SELECT m6.assert_rejection('UNDECLARED');
ROLLBACK;

SELECT * FROM pgreact.execute_claimed_batch(:'structural_batch_id'::uuid, 'm6-structural');

INSERT INTO m6.facts VALUES
    (20, true, true), (21, true, false), (22, true, false),
    (23, true, false), (24, true, false), (25, true, true);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6112);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE edge_failure_claim AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-first-failure', 3);
SELECT batch_id::text AS first_failure_batch_id
FROM edge_failure_claim ORDER BY item_order LIMIT 1 \gset
CREATE TEMP TABLE first_failure_result AS
SELECT * FROM pgreact.execute_claimed_batch(:'first_failure_batch_id'::uuid, 'm6-first-failure');
TRUNCATE edge_failure_claim;
INSERT INTO edge_failure_claim
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-last-failure', 3);
SELECT batch_id::text AS last_failure_batch_id
FROM edge_failure_claim ORDER BY item_order LIMIT 1 \gset
CREATE TEMP TABLE last_failure_result AS
SELECT * FROM pgreact.execute_claimed_batch(:'last_failure_batch_id'::uuid, 'm6-last-failure');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(r) ORDER BY episode_id) INTO actual FROM first_failure_result r;
    IF actual IS DISTINCT FROM '[
      {"episode_id":21,"status":"FAILED","error_code":"P6001","error_message":"intentional M6 failure for fact 20"},
      {"episode_id":22,"status":"COMPLETED","error_code":null,"error_message":null},
      {"episode_id":23,"status":"COMPLETED","error_code":null,"error_message":null}
    ]'::jsonb THEN RAISE EXCEPTION 'first-item failure output changed: %', actual; END IF;
    SELECT jsonb_agg(to_jsonb(r) ORDER BY episode_id) INTO actual FROM last_failure_result r;
    IF actual IS DISTINCT FROM '[
      {"episode_id":24,"status":"COMPLETED","error_code":null,"error_message":null},
      {"episode_id":25,"status":"COMPLETED","error_code":null,"error_message":null},
      {"episode_id":26,"status":"FAILED","error_code":"P6001","error_message":"intentional M6 failure for fact 25"}
    ]'::jsonb THEN RAISE EXCEPTION 'last-item failure output changed: %', actual; END IF;
    SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) INTO actual
    FROM m6.effects e WHERE fact_id >= 20;
    IF actual IS DISTINCT FROM '[
      {"episode_id":22,"fact_id":21},{"episode_id":23,"fact_id":22},
      {"episode_id":24,"fact_id":23},{"episode_id":25,"fact_id":24}
    ]'::jsonb THEN RAISE EXCEPTION 'edge-failure effects changed: %', actual; END IF;
END
$$;

SELECT 'M6 audited batch acceptance passed' AS result;
