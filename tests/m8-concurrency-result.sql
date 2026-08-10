\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'program', (SELECT jsonb_build_object(
            'name', program_name || '@' || program_version,
            'state', state, 'frontier', frontier)
            FROM pgreact.derivation_programs WHERE state = 'ACTIVE'),
        'facts', (SELECT jsonb_agg(format('%s(%s)', relation, id) ORDER BY relation)
            FROM (SELECT 'A' relation, id FROM m8_ref.a
                  UNION ALL SELECT 'B', id FROM m8_ref.b
                  UNION ALL SELECT 'C', id FROM m8_ref.c
                  UNION ALL SELECT 'D', id FROM m8_ref.d) q),
        'supports', (SELECT jsonb_agg(format('%s(%s)=%s',
            upper(regexp_replace(relation_name, '^.*\.', '')), semantic_key, support_count)
            ORDER BY relation_name)
            FROM pgreact.derived_facts
            WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
        'failure', (SELECT jsonb_build_object(
            'program', program_name || '@' || program_version,
            'started', started_at IS NOT NULL,
            'completed', completed_at IS NOT NULL,
            'prior_frontier', prior_frontier,
            'committed_frontier', committed_frontier,
            'iterations', iterations,
            'fact_count', fact_count,
            'support_count', support_count,
            'status', status,
            'error_sqlstate', error_sqlstate,
            'error_message', error_message,
            'error_detail', error_detail,
            'error_hint', error_hint,
            'requested_by', requested_by::text)
            FROM pgreact.derivation_program_runs
            WHERE program_version_id = (SELECT program_version_id FROM m8_ref.pack_control)
              AND status = 'FAILED'
            ORDER BY run_id DESC LIMIT 1),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = (SELECT observer_version_id FROM m8_ref.pack_control))
    ) INTO actual;
    expected := jsonb_build_object(
        'program', jsonb_build_object(
            'name', 'm8.reference@3', 'state', 'ACTIVE', 'frontier', 2),
        'facts', jsonb_build_array('A(7)', 'B(7)', 'C(7)', 'D(7)'),
        'supports', jsonb_build_array('A(7)=2', 'B(7)=1', 'C(7)=3', 'D(7)=1'),
        'failure', jsonb_build_object(
            'program', 'm8.reference@3',
            'started', true,
            'completed', true,
            'prior_frontier', 2,
            'committed_frontier', 2,
            'iterations', 0,
            'fact_count', NULL,
            'support_count', NULL,
            'status', 'FAILED',
            'error_sqlstate', '55P03',
            'error_message', 'canceling statement due to lock timeout',
            'error_detail', NULL,
            'error_hint', NULL,
            'requested_by', 'postgres'),
        'events', jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'generation', 1)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 concurrent graph changed: %', actual;
    END IF;
END $$;

SELECT 'M8 concurrent refresh and DDL preserved exact V3 graph' AS result;
