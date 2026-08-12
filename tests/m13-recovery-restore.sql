\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE FUNCTION m13_recovery.normalized_state(target_version uuid)
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_build_object(
    'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
    'matches', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'key', semantic_key, 'active', active,
        'generation', generation, 'revision', revision) ORDER BY semantic_key)
        FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version), '[]'::jsonb),
    'jobs', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'key', state.semantic_key, 'event', job.event_kind,
        'state', job.state, 'generation', job.activation_generation)
        ORDER BY job.episode_id)
        FROM pgreact_internal.agenda job
        JOIN pgreact_internal.activation_state state
          USING (rule_version_id, activation_id)
        WHERE job.rule_version_id = target_version), '[]'::jsonb),
    'attempts', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'key', state.semantic_key, 'attempt', attempt.attempt_no,
        'status', attempt.status)
        ORDER BY attempt.episode_id, attempt.attempt_no)
        FROM pgreact_internal.executions attempt
        JOIN pgreact_internal.agenda job USING (episode_id)
        JOIN pgreact_internal.activation_state state
          USING (rule_version_id, activation_id)
        WHERE job.rule_version_id = target_version), '[]'::jsonb),
    'effects', COALESCE((SELECT jsonb_agg(payload ORDER BY effect_id)
        FROM m13_recovery.effects), '[]'::jsonb))
$$;

DO $$
DECLARE actual jsonb; expected_before jsonb; expected_after jsonb; version_id uuid;
BEGIN
    SELECT rule_version_id, before_state, after_state
      INTO STRICT version_id, expected_before, expected_after
      FROM m13_recovery.control;
    actual := m13_recovery.normalized_state(version_id);
    IF actual IS DISTINCT FROM expected_before
       AND actual IS DISTINCT FROM expected_after THEN
        RAISE EXCEPTION 'M13 recovered state changed: %', actual;
    END IF;
    IF (SELECT extversion FROM pg_catalog.pg_extension
        WHERE extname = 'pg_react') <> '0.10.0'
       OR (SELECT function_digest = sha256(convert_to(
            pg_get_functiondef(function_oid), 'UTF8'))
           FROM pgreact_internal.consequence_bindings
           WHERE rule_version_id = version_id AND event_kind = 'ACTIVATE')
          IS DISTINCT FROM true
       OR NOT has_function_privilege(
            'm13_recovery_operator',
            'pgreact_api.run(timestamptz)', 'EXECUTE')
       OR has_function_privilege(
            'm13_recovery_reader',
            'pgreact_api.execute(bigint,text,uuid)', 'EXECUTE') THEN
        RAISE EXCEPTION 'M13 recovered contract or grant matrix changed';
    END IF;
END
$$;

DO $$
DECLARE claimed record;
BEGIN
    IF (SELECT frontier FROM pgreact_internal.clock_frontier)
       < '2035-01-02 00:00:00+00'::timestamptz THEN
        PERFORM pgreact_api.run('2035-01-02 00:00:00+00');
        SELECT * INTO STRICT claimed
          FROM pgreact_api.claim('recovery-worker', 1);
        IF pgreact_api.execute(
            claimed.episode_id, 'recovery-worker', claimed.lease_token)
           IS DISTINCT FROM 'COMPLETED' THEN
            RAISE EXCEPTION 'M13 recovered action did not complete';
        END IF;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb; expected jsonb; version_id uuid;
BEGIN
    SELECT rule_version_id, after_state
      INTO STRICT version_id, expected FROM m13_recovery.control;
    actual := m13_recovery.normalized_state(version_id);
    IF actual IS DISTINCT FROM expected
       OR pg_catalog.pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M13 recovery catch-up changed: %, %', actual, expected;
    END IF;
END
$$;

DROP FUNCTION m13_recovery.normalized_state(uuid);
SELECT 'M13 crash, restart, physical restore, grants, and context-free action passed';
