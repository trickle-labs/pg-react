\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

SELECT pgreact_api.run('2026-01-01 00:00:00+00'::timestamptz);
SELECT frontier AS base_time FROM pgreact_internal.clock_frontier \gset

CREATE SCHEMA m25_reference;
CREATE TABLE m25_reference.fact (
    id bigint PRIMARY KEY,
    amount integer NOT NULL
);
CREATE TABLE m25_reference.parameters (
    id bigint PRIMARY KEY,
    minimum_amount integer NOT NULL,
    enabled boolean NOT NULL,
    secret text NOT NULL
);
CREATE VIEW m25_reference.eligible AS
SELECT fact.id, fact.amount, parameters.minimum_amount, parameters.enabled
FROM m25_reference.fact fact
JOIN m25_reference.parameters parameters ON parameters.id = fact.id
WHERE parameters.enabled AND fact.amount >= parameters.minimum_amount;

INSERT INTO m25_reference.fact VALUES (1, 150), (2, 50);
CREATE TABLE m25_reference.bad_parameters (
    id integer PRIMARY KEY,
    value integer NOT NULL
);
CREATE TABLE m25_reference.bad_unique (
    id bigint NOT NULL,
    value integer NOT NULL
);
CREATE TABLE m25_reference.bad_value_type (
    id bigint PRIMARY KEY,
    payload jsonb NOT NULL
);
CREATE TABLE m25_reference.nullable_parameters (
    id bigint PRIMARY KEY,
    value integer
);
CREATE VIEW m25_reference.unrelated AS
SELECT id, amount FROM m25_reference.fact;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('code', code, 'severity', severity)
                     ORDER BY code)
    INTO actual
    FROM pgreact_api.validate_parameter_family(
        'm25-bad', 'm25_reference.bad_parameters'::regclass, 'id',
        ARRAY['value']::name[])
    WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('code', 'M25_PARAMETER_KEY_TYPE', 'severity', 'ERROR')) THEN
        RAISE EXCEPTION 'M25 invalid declaration changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    WITH cases(case_name, errors) AS (
        SELECT 'bad_key_type', (SELECT jsonb_agg(code ORDER BY code)
                                FROM pgreact_api.validate_parameter_family(
                                    'm25-bad', 'm25_reference.bad_parameters'::regclass,
                                    'id', ARRAY['value']::name[])
                                WHERE severity = 'ERROR')
        UNION ALL
        SELECT 'bad_key_unique', (SELECT jsonb_agg(code ORDER BY code)
                                  FROM pgreact_api.validate_parameter_family(
                                      'm25-bad-unique', 'm25_reference.bad_unique'::regclass,
                                      'id', ARRAY['value']::name[])
                                  WHERE severity = 'ERROR')
        UNION ALL
        SELECT 'bad_value_type', (SELECT jsonb_agg(code ORDER BY code)
                                  FROM pgreact_api.validate_parameter_family(
                                      'm25-bad-value', 'm25_reference.bad_value_type'::regclass,
                                      'id', ARRAY['payload']::name[])
                                  WHERE severity = 'ERROR')
        UNION ALL
        SELECT 'empty_family_name', (SELECT jsonb_agg(code ORDER BY code)
                                     FROM pgreact_api.validate_parameter_family(
                                         '', 'm25_reference.parameters'::regclass,
                                         'id', ARRAY['minimum_amount']::name[])
                                     WHERE severity = 'ERROR')
        UNION ALL
        SELECT 'empty_value_columns', (SELECT jsonb_agg(code ORDER BY code)
                                       FROM pgreact_api.validate_parameter_family(
                                           'm25-empty-values', 'm25_reference.parameters'::regclass,
                                           'id', ARRAY[]::name[])
                                       WHERE severity = 'ERROR')
        UNION ALL
        SELECT 'duplicate_columns', (SELECT jsonb_agg(code ORDER BY code)
                                     FROM pgreact_api.validate_parameter_family(
                                         'm25-duplicate-columns', 'm25_reference.parameters'::regclass,
                                         'id', ARRAY['enabled', 'enabled']::name[])
                                     WHERE severity = 'ERROR')
        UNION ALL
        SELECT 'missing_value_column', (SELECT jsonb_agg(code ORDER BY code)
                                        FROM pgreact_api.validate_parameter_family(
                                            'm25-missing-value', 'm25_reference.parameters'::regclass,
                                            'id', ARRAY['missing']::name[])
                                        WHERE severity = 'ERROR')
        UNION ALL
        SELECT 'nullable_value', (SELECT jsonb_agg(code ORDER BY code)
                                  FROM pgreact_api.validate_parameter_family(
                                      'm25-nullable-value', 'm25_reference.nullable_parameters'::regclass,
                                      'id', ARRAY['value']::name[])
                                  WHERE severity = 'ERROR')
    )
    SELECT jsonb_agg(jsonb_build_object('case', case_name, 'errors', errors)
                     ORDER BY case_name)
    INTO actual
    FROM cases;
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('case', 'bad_key_type', 'errors', jsonb_build_array('M25_PARAMETER_KEY_TYPE')),
        jsonb_build_object('case', 'bad_key_unique', 'errors', jsonb_build_array('M25_PARAMETER_KEY_UNIQUE')),
        jsonb_build_object('case', 'bad_value_type', 'errors', jsonb_build_array('M25_PARAMETER_VALUE_TYPE')),
        jsonb_build_object('case', 'duplicate_columns', 'errors', jsonb_build_array('M25_PARAMETER_COLUMNS')),
        jsonb_build_object('case', 'empty_family_name', 'errors', jsonb_build_array('M25_FAMILY_NAME')),
        jsonb_build_object('case', 'empty_value_columns', 'errors', jsonb_build_array('M25_PARAMETER_VALUES')),
        jsonb_build_object('case', 'missing_value_column', 'errors', jsonb_build_array('M25_PARAMETER_VALUE_COLUMN')),
        jsonb_build_object('case', 'nullable_value', 'errors', jsonb_build_array('M25_PARAMETER_VALUE_TYPE'))
    ) THEN
        RAISE EXCEPTION 'M25 validation matrix changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('code', code, 'severity', severity)
                     ORDER BY code)
    INTO actual
    FROM pgreact_api.validate_parameter_family(
        'm25-pricing', 'm25_reference.parameters'::regclass, 'id',
        ARRAY['minimum_amount', 'enabled']::name[]);
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('code', 'OK', 'severity', 'INFO')) THEN
        RAISE EXCEPTION 'M25 valid family changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.author_parameter_family(
    'm25-pricing', 'm25_reference.parameters'::regclass, 'id',
    ARRAY['minimum_amount', 'enabled']::name[]) AS family_id \gset
