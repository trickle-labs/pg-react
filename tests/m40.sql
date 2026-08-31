\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m40_reference;
CREATE TABLE m40_reference.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    risk_level text NOT NULL
);
INSERT INTO m40_reference.orders VALUES
    (10, 100, 'HIGH'), (20, 200, 'LOW');
CREATE VIEW m40_reference.high_risk_orders AS
SELECT order_id, customer_id, risk_level
FROM m40_reference.orders
WHERE risk_level = 'HIGH';

CREATE TABLE m40_reference.routes (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m40_reference.routes VALUES
    (10, 1000, 1, 'manual'), (10, 1001, 2, 'automatic');

CREATE TABLE m40_reference.customers (
    customer_id bigint PRIMARY KEY
);
INSERT INTO m40_reference.customers VALUES (100);
CREATE TYPE m40_reference.fact_row AS (order_id bigint);
SELECT pgreact.create_derived_relation(
    'm40_reference.risk_fact', 'm40_reference.fact_row'::regtype, ARRAY['order_id']);

DO $m40$
DECLARE
    rule_declaration pgreact_api.declaration;
    decision_declaration pgreact_api.declaration;
    policy_declaration pgreact_api.declaration;
    preview jsonb;
    result jsonb;
    legacy jsonb;
    explicit_false jsonb;
    before_checksum text;
    after_checksum text;
BEGIN
    rule_declaration := pgreact.rule(
        'm40-review', 'm40_reference.high_risk_orders'::regclass, 'order_id'::name);
    preview := pgreact.preview(rule_declaration);
    IF (pgreact.deploy(rule_declaration, jsonb_build_object(
            'preview_digest', preview -> 'summary' ->> 'preview_digest')) ->> 'state')
       <> 'deployed' THEN
        RAISE EXCEPTION 'M40 rule fixture deployment failed';
    END IF;
    PERFORM pgreact.run('2026-08-31 09:00:00+00');

    legacy := pgreact.explain('m40-review', '20'::jsonb);
    explicit_false := pgreact.explain(
        'm40-review', '20'::jsonb, '{"why_not":false}'::jsonb);
    IF legacy IS DISTINCT FROM explicit_false THEN
        RAISE EXCEPTION 'M40 false why_not changed the legacy result';
    END IF;

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    result := pgreact.explain(
        'm40-review', '20'::jsonb,
        '{"why_not":{"result_kind":"rule_match","result_key":"20"}}'::jsonb);
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF result ->> 'contract_version' <> '26'
       OR result ->> 'state' <> 'complete'
       OR result -> 'request' -> 'expected_result' IS DISTINCT FROM
          jsonb_build_object('kind', 'rule_match', 'key', '20')
       OR jsonb_array_length(result -> 'causes') <> 1
       OR result -> 'causes' -> 0 ->> 'kind' <> 'missing_input'
       OR result -> 'causes' -> 0 ->> 'path' <> 'source.order_id'
       OR result -> 'completeness' ->> 'causes_exact' <> 'true'
       OR result -> 'cost' ->> 'candidate_discovery' <> '1'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M40_NO_EFFECT'
       OR result::text LIKE '%activation_id%'
       OR before_checksum IS DISTINCT FROM after_checksum THEN
        RAISE EXCEPTION 'M40 missing rule result mismatch: %', result;
    END IF;

    result := pgreact.explain(
        'm40-review', '10'::jsonb,
        '{"why_not":{"result_kind":"rule_match","result_key":"10"}}'::jsonb);
    IF result ->> 'state' <> 'already_present'
       OR jsonb_array_length(result -> 'causes') <> 0
       OR result -> 'observed' ->> 'state' <> 'MATCH' THEN
        RAISE EXCEPTION 'M40 present rule result mismatch: %', result;
    END IF;

    result := pgreact.explain(
        'm40_reference.risk_fact', '20'::jsonb,
        '{"why_not":{"result_kind":"derived_fact","result_key":"20"}}'::jsonb);
    IF result ->> 'state' <> 'complete'
       OR result -> 'causes' -> 0 ->> 'kind' <> 'derived_fact'
       OR result -> 'causes' -> 0 ->> 'path' <> 'derived.m40_reference.risk_fact.fact'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M40_DERIVED_FACT_MISSING' THEN
        RAISE EXCEPTION 'M40 derived fact result mismatch: %', result;
    END IF;

    decision_declaration := pgreact.decision(
        'm40-routing', 'm40_reference.routes'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-01-01 00:00:00+00');
    preview := pgreact.preview(decision_declaration);
    IF (pgreact.deploy(decision_declaration, jsonb_build_object(
            'preview_digest', preview -> 'summary' ->> 'preview_digest')) ->> 'state')
       <> 'deployed' THEN
        RAISE EXCEPTION 'M40 decision fixture deployment failed';
    END IF;
    PERFORM pgreact.run('2026-08-31 09:00:00+00');
    result := pgreact.explain(
        'm40-routing', '10'::jsonb,
        '{"why_not":{"result_kind":"decision_result","result_key":"1001"}}'::jsonb);
    IF result ->> 'state' <> 'complete'
       OR result -> 'causes' -> 0 ->> 'kind' <> 'decision_selection'
       OR result -> 'causes' -> 0 ->> 'path' <> 'decision.winner' THEN
        RAISE EXCEPTION 'M40 decision selection mismatch: %', result;
    END IF;

    policy_declaration := pgreact.policy_set(
        'm40-customers', '1', ARRAY[rule_declaration],
        'm40_reference.customers'::regclass, ARRAY['customer_id']::name[],
        '2026-01-01 00:00:00+00');
    preview := pgreact.preview(policy_declaration);
    IF (pgreact.deploy(policy_declaration, jsonb_build_object(
            'preview_digest', preview -> 'summary' ->> 'preview_digest')) ->> 'state')
       <> 'deployed' THEN
        RAISE EXCEPTION 'M40 policy fixture deployment failed';
    END IF;
    PERFORM pgreact.run('2026-08-31 09:00:00+00');
    result := pgreact.explain(
        'm40-customers', '{"customer_id":200}'::jsonb,
        '{"why_not":{"result_kind":"policy_eligibility","result_key":"{\"customer_id\": 200}"}}'::jsonb);
    IF result ->> 'state' <> 'complete'
       OR result -> 'causes' -> 0 ->> 'kind' <> 'applicability'
       OR result -> 'causes' -> 0 ->> 'path' <> 'policy_set.eligibility' THEN
        RAISE EXCEPTION 'M40 policy applicability mismatch: %', result;
    END IF;

    result := pgreact.explain(
        'm40-review', '20'::jsonb, '{"why_not":true}'::jsonb);
    IF result ->> 'state' <> 'unsupported'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M40_OPTIONS_INVALID' THEN
        RAISE EXCEPTION 'M40 invalid options mismatch: %', result;
    END IF;
    result := pgreact.explain(
        'm40-review', '20'::jsonb,
        '{"why_not":{"result_kind":"unknown","result_key":"20"}}'::jsonb);
    IF result ->> 'state' <> 'unsupported'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M40_UNSUPPORTED_RESULT' THEN
        RAISE EXCEPTION 'M40 unsupported result mismatch: %', result;
    END IF;
    result := pgreact.explain(
        'm40-review', '20'::jsonb,
        '{"why_not":{"result_kind":"rule_match","result_key":"21"}}'::jsonb);
    IF result ->> 'state' <> 'unsupported'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M40_EXPECTED_RESULT_INVALID' THEN
        RAISE EXCEPTION 'M40 mismatched result identity mismatch: %', result;
    END IF;
    result := pgreact.explain(
        'm40-review', '20'::jsonb,
        '{"why_not":{"result_kind":"rule_match","result_key":"20","cause_limit":999999}}'::jsonb);
    IF result ->> 'state' <> 'unsupported'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M40_OPTIONS_INVALID' THEN
        RAISE EXCEPTION 'M40 oversized cause limit mismatch: %', result;
    END IF;
END
$m40$;
