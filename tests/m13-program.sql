\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
\ir /tmp/m8-setup.sql

INSERT INTO m8_ref.left_seed VALUES (8);
INSERT INTO m8_ref.right_seed VALUES (8);

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.run('2031-01-01 00:00:00+00');
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', CASE
            WHEN (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') IN ('0.12.0', '0.13.0')
            THEN 5 ELSE 3 END,
        'sampled_time', '2031-01-01 00:00:00+00'::timestamptz,
        'rules', jsonb_build_array(jsonb_build_object(
            'rule', 'm8.observe_d', 'kind', 'ordinary', 'result', 'refreshed')),
        'relations', '[]'::jsonb,
        'programs', jsonb_build_array(jsonb_build_object(
            'program', 'm8.reference', 'frontier', 2)),
        'clock', jsonb_build_object(
            'sampled_time', '2031-01-01 00:00:00+00'::timestamptz,
            'previous_frontier', '-infinity'::timestamptz,
            'frontier', '2031-01-01 00:00:00+00'::timestamptz,
            'affected_rules', 0, 'affected_keys', 0),
        'jobs_created', 0) THEN
        RAISE EXCEPTION 'M13 program run result changed: %', actual;
    END IF;
    SELECT jsonb_build_object(
        'program_frontier', (SELECT frontier
            FROM pgreact.derivation_programs
            WHERE program_version_id = current_setting('m8.program')::uuid),
        'facts', (SELECT jsonb_agg(format('%s(%s)', relation, id)
            ORDER BY relation, id)
            FROM (SELECT 'A' relation, id FROM m8_ref.a
                  UNION ALL SELECT 'B', id FROM m8_ref.b
                  UNION ALL SELECT 'C', id FROM m8_ref.c
                  UNION ALL SELECT 'D', id FROM m8_ref.d) facts),
        'observer', (SELECT jsonb_agg(jsonb_build_object(
            'key', semantic_key, 'active', active, 'generation', generation)
            ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m8.observer')::uuid))
      INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'program_frontier', 2,
        'facts', jsonb_build_array(
            'A(7)', 'A(8)', 'B(7)', 'B(8)',
            'C(7)', 'C(8)', 'D(7)', 'D(8)'),
        'observer', jsonb_build_array(
            jsonb_build_object('key', 7, 'active', true, 'generation', 1),
            jsonb_build_object('key', 8, 'active', true, 'generation', 1))) THEN
        RAISE EXCEPTION 'M13 program dependency order changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.run('2031-01-01 00:00:00+00');
    IF actual -> 'programs' IS DISTINCT FROM jsonb_build_array(
            jsonb_build_object('program', 'm8.reference', 'frontier', 2))
       OR actual -> 'jobs_created' IS DISTINCT FROM '0'::jsonb
       OR (SELECT count(*) FROM pgreact_internal.lifecycle_events
           WHERE rule_version_id = current_setting('m8.observer')::uuid) <> 2 THEN
        RAISE EXCEPTION 'M13 repeated program run changed state: %', actual;
    END IF;
END
$$;

SELECT 'M13 dependency-ordered program coordinator gate passed';
