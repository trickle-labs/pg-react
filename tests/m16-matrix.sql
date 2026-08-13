\set ON_ERROR_STOP on
SET statement_timeout = '5min';
SET TIME ZONE 'America/Los_Angeles';

CREATE SCHEMA m16_matrix AUTHORIZATION m16_author;
SET SESSION AUTHORIZATION m16_author;
CREATE TYPE m16_matrix.fact_row AS (id bigint);
CREATE TABLE m16_matrix.groups (id bigint PRIMARY KEY);
CREATE TABLE m16_matrix.values (
    value_id bigint PRIMARY KEY,
    id bigint NOT NULL,
    boolean_v boolean,
    smallint_v smallint,
    integer_v integer,
    bigint_v bigint,
    numeric_v numeric,
    real_v real,
    double_v double precision,
    text_v text COLLATE "C",
    date_v date,
    timestamp_v timestamp,
    timestamptz_v timestamptz,
    uuid_v uuid
);
CREATE TABLE m16_matrix.expected (
    rule_name text PRIMARY KEY,
    function_name text NOT NULL,
    expression_name name NOT NULL,
    input_type_name text NOT NULL,
    result_type_name text NOT NULL,
    normal_value text NOT NULL
);
CREATE VIEW m16_matrix.group_source AS SELECT id FROM m16_matrix.groups;
CREATE VIEW m16_matrix.value_source AS
SELECT id, boolean_v, smallint_v, integer_v, bigint_v, numeric_v, real_v,
       double_v, text_v, date_v, timestamp_v, timestamptz_v, uuid_v
FROM m16_matrix.values;

INSERT INTO m16_matrix.expected VALUES
    ('m16_matrix.count_bigint_v', 'COUNT', 'bigint_v', 'bigint', 'bigint', '2'),
    ('m16_matrix.count_boolean_v', 'COUNT', 'boolean_v', 'boolean', 'bigint', '2'),
    ('m16_matrix.count_date_v', 'COUNT', 'date_v', 'date', 'bigint', '2'),
    ('m16_matrix.count_double_v', 'COUNT', 'double_v', 'double precision', 'bigint', '2'),
    ('m16_matrix.count_integer_v', 'COUNT', 'integer_v', 'integer', 'bigint', '2'),
    ('m16_matrix.count_numeric_v', 'COUNT', 'numeric_v', 'numeric', 'bigint', '2'),
    ('m16_matrix.count_real_v', 'COUNT', 'real_v', 'real', 'bigint', '2'),
    ('m16_matrix.count_smallint_v', 'COUNT', 'smallint_v', 'smallint', 'bigint', '2'),
    ('m16_matrix.count_text_v', 'COUNT', 'text_v', 'text', 'bigint', '2'),
    ('m16_matrix.count_timestamp_v', 'COUNT', 'timestamp_v',
        'timestamp without time zone', 'bigint', '2'),
    ('m16_matrix.count_timestamptz_v', 'COUNT', 'timestamptz_v',
        'timestamp with time zone', 'bigint', '2'),
    ('m16_matrix.count_uuid_v', 'COUNT', 'uuid_v', 'uuid', 'bigint', '2'),
    ('m16_matrix.max_bigint_v', 'MAX', 'bigint_v', 'bigint', 'bigint',
        '9223372036854775807'),
    ('m16_matrix.max_date_v', 'MAX', 'date_v', 'date', 'date', '2026-01-02'),
    ('m16_matrix.max_double_v', 'MAX', 'double_v', 'double precision',
        'double precision', '2.25'),
    ('m16_matrix.max_integer_v', 'MAX', 'integer_v', 'integer', 'integer', '10'),
    ('m16_matrix.max_numeric_v', 'MAX', 'numeric_v', 'numeric', 'numeric', '2.50'),
    ('m16_matrix.max_real_v', 'MAX', 'real_v', 'real', 'real', '2.75'),
    ('m16_matrix.max_smallint_v', 'MAX', 'smallint_v', 'smallint', 'smallint', '5'),
    ('m16_matrix.max_text_v', 'MAX', 'text_v', 'text', 'text', 'a'),
    ('m16_matrix.max_timestamp_v', 'MAX', 'timestamp_v',
        'timestamp without time zone', 'timestamp without time zone',
        '2026-01-02 00:00:00'),
    ('m16_matrix.max_timestamptz_v', 'MAX', 'timestamptz_v',
        'timestamp with time zone', 'timestamp with time zone',
        '2026-01-01 00:00:00+00'),
    ('m16_matrix.max_uuid_v', 'MAX', 'uuid_v', 'uuid', 'uuid',
        '00000000-0000-0000-0000-000000000002'),
    ('m16_matrix.min_bigint_v', 'MIN', 'bigint_v', 'bigint', 'bigint', '1'),
    ('m16_matrix.min_date_v', 'MIN', 'date_v', 'date', 'date', '2025-12-31'),
    ('m16_matrix.min_double_v', 'MIN', 'double_v', 'double precision',
        'double precision', '-4.5'),
    ('m16_matrix.min_integer_v', 'MIN', 'integer_v', 'integer', 'integer', '-3'),
    ('m16_matrix.min_numeric_v', 'MIN', 'numeric_v', 'numeric', 'numeric', '-1.25'),
    ('m16_matrix.min_real_v', 'MIN', 'real_v', 'real', 'real', '-1.5'),
    ('m16_matrix.min_smallint_v', 'MIN', 'smallint_v', 'smallint', 'smallint', '-2'),
    ('m16_matrix.min_text_v', 'MIN', 'text_v', 'text', 'text', 'Z'),
    ('m16_matrix.min_timestamp_v', 'MIN', 'timestamp_v',
        'timestamp without time zone', 'timestamp without time zone',
        '2026-01-01 01:02:03.456789'),
    ('m16_matrix.min_timestamptz_v', 'MIN', 'timestamptz_v',
        'timestamp with time zone', 'timestamp with time zone',
        '2025-12-31 23:00:00+00'),
    ('m16_matrix.min_uuid_v', 'MIN', 'uuid_v', 'uuid', 'uuid',
        '00000000-0000-0000-0000-000000000001'),
    ('m16_matrix.sum_bigint_v', 'SUM', 'bigint_v', 'bigint', 'numeric',
        '9223372036854775808'),
    ('m16_matrix.sum_double_v', 'SUM', 'double_v', 'double precision',
        'double precision', '-2.25'),
    ('m16_matrix.sum_integer_v', 'SUM', 'integer_v', 'integer', 'bigint', '7'),
    ('m16_matrix.sum_numeric_v', 'SUM', 'numeric_v', 'numeric', 'numeric', '1.25'),
    ('m16_matrix.sum_real_v', 'SUM', 'real_v', 'real', 'real', '1.25'),
    ('m16_matrix.sum_smallint_v', 'SUM', 'smallint_v', 'smallint', 'bigint', '3');

