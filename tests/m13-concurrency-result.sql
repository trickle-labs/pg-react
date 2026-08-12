\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
DECLARE actual jsonb; expected_key text; version_id uuid; activation_id uuid;
BEGIN
    SELECT state.rule_version_id, state.activation_id
      INTO STRICT version_id, activation_id
      FROM pgreact_internal.activation_state state;
    expected_key := encode(sha256(convert_to(
        version_id::text || ':' || activation_id::text || ':1:ACTIVATE:0',
        'UTF8')), 'hex');
    SELECT jsonb_build_object(
        'matches', (SELECT jsonb_agg(jsonb_build_object(
            'key', semantic_key, 'active', active,
            'generation', generation, 'revision', revision)
            ORDER BY semantic_key)
            FROM pgreact_internal.activation_state),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation, 'revision', revision)
            ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events),
        'jobs', (SELECT jsonb_agg(jsonb_build_object(
            'action', event_kind, 'state', state,
            'idempotency_key', idempotency_key)
            ORDER BY episode_id)
            FROM pgreact_internal.agenda),
        'clock', (SELECT jsonb_agg(jsonb_build_object(
            'previous', previous_frontier, 'frontier', frontier,
            'affected_rules', affected_rules, 'affected_keys', affected_keys)
            ORDER BY clock_event_id)
            FROM pgreact_internal.clock_history),
        'barriers', (SELECT count(*) FROM pgreact_internal.rule_barriers))
      INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'matches', jsonb_build_array(jsonb_build_object(
            'key', 1, 'active', true, 'generation', 1, 'revision', 0)),
        'events', jsonb_build_array(jsonb_build_object(
            'event', 'ACTIVATE', 'generation', 1, 'revision', 0)),
        'jobs', jsonb_build_array(jsonb_build_object(
            'action', 'ACTIVATE', 'state', 'PENDING',
            'idempotency_key', expected_key)),
        'clock', jsonb_build_array(
            jsonb_build_object(
                'previous', '-infinity'::timestamptz,
                'frontier', '2033-01-01 00:00:00+00'::timestamptz,
                'affected_rules', 0, 'affected_keys', 0),
            jsonb_build_object(
                'previous', '2033-01-01 00:00:00+00'::timestamptz,
                'frontier', '2033-01-01 00:00:00+00'::timestamptz,
                'affected_rules', 0, 'affected_keys', 0)),
        'barriers', 0) THEN
        RAISE EXCEPTION 'M13 concurrent run state changed: %', actual;
    END IF;
END
$$;

SELECT 'M13 concurrent coordinator serialization gate passed';
