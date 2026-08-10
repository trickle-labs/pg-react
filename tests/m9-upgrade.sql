\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react VERSION '0.5.0';
\ir /tmp/m8-setup.sql

CREATE TEMP TABLE m9_pre_upgrade AS
SELECT jsonb_build_object(
    'programs', (SELECT jsonb_agg(to_jsonb(row) ORDER BY program_id)
        FROM (SELECT program_id, program_name, program_version_id,
                     program_version, owner, state, max_iterations, max_facts,
                     frontier, created_at
              FROM pgreact.derivation_programs) row),
    'components', (SELECT jsonb_agg(to_jsonb(row)
                                   ORDER BY program_version_id, component_order)
        FROM (SELECT program_version_id, component_id, component_order, cyclic,
                     rule_names, target_relations, frontier, iterations,
                     fact_count, support_count, fingerprint, committed_at
              FROM pgreact.derivation_components) row),
    'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_name, semantic_key)
              FROM pgreact.derived_facts f),
    'supports', (SELECT jsonb_agg(to_jsonb(s) ORDER BY relation_name, rule_name,
                                 semantic_key, support_id)
                 FROM pgreact.support_history s),
    'inputs', (SELECT jsonb_agg(to_jsonb(i) ORDER BY support_id, input_order)
               FROM pgreact.recursive_support_inputs i)
) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.6.0';

DO $$
DECLARE actual jsonb; expected jsonb; explanation jsonb;
BEGIN
    SELECT jsonb_build_object(
        'programs', (SELECT jsonb_agg(to_jsonb(row) ORDER BY program_id)
            FROM (SELECT program_id, program_name, program_version_id,
                         program_version, owner, state, max_iterations, max_facts,
                         frontier, created_at
                  FROM pgreact.derivation_programs) row),
        'components', (SELECT jsonb_agg(to_jsonb(row)
                                       ORDER BY program_version_id, component_order)
            FROM (SELECT program_version_id, component_id, component_order, cyclic,
                         rule_names, target_relations, frontier, iterations,
                         fact_count, support_count, fingerprint, committed_at
                  FROM pgreact.derivation_components) row),
        'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_name, semantic_key)
                  FROM pgreact.derived_facts f),
        'supports', (SELECT jsonb_agg(to_jsonb(s) ORDER BY relation_name, rule_name,
                                     semantic_key, support_id)
                     FROM pgreact.support_history s),
        'inputs', (SELECT jsonb_agg(to_jsonb(i) ORDER BY support_id, input_order)
                   FROM pgreact.recursive_support_inputs i)
    ) INTO actual;
    SELECT state INTO STRICT expected FROM m9_pre_upgrade;
    explanation := pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7);
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.6.0'
       OR actual IS DISTINCT FROM expected
       OR EXISTS (SELECT 1 FROM pgreact.derivation_dependency_graph
                  WHERE polarity <> 'POSITIVE')
       OR EXISTS (SELECT 1 FROM pgreact.derivation_strata WHERE stratum <> 0)
       OR EXISTS (SELECT 1 FROM pgreact.negative_dependency_evidence)
       OR NOT (jsonb_path_query_array(
                   explanation, 'strict $.**.negative_checks') @> '[[]]'::jsonb) THEN
        RAISE EXCEPTION 'M9 direct upgrade changed M8 state: %, explanation=%',
            actual, explanation;
    END IF;
END
$$;

SELECT pgreact.refresh_derivation_program(
    current_setting('m8.program')::uuid) = 1 AS refresh_noop \gset
SELECT pgreact.reconcile_derivation_program(
    current_setting('m8.program')::uuid) = 0 AS reconcile_noop \gset
\if :refresh_noop
\else
  SELECT 1 / 0;
\endif
\if :reconcile_noop
\else
  SELECT 1 / 0;
\endif

SELECT 'M9 direct 0.5.0 to 0.6.0 upgrade preserved exact M8 state' AS result;
