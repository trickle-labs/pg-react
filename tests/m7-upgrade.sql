\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react VERSION '0.3.0';
CREATE SCHEMA m7_upgrade;
CREATE TABLE m7_upgrade.command_facts (id bigint PRIMARY KEY);
CREATE TABLE m7_upgrade.effects (episode_id bigint PRIMARY KEY, fact_id bigint NOT NULL);
CREATE VIEW m7_upgrade.command_active AS SELECT id FROM m7_upgrade.command_facts;
CREATE FUNCTION m7_upgrade.record_effect(
    context pgreact.activation_context, match m7_upgrade.command_active
) RETURNS void LANGUAGE SQL AS
'INSERT INTO m7_upgrade.effects VALUES (($1).episode_id, ($2).id)';

SELECT pgreact.create_rule(
    'm7-upgrade-command', 'm7_upgrade.command_active'::regclass, ARRAY['id'], 'COMMAND',
    'm7_upgrade.record_effect(pgreact.activation_context,m7_upgrade.command_active)'::regprocedure,
    bootstrap_policy => 'REQUIRE_EMPTY'
) AS command_version_id \gset
SELECT pgreact.declare_batch_safe(:'command_version_id'::uuid, 'ACTIVATE');
INSERT INTO m7_upgrade.command_facts VALUES (10), (11);
SELECT pgreact.begin_refresh(:'command_version_id'::uuid, 7201);
BEGIN; SELECT pgreact.refresh_rule(:'command_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'command_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE held_claim AS
SELECT * FROM pgreact.claim_batch(
    :'command_version_id'::uuid, 'ACTIVATE', 'm7-upgrade-batch', 2, interval '120 seconds'
);
SELECT batch_id::text AS held_batch_id FROM held_claim ORDER BY item_order LIMIT 1 \gset
SELECT set_config('m7.upgrade_batch', :'held_batch_id', false);

CREATE TABLE m7_upgrade.pre_upgrade_snapshot (state jsonb NOT NULL);
INSERT INTO m7_upgrade.pre_upgrade_snapshot
SELECT jsonb_build_object(
    'episodes', (SELECT jsonb_agg(jsonb_build_object(
        'episode_id', episode_id, 'generation', activation_generation, 'event', event_kind,
        'state', state, 'attempt_count', attempt_count) ORDER BY episode_id)
        FROM pgreact.episodes),
    'batch', (SELECT jsonb_build_object('state', state, 'items', items)
        FROM pgreact.batch_history(current_setting('m7.upgrade_batch')::uuid))
);

ALTER EXTENSION pg_react UPDATE TO '0.4.0';

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.4.0'
       OR NOT pgreact.worker_protocol_compatible(1)
       OR NOT pgreact.worker_protocol_compatible(2)
       OR pgreact.worker_protocol_compatible(3) THEN
        RAISE EXCEPTION 'upgrade version or protocol compatibility changed';
    END IF;
    SELECT jsonb_build_object(
        'episodes', (SELECT jsonb_agg(jsonb_build_object(
            'episode_id', episode_id, 'generation', activation_generation, 'event', event_kind,
            'state', state, 'attempt_count', attempt_count) ORDER BY episode_id)
            FROM pgreact.episodes),
        'batch', (SELECT jsonb_build_object('state', state, 'items', items)
            FROM pgreact.batch_history(current_setting('m7.upgrade_batch')::uuid))
    ) INTO actual;
    SELECT state INTO expected FROM m7_upgrade.pre_upgrade_snapshot;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M6 durable state changed across M7 upgrade: %', actual;
    END IF;
END
$$;

SELECT * FROM pgreact.execute_claimed_batch(
    current_setting('m7.upgrade_batch')::uuid, 'm7-upgrade-batch'
);

CREATE TYPE m7_upgrade.derived_row AS (id bigint);
CREATE TABLE m7_upgrade.derived_source (id bigint PRIMARY KEY);
CREATE VIEW m7_upgrade.derived_active AS SELECT id FROM m7_upgrade.derived_source;
SELECT pgreact.create_derived_relation(
    'm7_upgrade.derived_fact', 'm7_upgrade.derived_row'::regtype, ARRAY['id'], 1
) AS relation_version_id \gset
SELECT pgreact.create_derivation_rule(
    'm7-upgrade-derivation', 'm7_upgrade.derived_active'::regclass, ARRAY['id'],
    :'relation_version_id'::uuid, 1
) AS derivation_version_id \gset
SELECT set_config('m7.upgrade_relation', :'relation_version_id', false),
       set_config('m7.upgrade_derivation', :'derivation_version_id', false);
INSERT INTO m7_upgrade.derived_source VALUES (7);
SELECT pgreact.refresh_derived_relation(:'relation_version_id'::uuid);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'effects', (SELECT jsonb_agg(jsonb_build_object(
            'episode_id', episode_id, 'fact_id', fact_id) ORDER BY episode_id)
            FROM m7_upgrade.effects),
        'batch', (SELECT jsonb_build_object('state', state, 'items', items)
            FROM pgreact.batch_history(current_setting('m7.upgrade_batch')::uuid)),
        'facts', (SELECT jsonb_agg(jsonb_build_object(
            'id', semantic_key, 'support_count', support_count,
            'first_frontier', first_frontier, 'last_frontier', last_frontier)
            ORDER BY semantic_key)
            FROM pgreact.current_facts(current_setting('m7.upgrade_relation')::uuid)),
        'explanation', pgreact.explain_fact(current_setting('m7.upgrade_relation')::uuid, 7),
        'agenda', (SELECT count(*) FROM pgreact.episodes
            WHERE rule_version_id = current_setting('m7.upgrade_derivation')::uuid)
    ) INTO actual;
    expected := jsonb_build_object(
        'effects', jsonb_build_array(
            jsonb_build_object('episode_id', 1, 'fact_id', 10),
            jsonb_build_object('episode_id', 2, 'fact_id', 11)),
        'batch', jsonb_build_object(
            'state', 'COMPLETED',
            'items', jsonb_build_array(
                jsonb_build_object('item_order', 1, 'episode_id', 1, 'attempt_no', 1,
                    'outcome', 'COMPLETED', 'error_code', NULL, 'error_message', NULL),
                jsonb_build_object('item_order', 2, 'episode_id', 2, 'attempt_no', 1,
                    'outcome', 'COMPLETED', 'error_code', NULL, 'error_message', NULL))),
        'facts', jsonb_build_array(jsonb_build_object(
            'id', 7, 'support_count', 1, 'first_frontier', 1, 'last_frontier', 1)),
        'explanation', jsonb_build_object(
            'relation', 'm7_upgrade.derived_fact@1',
            'fact', jsonb_build_object('id', 7),
            'active_supports', jsonb_build_array(jsonb_build_object(
                'rule', 'm7-upgrade-derivation@1',
                'activation_generation', 1,
                'source_binding', jsonb_build_object('id', 7)))),
        'agenda', 0);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M7 post-upgrade workflow changed: %', actual;
    END IF;
END
$$;

SELECT 'M7 direct 0.3.0 to 0.4.0 upgrade checks passed' AS result;