INSERT INTO m16_matrix.groups SELECT value FROM generate_series(1, 7) value;
INSERT INTO m16_matrix.values VALUES
    (11, 1, true, -2, -3, 9223372036854775807, -1.25, -1.5, 2.25,
        'Z', '2026-01-02', '2026-01-01 01:02:03.456789',
        '2026-01-01 00:00:00+00', '00000000-0000-0000-0000-000000000002'),
    (12, 1, false, 5, 10, 1, 2.50, 2.75, -4.5,
        'a', '2025-12-31', '2026-01-02 00:00:00',
        '2025-12-31 23:00:00+00', '00000000-0000-0000-0000-000000000001'),
    (13, 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL),
    (21, 2, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL),
    (41, 4, false, 5, 10, 1, 2.50, 2.75, -4.5,
        'a', '2025-12-31', '2026-01-02 00:00:00',
        '2025-12-31 23:00:00+00', '00000000-0000-0000-0000-000000000001'),
    (42, 4, true, -2, -3, 9223372036854775807, -1.25, -1.5, 2.25,
        'Z', '2026-01-02', '2026-01-01 01:02:03.456789',
        '2026-01-01 00:00:00+00', '00000000-0000-0000-0000-000000000002'),
    (43, 4, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, NULL),
    (51, 5, NULL, NULL, NULL, NULL, NULL, 'NaN', 'NaN',
        NULL, NULL, 'infinity', 'infinity', NULL),
    (61, 6, NULL, NULL, NULL, NULL, NULL, 'Infinity', 'Infinity',
        NULL, NULL, '-infinity', '-infinity', NULL),
    (71, 7, NULL, NULL, NULL, NULL, NULL, '-Infinity', '-Infinity',
        NULL, NULL, NULL, NULL, NULL);

SELECT pgreact_api.declare_derived_relation(
    'm16_matrix.alert', 'm16_matrix.fact_row'::regtype, ARRAY['id']::name[]);
