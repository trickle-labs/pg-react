\set ON_ERROR_STOP on
\set m8_seed_left false
\set m8_seed_right false
\ir /tmp/m8-setup.sql

INSERT INTO m8_ref.manifests
SELECT 40,
       jsonb_set(jsonb_set(jsonb_set(definition, '{version}', '"40"'),
                           '{programs,0,version}', '2'),
                 '{programs,0,max_facts}', '3'), mappings
FROM m8_ref.manifests WHERE version = 2;
SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 40),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 40)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 40), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 40));
SELECT program_version_id
FROM pgreact.derivation_programs
WHERE program_name = 'm8.reference' AND state = 'ACTIVE' \gset
SELECT set_config('m8.program', :'program_version_id', false);

CREATE FUNCTION m8_ref.resource_state()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_build_object(
    'pack', (SELECT version FROM pgreact.pack_history('m8-reference-pack')
             WHERE status = 'ACTIVE'),
    'program', (SELECT jsonb_build_object(
        'name', program_name || '@' || program_version,
        'state', state, 'frontier', frontier,
        'max_iterations', max_iterations, 'max_facts', max_facts)
        FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m8.program')::uuid),
    'components', (SELECT jsonb_agg(jsonb_build_object(
        'relations', format('[%s]', (SELECT string_agg(
            upper(regexp_replace(regexp_replace(name, '^.*\.', ''), '@.*$', '')),
            ',' ORDER BY name) FROM unnest(c.target_relations) name)),
        'frontier', frontier, 'iterations', iterations,
        'facts', fact_count, 'supports', support_count) ORDER BY component_order)
        FROM pgreact.derivation_components c
        WHERE program_version_id = current_setting('m8.program')::uuid),
    'facts', COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts f
        WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
        '[]'::jsonb),
    'supports', COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY support_id)
        FROM pgreact.support_history s
        WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')
          AND active), '[]'::jsonb),
    'rows', jsonb_build_object(
        'A', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM m8_ref.a a), '[]'::jsonb),
        'B', COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY id) FROM m8_ref.b b), '[]'::jsonb),
        'C', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM m8_ref.c c), '[]'::jsonb),
        'D', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM m8_ref.d d), '[]'::jsonb)),
    'seeds', jsonb_build_object(
        'left', COALESCE((SELECT jsonb_agg(id ORDER BY id) FROM m8_ref.left_seed), '[]'::jsonb),
        'right', COALESCE((SELECT jsonb_agg(id ORDER BY id) FROM m8_ref.right_seed), '[]'::jsonb))
)
$$;

INSERT INTO m8_ref.right_seed VALUES (7);
CREATE TEMP TABLE prior_resource_state AS SELECT m8_ref.resource_state() AS state;

DO $$
DECLARE result bigint;
BEGIN
    result := pgreact.refresh_derivation_program(current_setting('m8.program')::uuid);
    IF result IS NOT NULL THEN
        RAISE EXCEPTION 'resource-limited refresh unexpectedly returned %', result;
    END IF;
END $$;

DO $$
DECLARE actual jsonb; failed_runs jsonb;
BEGIN
    actual := m8_ref.resource_state();
    IF actual IS DISTINCT FROM (SELECT state FROM prior_resource_state) THEN
        RAISE EXCEPTION 'resource failure changed prior converged state: %', actual;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations, 'fact_count', fact_count,
        'support_count', support_count, 'status', status,
        'error_sqlstate', error_sqlstate, 'error_message', error_message,
        'error_detail', error_detail, 'error_hint', error_hint,
        'requested_by', requested_by) ORDER BY run_id)
    INTO failed_runs
    FROM pgreact_internal.derivation_program_runs
    WHERE program_version_id = current_setting('m8.program')::uuid
      AND status = 'FAILED';
    IF failed_runs IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'prior_frontier', 1, 'committed_frontier', 1,
        'iterations', 0, 'fact_count', NULL, 'support_count', NULL,
        'status', 'FAILED', 'error_sqlstate', 'P0001',
        'error_message', format('derivation program %s exceeded max_facts 3',
                                current_setting('m8.program')),
        'error_detail', NULL, 'error_hint', NULL,
        'requested_by', current_user)) THEN
        RAISE EXCEPTION 'resource FAILED run changed: %', failed_runs;
    END IF;
END $$;

SELECT 'M8 resource rollback and durable FAILED run passed' AS result;
