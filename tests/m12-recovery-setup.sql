\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;

CREATE SCHEMA m12_recovery;
CREATE TABLE m12_recovery.source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW m12_recovery.candidate AS
SELECT id, deadline FROM m12_recovery.source;
INSERT INTO m12_recovery.source VALUES
    (1, '2026-05-01 00:00:00+00'),
    (2, '2026-05-02 00:00:00+00');
SELECT pgreact_api.author_deadline_rule(
    'recovery-deadline', 'm12_recovery.candidate'::regclass,
    'id', 'deadline', 'CONSTRAINT') AS version_id \gset
SELECT pgreact.begin_deadline_refresh(12401);
SELECT pgreact.advance_deadline_clock('2026-05-01 00:00:00+00');
SELECT pgreact.finish_deadline_refresh();

CREATE TABLE m12_recovery.control (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    rule_version_id uuid NOT NULL,
    before_state jsonb NOT NULL,
    after_state jsonb NOT NULL
);
INSERT INTO m12_recovery.control (rule_version_id, before_state, after_state)
VALUES (
    :'version_id'::uuid,
    jsonb_build_object(
        'frontier', '2026-05-01 00:00:00+00'::timestamptz,
        'activations', jsonb_build_array(jsonb_build_object(
            'semantic_key', 1, 'active', true, 'generation', 1, 'revision', 0)),
        'history', jsonb_build_array(jsonb_build_object(
            'rule_name', 'recovery-deadline', 'semantic_key', 1,
            'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
            'declared_deadline', '2026-05-01 00:00:00+00'::timestamptz,
            'clock_frontier', '2026-05-01 00:00:00+00'::timestamptz)),
        'clock', jsonb_build_array(jsonb_build_object(
            'sampled_time', '2026-05-01 00:00:00+00'::timestamptz,
            'previous_frontier', '-infinity'::timestamptz,
            'frontier', '2026-05-01 00:00:00+00'::timestamptz,
            'affected_rules', 1, 'affected_keys', 1))),
    jsonb_build_object(
        'frontier', '2026-05-02 00:00:00+00'::timestamptz,
        'activations', jsonb_build_array(
            jsonb_build_object('semantic_key', 1, 'active', true, 'generation', 1, 'revision', 0),
            jsonb_build_object('semantic_key', 2, 'active', true, 'generation', 1, 'revision', 0)),
        'history', jsonb_build_array(
            jsonb_build_object('rule_name', 'recovery-deadline', 'semantic_key', 1,
                'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2026-05-01 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-05-01 00:00:00+00'::timestamptz),
            jsonb_build_object('rule_name', 'recovery-deadline', 'semantic_key', 2,
                'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
                'declared_deadline', '2026-05-02 00:00:00+00'::timestamptz,
                'clock_frontier', '2026-05-02 00:00:00+00'::timestamptz)),
        'clock', jsonb_build_array(
            jsonb_build_object(
                'sampled_time', '2026-05-01 00:00:00+00'::timestamptz,
                'previous_frontier', '-infinity'::timestamptz,
                'frontier', '2026-05-01 00:00:00+00'::timestamptz,
                'affected_rules', 1, 'affected_keys', 1),
            jsonb_build_object(
                'sampled_time', '2026-05-02 00:00:00+00'::timestamptz,
                'previous_frontier', '2026-05-01 00:00:00+00'::timestamptz,
                'frontier', '2026-05-02 00:00:00+00'::timestamptz,
                'affected_rules', 1, 'affected_keys', 1)))
);

CHECKPOINT;
