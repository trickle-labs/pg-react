\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m31_performance_reference;
CREATE TABLE m31_performance_reference.facts(
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL);
CREATE VIEW m31_performance_reference.facts_match AS
SELECT order_id, customer_id FROM m31_performance_reference.facts;
CREATE TABLE m31_performance_reference.customer_gate(
    customer_id bigint PRIMARY KEY);
INSERT INTO m31_performance_reference.facts
SELECT value, value FROM generate_series(1, 1000) value;
INSERT INTO m31_performance_reference.customer_gate
SELECT value FROM generate_series(1, 1000) value;

DO $m31_performance$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    preview jsonb;
    deployed jsonb;
    started timestamptz;
    finished timestamptz;
    duration_ms bigint;
    runtime jsonb;
    support_count bigint;
BEGIN
    member := pgreact_api.declaration('rule', 'm31-performance-rule', jsonb_build_object(
        'condition', 'm31_performance_reference.facts_match',
        'semantic_key', 'order_id', 'kind', 'CONSTRAINT', 'delegate', true));
    preview := pgreact_api.preview(member);
    deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 performance rule deployment changed: %', deployed;
    END IF;
    policy_set := pgreact_api.declaration('policy_set', 'm31-performance-set',
        jsonb_build_object(
            'version', '1',
            'members', jsonb_build_array(jsonb_build_object(
                'kind', 'rule', 'name', 'm31-performance-rule', 'version', '1',
                'match_keys', jsonb_build_array('order_id'),
                'subject_keys', jsonb_build_array('customer_id'),
                'scope_mode', 'POLICY_SET_REQUIRED')),
            'applicability', jsonb_build_object(
                'source_kind', 'relation',
                'relation', 'm31_performance_reference.customer_gate',
                'subject_keys', jsonb_build_array('customer_id')),
            'valid_from', '2026-01-01 00:00:00+00'));
    preview := pgreact_api.preview(policy_set);
    deployed := pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 performance policy-set deployment changed: %', deployed;
    END IF;
    started := clock_timestamp();
    runtime := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-performance-set', '1'),
        '2026-01-01 00:00:00+00');
    finished := clock_timestamp();
    duration_ms := round(extract(epoch FROM (finished - started)) * 1000);
    SELECT count(*) INTO support_count
    FROM pgreact.policy_set_scope_supports
    WHERE set_name = 'm31-performance-set';
    IF runtime -> 'runtime' ->> 'runtime_state' <> 'AUTHORITATIVE'
       OR support_count <> 1000
       OR duration_ms > 10000 THEN
        RAISE EXCEPTION 'M31 bounded workload exceeded contract: runtime %, supports %, duration_ms %',
            runtime, support_count, duration_ms;
    END IF;
    RAISE NOTICE 'M31 bounded workload exact result: supports=% duration_ms=%',
        support_count, duration_ms;
END
$m31_performance$;

SELECT 'M31 bounded performance workload passed' AS result;
