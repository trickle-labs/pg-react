\set ON_ERROR_STOP on
\o /dev/null
\set m8_seed_left true
\set m8_seed_right true
\if :left_first
  \set m8_left_first true
  \set m8_seed_delay 0
\else
  \set m8_left_first false
  \set m8_seed_delay 0.05
\endif
\ir /tmp/m8-setup.sql
\o

SELECT jsonb_build_object(
    'program', (SELECT jsonb_build_object(
        'name', program_name || '@' || program_version, 'frontier', frontier)
        FROM pgreact.derivation_programs WHERE state = 'ACTIVE'),
    'components', (SELECT jsonb_agg(jsonb_build_object(
        'order', component_order, 'cyclic', cyclic,
        'rules', rule_names, 'targets', target_relations,
        'frontier', frontier, 'iterations', iterations,
        'facts', fact_count, 'supports', support_count)
        ORDER BY component_order) FROM pgreact.derivation_components),
    'runs', (SELECT jsonb_agg(jsonb_build_object(
        'prior_frontier', prior_frontier, 'committed_frontier', committed_frontier,
        'iterations', iterations, 'facts', fact_count, 'supports', support_count,
        'status', status, 'requested_by', requested_by) ORDER BY run_id)
        FROM pgreact_internal.derivation_program_runs),
    'iteration_history', (SELECT jsonb_agg(jsonb_build_object(
        'component', format('[%s]', (SELECT string_agg(
            upper(regexp_replace(regexp_replace(name, '^.*\.', ''), '@.*$', '')),
            ',' ORDER BY name) FROM unnest(c.target_relations) AS name)),
        'iteration', i.iteration, 'facts', i.fact_count,
        'supports', i.support_count, 'fingerprint', i.fingerprint)
        ORDER BY i.run_id, c.component_order, i.iteration)
        FROM pgreact.derivation_iterations i
        JOIN pgreact.derivation_components c
          ON c.program_version_id = i.program_version_id
         AND c.component_id = i.component_id),
    'facts', (SELECT jsonb_agg(format('%s(%s)', relation, id) ORDER BY relation)
        FROM (SELECT 'A' relation, id FROM m8_ref.a
              UNION ALL SELECT 'B', id FROM m8_ref.b
              UNION ALL SELECT 'C', id FROM m8_ref.c
              UNION ALL SELECT 'D', id FROM m8_ref.d) q),
    'support_counts', (SELECT jsonb_agg(format('%s(%s)=%s',
        upper(regexp_replace(relation_name, '^.*\.', '')), semantic_key, support_count)
        ORDER BY relation_name)
        FROM pgreact.derived_facts
        WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
    'support_history', (SELECT jsonb_agg(jsonb_build_object(
        'rule', r.rule_name, 'target', d.relation_name,
        'semantic_key', s.semantic_key, 'fact', s.fact,
        'source_binding', s.source_binding, 'active', s.active,
        'grounded', s.grounded, 'first_frontier', s.first_frontier,
        'last_frontier', s.last_frontier, 'support_frontier', s.support_frontier)
        ORDER BY r.rule_name, s.semantic_key)
        FROM pgreact_internal.derived_supports s
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = current_setting('m8.program')::uuid
         AND r.rule_version_id = s.rule_version_id
        JOIN pgreact_internal.derived_relation_versions v
          ON v.relation_version_id = s.relation_version_id
        JOIN pgreact_internal.derived_relations d USING (relation_id)),
    'support_inputs', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'rule', r.rule_name, 'semantic_key', s.semantic_key,
        'input_order', i.input_order, 'input_relation', d.relation_name,
        'input_semantic_key', i.semantic_key)
        ORDER BY r.rule_name, s.semantic_key, i.input_order)
        FROM pgreact_internal.derived_support_inputs i
        JOIN pgreact_internal.derived_supports s USING (support_id)
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = current_setting('m8.program')::uuid
         AND r.rule_version_id = s.rule_version_id
        JOIN pgreact_internal.derived_relation_versions v
          ON v.relation_version_id = i.relation_version_id
        JOIN pgreact_internal.derived_relations d USING (relation_id)), '[]'::jsonb),
    'explanation', (pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7)
        #- '{proof,supports,0,logical_support_id}'
        #- '{proof,supports,1,logical_support_id}'
        #- '{proof,supports,2,logical_support_id}'
        #- '{proof,supports,0,inputs,0,supports,0,logical_support_id}'
        #- '{proof,supports,0,inputs,0,supports,1,logical_support_id}'
        #- '{proof,supports,1,inputs,0,supports,0,logical_support_id}'
        #- '{proof,supports,1,inputs,0,supports,0,inputs,0,supports,0,logical_support_id}'
        #- '{proof,supports,1,inputs,0,supports,0,inputs,0,supports,1,logical_support_id}'
        #- '{proof,supports,2,inputs,0,supports,0,logical_support_id}')
)::text;
