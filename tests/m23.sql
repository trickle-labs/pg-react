\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m23_reference;
CREATE TABLE m23_reference.fact (
    id bigint PRIMARY KEY,
    duration_on boolean NOT NULL DEFAULT false,
    absence_satisfied boolean NOT NULL DEFAULT true,
    deadline timestamptz,
    cooldown_on boolean NOT NULL DEFAULT false,
    enter_on boolean NOT NULL DEFAULT false,
    recovered boolean NOT NULL DEFAULT false
);
CREATE VIEW m23_reference.duration_condition AS
SELECT id FROM m23_reference.fact WHERE duration_on;
CREATE VIEW m23_reference.absence_condition AS
SELECT id, deadline FROM m23_reference.fact WHERE absence_satisfied;
CREATE VIEW m23_reference.cooldown_condition AS
SELECT id FROM m23_reference.fact WHERE cooldown_on;
CREATE VIEW m23_reference.enter_condition AS
SELECT id FROM m23_reference.fact WHERE enter_on;
CREATE VIEW m23_reference.recovery_condition AS
SELECT id FROM m23_reference.fact WHERE recovered;

SELECT pgreact_api.run('2026-01-01 00:00:00+00'::timestamptz);
SELECT frontier AS base_time FROM pgreact_internal.clock_frontier \gset
INSERT INTO m23_reference.fact (id, duration_on, deadline, cooldown_on, enter_on)
SELECT 1, true, frontier + interval '5 minutes', true, true
FROM pgreact_internal.clock_frontier;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('code', code, 'severity', severity,
                                        'primitive', details -> 'primitive') ORDER BY code)
      INTO actual
    FROM pgreact_api.validate_temporal_rule(
        'm23_reference.duration_condition'::regclass, 'id', 'DURATION', interval '10 minutes');
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'code', 'OK', 'severity', 'INFO', 'primitive', '"DURATION"'::jsonb)) THEN
        RAISE EXCEPTION 'M23 duration validation changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.author_temporal_rule(
    'm23-duration', 'm23_reference.duration_condition'::regclass, 'id',
    'DURATION', interval '10 minutes') AS duration_version \gset
SELECT pgreact_api.author_temporal_rule(
    'm23-absence', 'm23_reference.absence_condition'::regclass, 'id',
    'ABSENCE', NULL, 'deadline') AS absence_version \gset
SELECT pgreact_api.author_temporal_rule(
    'm23-cooldown', 'm23_reference.cooldown_condition'::regclass, 'id',
    'COOLDOWN', NULL, NULL, interval '30 minutes') AS cooldown_version \gset
SELECT pgreact_api.author_temporal_rule(
    'm23-hysteresis', 'm23_reference.enter_condition'::regclass, 'id',
    'HYSTERESIS', NULL, NULL, NULL,
    'm23_reference.recovery_condition'::regclass, 'id') AS hysteresis_version \gset
SELECT set_config('m23.duration_version', :'duration_version', false);
SELECT set_config('m23.absence_version', :'absence_version', false);
SELECT set_config('m23.cooldown_version', :'cooldown_version', false);
SELECT set_config('m23.hysteresis_version', :'hysteresis_version', false);
SELECT set_config('m23.base_time', :'base_time', false);

