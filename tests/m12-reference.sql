\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m12_reference;
CREATE TABLE m12_reference.tasks (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    payload text NOT NULL
);
CREATE VIEW m12_reference.deadline_candidate AS
SELECT id, deadline, payload
FROM m12_reference.tasks
WHERE enabled;
CREATE FUNCTION m12_reference.activate(
    context pgreact.activation_context,
    candidate m12_reference.deadline_candidate
)
RETURNS void
LANGUAGE SQL
AS $$ SELECT $$;

INSERT INTO m12_reference.tasks (id, deadline, payload) VALUES
    (1, '2026-01-02 00:00:00+00', 'future'),
    (2, '2026-01-01 00:00:00+00', 'equal'),
    (3, '2025-12-31 00:00:00+00', 'overdue'),
    (4, '2026-01-03 00:00:00+00', 'advance');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'contract_version', contract_version,
        'code', code,
        'severity', severity,
        'details', details) ORDER BY code)
    INTO actual
    FROM pgreact_api.validate_deadline_rule(
        'm12_reference.deadline_candidate'::regclass,
        'id', 'deadline',
        'm12_reference.activate(pgreact.activation_context,m12_reference.deadline_candidate)');
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 2,
        'code', 'OK',
        'severity', 'INFO',
        'details', jsonb_build_object(
            'semantic_key', 'id',
            'deadline_column', 'deadline',
            'predicate', 'clock_frontier >= deadline',
            'refresh_mode', 'DIFFERENTIAL'))) THEN
        RAISE EXCEPTION 'M12 validation changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.author_deadline_rule(
    rule_name => 'reference-deadline',
    condition => 'm12_reference.deadline_candidate'::regclass,
    semantic_key => 'id',
    deadline_column => 'deadline',
    kind => 'COMMAND',
    on_activate => 'm12_reference.activate(pgreact.activation_context,m12_reference.deadline_candidate)'
) AS reference_version \gset
SELECT set_config('m12.reference_version', :'reference_version', false);

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'active', COALESCE(jsonb_agg(semantic_key ORDER BY semantic_key)
                           FILTER (WHERE active), '[]'::jsonb))
    INTO actual
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = current_setting('m12.reference_version')::uuid;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'frontier', '-infinity'::timestamptz,
        'active', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M12 activated before the first frontier: %', actual;
    END IF;
END
$$;

SELECT pgreact.begin_deadline_refresh(12001);
SELECT pgreact.advance_deadline_clock('2026-01-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'semantic_key', semantic_key,
        'active', active,
        'generation', generation) ORDER BY semantic_key)
    INTO actual
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = current_setting('m12.reference_version')::uuid;
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('semantic_key', 2, 'active', true, 'generation', 1),
        jsonb_build_object('semantic_key', 3, 'active', true, 'generation', 1)) THEN
        RAISE EXCEPTION 'M12 equality/overdue frontier result changed: %', actual;
    END IF;
END
$$;

SELECT pgreact.begin_deadline_refresh(12002);
SELECT pgreact.advance_deadline_clock('2026-01-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();
SELECT pgreact.begin_deadline_refresh(12003);
SELECT pgreact.advance_deadline_clock('2025-12-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'events', COALESCE(jsonb_agg(jsonb_build_object(
            'semantic_key', activation.semantic_key,
            'event_kind', event.event_kind,
            'generation', event.generation)
            ORDER BY event.event_id), '[]'::jsonb))
    INTO actual
    FROM pgreact_internal.lifecycle_events event
    JOIN pgreact_internal.activation_state activation
      USING (rule_version_id, activation_id)
    WHERE event.rule_version_id = current_setting('m12.reference_version')::uuid;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'frontier', '2026-01-01 00:00:00+00'::timestamptz,
        'events', jsonb_build_array(
            jsonb_build_object('semantic_key', 3, 'event_kind', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('semantic_key', 2, 'event_kind', 'ACTIVATE', 'generation', 1))) THEN
        RAISE EXCEPTION 'M12 retry/backward adjustment duplicated or retracted work: %', actual;
    END IF;
END
$$;

