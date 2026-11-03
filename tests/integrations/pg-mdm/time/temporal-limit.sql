\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE EXTENSION dblink;
CREATE SCHEMA temporal_limit;
CREATE TABLE temporal_limit.source (id bigint PRIMARY KEY);
CREATE VIEW temporal_limit.condition AS SELECT id FROM temporal_limit.source;
CREATE TABLE temporal_limit.clock_samples (sampled_time timestamptz NOT NULL);
UPDATE pgreact_internal.operational_settings
SET max_temporal_keys_per_pass = 1;

CREATE FUNCTION temporal_limit.state_vector()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $state$
DECLARE version_row record; match_rows jsonb; matches jsonb := '[]'::jsonb;
BEGIN
    FOR version_row IN
        SELECT rule.rule_name, version.match_relid
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        ORDER BY rule.rule_name
    LOOP
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY to_jsonb(entry)::text), ''[]''::jsonb) FROM %s entry',
            version_row.match_relid::regclass) INTO match_rows;
        matches := matches || jsonb_build_array(jsonb_build_object(
            'rule_name', version_row.rule_name, 'rows', match_rows));
    END LOOP;
    RETURN jsonb_build_object(
        'rules', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.rule_id), '[]'::jsonb)
                  FROM pgreact_internal.rules entry),
        'versions', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.rule_version_id), '[]'::jsonb)
                     FROM pgreact_internal.rule_versions entry),
        'temporal_rules', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.rule_version_id), '[]'::jsonb)
                           FROM pgreact_internal.temporal_rules entry),
        'temporal_state', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.rule_version_id, entry.semantic_key), '[]'::jsonb)
                           FROM pgreact_internal.temporal_state entry),
        'temporal_history', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.temporal_event_id), '[]'::jsonb)
                             FROM pgreact_internal.temporal_history entry),
        'activation_state', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.rule_version_id, entry.semantic_key), '[]'::jsonb)
                             FROM pgreact_internal.activation_state entry),
        'lifecycle_events', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.event_id), '[]'::jsonb)
                             FROM pgreact_internal.lifecycle_events entry),
        'agenda', (SELECT COALESCE(jsonb_agg(to_jsonb(entry) ORDER BY entry.episode_id), '[]'::jsonb)
                   FROM pgreact_internal.agenda entry),
        'matches', matches);
END
$state$;

CREATE FUNCTION temporal_limit.try_concurrent_author(target_name text)
RETURNS text LANGUAGE plpgsql AS $attempt$
DECLARE actual_message text;
BEGIN
    PERFORM pgreact_api.author_temporal_rule(
        target_name, 'temporal_limit.condition'::regclass,
        'id', 'DURATION', interval '1 day');
    RETURN 'ACCEPTED:' || target_name;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
    RETURN 'REJECTED:' || actual_message;
END
$attempt$;

CREATE FUNCTION temporal_limit.try_concurrent_reconcile(target_name text)
RETURNS text LANGUAGE plpgsql AS $attempt$
DECLARE actual_message text;
BEGIN
    PERFORM pgreact_api.reconcile_temporal_rule(target_name);
    RETURN 'RECONCILED:' || target_name;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
    RETURN 'REJECTED:' || actual_message;
END
$attempt$;

CREATE FUNCTION temporal_limit.try_concurrent_refresh(target_name text)
RETURNS text LANGUAGE plpgsql AS $attempt$
DECLARE actual_message text; version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = target_name AND version.state = 'ACTIVE';
    PERFORM pgreact.refresh_rule(version_id);
    RETURN 'REFRESHED:' || target_name;
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
    RETURN 'REJECTED:' || actual_message;
END
$attempt$;

