\set ON_ERROR_STOP on
\o /dev/null

CREATE VIEW m10_slice1.grouped_items AS
SELECT id, count(*) AS copies FROM m10_slice1.items GROUP BY id;

CREATE TEMP TABLE m10_boundary_results AS
WITH base AS (
    SELECT pgreact_internal.m8_program_definition(
        definition -> 'programs' -> 0, mappings) AS program
    FROM m10_slice1.manifest
), candidates(fixture, program) AS (
    SELECT 'negative_threshold', jsonb_set(
        program, '{rules,0,aggregate_input,threshold}', '-1'::jsonb) FROM base
    UNION ALL SELECT 'unbound_group_key', jsonb_set(
        program, '{rules,0,aggregate_input,key}', '"other"'::jsonb) FROM base
    UNION ALL SELECT 'nested_aggregate', jsonb_set(
        program, '{rules,0,aggregate_input,relation}',
        '"m10_slice1.grouped_items"'::jsonb) FROM base
    UNION ALL SELECT 'aggregate_cycle', jsonb_set(
        program, '{rules,0,aggregate_input,relation}',
        '"m10_slice1.alert"'::jsonb) FROM base
)
SELECT fixture, jsonb_build_object(
    'contract_version', contract_version, 'code', code, 'severity', severity,
    'object_identity', object_identity, 'message', message, 'hint', hint,
    'details', details) AS diagnostic
FROM candidates CROSS JOIN LATERAL pgreact.validate_derivation_program(program);

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_object_agg(fixture, diagnostic ORDER BY fixture) INTO actual
    FROM m10_boundary_results;
    expected := jsonb_build_object(
        'aggregate_cycle', jsonb_build_object(
            'contract_version', 4, 'code', 'PROGRAM_AGGREGATE_CYCLE',
            'severity', 'ERROR', 'object_identity', 'm10.slice1',
            'message', 'derivation program contains a cycle through negation or aggregation',
            'hint', 'Make every aggregate and negative dependency point strictly downward.',
            'details', '{}'::jsonb),
        'negative_threshold', jsonb_build_object(
            'contract_version', 4, 'code', 'PROGRAM_AGGREGATE_THRESHOLD_INVALID',
            'severity', 'ERROR', 'object_identity', 'm10.groups_to_alert',
            'message', 'aggregate threshold must be one immutable non-negative bigint with =, <, <=, >, or >=',
            'hint', 'Use a JSON integer threshold and one supported comparison.',
            'details', jsonb_build_object('comparison', '>=', 'threshold', -1)),
        'nested_aggregate', jsonb_build_object(
            'contract_version', 4, 'code', 'PROGRAM_AGGREGATE_UNSUPPORTED',
            'severity', 'ERROR', 'object_identity', 'm10.groups_to_alert',
            'message', 'aggregate_input must name raw rows; M10 computes the only COUNT(*) itself',
            'hint', 'Remove nested aggregates, DISTINCT, FILTER, windows, and grouping from the input relation.',
            'details', jsonb_build_object('relation', 'm10_slice1.grouped_items')),
        'unbound_group_key', jsonb_build_object(
            'contract_version', 4, 'code', 'PROGRAM_AGGREGATE_UNBOUND',
            'severity', 'ERROR', 'object_identity', 'm10.groups_to_alert',
            'message', 'aggregate group key must equal the derived fact semantic key',
            'hint', 'Bind aggregate_input.key to the rule output key.',
            'details', jsonb_build_object('aggregate_key', 'other', 'output_key', 'id')));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M10 aggregate boundary diagnostics changed: expected %, got %',
            expected, actual;
    END IF;
END
$$;

\o
SELECT 'M10 aggregate boundary gate passed';