SELECT set_config('m25.family_id', :'family_id', false);

DO $$
DECLARE before_rows bigint;
    before_events bigint;
    base_time timestamptz;
BEGIN
    SELECT frontier INTO base_time FROM pgreact_internal.clock_frontier;
    SELECT count(*) INTO before_rows FROM m25_reference.parameters;
    SELECT count(*) INTO before_events
    FROM pgreact_internal.parameter_family_events
    WHERE family_id = current_setting('m25.family_id')::uuid;
    BEGIN
        PERFORM pgreact_api.author_parameterized_rule(
            'm25-unauthorized-dependency', 'm25-unauthorized-dependency-v1',
            'm25_reference.unrelated'::regclass, 'id', 'm25-pricing',
            base_time, NULL, 'CONSTRAINT', NULL, NULL, NULL,
            'SEED_CURRENT', NULL, 0, 'default', NULL, 1, 1, 2, 60, '[]'::jsonb);
        RAISE EXCEPTION 'M25 dependency rejection unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M25_PARAMETER_DEPENDENCY:%' THEN RAISE; END IF;
    END;
    IF (SELECT count(*) FROM m25_reference.parameters) <> before_rows
       OR (SELECT count(*) FROM pgreact_internal.parameter_family_events
           WHERE family_id = current_setting('m25.family_id')::uuid) <> before_events
       OR EXISTS (SELECT 1 FROM pgreact_internal.effective_policies
                  WHERE policy_name = 'm25-unauthorized-dependency') THEN
        RAISE EXCEPTION 'M25 dependency rejection left durable state behind';
    END IF;
END
$$;

DO $$
DECLARE before_rows bigint;
    before_events bigint;
    base_time timestamptz;