SELECT pgreact.begin_deadline_refresh(12004);
SELECT pgreact.advance_deadline_clock('2026-01-02 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

UPDATE m12_reference.tasks
SET deadline = '2026-01-01 00:00:00+00'
WHERE id = 4;
SELECT pgreact_api.run_rule('reference-deadline');

UPDATE m12_reference.tasks
SET deadline = '2026-01-04 00:00:00+00'
WHERE id = 1;
SELECT pgreact_api.run_rule('reference-deadline');

SELECT pgreact.begin_deadline_refresh(12005);
SELECT pgreact.advance_deadline_clock('2026-01-03 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();
SELECT pgreact.begin_deadline_refresh(12006);
SELECT pgreact.advance_deadline_clock('2026-01-04 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

DELETE FROM m12_reference.tasks WHERE id = 2;
SELECT pgreact_api.run_rule('reference-deadline');

SELECT pgreact_api.pause_rule('reference-deadline');
INSERT INTO m12_reference.tasks (id, deadline, payload)
VALUES (5, '2026-01-01 00:00:00+00', 'during-pause');
DO $$
BEGIN
    PERFORM pgreact_api.run_rule('reference-deadline');
    RAISE EXCEPTION 'paused M12 rule unexpectedly refreshed';
EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'M12_RULE_NOT_ACTIVE: reference-deadline' THEN RAISE; END IF;
END
$$;
SELECT pgreact.begin_deadline_refresh(12007);
SELECT pgreact.advance_deadline_clock('2026-01-05 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();
SELECT pgreact_api.resume_rule('reference-deadline');

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'activations', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'semantic_key', semantic_key,
            'active', active,
            'generation', generation,
            'revision', revision) ORDER BY semantic_key)
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = current_setting('m12.reference_version')::uuid), '[]'::jsonb),
        'history', pgreact_internal.deadline_history('reference-deadline'),
        'clock', (SELECT jsonb_agg(jsonb_build_object(
            'sampled_time', sampled_time,
            'previous_frontier', previous_frontier,
            'frontier', frontier,
            'affected_rules', affected_rules,
            'affected_keys', affected_keys) ORDER BY clock_event_id)
            FROM pgreact_internal.clock_history))
    INTO actual;
    expected := jsonb_build_object(
        'activations', jsonb_build_array(
            jsonb_build_object('semantic_key', 1, 'active', true, 'generation', 2, 'revision', 0),
            jsonb_build_object('semantic_key', 2, 'active', false, 'generation', 1, 'revision', 0),
            jsonb_build_object('semantic_key', 3, 'active', true, 'generation', 1, 'revision', 0),
            jsonb_build_object('semantic_key', 4, 'active', true, 'generation', 1, 'revision', 0),
            jsonb_build_object('semantic_key', 5, 'active', true, 'generation', 1, 'revision', 0)),
        'history', jsonb_build_array(
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 3,
                'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2025-12-31 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-01 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 2,
                'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2026-01-01 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-01 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 1,
                'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2026-01-02 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-02 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 4,
                'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2026-01-01 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-02 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 1,
                'generation', 1, 'revision', 0, 'event_kind', 'DEACTIVATE',
                'declared_deadline', '2026-01-04 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-02 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 1,
                'generation', 2, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2026-01-04 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-04 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 2,
                'generation', 1, 'revision', 0, 'event_kind', 'DEACTIVATE',
                'declared_deadline', '2026-01-01 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-04 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'reference-deadline', 'semantic_key', 5,
                'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2026-01-01 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-01-05 00:00:00+00'::timestamptz)),
        'clock', jsonb_build_array(
            jsonb_build_object('sampled_time', '2026-01-01 00:00:00+00'::timestamptz,
                'previous_frontier', '-infinity'::timestamptz,
                'frontier', '2026-01-01 00:00:00+00'::timestamptz,
                'affected_rules', 1, 'affected_keys', 2),
            jsonb_build_object('sampled_time', '2026-01-01 00:00:00+00'::timestamptz,
                'previous_frontier', '2026-01-01 00:00:00+00'::timestamptz,
                'frontier', '2026-01-01 00:00:00+00'::timestamptz,
                'affected_rules', 0, 'affected_keys', 0),
            jsonb_build_object('sampled_time', '2025-12-01 00:00:00+00'::timestamptz,
                'previous_frontier', '2026-01-01 00:00:00+00'::timestamptz,
                'frontier', '2026-01-01 00:00:00+00'::timestamptz,
                'affected_rules', 0, 'affected_keys', 0),
            jsonb_build_object('sampled_time', '2026-01-02 00:00:00+00'::timestamptz,
                'previous_frontier', '2026-01-01 00:00:00+00'::timestamptz,
                'frontier', '2026-01-02 00:00:00+00'::timestamptz,
                'affected_rules', 1, 'affected_keys', 1),
            jsonb_build_object('sampled_time', '2026-01-03 00:00:00+00'::timestamptz,
                'previous_frontier', '2026-01-02 00:00:00+00'::timestamptz,
                'frontier', '2026-01-03 00:00:00+00'::timestamptz,
                'affected_rules', 0, 'affected_keys', 0),
            jsonb_build_object('sampled_time', '2026-01-04 00:00:00+00'::timestamptz,
                'previous_frontier', '2026-01-03 00:00:00+00'::timestamptz,
                'frontier', '2026-01-04 00:00:00+00'::timestamptz,
                'affected_rules', 1, 'affected_keys', 1),
            jsonb_build_object('sampled_time', '2026-01-05 00:00:00+00'::timestamptz,
                'previous_frontier', '2026-01-04 00:00:00+00'::timestamptz,
                'frontier', '2026-01-05 00:00:00+00'::timestamptz,
                'affected_rules', 0, 'affected_keys', 0)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M12 reference workload changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE status jsonb; explanation jsonb;
BEGIN
    status := pgreact_api.rule_status('reference-deadline');
    explanation := pgreact_api.explain_rule('reference-deadline');
    IF status -> 'contract_version' IS DISTINCT FROM '2'::jsonb
       OR status -> 'deadlines' IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
           'rule_name', 'reference-deadline',
           'state', 'ACTIVE',
           'deadline_column', 'deadline',
           'clock_frontier', '2026-01-05 00:00:00+00'::timestamptz,
           'candidates', jsonb_build_array(
               jsonb_build_object('semantic_key', 3, 'deadline', '2025-12-31 00:00:00+00'::timestamptz, 'due', true, 'active', true),
               jsonb_build_object('semantic_key', 4, 'deadline', '2026-01-01 00:00:00+00'::timestamptz, 'due', true, 'active', true),
               jsonb_build_object('semantic_key', 5, 'deadline', '2026-01-01 00:00:00+00'::timestamptz, 'due', true, 'active', true),
               jsonb_build_object('semantic_key', 1, 'deadline', '2026-01-04 00:00:00+00'::timestamptz, 'due', true, 'active', true))))
       OR explanation -> 'deadline_history'
          IS DISTINCT FROM pgreact_internal.deadline_history('reference-deadline') THEN
        RAISE EXCEPTION 'M12 public status or explanation changed: %, %', status, explanation;
    END IF;
END
$$;

SELECT 'M12 exact reference deadline workload passed';
