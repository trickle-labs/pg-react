\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
SET TIME ZONE 'UTC';

CREATE SCHEMA managed_fairness;
CREATE TABLE managed_fairness.source(
    cohort text NOT NULL,
    id bigint PRIMARY KEY,
    payload text NOT NULL
);
CREATE VIEW managed_fairness.low_candidate AS
    SELECT id, payload FROM managed_fairness.source WHERE cohort = 'low';
CREATE VIEW managed_fairness.high_candidate AS
    SELECT id, payload FROM managed_fairness.source WHERE cohort = 'high';
CREATE TABLE managed_fairness.actions(
    activation_id uuid PRIMARY KEY,
    rule_name text NOT NULL,
    id bigint NOT NULL,
    payload text NOT NULL
);

CREATE FUNCTION managed_fairness.activate_low(
    context pgreact.activation_context, candidate managed_fairness.low_candidate
) RETURNS void LANGUAGE SQL AS $callback$
    INSERT INTO managed_fairness.actions
    VALUES ((context).activation_id, 'managed-fairness-low', (candidate).id, (candidate).payload)
$callback$;
CREATE FUNCTION managed_fairness.activate_high(
    context pgreact.activation_context, candidate managed_fairness.high_candidate
) RETURNS void LANGUAGE SQL AS $callback$
    INSERT INTO managed_fairness.actions
    VALUES ((context).activation_id, 'managed-fairness-high', (candidate).id, (candidate).payload)
$callback$;

SELECT pgreact.create_rule(
    'managed-fairness-low', 'managed_fairness.low_candidate'::regclass, ARRAY['id'], 'COMMAND',
    'managed_fairness.activate_low(pgreact.activation_context,managed_fairness.low_candidate)'::regprocedure,
    NULL, NULL, 'SEED_CURRENT', ARRAY['payload'], 0, 'fairness', ARRAY['id']) AS low_version \gset
SELECT pgreact.create_rule(
    'managed-fairness-high', 'managed_fairness.high_candidate'::regclass, ARRAY['id'], 'COMMAND',
    'managed_fairness.activate_high(pgreact.activation_context,managed_fairness.high_candidate)'::regprocedure,
    NULL, NULL, 'SEED_CURRENT', ARRAY['payload'], 99, 'fairness', ARRAY['id']) AS high_version \gset

INSERT INTO managed_fairness.source VALUES
    ('low', 1, 'low-1'),
    ('high', 101, 'high-101'),
    ('high', 102, 'high-102');

SELECT pgreact.begin_refresh(:'low_version'::uuid, 30001);
BEGIN; SELECT pgreact.refresh_rule(:'low_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'low_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT pgreact.begin_refresh(:'high_version'::uuid, 30002);
BEGIN; SELECT pgreact.refresh_rule(:'high_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'high_version'::uuid); SELECT pgreact.release_refresh_lock();

CREATE FUNCTION managed_fairness.state() RETURNS jsonb LANGUAGE SQL AS $state$
    SELECT jsonb_build_object(
        'actions', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'name', rule_name, 'id', id, 'payload', payload) ORDER BY rule_name, id), '[]')
            FROM managed_fairness.actions),
        'work', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'name', w.name, 'id', (a.new_bindings->>'id')::bigint,
            'salience', a.salience, 'state', a.state, 'claimable', w.claimable)
            ORDER BY w.name, (a.new_bindings->>'id')::bigint), '[]')
            FROM pgreact_internal.agenda a
            JOIN pgreact.work w ON w.work_id = a.episode_id::text
            WHERE w.name IN ('managed-fairness-high', 'managed-fairness-low')),
        'attempts', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'name', e.name, 'id', (a.new_bindings->>'id')::bigint,
            'attempt_no', e.attempt_no, 'status', e.status, 'error_code', e.error_code)
            ORDER BY e.name, (a.new_bindings->>'id')::bigint), '[]')
            FROM pgreact_internal.agenda a
            JOIN pgreact.attempts e USING (episode_id)
            WHERE e.name IN ('managed-fairness-high', 'managed-fairness-low')))
$state$;