CREATE FUNCTION temporal_limit.assert_empty_run(sample timestamptz, previous_frontier timestamptz)
RETURNS void LANGUAGE plpgsql AS $run$
DECLARE actual jsonb; expected jsonb;
BEGIN
    actual := pgreact_api.run(sample);
    expected := jsonb_build_object(
        'contract_version', 15, 'sampled_time', sample, 'frontier', sample,
        'rules', '[]'::jsonb, 'programs', '[]'::jsonb, 'relations', '[]'::jsonb,
        'policy_sets', '[]'::jsonb, 'jobs_created', 0, 'temporal_changed', 0,
        'clock', jsonb_build_object('sampled_time', sample, 'previous_frontier', previous_frontier,
            'frontier', sample, 'affected_keys', 0, 'affected_rules', 0),
        'decision_analyses', jsonb_build_object('analyses', '[]'::jsonb, 'frontier', sample, 'contract_version', 15),
        'decision_programs', jsonb_build_object('programs', '[]'::jsonb, 'subjects', '[]'::jsonb,
            'frontier', sample, 'contract_version', 14,
            'selection', 'lowest priority wins; an equal best priority is ambiguous'),
        'effective_policies', jsonb_build_object('changed', '[]'::jsonb, 'frontier', sample, 'transitions', 0),
        'parameter_families', jsonb_build_object('families', '[]'::jsonb, 'frontier', sample, 'contract_version', 13),
        'frontier_invariant', jsonb_build_object('sampled_time', sample, 'frontier', sample));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'empty managed run vector differs: %', actual;
    END IF;
END
$run$;

DO $initial_run$
DECLARE previous_frontier timestamptz; sample timestamptz;
BEGIN
    previous_frontier := (pgreact_api.health() ->> 'clock_frontier')::timestamptz;
    sample := GREATEST(clock_timestamp(), COALESCE(previous_frontier, '-infinity'::timestamptz))
        + interval '1 minute';
    PERFORM temporal_limit.assert_empty_run(sample, previous_frontier);
    INSERT INTO temporal_limit.clock_samples VALUES (sample);
END
$initial_run$;

INSERT INTO temporal_limit.source VALUES (1), (2);

DO $author_limit$
DECLARE before_state jsonb; actual_message text;
BEGIN
    before_state := temporal_limit.state_vector();
    BEGIN
        PERFORM pgreact_api.author_temporal_rule(
            'temporal-limit-overflow', 'temporal_limit.condition'::regclass,
            'id', 'DURATION', interval '1 day');
        RAISE EXCEPTION 'test expected temporal authoring to exceed the configured limit';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
        IF actual_message IS DISTINCT FROM
           'M23_TEMPORAL_LIMIT: 2 temporal keys exceed max_temporal_keys_per_pass 1' THEN
            RAISE EXCEPTION 'temporal authoring returned the wrong result: %', actual_message;
        END IF;
    END;
    IF temporal_limit.state_vector() IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'over-limit temporal authoring changed the complete rule state';
    END IF;
END
$author_limit$;

DO $healthy_run$
DECLARE sample timestamptz; previous_frontier timestamptz;
BEGIN
    SELECT sampled_time INTO STRICT previous_frontier FROM temporal_limit.clock_samples;
    sample := previous_frontier + interval '1 second';
    PERFORM temporal_limit.assert_empty_run(sample, previous_frontier);
END
$healthy_run$;

DELETE FROM temporal_limit.source WHERE id = 2;
SELECT pgreact_api.author_temporal_rule(
    'temporal-limit-one-key', 'temporal_limit.condition'::regclass,
    'id', 'DURATION', interval '1 day');
DO $target_key_seeded$
DECLARE actual jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(semantic_key ORDER BY semantic_key), '[]'::jsonb)
    INTO actual
    FROM pgreact_internal.temporal_state
    WHERE rule_version_id = (
        SELECT version.rule_version_id
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name = 'temporal-limit-one-key');
    IF actual IS DISTINCT FROM '[1]'::jsonb THEN
        RAISE EXCEPTION 'one-key temporal authoring seeded unexpected state: %', actual;
    END IF;
END
$target_key_seeded$;

DO $cross_rule_limit$
DECLARE before_state jsonb; actual_message text;
BEGIN
    before_state := temporal_limit.state_vector();
    BEGIN
        PERFORM pgreact_api.author_temporal_rule(
            'temporal-limit-second-rule', 'temporal_limit.condition'::regclass,
            'id', 'DURATION', interval '1 day');
        RAISE EXCEPTION 'test expected cross-rule temporal authoring to exceed the configured limit';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
        IF actual_message IS DISTINCT FROM
           'M23_TEMPORAL_LIMIT: 2 temporal keys exceed max_temporal_keys_per_pass 1' THEN
            RAISE EXCEPTION 'cross-rule temporal authoring returned the wrong result: %', actual_message;
        END IF;
    END;
    IF temporal_limit.state_vector() IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'over-limit cross-rule authoring changed the complete rule state';
    END IF;
