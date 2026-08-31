\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m41_reference;
CREATE TABLE m41_reference.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    risk_level text NOT NULL
);
INSERT INTO m41_reference.orders VALUES
    (10, 100, 'HIGH'), (20, 200, 'LOW');
CREATE VIEW m41_reference.high_risk_orders AS
SELECT order_id, customer_id, risk_level
FROM m41_reference.orders
WHERE risk_level = 'HIGH';

CREATE FUNCTION m41_reference.activate(
    context pgreact.activation_context, match m41_reference.high_risk_orders)
RETURNS void LANGUAGE plpgsql AS $m41fn$
BEGIN
    RETURN;
END
$m41fn$;

CREATE TABLE m41_reference.routes (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m41_reference.routes VALUES
    (10, 1000, 1, 'manual'), (10, 1001, 2, 'automatic');

CREATE TABLE m41_reference.customers (customer_id bigint PRIMARY KEY);
INSERT INTO m41_reference.customers VALUES (100);
CREATE TYPE m41_reference.fact_row AS (order_id bigint);
SELECT pgreact.create_derived_relation(
    'm41_reference.risk_fact', 'm41_reference.fact_row'::regtype, ARRAY['order_id']);

DO $m41$
DECLARE
    rule_declaration pgreact_api.declaration;
    decision_declaration pgreact_api.declaration;
    policy_declaration pgreact_api.declaration;
    preview jsonb;
    result jsonb;
    legacy jsonb;
    explicit_false jsonb;
    work_id text;
    work_generation bigint;
    work_revision bigint;
    work_event text;
    decision_generation bigint;
    decision_revision bigint;
BEGIN
    rule_declaration := pgreact.rule(
        name => 'm41-review',
        condition => 'm41_reference.high_risk_orders'::regclass,
        semantic_key => 'order_id'::name,
        kind => 'COMMAND',
        on_activate => 'm41_reference.activate(pgreact.activation_context,m41_reference.high_risk_orders)'::regprocedure);
    preview := pgreact.preview(rule_declaration);
    IF (pgreact.deploy(rule_declaration, jsonb_build_object(
            'preview_digest', preview -> 'summary' ->> 'preview_digest')) ->> 'state')
       <> 'deployed' THEN
        RAISE EXCEPTION 'M41 rule fixture deployment failed';
    END IF;

    decision_declaration := pgreact.decision(
        'm41-routing', 'm41_reference.routes'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-01-01 00:00:00+00');
    preview := pgreact.preview(decision_declaration);
    IF (pgreact.deploy(decision_declaration, jsonb_build_object(
            'preview_digest', preview -> 'summary' ->> 'preview_digest')) ->> 'state')
       <> 'deployed' THEN
        RAISE EXCEPTION 'M41 decision fixture deployment failed';
    END IF;
    UPDATE m41_reference.orders SET risk_level = 'LOW' WHERE order_id = 10;
    PERFORM pgreact.run(clock_timestamp() + interval '1 minute');
    UPDATE m41_reference.orders SET risk_level = 'HIGH' WHERE order_id = 10;
    PERFORM pgreact.run(clock_timestamp() + interval '2 minutes');

    legacy := pgreact.explain('m41-routing', '10'::jsonb);
    explicit_false := pgreact.explain(
        'm41-routing', '10'::jsonb, '{"causal_path":false}'::jsonb);
    IF legacy IS DISTINCT FROM explicit_false THEN
        RAISE EXCEPTION 'M41 false causal_path changed the legacy result';
    END IF;

    result := pgreact.explain(
        'm41-routing', '10'::jsonb,
        '{"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'::jsonb);
    IF result ->> 'contract_version' <> '27'
       OR result ->> 'state' <> 'complete'
       OR result -> 'root' ->> 'kind' <> 'decision_result'
       OR result -> 'root' ->> 'result_key' <> '1000'
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'nodes') node
                      WHERE node.value ->> 'kind' = 'decision_selection')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'nodes') node
                      WHERE node.value ->> 'kind' = 'authoritative_fact')
       OR jsonb_array_length(result -> 'paths') < 1
       OR result -> 'completeness' ->> 'paths_exact' <> 'true'
       OR result ->> 'read_only' <> 'true'
       OR result::text LIKE '%activation_id%' THEN
        RAISE EXCEPTION 'M41 decision result mismatch: %', result;
    END IF;

    result := pgreact.explain(
        'm41-routing', '10'::jsonb,
        '{"causal_path":{"root_kind":"decision_result","result_key":"9999"}}'::jsonb);
    IF result ->> 'state' <> 'unavailable'
       OR result -> 'root' IS DISTINCT FROM 'null'::jsonb
       OR jsonb_array_length(result -> 'nodes') <> 0
       OR result -> 'findings' -> 0 ->> 'code' <> 'M41_ROOT_NOT_FOUND' THEN
        RAISE EXCEPTION 'M41 missing root mismatch: %', result;
    END IF;

    SELECT episode_id::text, activation_generation, activation_revision, event_kind
    INTO work_id, work_generation, work_revision, work_event
    FROM pgreact.episodes episode
    JOIN pgreact.rules rule ON rule.rule_version_id = episode.rule_version_id
    WHERE rule.rule_name = 'm41-review'
    ORDER BY episode_id DESC LIMIT 1;
    IF work_id IS NULL THEN
        RAISE EXCEPTION 'M41 rule work fixture did not create an episode';
    END IF;
    result := pgreact.explain(
        'm41-review', '10'::jsonb,
        jsonb_build_object('causal_path', jsonb_build_object(
            'root_kind', 'rule_work', 'work_id', work_id,
            'generation', work_generation, 'revision', work_revision,
            'event_kind', work_event)));
    IF result ->> 'contract_version' <> '27'
       OR result -> 'root' ->> 'kind' <> 'rule_work'
       OR result -> 'root' ->> 'work_id' <> work_id
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'nodes') node
                      WHERE node.value ->> 'kind' = 'lifecycle_event')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'nodes') node
                      WHERE node.value ->> 'kind' = 'rule_match') THEN
        RAISE EXCEPTION 'M41 rule work mismatch: %', result;
    END IF;

    SELECT generation, revision
    INTO decision_generation, decision_revision
    FROM pgreact.decision_winners
    WHERE program_name = 'm41-routing' AND subject_key = 10;
    result := pgreact.explain(
        'm41-routing', '10'::jsonb,
        jsonb_build_object('causal_path', jsonb_build_object(
            'root_kind', 'decision_work', 'work_id', '10',
            'generation', decision_generation, 'revision', decision_revision)));
    IF result ->> 'contract_version' <> '27'
       OR result -> 'root' ->> 'kind' <> 'decision_work'
       OR result ->> 'read_only' <> 'true' THEN
        RAISE EXCEPTION 'M41 decision work mismatch: %', result;
    END IF;

    result := pgreact.explain(
        'm41-routing', '10'::jsonb,
        '{"causal_path":{"root_kind":"not_supported","result_key":"1000"}}'::jsonb);
    IF result ->> 'state' <> 'unsupported'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M41_UNSUPPORTED_ROOT' THEN
        RAISE EXCEPTION 'M41 unsupported root mismatch: %', result;
    END IF;
END
$m41$;
