\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m12_boundary;
CREATE TABLE m12_boundary.good_source (
    id bigint PRIMARY KEY,
    deadline timestamptz,
    enabled boolean NOT NULL DEFAULT true
);
CREATE VIEW m12_boundary.good_candidate AS
SELECT id, deadline FROM m12_boundary.good_source WHERE enabled;
CREATE VIEW m12_boundary.computed_candidate AS
SELECT id, deadline + interval '1 hour' AS deadline
FROM m12_boundary.good_source;
CREATE VIEW m12_boundary.negative_candidate AS
SELECT source.id, source.deadline
FROM m12_boundary.good_source source
WHERE NOT EXISTS (
    SELECT 1 FROM m12_boundary.good_source blocked
    WHERE blocked.id = -source.id);
CREATE VIEW m12_boundary.window_candidate AS
SELECT id, deadline, row_number() OVER (ORDER BY id) AS ordinal
FROM m12_boundary.good_source;
CREATE VIEW m12_boundary.wrong_type_candidate AS
SELECT id, deadline::text AS deadline FROM m12_boundary.good_source;

INSERT INTO m12_boundary.good_source VALUES
    (1, '2026-02-01 00:00:00+00', true);

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.code) INTO actual
    FROM pgreact_api.validate_deadline_rule(
        'm12_boundary.computed_candidate'::regclass, 'id', 'deadline') result;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 2,
        'code', 'M12_DEADLINE_NOT_DIRECT',
        'severity', 'ERROR',
        'object_identity', 'm12_boundary.computed_candidate',
        'message', 'deadline must be one unambiguous direct column, not a computed time expression',
        'hint', 'Project a stored timestamptz column unchanged from one finite source row.',
        'details', jsonb_build_object('deadline_column', 'deadline'))) THEN
        RAISE EXCEPTION 'M12 computed-deadline diagnostic changed: %', actual;
    END IF;

    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.code) INTO actual
    FROM pgreact_api.validate_deadline_rule(
        'm12_boundary.negative_candidate'::regclass, 'id', 'deadline') result;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 2,
        'code', 'M12_DEADLINE_QUERY_UNSUPPORTED',
        'severity', 'ERROR',
        'object_identity', 'm12_boundary.negative_candidate',
        'message', 'deadline candidates cannot use volatile, recursive, negative, aggregate, windowed, or derived-program time expressions',
        'hint', 'Use a finite ordinary condition view with one direct stored deadline.',
        'details', '{}'::jsonb)) THEN
        RAISE EXCEPTION 'M12 negative-deadline diagnostic changed: %', actual;
    END IF;

    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.code) INTO actual
    FROM pgreact_api.validate_deadline_rule(
        'm12_boundary.window_candidate'::regclass, 'id', 'deadline') result;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 2,
        'code', 'M12_DEADLINE_QUERY_UNSUPPORTED',
        'severity', 'ERROR',
        'object_identity', 'm12_boundary.window_candidate',
        'message', 'deadline candidates cannot use volatile, recursive, negative, aggregate, windowed, or derived-program time expressions',
        'hint', 'Use a finite ordinary condition view with one direct stored deadline.',
        'details', '{}'::jsonb)) THEN
        RAISE EXCEPTION 'M12 window-deadline diagnostic changed: %', actual;
    END IF;

    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.code) INTO actual
    FROM pgreact_api.validate_deadline_rule(
        'm12_boundary.wrong_type_candidate'::regclass, 'id', 'deadline') result;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 2,
        'code', 'M12_DEADLINE_TYPE',
        'severity', 'ERROR',
        'object_identity', 'm12_boundary.wrong_type_candidate',
        'message', 'deadline must name one timestamptz column projected by the condition view',
        'hint', 'Project one non-null timestamptz deadline column.',
        'details', jsonb_build_object('deadline_column', 'deadline'))) THEN
        RAISE EXCEPTION 'M12 deadline-type diagnostic changed: %', actual;
    END IF;
END
$$;

UPDATE m12_boundary.good_source SET deadline = NULL WHERE id = 1;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.code) INTO actual
    FROM pgreact_api.validate_deadline_rule(
        'm12_boundary.good_candidate'::regclass, 'id', 'deadline') result;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 2,
        'code', 'M12_DEADLINE_VALUE',
        'severity', 'ERROR',
        'object_identity', 'm12_boundary.good_candidate',
        'message', 'deadline candidates must contain finite non-null timestamptz values',
        'hint', 'Populate every deadline with one finite PostgreSQL timestamptz value.',
        'details', jsonb_build_object('invalid_rows', 1, 'deadline_column', 'deadline'))) THEN
        RAISE EXCEPTION 'M12 null-deadline diagnostic changed: %', actual;
    END IF;
END
$$;
UPDATE m12_boundary.good_source
SET deadline = '2026-02-01 00:00:00+00' WHERE id = 1;

