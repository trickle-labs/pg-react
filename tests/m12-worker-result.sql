\set ON_ERROR_STOP on
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'activation', (SELECT jsonb_build_object(
            'semantic_key', activation.semantic_key,
            'active', activation.active,
            'generation', activation.generation,
            'revision', activation.revision)
            FROM pgreact_internal.activation_state activation
            JOIN pgreact_internal.rule_versions version USING (rule_version_id)
            JOIN pgreact_internal.rules rule USING (rule_id)
            WHERE rule.rule_name = 'worker-deadline' AND version.state = 'ACTIVE'),
        'agenda', (SELECT jsonb_agg(jsonb_build_object(
            'state', agenda.state,
            'event_kind', agenda.event_kind,
            'generation', agenda.activation_generation,
            'attempt_count', agenda.attempt_count) ORDER BY agenda.episode_id)
            FROM pgreact_internal.agenda agenda
            JOIN pgreact_internal.rule_versions version USING (rule_version_id)
            JOIN pgreact_internal.rules rule ON rule.rule_id = agenda.rule_id
            WHERE rule.rule_name = 'worker-deadline'),
        'history', pgreact_internal.deadline_history('worker-deadline'),
        'frontier_reached_deadline', (SELECT frontier >= '2000-01-01 00:00:00+00'
            FROM pgreact_internal.clock_frontier))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'activation', jsonb_build_object(
            'semantic_key', 1, 'active', true,
            'generation', 1, 'revision', 0),
        'agenda', jsonb_build_array(jsonb_build_object(
            'state', 'COMPLETED', 'event_kind', 'ACTIVATE',
            'generation', 1, 'attempt_count', 1)),
        'history', jsonb_build_array(jsonb_build_object(
            'rule_name', 'worker-deadline', 'semantic_key', 1,
            'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
            'declared_deadline', '2000-01-01 00:00:00+00'::timestamptz,
            'clock_frontier', (SELECT frontier FROM pgreact_internal.clock_frontier))),
        'frontier_reached_deadline', true) THEN
        RAISE EXCEPTION 'M12 worker clock/claim/execute result changed: %', actual;
    END IF;
END
$$;
SELECT 'M12 bundled worker clock, claim, and execute path passed';
