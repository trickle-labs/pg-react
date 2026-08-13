\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
DECLARE actual jsonb; expected_before jsonb; expected_after jsonb; version_id uuid;
BEGIN
    SELECT rule_version_id, before_state, after_state
      INTO STRICT version_id, expected_before, expected_after
    FROM m12_recovery.control;
    SELECT jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'activations', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision) ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = version_id), '[]'::jsonb),
        'history', pgreact_internal.deadline_history('recovery-deadline'),
        'clock', (SELECT jsonb_agg(jsonb_build_object(
            'sampled_time', sampled_time,
            'previous_frontier', previous_frontier,
            'frontier', frontier,
            'affected_rules', affected_rules,
            'affected_keys', affected_keys) ORDER BY clock_event_id)
            FROM pgreact_internal.clock_history))
    INTO actual;
    IF actual IS DISTINCT FROM expected_before
       AND actual IS DISTINCT FROM expected_after THEN
        RAISE EXCEPTION 'M12 restored durable state changed: %', actual;
    END IF;
END
$$;

DO $$
BEGIN
    IF (SELECT frontier FROM pgreact_internal.clock_frontier)
       < '2026-05-02 00:00:00+00'::timestamptz THEN
        PERFORM pgreact.begin_deadline_refresh(12402);
        PERFORM pgreact.advance_deadline_clock('2026-05-02 00:00:00+00');
        PERFORM pgreact.finish_deadline_refresh();
    END IF;
END
$$;

DO $$
DECLARE actual jsonb; expected jsonb; version_id uuid;
BEGIN
    SELECT rule_version_id, after_state INTO STRICT version_id, expected
    FROM m12_recovery.control;
    SELECT jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'activations', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision) ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = version_id), '[]'::jsonb),
        'history', pgreact_internal.deadline_history('recovery-deadline'),
        'clock', (SELECT jsonb_agg(jsonb_build_object(
            'sampled_time', sampled_time,
            'previous_frontier', previous_frontier,
            'frontier', frontier,
            'affected_rules', affected_rules,
            'affected_keys', affected_keys) ORDER BY clock_event_id)
            FROM pgreact_internal.clock_history))
    INTO actual;
    IF actual IS DISTINCT FROM expected
       OR (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') NOT IN ('0.9.0', '0.10.0', '0.11.0', '0.12.0')
       OR pg_catalog.pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M12 recovery catch-up changed: %, %', actual, expected;
    END IF;
END
$$;

SELECT 'M12 crash, restart, physical restore, and catch-up state passed';