END
$cross_rule_limit$;

INSERT INTO temporal_limit.source VALUES (2);

DO $direct_reconcile_limit$
DECLARE before_state jsonb; actual_message text;
BEGIN
    before_state := temporal_limit.state_vector();
    BEGIN
        PERFORM pgreact_api.reconcile_temporal_rule('temporal-limit-one-key');
        RAISE EXCEPTION 'test expected direct temporal reconciliation to exceed the configured limit';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
        IF actual_message IS DISTINCT FROM
           'M23_TEMPORAL_LIMIT: 2 temporal keys exceed max_temporal_keys_per_pass 1' THEN
            RAISE EXCEPTION 'direct temporal reconciliation returned the wrong result: %', actual_message;
        END IF;
    END;
    IF temporal_limit.state_vector() IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'over-limit direct reconciliation changed the complete rule state';
    END IF;
END
$direct_reconcile_limit$;

DO $generic_refresh_limit$
DECLARE before_state jsonb; actual_message text; version_id uuid;
BEGIN
    before_state := temporal_limit.state_vector();
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = 'temporal-limit-one-key';
    BEGIN
        PERFORM pgreact.refresh_rule(version_id);
        RAISE EXCEPTION 'test expected generic temporal refresh to exceed the configured limit';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
        IF actual_message IS DISTINCT FROM
           'M23_TEMPORAL_LIMIT: 2 temporal keys exceed max_temporal_keys_per_pass 1' THEN
            RAISE EXCEPTION 'generic temporal refresh returned the wrong result: %', actual_message;
        END IF;
    END;
    IF temporal_limit.state_vector() IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'over-limit generic temporal refresh changed the complete rule state';
    END IF;
END
$generic_refresh_limit$;

SELECT pgreact_api.pause_temporal_rule('temporal-limit-one-key');

DO $generic_resume_limit$
DECLARE before_state jsonb; actual_message text; version_id uuid;
BEGIN
    before_state := temporal_limit.state_vector();
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = 'temporal-limit-one-key';
    BEGIN
        PERFORM pgreact.resume_rule(version_id);
        RAISE EXCEPTION 'test expected generic temporal resume to exceed the configured limit';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
        IF actual_message IS DISTINCT FROM
           'M23_TEMPORAL_LIMIT: 2 temporal keys exceed max_temporal_keys_per_pass 1' THEN
            RAISE EXCEPTION 'generic temporal resume returned the wrong result: %', actual_message;
        END IF;
    END;
    IF temporal_limit.state_vector() IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'over-limit generic temporal resume changed the complete rule state';
    END IF;
END
$generic_resume_limit$;

DO $resume_limit$
DECLARE before_state jsonb; actual_message text;
BEGIN
    before_state := temporal_limit.state_vector();
    BEGIN
        PERFORM pgreact_api.resume_temporal_rule('temporal-limit-one-key');
        RAISE EXCEPTION 'test expected temporal resume to exceed the configured limit';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS actual_message = MESSAGE_TEXT;
        IF actual_message IS DISTINCT FROM
           'M23_TEMPORAL_LIMIT: 2 temporal keys exceed max_temporal_keys_per_pass 1' THEN
            RAISE EXCEPTION 'temporal resume returned the wrong result: %', actual_message;
        END IF;
    END;
    IF temporal_limit.state_vector() IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'over-limit temporal resume changed the complete rule state';
    END IF;
END
$resume_limit$;

DELETE FROM temporal_limit.source WHERE id = 2;
SELECT pgreact_api.resume_temporal_rule('temporal-limit-one-key');

UPDATE pgreact_internal.operational_settings
SET max_temporal_keys_per_pass = 2;
CREATE TABLE temporal_limit.concurrent_results (outcome_a text NOT NULL, outcome_b text NOT NULL);

DO $concurrent_temporal_limit$
DECLARE waiting_sessions integer; attempt integer; sent_a integer; sent_b integer;
    outcome_a text; outcome_b text; connection_string text;
