\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE SCHEMA s1_boundary;
CREATE TABLE s1_boundary.source (case_key bigint PRIMARY KEY, deadline timestamptz NOT NULL);
INSERT INTO s1_boundary.source VALUES (1, '2026-10-02 00:00:00+00');
CREATE VIEW s1_boundary.candidate AS SELECT case_key, deadline FROM s1_boundary.source;
CREATE FUNCTION s1_boundary.activate(
    context pgreact.activation_context, candidate s1_boundary.candidate
) RETURNS void LANGUAGE SQL AS $$ SELECT $$;
SELECT pgreact_api.author_deadline_rule(
    's1-boundary', 's1_boundary.candidate'::regclass, 'case_key', 'deadline', 'COMMAND',
    's1_boundary.activate(pgreact.activation_context,s1_boundary.candidate)');
SELECT pgreact_api.run('2026-10-01 23:59:59.999999+00'::timestamptz);
DO $before$
BEGIN
    IF pgreact_api.deadline_history('s1-boundary') IS DISTINCT FROM
        jsonb_build_object('contract_version', 2, 'rule_name', 's1-boundary', 'events', '[]'::jsonb) THEN
        RAISE EXCEPTION 'deadline activated one microsecond before equality';
    END IF;
END
$before$;
SELECT pgreact_api.run('2026-10-02 00:00:00+00'::timestamptz);
CREATE TABLE s1_boundary.expected AS
SELECT jsonb_build_object('contract_version', 2, 'rule_name', 's1-boundary',
    'events', jsonb_build_array(jsonb_build_object(
        'rule_name', 's1-boundary', 'semantic_key', 1,
        'generation', 1, 'revision', 0, 'event_kind', 'ACTIVATE',
        'declared_deadline', '2026-10-02 00:00:00+00'::timestamptz,
        'clock_frontier', '2026-10-02 00:00:00+00'::timestamptz))) AS history;
DO $equal$
BEGIN
    IF pgreact_api.deadline_history('s1-boundary') IS DISTINCT FROM
        (SELECT history FROM s1_boundary.expected) THEN
        RAISE EXCEPTION 'equality did not produce the exact expected deadline event: %',
            pgreact_api.deadline_history('s1-boundary');
    END IF;
END
$equal$;
SELECT pgreact_api.run('2026-10-02 00:00:00.000001+00'::timestamptz);
SELECT pgreact_api.run('2026-10-01 17:00:00.000001-07'::timestamptz);
SELECT pgreact_api.run('2026-10-01 23:59:59.999999+00'::timestamptz);
DO $stable$
BEGIN
    IF pgreact_api.deadline_history('s1-boundary') IS DISTINCT FROM
        (SELECT history FROM s1_boundary.expected)
       OR (SELECT jsonb_agg(to_jsonb(s) ORDER BY case_key) FROM s1_boundary.source s)
          IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
            'case_key', 1, 'deadline', '2026-10-02 00:00:00+00'::timestamptz)) THEN
        RAISE EXCEPTION 'after/equivalent/backward samples repeated an event or changed the source';
    END IF;
END
$stable$;
SELECT 'S1 before/equal/after, timezone equivalence and monotone frontier: PASS' AS result;
