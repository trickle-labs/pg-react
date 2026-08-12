\set ON_ERROR_STOP on

CREATE TEMP TABLE m11_before AS
SELECT jsonb_build_object(
    'programs', (SELECT jsonb_agg(to_jsonb(row) ORDER BY program_id)
        FROM (SELECT * FROM pgreact.derivation_programs) row),
    'facts', (SELECT jsonb_agg(to_jsonb(row) ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts row),
    'supports', (SELECT jsonb_agg(to_jsonb(row) ORDER BY relation_name, rule_name,
                                                   semantic_key, support_id)
        FROM pgreact.support_history row),
    'graph', (SELECT jsonb_agg(to_jsonb(row) ORDER BY rule_name, polarity, input_order)
        FROM pgreact.derivation_dependency_graph row),
    'negative_evidence', (SELECT jsonb_agg(to_jsonb(row) ORDER BY evidence_id)
        FROM pgreact.negative_dependency_evidence row),
    'aggregate_evidence', (SELECT jsonb_agg(to_jsonb(row) ORDER BY evidence_id)
        FROM pgreact.aggregate_dependency_evidence row)
) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.8.0';

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'programs', (SELECT jsonb_agg(to_jsonb(row) ORDER BY program_id)
            FROM (SELECT * FROM pgreact.derivation_programs) row),
        'facts', (SELECT jsonb_agg(to_jsonb(row) ORDER BY relation_name, semantic_key)
            FROM pgreact.derived_facts row),
        'supports', (SELECT jsonb_agg(to_jsonb(row) ORDER BY relation_name, rule_name,
                                                       semantic_key, support_id)
            FROM pgreact.support_history row),
        'graph', (SELECT jsonb_agg(to_jsonb(row) ORDER BY rule_name, polarity, input_order)
            FROM pgreact.derivation_dependency_graph row),
        'negative_evidence', (SELECT jsonb_agg(to_jsonb(row) ORDER BY evidence_id)
            FROM pgreact.negative_dependency_evidence row),
        'aggregate_evidence', (SELECT jsonb_agg(to_jsonb(row) ORDER BY evidence_id)
            FROM pgreact.aggregate_dependency_evidence row)
    ) INTO actual;
    SELECT state INTO STRICT expected FROM m11_before;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.8.0'
       OR actual IS DISTINCT FROM expected
       OR NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgreact_api') THEN
      RAISE EXCEPTION 'M11 direct upgrade changed durable state: %', actual;
    END IF;
END
$$;

SELECT 'M11 direct 0.7.0 to 0.8.0 upgrade preserved exact M10 state';