CREATE FUNCTION managed_fairness.expected_state(
    low_completed boolean, high_101_completed boolean, high_102_completed boolean
) RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $expected$
    WITH expected(name, id, payload, salience, completed) AS (
        VALUES ('managed-fairness-low'::text, 1::bigint, 'low-1'::text, 0, low_completed),
               ('managed-fairness-high'::text, 101::bigint, 'high-101'::text, 99, high_101_completed),
               ('managed-fairness-high'::text, 102::bigint, 'high-102'::text, 99, high_102_completed)
    )
    SELECT jsonb_build_object(
        'actions', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'name', name, 'id', id, 'payload', payload) ORDER BY name, id), '[]')
            FROM expected WHERE completed),
        'work', (SELECT jsonb_agg(jsonb_build_object(
            'name', name, 'id', id, 'salience', salience,
            'state', CASE WHEN completed THEN 'COMPLETED' ELSE 'PENDING' END,
            'claimable', NOT completed) ORDER BY name, id)
            FROM expected),
        'attempts', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'name', name, 'id', id, 'attempt_no', 1, 'status', 'COMPLETED', 'error_code', NULL)
            ORDER BY name, id), '[]') FROM expected WHERE completed))
$expected$;

CREATE TABLE managed_fairness.evidence(cycle integer PRIMARY KEY, result jsonb NOT NULL, state jsonb NOT NULL);
DO $cycles$
DECLARE result jsonb; actual jsonb; low_version uuid; high_version uuid;
BEGIN
    SELECT rule_version_id INTO STRICT low_version FROM pgreact.rules
    WHERE rule_name = 'managed-fairness-low';
    SELECT rule_version_id INTO STRICT high_version FROM pgreact.rules
    WHERE rule_name = 'managed-fairness-high';
    IF (SELECT fairness_window FROM pgreact_internal.operational_settings) IS DISTINCT FROM interval '30 seconds'
       OR current_setting('pg_react.batch_size')::integer <> 1 THEN
        RAISE EXCEPTION 'qualification requires a 30-second fairness window and one claim per cycle';
    END IF;
    UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '10 seconds'
    WHERE rule_version_id = low_version AND state = 'PENDING';
    UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '1 second'
    WHERE rule_version_id = high_version AND state = 'PENDING';

    result := pgreact_api.managed_cycle();
    actual := managed_fairness.state();
    IF actual IS DISTINCT FROM managed_fairness.expected_state(false, true, false)
       OR (result - 'run' - 'runtime_state') IS DISTINCT FROM
          '{"state":"ready","processed_jobs":1,"pending_jobs":2}'::jsonb THEN
        RAISE EXCEPTION 'first managed cycle did not execute high-salience work within the fairness window: % / %', result, actual;
    END IF;
    INSERT INTO managed_fairness.evidence VALUES (1, result - 'run' - 'runtime_state', actual);

    UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '31 seconds'
    WHERE rule_version_id = low_version AND state = 'PENDING';
    UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '1 second'
    WHERE rule_version_id = high_version AND state = 'PENDING';
    result := pgreact_api.managed_cycle();
    actual := managed_fairness.state();
    IF actual IS DISTINCT FROM managed_fairness.expected_state(true, true, false)
       OR (result - 'run' - 'runtime_state') IS DISTINCT FROM
          '{"state":"ready","processed_jobs":1,"pending_jobs":1}'::jsonb THEN
        RAISE EXCEPTION 'second managed cycle did not prioritize work past the fairness window: % / %', result, actual;
    END IF;
    INSERT INTO managed_fairness.evidence VALUES (2, result - 'run' - 'runtime_state', actual);

    IF (SELECT jsonb_agg(to_jsonb(source_row) ORDER BY id) FROM managed_fairness.source source_row)
       IS DISTINCT FROM '[{"cohort":"low","id":1,"payload":"low-1"},'
                         '{"cohort":"high","id":101,"payload":"high-101"},'
                         '{"cohort":"high","id":102,"payload":"high-102"}]'::jsonb THEN
        RAISE EXCEPTION 'managed-cycle fairness changed source rows';
    END IF;
END
$cycles$;

CREATE SCHEMA managed_fairness_conflict;
CREATE TABLE managed_fairness_conflict.source(
    cohort text NOT NULL,
    id bigint PRIMARY KEY,
    payload text NOT NULL,
    conflict_slot text NOT NULL
);
CREATE VIEW managed_fairness_conflict.low_candidate AS
    SELECT id, payload, conflict_slot FROM managed_fairness_conflict.source WHERE cohort = 'low';