DROP ROLE IF EXISTS m12_unauthorized;
CREATE ROLE m12_unauthorized LOGIN;
GRANT USAGE ON SCHEMA pgreact_api TO m12_unauthorized;
GRANT USAGE ON SCHEMA m12_boundary TO m12_unauthorized;
GRANT USAGE ON SCHEMA pgreact TO m12_unauthorized;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgreact_api TO m12_unauthorized;
GRANT EXECUTE ON FUNCTION pgreact.begin_deadline_refresh(bigint),
    pgreact.advance_deadline_clock(timestamptz),
    pgreact.finish_deadline_refresh() TO m12_unauthorized;
DO $$
DECLARE actual jsonb;
BEGIN
    SET LOCAL SESSION AUTHORIZATION m12_unauthorized;
    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.code) INTO actual
    FROM pgreact_api.validate_deadline_rule(
        'm12_boundary.good_candidate'::regclass, 'id', 'deadline') result;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 2,
        'code', 'SOURCE_NOT_OWNED',
        'severity', 'ERROR',
        'object_identity', 'm12_boundary.good_candidate',
        'message', 'rule owner must own the source view',
        'hint', 'Create the rule as the view owner.',
        'details', '{}'::jsonb)) THEN
        RAISE EXCEPTION 'M12 unauthorized declaration diagnostic changed: %', actual;
    END IF;
    BEGIN
        PERFORM pgreact.begin_deadline_refresh(12999);
        RAISE EXCEPTION 'unauthorized M12 clock advance unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'M12_CLOCK_UNAUTHORIZED: only pgreact_admin may advance database time' THEN
            RAISE;
        END IF;
    END;
END
$$;

CREATE FUNCTION m12_boundary.activate(
    context pgreact.activation_context,
    candidate m12_boundary.good_candidate
)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
SELECT pgreact_api.author_deadline_rule(
    rule_name => 'boundary-deadline',
    condition => 'm12_boundary.good_candidate'::regclass,
    semantic_key => 'id',
    deadline_column => 'deadline',
    kind => 'COMMAND',
    on_activate => 'm12_boundary.activate(pgreact.activation_context,m12_boundary.good_candidate)'
) AS boundary_version \gset
SELECT set_config('m12.boundary_version', :'boundary_version', false);

DO $$
BEGIN
    PERFORM pgreact.advance_deadline_clock('2026-01-31 00:00:00+00');
    RAISE EXCEPTION 'M12 clock advanced without a committed barrier';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'M12_CLOCK_BARRIER: begin_deadline_refresh must commit before clock advancement' THEN
        RAISE;
    END IF;
END
$$;

SELECT pgreact.begin_deadline_refresh(12100);
SELECT pgreact.advance_deadline_clock('2026-01-31 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();
SELECT pgreact.begin_deadline_refresh(12101);
SET pgreact.test_fail_clock_phase = 'lifecycle';
DO $$
BEGIN
    PERFORM pgreact.advance_deadline_clock('2026-02-01 00:00:00+00');
    RAISE EXCEPTION 'injected M12 clock failure did not fire';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'injected M12 clock failure after lifecycle update' THEN RAISE; END IF;
END
$$;
RESET pgreact.test_fail_clock_phase;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'activations', COALESCE((SELECT jsonb_agg(to_jsonb(row) ORDER BY semantic_key)
            FROM (SELECT semantic_key, active, generation, revision
                  FROM pgreact_internal.activation_state
                  WHERE rule_version_id = current_setting('m12.boundary_version')::uuid) row), '[]'::jsonb),
        'events', COALESCE((SELECT jsonb_agg(to_jsonb(row) ORDER BY event_id)
            FROM (SELECT event_id, event_kind, generation, revision
                  FROM pgreact_internal.lifecycle_events
                  WHERE rule_version_id = current_setting('m12.boundary_version')::uuid) row), '[]'::jsonb),
        'agenda', COALESCE((SELECT jsonb_agg(to_jsonb(row) ORDER BY episode_id)
            FROM (SELECT episode_id, state, event_kind, activation_generation
                  FROM pgreact_internal.agenda
                  WHERE rule_version_id = current_setting('m12.boundary_version')::uuid) row), '[]'::jsonb),
        'barrier', (SELECT jsonb_build_object('reason', reason, 'refresh_id', refresh_id)
                    FROM pgreact_internal.rule_barriers
                    WHERE rule_version_id = current_setting('m12.boundary_version')::uuid))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'frontier', '2026-01-31 00:00:00+00'::timestamptz,
        'activations', '[]'::jsonb,
        'events', '[]'::jsonb,
        'agenda', '[]'::jsonb,
        'barrier', jsonb_build_object('reason', 'REFRESHING', 'refresh_id', 12101)) THEN
        RAISE EXCEPTION 'M12 failed clock transaction exposed partial state: %', actual;
    END IF;
END
$$;
SELECT pgreact.finish_deadline_refresh();

