\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react VERSION '0.2.0';
CREATE SCHEMA m6_upgrade;
CREATE TABLE m6_upgrade.legacy_facts (id bigint PRIMARY KEY);
CREATE TABLE m6_upgrade.batch_facts (id bigint PRIMARY KEY);
CREATE TABLE m6_upgrade.effects (episode_id bigint PRIMARY KEY, label text NOT NULL, fact_id bigint NOT NULL);
CREATE VIEW m6_upgrade.legacy_active AS SELECT id FROM m6_upgrade.legacy_facts;
CREATE VIEW m6_upgrade.batch_active AS SELECT id FROM m6_upgrade.batch_facts;
CREATE FUNCTION m6_upgrade.record_legacy(
    context pgreact.activation_context,
    match m6_upgrade.legacy_active
) RETURNS void LANGUAGE SQL
AS 'INSERT INTO m6_upgrade.effects VALUES (($1).episode_id, ''legacy'', ($2).id)';
CREATE FUNCTION m6_upgrade.record_batch(
    context pgreact.activation_context,
    match m6_upgrade.batch_active
) RETURNS void LANGUAGE SQL
AS 'INSERT INTO m6_upgrade.effects VALUES (($1).episode_id, ''batch'', ($2).id)';

SELECT pgreact.create_rule(
    'm6-upgrade-legacy', 'm6_upgrade.legacy_active'::regclass, ARRAY['id'], 'COMMAND',
    'm6_upgrade.record_legacy(pgreact.activation_context,m6_upgrade.legacy_active)'::regprocedure
) AS legacy_version_id \gset
SELECT set_config('m6.legacy_version_id', :'legacy_version_id', false);
INSERT INTO m6_upgrade.legacy_facts VALUES (1), (2), (3);
SELECT pgreact.begin_refresh(:'legacy_version_id'::uuid, 6201);
BEGIN; SELECT pgreact.refresh_rule(:'legacy_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'legacy_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
SELECT episode_id, lease_token
FROM pgreact.claim_episode(:'legacy_version_id'::uuid, 'm6-upgrade-old', 60) \gset
SELECT pgreact.execute_claimed_episode(:episode_id, 'm6-upgrade-old', :'lease_token'::uuid);

ALTER EXTENSION pg_react UPDATE TO '0.3.0';

DO $$
DECLARE actual jsonb;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.3.0'
       OR NOT pgreact.worker_protocol_compatible(1)
       OR NOT pgreact.worker_protocol_compatible(2)
       OR pgreact.worker_protocol_compatible(3) THEN
        RAISE EXCEPTION 'upgrade version or protocol compatibility changed';
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'episode_id', episode_id, 'state', state, 'attempt_count', attempt_count
    ) ORDER BY episode_id) INTO actual
    FROM pgreact.episodes WHERE rule_version_id = current_setting('m6.legacy_version_id')::uuid;
    IF actual IS DISTINCT FROM '[
      {"episode_id":1,"state":"COMPLETED","attempt_count":1},
      {"episode_id":2,"state":"PENDING","attempt_count":0},
      {"episode_id":3,"state":"PENDING","attempt_count":0}
    ]'::jsonb THEN RAISE EXCEPTION 'legacy episode state changed across upgrade: %', actual; END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'episode_id', episode_id, 'attempt_no', attempt_no, 'status', status
    ) ORDER BY episode_id, attempt_no) INTO actual FROM pgreact.execution_history();
    IF actual IS DISTINCT FROM '[{"episode_id":1,"attempt_no":1,"status":"COMPLETED"}]'::jsonb THEN
        RAISE EXCEPTION 'legacy attempt history changed across upgrade: %', actual;
    END IF;
END
$$;

DO $$
DECLARE claimed record;
BEGIN
    FOR claimed IN
        SELECT * FROM pgreact.claim('m6-upgrade-protocol-1', 2, interval '60 seconds')
    LOOP
        PERFORM pgreact.execute_claimed_episode(
            claimed.episode_id, 'm6-upgrade-protocol-1', claimed.lease_token
        );
    END LOOP;
END
$$;

SELECT pgreact.create_rule(
    'm6-upgrade-batch', 'm6_upgrade.batch_active'::regclass, ARRAY['id'], 'COMMAND',
    'm6_upgrade.record_batch(pgreact.activation_context,m6_upgrade.batch_active)'::regprocedure,
    bootstrap_policy => 'REQUIRE_EMPTY'
) AS batch_version_id \gset
SELECT pgreact.declare_batch_safe(:'batch_version_id'::uuid, 'ACTIVATE');
INSERT INTO m6_upgrade.batch_facts VALUES (10), (11);
SELECT pgreact.begin_refresh(:'batch_version_id'::uuid, 6202);
BEGIN; SELECT pgreact.refresh_rule(:'batch_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'batch_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE upgraded_claim AS
SELECT * FROM pgreact.claim_batch(:'batch_version_id'::uuid, 'ACTIVATE', 'm6-upgrade-batch', 2);
SELECT batch_id::text AS upgraded_batch_id FROM upgraded_claim ORDER BY item_order LIMIT 1 \gset
SELECT set_config('m6.upgraded_batch_id', :'upgraded_batch_id', false);
SELECT * FROM pgreact.execute_claimed_batch(:'upgraded_batch_id'::uuid, 'm6-upgrade-batch');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'episode_id', episode_id, 'label', label, 'fact_id', fact_id
    ) ORDER BY episode_id) INTO actual FROM m6_upgrade.effects;
    IF actual IS DISTINCT FROM '[
      {"episode_id":1,"label":"legacy","fact_id":1},
      {"episode_id":2,"label":"legacy","fact_id":2},
      {"episode_id":3,"label":"legacy","fact_id":3},
      {"episode_id":4,"label":"batch","fact_id":10},
      {"episode_id":5,"label":"batch","fact_id":11}
    ]'::jsonb THEN RAISE EXCEPTION 'continued effects changed after upgrade: %', actual; END IF;
    SELECT jsonb_build_object('state', state, 'items', items) INTO actual
    FROM pgreact.batch_history(current_setting('m6.upgraded_batch_id')::uuid);
    IF actual IS DISTINCT FROM '{
      "state":"COMPLETED",
      "items":[
        {"item_order":1,"episode_id":4,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null},
        {"item_order":2,"episode_id":5,"attempt_no":1,"outcome":"COMPLETED","error_code":null,"error_message":null}
      ]
    }'::jsonb THEN RAISE EXCEPTION 'upgraded batch history changed: %', actual; END IF;
END
$$;

SELECT 'M6 direct 0.2.0 to 0.3.0 upgrade checks passed' AS result;