BEGIN
    connection_string := format('dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_locker');
    PERFORM dblink_connect('limit_locker', connection_string);
    PERFORM dblink_connect('limit_a', format('dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_a'));
    PERFORM dblink_connect('limit_b', format('dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_b'));
    PERFORM dblink_exec('limit_locker', 'BEGIN');
    PERFORM dblink_exec('limit_locker', 'LOCK TABLE pgreact_internal.temporal_state IN SHARE MODE');

    sent_a := dblink_send_query(
        'limit_a', $$SELECT temporal_limit.try_concurrent_author('temporal-limit-concurrent-a')$$);
    sent_b := dblink_send_query(
        'limit_b', $$SELECT temporal_limit.try_concurrent_author('temporal-limit-concurrent-b')$$);
    IF sent_a <> 1 OR sent_b <> 1 THEN
        RAISE EXCEPTION 'could not start both concurrent temporal authors: %, %', sent_a, sent_b;
    END IF;

    FOR attempt IN 1..1000 LOOP
        SELECT count(*) INTO waiting_sessions
        FROM pg_catalog.pg_stat_activity
        WHERE application_name IN ('temporal_limit_cap_a', 'temporal_limit_cap_b')
          AND wait_event_type = 'Lock';
        EXIT WHEN waiting_sessions = 2;
        PERFORM pg_catalog.pg_sleep(0.01);
    END LOOP;
    IF waiting_sessions <> 2 THEN
        RAISE EXCEPTION 'both concurrent temporal authors did not reach the lock barrier: %',
            waiting_sessions;
    END IF;

    PERFORM dblink_exec('limit_locker', 'COMMIT');
    SELECT result.value INTO STRICT outcome_a
    FROM dblink_get_result('limit_a') AS result(value text);
    SELECT result.value INTO STRICT outcome_b
    FROM dblink_get_result('limit_b') AS result(value text);
    INSERT INTO temporal_limit.concurrent_results VALUES (outcome_a, outcome_b);

    PERFORM dblink_disconnect('limit_a');
    PERFORM dblink_disconnect('limit_b');
    PERFORM dblink_disconnect('limit_locker');
EXCEPTION WHEN OTHERS THEN
    BEGIN PERFORM dblink_exec('limit_locker', 'ROLLBACK'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_a'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_b'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_locker'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
END
$concurrent_temporal_limit$;

DO $assert_concurrent_temporal_limit$
DECLARE outcome_a text; outcome_b text; accepted_name text; actual jsonb; expected jsonb;
BEGIN
    SELECT result.outcome_a, result.outcome_b INTO STRICT outcome_a, outcome_b
    FROM temporal_limit.concurrent_results result;
    IF outcome_a = 'ACCEPTED:temporal-limit-concurrent-a'
       AND outcome_b = 'REJECTED:M23_TEMPORAL_LIMIT: 3 temporal keys exceed max_temporal_keys_per_pass 2' THEN
        accepted_name := 'temporal-limit-concurrent-a';
    ELSIF outcome_b = 'ACCEPTED:temporal-limit-concurrent-b'
       AND outcome_a = 'REJECTED:M23_TEMPORAL_LIMIT: 3 temporal keys exceed max_temporal_keys_per_pass 2' THEN
        accepted_name := 'temporal-limit-concurrent-b';
    ELSE
        RAISE EXCEPTION 'concurrent temporal authors returned unexpected results: %, %',
            outcome_a, outcome_b;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'rule_name', rule.rule_name,
               'state', version.state,
               'keys', COALESCE((
                   SELECT jsonb_agg(state.semantic_key ORDER BY state.semantic_key)
                   FROM pgreact_internal.temporal_state state
                   WHERE state.rule_version_id = version.rule_version_id), '[]'::jsonb))
               ORDER BY rule.rule_name), '[]'::jsonb)
    INTO actual
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name IN ('temporal-limit-one-key',
                             'temporal-limit-concurrent-a', 'temporal-limit-concurrent-b');
    expected := jsonb_build_array(
        jsonb_build_object('rule_name', accepted_name, 'state', 'ACTIVE', 'keys', '[1]'::jsonb),
        jsonb_build_object('rule_name', 'temporal-limit-one-key', 'state', 'ACTIVE', 'keys', '[1]'::jsonb));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'concurrent temporal authors left an unexpected complete key vector: %', actual;
    END IF;
END
$assert_concurrent_temporal_limit$;