CREATE VIEW managed_fairness_conflict.high_candidate AS
    SELECT id, payload, conflict_slot FROM managed_fairness_conflict.source WHERE cohort = 'high';
CREATE FUNCTION managed_fairness_conflict.activate_low(
    context pgreact.activation_context, candidate managed_fairness_conflict.low_candidate
) RETURNS void LANGUAGE plpgsql AS $callback$
BEGIN
    RETURN;
END
$callback$;
CREATE FUNCTION managed_fairness_conflict.activate_high(
    context pgreact.activation_context, candidate managed_fairness_conflict.high_candidate
) RETURNS void LANGUAGE plpgsql AS $callback$
BEGIN
    RETURN;
END
$callback$;

SELECT pgreact.create_rule(
    'managed-fairness-conflict-low', 'managed_fairness_conflict.low_candidate'::regclass,
    ARRAY['id'], 'COMMAND',
    'managed_fairness_conflict.activate_low(pgreact.activation_context,managed_fairness_conflict.low_candidate)'::regprocedure,
    NULL, NULL, 'SEED_CURRENT', ARRAY['payload', 'conflict_slot'], 0, 'fairness-conflict', ARRAY['conflict_slot']) AS low_version \gset
SELECT pgreact.create_rule(
    'managed-fairness-conflict-high', 'managed_fairness_conflict.high_candidate'::regclass,
    ARRAY['id'], 'COMMAND',
    'managed_fairness_conflict.activate_high(pgreact.activation_context,managed_fairness_conflict.high_candidate)'::regprocedure,
    NULL, NULL, 'SEED_CURRENT', ARRAY['payload', 'conflict_slot'], 99, 'fairness-conflict', ARRAY['conflict_slot']) AS high_version \gset

INSERT INTO managed_fairness_conflict.source VALUES
    ('low', 1, 'held', 'shared'),
    ('high', 99, 'high-99', 'high');
SELECT pgreact.begin_refresh(:'low_version'::uuid, 31001);
BEGIN; SELECT pgreact.refresh_rule(:'low_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'low_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT pgreact.begin_refresh(:'high_version'::uuid, 31002);
BEGIN; SELECT pgreact.refresh_rule(:'high_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'high_version'::uuid); SELECT pgreact.release_refresh_lock();

SELECT episode_id
FROM pgreact.claim_episode(:'low_version'::uuid, 'conflict-holder', 300);

INSERT INTO managed_fairness_conflict.source VALUES
    ('low', 2, 'aged-blocked', 'shared'),
    ('low', 3, 'fresh-free', 'free');
SELECT pgreact.begin_refresh(:'low_version'::uuid, 31003);
BEGIN; SELECT pgreact.refresh_rule(:'low_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'low_version'::uuid); SELECT pgreact.release_refresh_lock();

UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '31 seconds'
WHERE rule_version_id = :'low_version'::uuid AND new_bindings->>'id' = '2' AND state = 'PENDING';
UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '1 second'
WHERE rule_version_id = :'low_version'::uuid AND new_bindings->>'id' = '3' AND state = 'PENDING';
UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '1 second'
WHERE rule_version_id = :'high_version'::uuid AND new_bindings->>'id' = '99' AND state = 'PENDING';

CREATE TEMP TABLE claim_fairness_claimed AS
SELECT * FROM pgreact.claim(
    'global-fairness-probe', 1, interval '60 seconds', ARRAY['fairness-conflict']);

DO $conflict_fairness$
DECLARE actual jsonb; expected jsonb; fresh_low_state jsonb; free_conflict_leases jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(claimed) ORDER BY claimed.episode_id), '[]'::jsonb)
    INTO actual FROM claim_fairness_claimed claimed;
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'episode_id', agenda.episode_id, 'lease_token', agenda.lease_token,
        'activation_id', agenda.activation_id, 'bindings', agenda.new_bindings,
        'event_kind', agenda.event_kind, 'rule_version_id', agenda.rule_version_id)
        ORDER BY agenda.episode_id), '[]'::jsonb)
    INTO expected
    FROM pgreact_internal.agenda agenda
    WHERE agenda.rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                                    WHERE rule_name = 'managed-fairness-conflict-high')
      AND agenda.new_bindings->>'id' = '99'
      AND agenda.state = 'LEASED'
      AND agenda.worker_id = 'global-fairness-probe';
    IF jsonb_array_length(actual) <> 1 OR jsonb_array_length(expected) <> 1
       OR actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'global conflict fairness did not return the exact eligible high-salience claim: actual %, expected %', actual, expected;
    END IF;
    SELECT jsonb_build_object(
        'state', agenda.state, 'attempt_count', agenda.attempt_count,
        'worker_id', agenda.worker_id, 'lease_token', agenda.lease_token,
        'claimed_at', agenda.claimed_at, 'lease_expires_at', agenda.lease_expires_at)
    INTO fresh_low_state
    FROM pgreact_internal.agenda agenda
    WHERE agenda.rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                                    WHERE rule_name = 'managed-fairness-conflict-low')
      AND agenda.new_bindings->>'id' = '3';
    IF fresh_low_state IS DISTINCT FROM
       '{"state":"PENDING","attempt_count":0,"worker_id":null,"lease_token":null,"claimed_at":null,"lease_expires_at":null}'::jsonb THEN
        RAISE EXCEPTION 'mismatched fresh low-salience claim was not fully restored: %', fresh_low_state;
    END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(lease) ORDER BY lease.episode_id), '[]'::jsonb)
    INTO free_conflict_leases
    FROM pgreact_internal.conflict_leases lease
    JOIN pgreact_internal.agenda agenda USING (episode_id)
    WHERE agenda.rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                                    WHERE rule_name = 'managed-fairness-conflict-low')
      AND agenda.new_bindings->>'id' = '3';
    IF free_conflict_leases IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'restored fresh low-salience claim retained a conflict lease: %', free_conflict_leases;
    END IF;