DO $$
DECLARE definition jsonb; preview jsonb;
BEGIN
    SELECT jsonb_build_object(
        'name', 'm16.matrix', 'version', 1,
        'max_iterations', 8, 'max_facts', 512,
        'rules', jsonb_agg(jsonb_build_object(
            'name', rule_name,
            'definition', 'm16_matrix.group_source',
            'key', 'id', 'target', 'm16_matrix.alert', 'version', 1,
            'aggregate_input', jsonb_build_object(
                'relation', 'm16_matrix.value_source', 'key', 'id',
                'function', function_name, 'expression', expression_name,
                'comparison', '=', 'threshold', normal_value))
            ORDER BY rule_name))
    INTO definition
    FROM m16_matrix.expected;
    preview := pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m16_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    WITH resolved AS (
        SELECT group_id, matrix.*,
               CASE
                   WHEN group_id IN (1, 4) THEN normal_value
                   WHEN function_name = 'COUNT' THEN CASE
                       WHEN group_id IN (5, 6)
                            AND expression_name IN (
                                'real_v', 'double_v', 'timestamp_v', 'timestamptz_v')
                           THEN '1'
                       WHEN group_id = 7
                            AND expression_name IN ('real_v', 'double_v') THEN '1'
                       ELSE '0' END
                   WHEN group_id = 5 AND expression_name IN ('real_v', 'double_v')
                       THEN 'NaN'
                   WHEN group_id = 6 AND expression_name IN ('real_v', 'double_v')
                       THEN 'Infinity'
                   WHEN group_id = 7 AND expression_name IN ('real_v', 'double_v')
                       THEN '-Infinity'
                   WHEN group_id = 5 AND function_name IN ('MIN', 'MAX')
                        AND expression_name IN ('timestamp_v', 'timestamptz_v')
                       THEN 'infinity'
                   WHEN group_id = 6 AND function_name IN ('MIN', 'MAX')
                        AND expression_name IN ('timestamp_v', 'timestamptz_v')
                       THEN '-infinity'
               END AS expected_value
        FROM generate_series(1, 7) group_id
        CROSS JOIN m16_matrix.expected matrix
    )
    SELECT jsonb_agg(jsonb_build_object(
        'rule', rule_name, 'key', group_id,
        'relation', 'm16_matrix.value_source',
        'function', function_name, 'expression', expression_name,
        'input_type', input_type_name, 'result_type', result_type_name,
        'collation', CASE WHEN expression_name = 'text_v' THEN '"C"' END,
        'value', expected_value, 'comparison', '=', 'threshold', normal_value,
        'truth', CASE
            WHEN group_id IN (1, 4) THEN true
            WHEN expected_value IS NULL THEN NULL
            ELSE false END)
        ORDER BY rule_name, group_id)
    INTO expected
    FROM resolved;

    SELECT jsonb_agg(jsonb_build_object(
        'rule', rule_name, 'key', public_group_key,
        'relation', counted_relation, 'function', aggregate_function,
        'expression', value_expression, 'input_type', input_type_name,
        'result_type', result_type_name,
        'collation', expression_collation_name,
        'value', exact_value, 'comparison', comparison,
        'threshold', typed_threshold, 'truth', truth_result)
        ORDER BY rule_name, public_group_key)
    INTO actual
    FROM pgreact.aggregate_dependency_evidence
    WHERE program_name = 'm16.matrix';
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M16 full aggregate/type/value matrix changed: %', actual;
    END IF;

    SELECT jsonb_build_object(
        'facts', (SELECT jsonb_agg(to_jsonb(alert) ORDER BY id)
                  FROM m16_matrix.alert alert),
        'supported', (SELECT jsonb_agg(
                public_group_key::text || ':' || rule.rule_name
                ORDER BY public_group_key, rule.rule_name)
            FROM pgreact_internal.aggregate_dependency_evidence evidence
            JOIN pgreact_internal.derivation_program_rules rule
              USING (program_version_id, rule_version_id)
            JOIN pgreact_internal.derivation_program_versions version
              USING (program_version_id)
            JOIN pgreact_internal.derivation_programs program USING (program_id)
            WHERE program.program_name = 'm16.matrix' AND version.state = 'ACTIVE'
              AND evidence.active AND evidence.support_id IS NOT NULL),
        'unsupported', (SELECT jsonb_agg(
                public_group_key::text || ':' || rule.rule_name
                ORDER BY public_group_key, rule.rule_name)
            FROM pgreact_internal.aggregate_dependency_evidence evidence
            JOIN pgreact_internal.derivation_program_rules rule
              USING (program_version_id, rule_version_id)
            JOIN pgreact_internal.derivation_program_versions version
              USING (program_version_id)
            JOIN pgreact_internal.derivation_programs program USING (program_id)
            WHERE program.program_name = 'm16.matrix' AND version.state = 'ACTIVE'
              AND evidence.active
              AND (evidence.support_id IS NOT NULL) IS DISTINCT FROM
                  (evidence.truth_result IS TRUE)))
    INTO actual;
    SELECT jsonb_build_object(
        'facts', jsonb_build_array(jsonb_build_object('id', 1), jsonb_build_object('id', 4)),
        'supported', jsonb_agg(group_id::text || ':' || rule_name
            ORDER BY group_id, rule_name),
        'unsupported', NULL)
    INTO expected
    FROM (VALUES (1), (4)) groups(group_id)
    CROSS JOIN m16_matrix.expected;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M16 matrix facts or supports changed: %', actual;
    END IF;

    SELECT jsonb_build_object(
        'program_frontier', version.frontier,
        'minimum_evidence_frontier', min(evidence.lower_frontier),
        'maximum_evidence_frontier', max(evidence.lower_frontier))
    INTO actual
    FROM pgreact_internal.derivation_programs program
    JOIN pgreact_internal.derivation_program_versions version USING (program_id)
    JOIN pgreact_internal.aggregate_dependency_evidence evidence
      USING (program_version_id)
    WHERE program.program_name = 'm16.matrix' AND version.state = 'ACTIVE'
      AND evidence.active
    GROUP BY version.frontier;
    IF actual -> 'program_frontier' IS DISTINCT FROM actual -> 'minimum_evidence_frontier'
       OR actual -> 'program_frontier' IS DISTINCT FROM actual -> 'maximum_evidence_frontier' THEN
        RAISE EXCEPTION 'M16 matrix did not commit at one complete frontier: %', actual;
    END IF;
END
$$;

SELECT 'M16 complete aggregate/type/null/empty/special/order matrix passed';