BEGIN
    SELECT frontier INTO base_time FROM pgreact_internal.clock_frontier;
    SELECT count(*) INTO before_rows FROM m25_reference.parameters;
    SELECT count(*) INTO before_events
    FROM pgreact_internal.parameter_family_events
    WHERE family_id = current_setting('m25.family_id')::uuid;
    BEGIN
        PERFORM pgreact_api.author_parameterized_rule(
            'm25-atomic-failure', 'm25-atomic-failure-v1',
            'm25_reference.eligible'::regclass, 'id', 'm25-pricing',
            base_time, NULL, 'CONSTRAINT', NULL, NULL, NULL,
            'SEED_CURRENT', NULL, 0, 'default', NULL, 1, 1, 2, 60,
            '[{"id":999,"minimum_amount":"not-an-integer","enabled":true}]'::jsonb);
        RAISE EXCEPTION 'M25 atomic failure unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%invalid input syntax for type integer%' THEN RAISE; END IF;
    END;
    IF (SELECT count(*) FROM m25_reference.parameters) <> before_rows
       OR (SELECT count(*) FROM pgreact_internal.parameter_family_events
           WHERE family_id = current_setting('m25.family_id')::uuid) <> before_events
       OR EXISTS (SELECT 1 FROM pgreact_internal.effective_policies
                  WHERE policy_name = 'm25-atomic-failure') THEN
        RAISE EXCEPTION 'M25 atomic authoring left durable state behind';
    END IF;
END
$$;

SELECT pgreact_api.author_parameterized_rule(
    'm25-policy', 'm25-policy-v1', 'm25_reference.eligible'::regclass, 'id',
    'm25-pricing', :'base_time'::timestamptz,
    NULL, 'CONSTRAINT', NULL, NULL, NULL, 'SEED_CURRENT', NULL,
    0, 'default', NULL, 1, 1, 2, 60,
    '[{"id":1,"minimum_amount":100,"enabled":true,"secret":"do-not-leak"}]'::jsonb) AS policy_version_id \gset

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'rows', (SELECT jsonb_agg(to_jsonb(parameters) ORDER BY id)
                 FROM m25_reference.parameters),
        'active', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                   FROM pgreact_internal.activation_state WHERE active),
        'family', (SELECT family_name FROM pgreact.parameter_families
                   WHERE family_name = 'm25-pricing'),
        'consumer', (SELECT count(*) FROM pgreact.parameter_family_consumers
                     WHERE family_name = 'm25-pricing' AND policy_name = 'm25-policy')
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'rows', jsonb_build_array(jsonb_build_object(
            'id', 1, 'minimum_amount', 100, 'enabled', true, 'secret', 'do-not-leak')),
        'active', jsonb_build_array(1),
        'family', 'm25-pricing', 'consumer', 1) THEN
        RAISE EXCEPTION 'M25 atomic parameterized authoring changed: %', actual;
    END IF;
END
$$;

DELETE FROM m25_reference.parameters WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '3 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                   FROM pgreact_internal.activation_state WHERE active),
        'operation', (SELECT details ->> 'operation'
                      FROM pgreact_internal.parameter_family_events
                      WHERE family_id = current_setting('m25.family_id')::uuid
                        AND event_kind = 'PARAMETER_CHANGED'
                      ORDER BY event_id DESC LIMIT 1)) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object('active', NULL, 'operation', 'DELETE') THEN
        RAISE EXCEPTION 'M25 parameter deletion changed: %', actual;
    END IF;
END
$$;

INSERT INTO m25_reference.parameters VALUES (1, 100, true, 'do-not-leak');
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '4 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                   FROM pgreact_internal.activation_state WHERE active),
        'generation', (SELECT generation FROM pgreact_internal.activation_state
                       WHERE semantic_key = 1 AND active),
        'operation', (SELECT details ->> 'operation'
                      FROM pgreact_internal.parameter_family_events
                      WHERE family_id = current_setting('m25.family_id')::uuid
                        AND event_kind = 'PARAMETER_CHANGED'
                      ORDER BY event_id DESC LIMIT 1)) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'active', jsonb_build_array(1), 'generation', 2, 'operation', 'INSERT') THEN
        RAISE EXCEPTION 'M25 parameter insertion changed: %', actual;
    END IF;
END
$$;

CREATE ROLE m25_editor_group;
CREATE ROLE m25_editor;
GRANT USAGE ON SCHEMA m25_reference TO m25_editor;
GRANT SELECT, UPDATE ON m25_reference.parameters TO m25_editor;
GRANT m25_editor_group TO m25_editor;
SELECT pgreact_api.grant_parameter_family_editor('m25-pricing', 'm25_editor_group'::regrole);
SET SESSION AUTHORIZATION m25_editor;
UPDATE m25_reference.parameters SET enabled = false WHERE id = 1;
RESET SESSION AUTHORIZATION;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '5 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                   FROM pgreact_internal.activation_state WHERE active),
        'operation', (SELECT details ->> 'operation'
                      FROM pgreact_internal.parameter_family_events
                      WHERE family_id = current_setting('m25.family_id')::uuid
                        AND event_kind = 'PARAMETER_CHANGED'
                      ORDER BY event_id DESC LIMIT 1)) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object('active', NULL, 'operation', 'UPDATE') THEN
        RAISE EXCEPTION 'M25 value-editor authorization or update changed: %', actual;
    END IF;