END
$conflict_fairness$;

CREATE SCHEMA managed_fairness_concurrent;
CREATE TABLE managed_fairness_concurrent.source(
    cohort text NOT NULL,
    id bigint PRIMARY KEY,
    payload text NOT NULL
);
CREATE VIEW managed_fairness_concurrent.low_candidate AS
    SELECT id, payload FROM managed_fairness_concurrent.source WHERE cohort = 'low';
CREATE VIEW managed_fairness_concurrent.high_candidate AS
    SELECT id, payload FROM managed_fairness_concurrent.source WHERE cohort = 'high';
CREATE FUNCTION managed_fairness_concurrent.activate_low(
    context pgreact.activation_context, candidate managed_fairness_concurrent.low_candidate
) RETURNS void LANGUAGE plpgsql AS $callback$
BEGIN
    RETURN;
END
$callback$;
CREATE FUNCTION managed_fairness_concurrent.activate_high(
    context pgreact.activation_context, candidate managed_fairness_concurrent.high_candidate
) RETURNS void LANGUAGE plpgsql AS $callback$
BEGIN
    RETURN;
END
$callback$;

SELECT pgreact.create_rule(
    'managed-fairness-concurrent-low', 'managed_fairness_concurrent.low_candidate'::regclass,
    ARRAY['id'], 'COMMAND',
    'managed_fairness_concurrent.activate_low(pgreact.activation_context,managed_fairness_concurrent.low_candidate)'::regprocedure,
    NULL, NULL, 'SEED_CURRENT', ARRAY['payload'], 0, 'managed-fairness-concurrent', ARRAY['id']) AS low_version \gset
SELECT pgreact.create_rule(
    'managed-fairness-concurrent-high', 'managed_fairness_concurrent.high_candidate'::regclass,
    ARRAY['id'], 'COMMAND',
    'managed_fairness_concurrent.activate_high(pgreact.activation_context,managed_fairness_concurrent.high_candidate)'::regprocedure,
    NULL, NULL, 'SEED_CURRENT', ARRAY['payload'], 99, 'managed-fairness-concurrent', ARRAY['id']) AS high_version \gset
INSERT INTO managed_fairness_concurrent.source VALUES
    ('high', 201, 'high-201'),
    ('high', 202, 'high-202'),
    ('low', 1, 'low-1');