SELECT pgreact_api.run(:'base_time'::timestamptz);
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_object_agg(rule, state) INTO actual
    FROM (
        SELECT rule.rule_name AS rule, state.state
        FROM pgreact_internal.temporal_state state
        JOIN pgreact_internal.rules rule ON rule.rule_id = (
            SELECT version.rule_id FROM pgreact_internal.rule_versions version
            WHERE version.rule_version_id = state.rule_version_id)
        WHERE state.semantic_key = 1 ORDER BY rule.rule_name
    ) states;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'm23-absence', 'WAITING', 'm23-cooldown', 'ACTIVE',
        'm23-duration', 'PENDING', 'm23-hysteresis', 'ACTIVE') THEN
        RAISE EXCEPTION 'M23 initial frontier changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.run(:'base_time'::timestamptz + interval '5 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'duration', (SELECT state FROM pgreact_internal.temporal_state state
                     WHERE state.rule_version_id = current_setting('m23.duration_version')::uuid AND semantic_key = 1),
        'absence', (SELECT state FROM pgreact_internal.temporal_state state
                    WHERE state.rule_version_id = current_setting('m23.absence_version')::uuid AND semantic_key = 1))
      INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'frontier', current_setting('m23.base_time')::timestamptz + interval '5 minutes',
        'duration', 'PENDING', 'absence', 'WAITING') THEN
        RAISE EXCEPTION 'M23 equality frontier changed: %', actual;
    END IF;
END
$$;

UPDATE m23_reference.fact SET absence_satisfied = false, duration_on = false,
    cooldown_on = false WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '10 minutes');
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'duration', (SELECT state FROM pgreact_internal.temporal_state
                     WHERE rule_version_id = current_setting('m23.duration_version')::uuid AND semantic_key = 1),
        'absence', (SELECT state FROM pgreact_internal.temporal_state
                    WHERE rule_version_id = current_setting('m23.absence_version')::uuid AND semantic_key = 1),
        'cooldown', (SELECT state FROM pgreact_internal.temporal_state
                     WHERE rule_version_id = current_setting('m23.cooldown_version')::uuid AND semantic_key = 1))
      INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'duration', 'WAITING', 'absence', 'ACTIVE', 'cooldown', 'COOLDOWN') THEN
        RAISE EXCEPTION 'M23 duration/absence/cooldown crossing changed: %', actual;
    END IF;
END
$$;

UPDATE m23_reference.fact SET duration_on = true, cooldown_on = true WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '20 minutes');
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '40 minutes');
DO $$
BEGIN
    IF (SELECT state FROM pgreact_internal.temporal_state
        WHERE rule_version_id = current_setting('m23.duration_version')::uuid AND semantic_key = 1) <> 'ACTIVE'
       OR (SELECT state FROM pgreact_internal.temporal_state
        WHERE rule_version_id = current_setting('m23.cooldown_version')::uuid AND semantic_key = 1) <> 'ACTIVE' THEN
        RAISE EXCEPTION 'M23 duration/cooldown re-entry changed';
    END IF;
END
$$;

UPDATE m23_reference.fact SET enter_on = false WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '41 minutes');
DO $$
DECLARE is_active boolean;
BEGIN
    SELECT active INTO is_active FROM pgreact_internal.temporal_state
    WHERE rule_version_id = current_setting('m23.hysteresis_version')::uuid AND semantic_key = 1;
    IF is_active IS NOT TRUE THEN RAISE EXCEPTION 'M23 hysteresis intermediate band changed'; END IF;
END
$$;
UPDATE m23_reference.fact SET recovered = true WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '42 minutes');
UPDATE m23_reference.fact SET enter_on = true, recovered = false WHERE id = 1;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '43 minutes');

DO $$
DECLARE status jsonb; explanation jsonb; history jsonb; doctor jsonb;
BEGIN
    status := pgreact_api.temporal_status();
    explanation := pgreact_api.temporal_explain('m23-duration', 1);
    history := pgreact_api.temporal_history('m23-duration');
    doctor := pgreact_api.temporal_doctor();
    IF status ->> 'contract_version' <> '11'
       OR explanation ->> 'boundary' IS NULL
       OR jsonb_array_length(history) < 3
       OR doctor ->> 'status' <> 'ready' THEN
        RAISE EXCEPTION 'M23 public evidence changed: % / % / % / %',
            status, explanation, history, doctor;
    END IF;
END
$$;

SELECT 'M23 temporal declaration, duration, absence, cooldown, hysteresis, evidence, and recovery gate passed';