END
$$;

DO $$
BEGIN
    IF (pgreact_api.parameter_family_explain('m25-pricing', 'm25-policy', 1)
            -> 'parameter_value') ? 'secret'
       OR pgreact_api.parameter_family_history('m25-pricing')::text LIKE '%do-not-leak%' THEN
        RAISE EXCEPTION 'M25 public parameter output leaked an undeclared value';
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.parameter_family_preview(
        'm25-pricing', 1,
        '{"minimum_amount":200,"enabled":true}'::jsonb);
    IF actual ->> 'contract_version' <> '13'
       OR actual ->> 'family' <> 'm25-pricing'
       OR actual ->> 'changed' <> 'true'
       OR jsonb_array_length(actual -> 'consumers') <> 1 THEN
        RAISE EXCEPTION 'M25 preview changed: %', actual;
    END IF;
END
$$;

UPDATE m25_reference.parameters SET minimum_amount = 200 WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '1 minute');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                   FROM pgreact_internal.activation_state WHERE active),
        'event', (SELECT event_kind FROM pgreact_internal.parameter_family_events
                  WHERE family_id = current_setting('m25.family_id')::uuid
                    AND event_kind = 'PARAMETER_CHANGED'
                  ORDER BY event_id DESC LIMIT 1),
        'history', (SELECT count(*) FROM pgreact_internal.parameter_family_events
                    WHERE family_id = current_setting('m25.family_id')::uuid))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'active', NULL, 'event', 'PARAMETER_CHANGED', 'history', 8) THEN
        RAISE EXCEPTION 'M25 parameter deactivation changed: %', actual;
    END IF;
END
$$;

UPDATE m25_reference.parameters SET minimum_amount = 100, enabled = true WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '2 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'active', (SELECT jsonb_agg(semantic_key ORDER BY semantic_key)
                   FROM pgreact_internal.activation_state WHERE active),
        'generation', (SELECT generation FROM pgreact_internal.activation_state
                       WHERE semantic_key = 1 AND active),
        'parameter_key', (pgreact_api.parameter_family_explain(
            'm25-pricing', 'm25-policy', 1) ->> 'parameter_key'),
        'minimum_amount', (pgreact_api.parameter_family_explain(
            'm25-pricing', 'm25-policy', 1) -> 'parameter_value' ->> 'minimum_amount')
    ) INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'active', jsonb_build_array(1), 'generation', 3,
        'parameter_key', '1', 'minimum_amount', '100') THEN
        RAISE EXCEPTION 'M25 parameter reactivation or explanation changed: %', actual;
    END IF;
END
$$;

DO $$
BEGIN
    BEGIN
        EXECUTE 'ALTER TABLE m25_reference.parameters DISABLE TRIGGER pgreact_parameter_family_guard';
        RAISE EXCEPTION 'M25 parameter guard unexpectedly allowed a disabled trigger';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M25_PARAMETER_GUARD:%' THEN RAISE; END IF;
    END;
END
$$;

DO $$
BEGIN
    BEGIN
        EXECUTE 'ALTER TRIGGER pgreact_parameter_family_guard ON m25_reference.parameters RENAME TO m25_parameter_guard_tampered';
        RAISE EXCEPTION 'M25 parameter guard unexpectedly allowed a rename';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M25_PARAMETER_GUARD:%' THEN RAISE; END IF;
    END;
END
$$;

SELECT pgreact_api.revoke_parameter_family_editor('m25-pricing', 'm25_editor_group'::regrole);
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pgreact_internal.parameter_family_editors
               WHERE family_id = current_setting('m25.family_id')::uuid
                 AND role_oid = 'm25_editor_group'::regrole::oid) THEN
        RAISE EXCEPTION 'M25 editor revoke left the role grant behind';
    END IF;
END
$$;
SET SESSION AUTHORIZATION m25_editor;
DO $$
BEGIN
    BEGIN
        UPDATE m25_reference.parameters SET enabled = true WHERE id = 1;
        SET CONSTRAINTS ALL IMMEDIATE;
        RAISE EXCEPTION 'M25 revoked editor unexpectedly changed parameters';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M25_PARAMETER_EDITOR_FORBIDDEN:%' THEN RAISE; END IF;
    END;
