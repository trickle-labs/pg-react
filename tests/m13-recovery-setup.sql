\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;

CREATE ROLE m13_recovery_author NOLOGIN;
CREATE ROLE m13_recovery_operator NOLOGIN;
CREATE ROLE m13_recovery_worker NOLOGIN;
CREATE ROLE m13_recovery_reader NOLOGIN;
SELECT pgreact_api.configure_roles(
    'm13_recovery_author', 'm13_recovery_operator',
    'm13_recovery_worker', 'm13_recovery_reader');

CREATE SCHEMA m13_recovery;
CREATE TABLE m13_recovery.source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW m13_recovery.condition AS
SELECT id, deadline FROM m13_recovery.source;
CREATE TABLE m13_recovery.effects (
    effect_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload jsonb NOT NULL
);
CREATE FUNCTION m13_recovery.activate(candidate m13_recovery.condition)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_recovery.effects(payload) VALUES (to_jsonb(candidate)) $$;
INSERT INTO m13_recovery.source VALUES
    (1, '2035-01-01 00:00:00+00'),
    (2, '2035-01-02 00:00:00+00');
SELECT pgreact_api.author_deadline_rule(
    rule_name => 'recovery-rule',
    condition => 'm13_recovery.condition'::regclass,
    semantic_key => 'id',
    deadline_column => 'deadline',
    action_schema => 'm13_recovery',
    on_activate => 'activate') AS version_id \gset

SET SESSION AUTHORIZATION m13_recovery_operator;
SELECT pgreact_api.run('2035-01-01 00:00:00+00');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m13_recovery_worker;
DO $$
DECLARE claimed record;
BEGIN
    SELECT * INTO STRICT claimed FROM pgreact_api.claim('recovery-worker', 1);
    IF pgreact_api.execute(
        claimed.episode_id, 'recovery-worker', claimed.lease_token)
       IS DISTINCT FROM 'COMPLETED' THEN
        RAISE EXCEPTION 'M13 recovery first action did not complete';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

CREATE TABLE m13_recovery.control (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    rule_version_id uuid NOT NULL,
    before_state jsonb NOT NULL,
    after_state jsonb NOT NULL
);
INSERT INTO m13_recovery.control (
    rule_version_id, before_state, after_state
) VALUES (
    :'version_id'::uuid,
    jsonb_build_object(
        'frontier', '2035-01-01 00:00:00+00'::timestamptz,
        'matches', jsonb_build_array(jsonb_build_object(
            'key', 1, 'active', true, 'generation', 1, 'revision', 0)),
        'jobs', jsonb_build_array(jsonb_build_object(
            'key', 1, 'event', 'ACTIVATE', 'state', 'COMPLETED',
            'generation', 1)),
        'attempts', jsonb_build_array(jsonb_build_object(
            'key', 1, 'attempt', 1, 'status', 'COMPLETED')),
        'effects', jsonb_build_array(jsonb_build_object(
            'id', 1, 'deadline', '2035-01-01T00:00:00+00:00'))),
    jsonb_build_object(
        'frontier', '2035-01-02 00:00:00+00'::timestamptz,
        'matches', jsonb_build_array(
            jsonb_build_object(
                'key', 1, 'active', true, 'generation', 1, 'revision', 0),
            jsonb_build_object(
                'key', 2, 'active', true, 'generation', 1, 'revision', 0)),
        'jobs', jsonb_build_array(
            jsonb_build_object(
                'key', 1, 'event', 'ACTIVATE', 'state', 'COMPLETED',
                'generation', 1),
            jsonb_build_object(
                'key', 2, 'event', 'ACTIVATE', 'state', 'COMPLETED',
                'generation', 1)),
        'attempts', jsonb_build_array(
            jsonb_build_object('key', 1, 'attempt', 1, 'status', 'COMPLETED'),
            jsonb_build_object('key', 2, 'attempt', 1, 'status', 'COMPLETED')),
        'effects', jsonb_build_array(
            jsonb_build_object(
                'id', 1, 'deadline', '2035-01-01T00:00:00+00:00'),
            jsonb_build_object(
                'id', 2, 'deadline', '2035-01-02T00:00:00+00:00')))
);

CHECKPOINT;