UPDATE pgreact_internal.operational_settings
SET max_temporal_keys_per_pass = 4;
SELECT pgreact_api.author_temporal_rule(
    'temporal-limit-concurrent-third', 'temporal_limit.condition'::regclass,
    'id', 'DURATION', interval '1 day');
CREATE TABLE temporal_limit.reconcile_targets (target_a text NOT NULL, target_b text NOT NULL);
INSERT INTO temporal_limit.reconcile_targets
SELECT 'temporal-limit-one-key',
       CASE WHEN outcome_a LIKE 'ACCEPTED:%'
            THEN 'temporal-limit-concurrent-a' ELSE 'temporal-limit-concurrent-b' END
FROM temporal_limit.concurrent_results;
INSERT INTO temporal_limit.source VALUES (2);
CREATE TABLE temporal_limit.concurrent_reconcile_results (outcome_a text NOT NULL, outcome_b text NOT NULL);

DO $concurrent_reconcile_limit$
DECLARE waiting_sessions integer; attempt integer; sent_a integer; sent_b integer;
    target_a text; target_b text; outcome_a text; outcome_b text;
BEGIN
    SELECT targets.target_a, targets.target_b INTO STRICT target_a, target_b
    FROM temporal_limit.reconcile_targets targets;
    PERFORM dblink_connect('limit_locker', format(
        'dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_locker'));
    PERFORM dblink_connect('limit_a', format(
        'dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_a'));
    PERFORM dblink_connect('limit_b', format(
        'dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_b'));
    PERFORM dblink_exec('limit_locker', 'BEGIN');
    PERFORM dblink_exec('limit_locker', 'LOCK TABLE pgreact_internal.temporal_state IN SHARE MODE');

    sent_a := dblink_send_query(
        'limit_a', format('SELECT temporal_limit.try_concurrent_reconcile(%L)', target_a));
    sent_b := dblink_send_query(
        'limit_b', format('SELECT temporal_limit.try_concurrent_reconcile(%L)', target_b));
    IF sent_a <> 1 OR sent_b <> 1 THEN
        RAISE EXCEPTION 'could not start both concurrent temporal reconciliations: %, %', sent_a, sent_b;
    END IF;

    FOR attempt IN 1..1000 LOOP
        SELECT count(*) INTO waiting_sessions
        FROM pg_catalog.pg_stat_activity
        WHERE application_name IN ('temporal_limit_cap_a', 'temporal_limit_cap_b')
          AND wait_event_type = 'Lock';
        EXIT WHEN waiting_sessions = 2;
        PERFORM pg_catalog.pg_sleep(0.01);
    END LOOP;
    IF waiting_sessions <> 2 THEN
        RAISE EXCEPTION 'both concurrent temporal reconciliations did not reach the lock barrier: %',
            waiting_sessions;
    END IF;

    PERFORM dblink_exec('limit_locker', 'COMMIT');
    SELECT result.value INTO STRICT outcome_a
    FROM dblink_get_result('limit_a') AS result(value text);
    SELECT result.value INTO STRICT outcome_b
    FROM dblink_get_result('limit_b') AS result(value text);
    INSERT INTO temporal_limit.concurrent_reconcile_results VALUES (outcome_a, outcome_b);

    PERFORM dblink_disconnect('limit_a');
    PERFORM dblink_disconnect('limit_b');
    PERFORM dblink_disconnect('limit_locker');
