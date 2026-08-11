\set ON_ERROR_STOP on

CREATE TEMP TABLE m10_pre_upgrade AS
SELECT jsonb_build_object(
    'programs', (SELECT jsonb_agg(to_jsonb(row) ORDER BY program_id)
        FROM (SELECT program_id, program_name, program_version_id, program_version,
                     owner, state, max_iterations, max_facts, frontier, created_at
              FROM pgreact.derivation_programs) row),
    'components', (SELECT jsonb_agg(to_jsonb(row)
        ORDER BY program_version_id, component_order)
        FROM (SELECT program_version_id, component_id, component_order, cyclic,
                     rule_names, target_relations, frontier, iterations, fact_count,
                     support_count, fingerprint, committed_at
              FROM pgreact.derivation_components) row),
    'facts', (SELECT jsonb_agg(to_jsonb(row) ORDER BY relation_name, semantic_key)
              FROM pgreact.derived_facts row),
    'supports', (SELECT jsonb_agg(to_jsonb(row)
        ORDER BY relation_name, rule_name, semantic_key, support_id)
        FROM pgreact.support_history row),
    'graph', (SELECT jsonb_agg(to_jsonb(row)
        ORDER BY rule_name, polarity, input_order, source_relation)
        FROM pgreact.derivation_dependency_graph row),
    'negative_evidence', (SELECT jsonb_agg(to_jsonb(row) ORDER BY evidence_id)
        FROM pgreact.negative_dependency_evidence row)
) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.7.0';

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'programs', (SELECT jsonb_agg(to_jsonb(row) ORDER BY program_id)
            FROM (SELECT program_id, program_name, program_version_id, program_version,
                         owner, state, max_iterations, max_facts, frontier, created_at
                  FROM pgreact.derivation_programs) row),
        'components', (SELECT jsonb_agg(to_jsonb(row)
            ORDER BY program_version_id, component_order)
            FROM (SELECT program_version_id, component_id, component_order, cyclic,
                         rule_names, target_relations, frontier, iterations, fact_count,
                         support_count, fingerprint, committed_at
                  FROM pgreact.derivation_components) row),
        'facts', (SELECT jsonb_agg(to_jsonb(row) ORDER BY relation_name, semantic_key)
                  FROM pgreact.derived_facts row),
        'supports', (SELECT jsonb_agg(to_jsonb(row)
            ORDER BY relation_name, rule_name, semantic_key, support_id)
            FROM pgreact.support_history row),
        'graph', (SELECT jsonb_agg(to_jsonb(row)
            ORDER BY rule_name, polarity, input_order, source_relation)
            FROM pgreact.derivation_dependency_graph row),
        'negative_evidence', (SELECT jsonb_agg(to_jsonb(row) ORDER BY evidence_id)
            FROM pgreact.negative_dependency_evidence row)
    ) INTO actual;
    SELECT state INTO STRICT expected FROM m10_pre_upgrade;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.7.0'
       OR actual IS DISTINCT FROM expected
       OR EXISTS (SELECT 1 FROM pgreact.aggregate_dependency_evidence)
       OR EXISTS (SELECT 1 FROM pgreact_internal.aggregate_dependency_evidence) THEN
        RAISE EXCEPTION 'M10 direct upgrade changed M9 state: %', actual;
    END IF;
END
$$;

SELECT 'M10 direct 0.6.0 to 0.7.0 upgrade preserved exact M9 state';