END
$$;
RESET SESSION AUTHORIZATION;

SELECT frontier AS unrelated_base_time FROM pgreact_internal.clock_frontier \gset
SELECT pgreact_api.author_effective_rule(
    'm25-unrelated', 'm25-unrelated-v1', 'm25_reference.unrelated'::regclass,
    'id', :'unrelated_base_time'::timestamptz) AS unrelated_policy_version_id \gset
SELECT set_config('m25.unrelated_policy_version_id', :'unrelated_policy_version_id', false);
DO $$
BEGIN
    BEGIN
        PERFORM pgreact_api.bind_parameter_family(
            'm25-pricing', current_setting('m25.unrelated_policy_version_id')::uuid);
        RAISE EXCEPTION 'M25 unrelated binding unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M25_PARAMETER_DEPENDENCY:%' THEN RAISE; END IF;
    END;
    IF EXISTS (SELECT 1 FROM pgreact_internal.parameter_family_consumers
               WHERE family_id = current_setting('m25.family_id')::uuid
                 AND policy_version_id = current_setting('m25.unrelated_policy_version_id')::uuid) THEN
        RAISE EXCEPTION 'M25 unrelated binding left a consumer behind';
    END IF;
END
$$;

\ir /tmp/m8-setup.sql
CREATE VIEW m25_reference.program_input AS
SELECT id FROM m25_reference.parameters WHERE enabled;
SELECT frontier AS program_base_time FROM pgreact_internal.clock_frontier \gset
DO $$
DECLARE actual text;
BEGIN
    SELECT pgreact_internal.m8_program_definition(
        definition -> 'programs' -> 0,
        mappings || jsonb_build_object(
            'objects', mappings -> 'objects' ||
                       jsonb_build_object('m8.left_to_a', 'm25_reference.program_input')))
        #>> '{rules,0,definition}'
    INTO actual
    FROM m8_ref.manifests WHERE version = 2;
    IF actual <> 'm25_reference.program_input' THEN
        RAISE EXCEPTION 'M25 program mapping changed: %', actual;
    END IF;
END
$$;
SELECT pgreact_api.author_parameterized_program(
    'm25-program',
    (SELECT jsonb_set(
        jsonb_set(mapped_program, '{rules}',
                  jsonb_build_array(mapped_program #> '{rules,0}')),
        '{rules,0,name}', '"m25.left_to_a"')
     FROM (
         SELECT pgreact_internal.m8_program_definition(
             definition -> 'programs' -> 0,
             mappings || jsonb_build_object(
                 'objects', mappings -> 'objects' ||
                            jsonb_build_object('m8.left_to_a', 'm25_reference.program_input')))
                AS mapped_program
         FROM m8_ref.manifests WHERE version = 2
     ) mapped),
    'm25-pricing', :'program_base_time'::timestamptz + interval '10 minutes'
) AS program_policy_version_id \gset
SELECT pgreact_api.run(:'program_base_time'::timestamptz + interval '10 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'target_kind', version.target_kind,
        'program_version_id', version.program_version_id,
        'consumers', (SELECT count(*) FROM pgreact.parameter_family_consumers
                      WHERE family_name = 'm25-pricing' AND target_kind = 'PROGRAM'),
        'parameter_key', (pgreact_api.parameter_family_explain(
            'm25-pricing', 'm25-program', 1) ->> 'parameter_key'))
    INTO actual
    FROM pgreact.effective_policy_versions version
    WHERE version.policy_name = 'm25-program';
    IF actual ->> 'target_kind' <> 'PROGRAM'
       OR actual ->> 'program_version_id' IS NULL
       OR actual ->> 'consumers' <> '1'
       OR actual ->> 'parameter_key' <> '1' THEN
        RAISE EXCEPTION 'M25 parameterized program binding changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.parameter_family_status('m25-pricing');
    IF actual ->> 'contract_version' <> '13'
       OR (actual -> 'families' -> 0 ->> 'row_count') <> '1'
       OR (pgreact_api.parameter_family_doctor() ->> 'status') <> 'ready' THEN
        RAISE EXCEPTION 'M25 family status changed: %', actual;
    END IF;
END
$$;

SELECT 'M25 typed declaration, atomic seed, relational insert/update maintenance, preview, explanation, authorization, and diagnostics gate passed';