SELECT pgreact.begin_deadline_refresh(12102);
SELECT pgreact.advance_deadline_clock('2026-02-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

INSERT INTO m12_boundary.good_source VALUES
    (2, '2026-02-02 00:00:00+00', true),
    (3, '2026-02-02 00:00:00+00', true);
SELECT pgreact.refresh_rule(:'boundary_version'::uuid);
UPDATE pgreact_internal.operational_settings SET max_deadlines_per_pass = 1;
SELECT pgreact.begin_deadline_refresh(12103);
DO $$
BEGIN
    PERFORM pgreact.advance_deadline_clock('2026-02-02 00:00:00+00');
    RAISE EXCEPTION 'M12 resource limit unexpectedly allowed two keys';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'M12_DEADLINE_LIMIT: clock pass would advance 2 keys; limit is 1' THEN
        RAISE;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'activations', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation) ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m12.boundary_version')::uuid),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'event_kind', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = current_setting('m12.boundary_version')::uuid),
        'barrier', (SELECT jsonb_build_object('reason', reason, 'refresh_id', refresh_id)
                    FROM pgreact_internal.rule_barriers
                    WHERE rule_version_id = current_setting('m12.boundary_version')::uuid))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'frontier', '2026-02-01 00:00:00+00'::timestamptz,
        'activations', jsonb_build_array(jsonb_build_object(
            'semantic_key', 1, 'active', true, 'generation', 1)),
        'events', jsonb_build_array(jsonb_build_object(
            'event_kind', 'ACTIVATE', 'generation', 1)),
        'barrier', jsonb_build_object('reason', 'REFRESHING', 'refresh_id', 12103)) THEN
        RAISE EXCEPTION 'M12 resource-limit failure exposed partial state: %', actual;
    END IF;
END
$$;
SELECT pgreact.finish_deadline_refresh();
UPDATE pgreact_internal.operational_settings SET max_deadlines_per_pass = 100000;
SELECT pgreact.begin_deadline_refresh(12104);
SELECT pgreact.advance_deadline_clock('2026-02-02 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

UPDATE m12_boundary.good_source SET deadline = NULL WHERE id = 2;
DO $$
BEGIN
    PERFORM pgreact_api.run_rule('boundary-deadline');
    SET CONSTRAINTS ALL IMMEDIATE;
    RAISE EXCEPTION 'M12 runtime null deadline unexpectedly refreshed';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE 'M12_DEADLINE_VALUE: %.deadline must be finite and non-null for key 2' THEN
        RAISE;
    END IF;
END
$$;
UPDATE m12_boundary.good_source
SET deadline = '2026-02-02 00:00:00+00' WHERE id = 2;
SELECT pgreact.refresh_rule(:'boundary_version'::uuid);

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'index_columns', (SELECT jsonb_agg(attribute.attname ORDER BY key.ordinality)
            FROM pgreact_internal.deadline_rules deadline
            JOIN pgreact_internal.rule_versions version USING (rule_version_id)
            JOIN pg_catalog.pg_index index ON index.indrelid = version.match_relid
            JOIN pg_catalog.pg_class index_relation ON index_relation.oid = index.indexrelid
            CROSS JOIN LATERAL unnest(index.indkey::smallint[]) WITH ORDINALITY key(attnum, ordinality)
            JOIN pg_catalog.pg_attribute attribute
              ON attribute.attrelid = index.indrelid AND attribute.attnum = key.attnum
            WHERE deadline.rule_version_id = current_setting('m12.boundary_version')::uuid
              AND index_relation.relname LIKE 'deadline_%'),
        'activations', (SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision) ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m12.boundary_version')::uuid),
        'history', pgreact_internal.deadline_history('boundary-deadline'))
    INTO actual;
    IF actual -> 'activations' IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('semantic_key', 1, 'active', true, 'generation', 1, 'revision', 0),
        jsonb_build_object('semantic_key', 2, 'active', true, 'generation', 1, 'revision', 0),
        jsonb_build_object('semantic_key', 3, 'active', true, 'generation', 1, 'revision', 0))
       OR actual -> 'index_columns' IS DISTINCT FROM '["deadline","id"]'::jsonb
       OR actual -> 'history' IS DISTINCT FROM jsonb_build_array(
           jsonb_build_object('rule_name', 'boundary-deadline', 'semantic_key', 1,
               'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
               'declared_deadline', '2026-02-01 00:00:00+00'::timestamptz,
               'clock_frontier', '2026-02-01 00:00:00+00'::timestamptz),
           jsonb_build_object('rule_name', 'boundary-deadline', 'semantic_key', 2,
               'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
               'declared_deadline', '2026-02-02 00:00:00+00'::timestamptz,
               'clock_frontier', '2026-02-02 00:00:00+00'::timestamptz),
           jsonb_build_object('rule_name', 'boundary-deadline', 'semantic_key', 3,
               'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
               'declared_deadline', '2026-02-02 00:00:00+00'::timestamptz,
               'clock_frontier', '2026-02-02 00:00:00+00'::timestamptz)) THEN
        RAISE EXCEPTION 'M12 indexed final boundary state changed: %', actual;
    END IF;
END
$$;

SELECT 'M12 validation, privilege, failure, and resource boundary passed';