EXCEPTION WHEN OTHERS THEN
    BEGIN PERFORM dblink_exec('limit_locker', 'ROLLBACK'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_a'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_b'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_locker'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
END
$concurrent_reconcile_limit$;

DO $assert_concurrent_reconcile_limit$
DECLARE target_a text; target_b text; outcome_a text; outcome_b text;
    reconciled_name text; rejected_name text; item record; match_keys jsonb;
    temporal_keys jsonb; actual jsonb := '[]'::jsonb; expected jsonb;
BEGIN
    SELECT targets.target_a, targets.target_b, result.outcome_a, result.outcome_b
    INTO STRICT target_a, target_b, outcome_a, outcome_b
    FROM temporal_limit.reconcile_targets targets
    CROSS JOIN temporal_limit.concurrent_reconcile_results result;
    IF outcome_a = 'RECONCILED:' || target_a
       AND outcome_b = 'REJECTED:M23_TEMPORAL_LIMIT: 5 temporal keys exceed max_temporal_keys_per_pass 4' THEN
        reconciled_name := target_a; rejected_name := target_b;
    ELSIF outcome_b = 'RECONCILED:' || target_b
       AND outcome_a = 'REJECTED:M23_TEMPORAL_LIMIT: 5 temporal keys exceed max_temporal_keys_per_pass 4' THEN
        reconciled_name := target_b; rejected_name := target_a;
    ELSE
        RAISE EXCEPTION 'concurrent temporal reconciliations returned unexpected results: %, %',
            outcome_a, outcome_b;
    END IF;

    FOR item IN
        SELECT rule.rule_name, version.state, version.rule_version_id,
               version.key_column, version.match_relid
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name IN (reconciled_name, rejected_name, 'temporal-limit-concurrent-third')
        ORDER BY rule.rule_name
    LOOP
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg((to_jsonb(entry) ->> %L)::bigint '
            'ORDER BY (to_jsonb(entry) ->> %L)::bigint), ''[]''::jsonb) FROM %s entry',
            item.key_column::text, item.key_column::text, item.match_relid::regclass)
        INTO match_keys;
        SELECT COALESCE(jsonb_agg(state.semantic_key ORDER BY state.semantic_key), '[]'::jsonb)
        INTO temporal_keys
        FROM pgreact_internal.temporal_state state
        WHERE state.rule_version_id = item.rule_version_id;
        actual := actual || jsonb_build_array(jsonb_build_object(
            'rule_name', item.rule_name, 'state', item.state,
            'match_keys', match_keys, 'temporal_keys', temporal_keys));
    END LOOP;

    SELECT jsonb_agg(expected_row.value ORDER BY expected_row.value ->> 'rule_name')
    INTO expected
    FROM (VALUES
        (jsonb_build_object('rule_name', reconciled_name, 'state', 'ACTIVE',
                            'match_keys', '[1,2]'::jsonb, 'temporal_keys', '[1,2]'::jsonb)),
        (jsonb_build_object('rule_name', rejected_name, 'state', 'ACTIVE',
                            'match_keys', '[1]'::jsonb, 'temporal_keys', '[1]'::jsonb)),
        (jsonb_build_object('rule_name', 'temporal-limit-concurrent-third', 'state', 'ACTIVE',
                            'match_keys', '[1]'::jsonb, 'temporal_keys', '[1]'::jsonb))
    ) AS expected_row(value);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'concurrent temporal reconciliation left an unexpected complete key vector: %', actual;
    END IF;
END
$assert_concurrent_reconcile_limit$;

UPDATE pgreact_internal.operational_settings
SET max_temporal_keys_per_pass = 10;
CREATE TABLE temporal_limit.refresh_source_a (id bigint PRIMARY KEY);
CREATE TABLE temporal_limit.refresh_source_b (id bigint PRIMARY KEY);
CREATE VIEW temporal_limit.refresh_condition_a AS
SELECT id FROM temporal_limit.refresh_source_a;
CREATE VIEW temporal_limit.refresh_condition_b AS
SELECT id FROM temporal_limit.refresh_source_b;
SELECT pgreact_api.author_temporal_rule(
    'temporal-limit-refresh-a', 'temporal_limit.refresh_condition_a'::regclass,
    'id', 'DURATION', interval '1 day');
SELECT pgreact_api.author_temporal_rule(
    'temporal-limit-refresh-b', 'temporal_limit.refresh_condition_b'::regclass,
    'id', 'DURATION', interval '1 day');
UPDATE pgreact_internal.operational_settings
SET max_temporal_keys_per_pass = 5;
INSERT INTO temporal_limit.refresh_source_a VALUES (100);
INSERT INTO temporal_limit.refresh_source_b VALUES (200);
CREATE TABLE temporal_limit.concurrent_refresh_results (outcome_a text NOT NULL, outcome_b text NOT NULL);

DO $concurrent_refresh_limit$
DECLARE waiting_sessions integer; attempt integer; sent_a integer; sent_b integer;
    outcome_a text; outcome_b text;
BEGIN
    PERFORM dblink_connect('limit_locker', format(
        'dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_locker'));
    PERFORM dblink_connect('limit_a', format(
        'dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_a'));
    PERFORM dblink_connect('limit_b', format(
        'dbname=%L application_name=%L', current_database(), 'temporal_limit_cap_b'));
    PERFORM dblink_exec('limit_locker', 'BEGIN');
    PERFORM dblink_exec('limit_locker', 'LOCK TABLE pgreact_internal.temporal_state IN SHARE MODE');

    sent_a := dblink_send_query(
        'limit_a', $$SELECT temporal_limit.try_concurrent_refresh('temporal-limit-refresh-a')$$);
    sent_b := dblink_send_query(
        'limit_b', $$SELECT temporal_limit.try_concurrent_refresh('temporal-limit-refresh-b')$$);
    IF sent_a <> 1 OR sent_b <> 1 THEN
        RAISE EXCEPTION 'could not start both concurrent temporal refreshes: %, %', sent_a, sent_b;
    END IF;

    FOR attempt IN 1..1000 LOOP
        SELECT count(*) INTO waiting_sessions
        FROM pg_catalog.pg_stat_activity
        WHERE application_name IN ('temporal_limit_cap_a', 'temporal_limit_cap_b')
          AND wait_event_type = 'Lock';
        EXIT WHEN waiting_sessions = 2;
        PERFORM pg_catalog.pg_sleep(0.01);
    END LOOP;
    IF waiting_sessions <> 2 THEN
        RAISE EXCEPTION 'both concurrent temporal refreshes did not reach the lock barrier: %',
            waiting_sessions;
    END IF;

    PERFORM dblink_exec('limit_locker', 'COMMIT');
    SELECT result.value INTO STRICT outcome_a
    FROM dblink_get_result('limit_a') AS result(value text);
    SELECT result.value INTO STRICT outcome_b
    FROM dblink_get_result('limit_b') AS result(value text);
    INSERT INTO temporal_limit.concurrent_refresh_results VALUES (outcome_a, outcome_b);

    PERFORM dblink_disconnect('limit_a');
    PERFORM dblink_disconnect('limit_b');
    PERFORM dblink_disconnect('limit_locker');
EXCEPTION WHEN OTHERS THEN
    BEGIN PERFORM dblink_exec('limit_locker', 'ROLLBACK'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_a'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_b'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_locker'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
END
$concurrent_refresh_limit$;

DO $assert_concurrent_refresh_limit$
DECLARE outcome_a text; outcome_b text; accepted_name text; rejected_name text;
    item record; match_keys jsonb; temporal_keys jsonb; actual jsonb := '[]'::jsonb;
    expected jsonb; accepted_key jsonb;
BEGIN
    SELECT result.outcome_a, result.outcome_b INTO STRICT outcome_a, outcome_b
    FROM temporal_limit.concurrent_refresh_results result;
    IF outcome_a = 'REFRESHED:temporal-limit-refresh-a'
       AND outcome_b = 'REJECTED:M23_TEMPORAL_LIMIT: 6 temporal keys exceed max_temporal_keys_per_pass 5' THEN
        accepted_name := 'temporal-limit-refresh-a'; rejected_name := 'temporal-limit-refresh-b';
    ELSIF outcome_b = 'REFRESHED:temporal-limit-refresh-b'
       AND outcome_a = 'REJECTED:M23_TEMPORAL_LIMIT: 6 temporal keys exceed max_temporal_keys_per_pass 5' THEN
        accepted_name := 'temporal-limit-refresh-b'; rejected_name := 'temporal-limit-refresh-a';
    ELSE
        RAISE EXCEPTION 'concurrent generic temporal refreshes returned unexpected results: %, %',
            outcome_a, outcome_b;
    END IF;
    accepted_key := CASE accepted_name
        WHEN 'temporal-limit-refresh-a' THEN '[100]'::jsonb ELSE '[200]'::jsonb END;

    FOR item IN
        SELECT rule.rule_name, version.state, version.rule_version_id,
               version.key_column, version.match_relid
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name IN ('temporal-limit-refresh-a', 'temporal-limit-refresh-b')
        ORDER BY rule.rule_name
    LOOP
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg((to_jsonb(entry) ->> %L)::bigint '
            'ORDER BY (to_jsonb(entry) ->> %L)::bigint), ''[]''::jsonb) FROM %s entry',
            item.key_column::text, item.key_column::text, item.match_relid::regclass)
        INTO match_keys;
        SELECT COALESCE(jsonb_agg(state.semantic_key ORDER BY state.semantic_key), '[]'::jsonb)
        INTO temporal_keys
        FROM pgreact_internal.temporal_state state
        WHERE state.rule_version_id = item.rule_version_id;
        actual := actual || jsonb_build_array(jsonb_build_object(
            'rule_name', item.rule_name, 'state', item.state,
            'match_keys', match_keys, 'temporal_keys', temporal_keys));
    END LOOP;
    SELECT jsonb_agg(expected_row.value ORDER BY expected_row.value ->> 'rule_name')
    INTO expected
    FROM (VALUES
        (jsonb_build_object('rule_name', accepted_name, 'state', 'ACTIVE',
                            'match_keys', accepted_key, 'temporal_keys', accepted_key)),
        (jsonb_build_object('rule_name', rejected_name, 'state', 'ACTIVE',
                            'match_keys', '[]'::jsonb, 'temporal_keys', '[]'::jsonb))
    ) AS expected_row(value);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'concurrent generic temporal refreshes left an unexpected exact key vector: %', actual;
    END IF;
    IF (SELECT count(*) FROM pgreact_internal.temporal_state) <> 5 THEN
        RAISE EXCEPTION 'concurrent generic temporal refreshes did not preserve the exact global cap state';
    END IF;
END
$assert_concurrent_refresh_limit$;

SELECT 'PASS: temporal-limit concurrent outcomes author=[' || author.outcome_a || ' | ' || author.outcome_b
    || '] reconcile=[' || reconcile.outcome_a || ' | ' || reconcile.outcome_b
    || '] generic-refresh=[' || refresh.outcome_a || ' | ' || refresh.outcome_b || ']'
FROM temporal_limit.concurrent_results author
CROSS JOIN temporal_limit.concurrent_reconcile_results reconcile
CROSS JOIN temporal_limit.concurrent_refresh_results refresh;
UPDATE pgreact_internal.operational_settings SET max_temporal_keys_per_pass = 100000;
DO $repeatable_read_temporal_limit$
DECLARE actual text; snapshot_rows bigint; before_state jsonb; after_state jsonb;
BEGIN
    PERFORM dblink_connect('limit_repeatable_read', format(
        'dbname=%L application_name=%L', current_database(), 'temporal_limit_repeatable_read'));
    PERFORM dblink_exec('limit_repeatable_read', 'BEGIN ISOLATION LEVEL REPEATABLE READ');
    before_state := temporal_limit.state_vector();
    SELECT result.value INTO STRICT snapshot_rows
    FROM dblink('limit_repeatable_read',
        'SELECT count(*) FROM pgreact_internal.temporal_state') AS result(value bigint);
    IF snapshot_rows <> 5 THEN
        RAISE EXCEPTION 'repeatable-read snapshot saw an unexpected temporal-state count: %', snapshot_rows;
    END IF;
    SELECT result.value INTO STRICT actual
    FROM dblink('limit_repeatable_read',
        $$SELECT temporal_limit.try_concurrent_author('temporal-limit-repeatable-read')$$)
        AS result(value text);
    IF actual <> 'REJECTED:M23_ISOLATION_UNSUPPORTED: temporal-key operations require READ COMMITTED' THEN
        RAISE EXCEPTION 'repeatable-read temporal author returned unexpected output: %', actual;
    END IF;
    after_state := temporal_limit.state_vector();
    IF after_state IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'repeatable-read temporal rejection changed the complete state vector: %', after_state;
    END IF;
    PERFORM dblink_exec('limit_repeatable_read', 'ROLLBACK');
    PERFORM dblink_disconnect('limit_repeatable_read');
EXCEPTION WHEN OTHERS THEN
    BEGIN PERFORM dblink_exec('limit_repeatable_read', 'ROLLBACK'); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM dblink_disconnect('limit_repeatable_read'); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
END
$repeatable_read_temporal_limit$;
UPDATE pgreact_internal.operational_settings SET max_temporal_keys_per_pass = 5;
SELECT 'PASS: temporal key cap rejects REPEATABLE READ with exact M23_ISOLATION_UNSUPPORTED output';
SELECT 'PASS: temporal key limits cover author, cross-rule author, direct reconcile, generic refresh/resume, temporal resume, concurrent author/reconcile/refresh, healthy managed run and REPEATABLE READ rejection';