SELECT pgreact.begin_refresh(:'low_version'::uuid, 32001);
BEGIN; SELECT pgreact.refresh_rule(:'low_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'low_version'::uuid); SELECT pgreact.release_refresh_lock();
SELECT pgreact.begin_refresh(:'high_version'::uuid, 32002);
BEGIN; SELECT pgreact.refresh_rule(:'high_version'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'high_version'::uuid); SELECT pgreact.release_refresh_lock();
UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '10 seconds'
WHERE rule_version_id = :'low_version'::uuid AND state = 'PENDING';
UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '2 seconds'
WHERE rule_version_id = :'high_version'::uuid AND new_bindings->>'id' = '201' AND state = 'PENDING';
UPDATE pgreact_internal.agenda SET available_at = clock_timestamp() - interval '1 second'
WHERE rule_version_id = :'high_version'::uuid AND new_bindings->>'id' = '202' AND state = 'PENDING';

CREATE FUNCTION managed_fairness_concurrent.claim_and_hold(worker_name text)
RETURNS jsonb LANGUAGE plpgsql AS $hold$
DECLARE result jsonb;
BEGIN
    SELECT to_jsonb(claimed) INTO STRICT result
    FROM pgreact.claim(worker_name, 1, interval '60 seconds',
                       ARRAY['managed-fairness-concurrent']) AS claimed;
    PERFORM pg_sleep(2);
    RETURN result;
END
$hold$;
CREATE TABLE managed_fairness.concurrent_evidence(claims jsonb NOT NULL, state jsonb NOT NULL);

DO $concurrent_fairness$
DECLARE sent_holder integer; sent_second integer; attempt integer;
    holder_sleeping integer; second_waiting integer;
    holder_claim jsonb; second_claim jsonb; expected jsonb;
    high_state jsonb; low_state jsonb; state_vector jsonb;
BEGIN
    PERFORM dblink_connect('managed_fairness_holder',
        format('dbname=%L application_name=%L', current_database(), 'managed_fairness_holder'));
    PERFORM dblink_connect('managed_fairness_second',
        format('dbname=%L application_name=%L', current_database(), 'managed_fairness_second'));
    sent_holder := dblink_send_query('managed_fairness_holder',
        $remote$SELECT managed_fairness_concurrent.claim_and_hold('global-fairness-holder')$remote$);
    IF sent_holder <> 1 THEN
        RAISE EXCEPTION 'could not start the first concurrent fairness claim: %', sent_holder;
    END IF;
    holder_sleeping := 0;
    FOR attempt IN 1..500 LOOP
        SELECT count(*) INTO holder_sleeping
        FROM pg_catalog.pg_stat_activity
        WHERE application_name = 'managed_fairness_holder'
          AND wait_event_type = 'Timeout' AND wait_event = 'PgSleep';
        EXIT WHEN holder_sleeping = 1;
        PERFORM pg_sleep(0.01);
    END LOOP;
    IF holder_sleeping <> 1 THEN
        RAISE EXCEPTION 'first concurrent fairness claim did not hold its transaction after claiming';
    END IF;

    sent_second := dblink_send_query('managed_fairness_second',
        $remote$SELECT to_jsonb(claimed)
                 FROM pgreact.claim('global-fairness-second', 1, interval '60 seconds',
                                    ARRAY['managed-fairness-concurrent']) AS claimed$remote$);
    IF sent_second <> 1 THEN
        RAISE EXCEPTION 'could not start the second concurrent fairness claim: %', sent_second;
    END IF;
    second_waiting := 0;
    FOR attempt IN 1..500 LOOP
        SELECT count(*) INTO second_waiting
        FROM pg_catalog.pg_stat_activity
        WHERE application_name = 'managed_fairness_second'
          AND wait_event_type = 'Lock';
        EXIT WHEN second_waiting = 1;
        PERFORM pg_sleep(0.01);
    END LOOP;
    IF second_waiting <> 1 THEN
        RAISE EXCEPTION 'second concurrent fairness claim did not wait behind the first rule claim';
    END IF;

    SELECT result.claim INTO STRICT holder_claim
    FROM dblink_get_result('managed_fairness_holder') AS result(claim jsonb);
    SELECT result.claim INTO STRICT second_claim
    FROM dblink_get_result('managed_fairness_second') AS result(claim jsonb);
    PERFORM dblink_disconnect('managed_fairness_holder');
    PERFORM dblink_disconnect('managed_fairness_second');

    SELECT jsonb_build_object(
        'episode_id', agenda.episode_id, 'lease_token', agenda.lease_token,
        'activation_id', agenda.activation_id, 'bindings', agenda.new_bindings,
        'event_kind', agenda.event_kind, 'rule_version_id', agenda.rule_version_id)
    INTO STRICT expected
    FROM pgreact_internal.agenda agenda
    WHERE agenda.rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                                    WHERE rule_name = 'managed-fairness-concurrent-high')
      AND agenda.new_bindings->>'id' = '201'
      AND agenda.state = 'LEASED'
      AND agenda.worker_id = 'global-fairness-holder';
    IF holder_claim IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'first concurrent worker did not return the exact highest-priority claim: %, expected %',
            holder_claim, expected;
    END IF;
    SELECT jsonb_build_object(
        'episode_id', agenda.episode_id, 'lease_token', agenda.lease_token,
        'activation_id', agenda.activation_id, 'bindings', agenda.new_bindings,
        'event_kind', agenda.event_kind, 'rule_version_id', agenda.rule_version_id)
    INTO STRICT expected
    FROM pgreact_internal.agenda agenda
    WHERE agenda.rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                                    WHERE rule_name = 'managed-fairness-concurrent-high')
      AND agenda.new_bindings->>'id' = '202'
      AND agenda.state = 'LEASED'
      AND agenda.worker_id = 'global-fairness-second';
    IF second_claim IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'second concurrent worker did not return the exact next high-salience claim: %, expected %',
            second_claim, expected;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'id', (agenda.new_bindings->>'id')::bigint,
        'worker_id', agenda.worker_id, 'state', agenda.state,
        'attempt_count', agenda.attempt_count) ORDER BY agenda.new_bindings->>'id')
    INTO high_state
    FROM pgreact_internal.agenda agenda
    WHERE agenda.rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                                    WHERE rule_name = 'managed-fairness-concurrent-high');
    IF high_state IS DISTINCT FROM
       '[{"id":201,"worker_id":"global-fairness-holder","state":"LEASED","attempt_count":1},'
        '{"id":202,"worker_id":"global-fairness-second","state":"LEASED","attempt_count":1}]'::jsonb THEN
        RAISE EXCEPTION 'concurrent high-salience work was not claimed once in order: %', high_state;
    END IF;
    SELECT jsonb_build_object(
        'state', agenda.state, 'attempt_count', agenda.attempt_count,
        'worker_id', agenda.worker_id, 'lease_token', agenda.lease_token,
        'claimed_at', agenda.claimed_at, 'lease_expires_at', agenda.lease_expires_at)
    INTO STRICT low_state
    FROM pgreact_internal.agenda agenda
    WHERE agenda.rule_version_id = (SELECT rule_version_id FROM pgreact.rules
                                    WHERE rule_name = 'managed-fairness-concurrent-low');
    IF low_state IS DISTINCT FROM
       '{"state":"PENDING","attempt_count":0,"worker_id":null,"lease_token":null,"claimed_at":null,"lease_expires_at":null}'::jsonb THEN
        RAISE EXCEPTION 'concurrent workers claimed low-salience work before both high items: %', low_state;
    END IF;
    state_vector := jsonb_build_object('high', high_state, 'low',
        low_state - 'lease_token' - 'claimed_at' - 'lease_expires_at');
    INSERT INTO managed_fairness.concurrent_evidence
    VALUES (jsonb_build_object('holder', holder_claim, 'second', second_claim), state_vector);
EXCEPTION WHEN OTHERS THEN
    BEGIN PERFORM dblink_cancel_query('managed_fairness_holder'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_cancel_query('managed_fairness_second'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('managed_fairness_holder'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('managed_fairness_second'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
END
$concurrent_fairness$;
SELECT 'managed-cycle fairness state vectors passed';
SELECT 'global claim conflict fairness state vector passed';
SELECT 'concurrent global claim fairness state vector passed';
