\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = warning;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm20_author') THEN CREATE ROLE m20_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm20_operator') THEN CREATE ROLE m20_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm20_worker') THEN CREATE ROLE m20_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm20_reader') THEN CREATE ROLE m20_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm20_advanced') THEN CREATE ROLE m20_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm20_author', 'm20_operator', 'm20_worker', 'm20_reader', 'm20_advanced');

CREATE SCHEMA m20_app AUTHORIZATION m20_author;
SET SESSION AUTHORIZATION m20_author;
CREATE TYPE m20_app.risk_row AS (customer_id bigint, risk_score integer, country text);
CREATE TYPE m20_app.risk_row_v2 AS (customer_id bigint, risk_score integer, country text, reason text);
CREATE TABLE m20_app.customers(customer_id bigint PRIMARY KEY, risk_score integer NOT NULL, country text NOT NULL);
CREATE VIEW m20_app.high_risk_source AS
SELECT customer_id, risk_score, country FROM m20_app.customers WHERE risk_score >= 80;
CREATE VIEW m20_app.high_risk_source_v2 AS
SELECT customer_id, risk_score, country FROM m20_app.customers WHERE risk_score >= 90;
CREATE VIEW m20_app.high_risk_source_bad AS
SELECT customer_id, risk_score, country, 'schema-change'::text AS reason
FROM m20_app.customers WHERE risk_score >= 90;
SELECT pgreact_api.deploy_shared_condition(
    jsonb_build_object(
        'name', 'm20_app.high_risk', 'version', 1,
        'source', 'm20_app.high_risk_source',
        'row_type', 'm20_app.risk_row', 'key', ARRAY['customer_id'],
        'maintenance_mode', 'SCHEDULED'),
    NULL);
SELECT pgreact_api.author_rule(
    rule_name => 'm20.review', condition => 'm20_app.high_risk'::regclass,
    semantic_key => 'customer_id', kind => 'CONSTRAINT');
SELECT pgreact_api.author_rule(
    rule_name => 'm20.audit', condition => 'm20_app.high_risk'::regclass,
    semantic_key => 'customer_id', kind => 'CONSTRAINT');
SELECT pgreact_api.register_shared_condition_consumer('m20_app.high_risk', 'RULE', 'm20.review');
SELECT pgreact_api.register_shared_condition_consumer('m20_app.high_risk', 'RULE', 'm20.audit');
SELECT pgreact_api.grant_shared_condition_reader('m20_app.high_risk', 'm20_reader');
RESET SESSION AUTHORIZATION;

INSERT INTO m20_app.customers VALUES (1, 95, 'NO'), (2, 50, 'SE');
SET SESSION AUTHORIZATION m20_operator;
SELECT pgreact_api.run('2030-01-01T00:00:00Z');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.shared_condition_matches('m20_app.high_risk');
    IF actual -> 'matches' IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('customer_id', 1, 'risk_score', 95, 'country', 'NO')) THEN
        RAISE EXCEPTION 'M20 shared relation changed: %', actual;
    END IF;
    IF (pgreact_api.shared_condition_status('m20_app.high_risk') #>> '{conditions,0,version}') <> '1'
       OR jsonb_array_length(pgreact_api.shared_condition_status('m20_app.high_risk') #> '{conditions,0,consumers}') <> 2
       OR (pgreact_api.shared_condition_cost('m20_app.high_risk') ->> 'admission') <> 'accepted' THEN
        RAISE EXCEPTION 'M20 status/cost changed: % / %',
            pgreact_api.shared_condition_status('m20_app.high_risk'),
            pgreact_api.shared_condition_cost('m20_app.high_risk');
    END IF;
    IF (pgreact_api.shared_condition_explain('m20_app.high_risk', '1'::jsonb)
        -> 'shared_condition' ->> 'boundary') <> 'named shared condition' THEN
        RAISE EXCEPTION 'M20 explanation boundary changed: %',
            pgreact_api.shared_condition_explain('m20_app.high_risk', '1'::jsonb);
    END IF;
END
$$;

SET SESSION AUTHORIZATION m20_author;
SELECT pgreact_api.deploy_shared_condition(
    jsonb_build_object(
        'name', 'm20_app.high_risk', 'version', 2,
        'source', 'm20_app.high_risk_source_v2',
        'row_type', 'm20_app.risk_row', 'key', ARRAY['customer_id'],
        'maintenance_mode', 'SCHEDULED'),
    (pgreact_api.preview_shared_condition(jsonb_build_object(
        'name', 'm20_app.high_risk', 'version', 2,
        'source', 'm20_app.high_risk_source_v2',
        'row_type', 'm20_app.risk_row', 'key', ARRAY['customer_id'],
        'maintenance_mode', 'SCHEDULED')) ->> 'plan_digest'));
DO $$
BEGIN
    BEGIN
        PERFORM pgreact_api.deploy_shared_condition(jsonb_build_object(
            'name', 'm20_app.high_risk', 'version', 3,
            'source', 'm20_app.high_risk_source_bad',
            'row_type', 'm20_app.risk_row_v2', 'key', ARRAY['customer_id'],
            'maintenance_mode', 'SCHEDULED'));
        RAISE EXCEPTION 'M20 incompatible replacement was accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M20_INCOMPATIBLE_REPLACEMENT:%' THEN RAISE; END IF;
    END;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m20_author;
DO $$
BEGIN
    BEGIN
        PERFORM pgreact_api.remove_shared_condition('m20_app.high_risk');
        RAISE EXCEPTION 'M20 live condition removal was accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M20_CONDITION_IN_USE:%' THEN RAISE; END IF;
    END;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m20_author;
CREATE OR REPLACE VIEW m20_app.high_risk_source_v2 AS
SELECT customer_id, risk_score, country FROM m20_app.customers WHERE risk_score >= 85;
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(pgreact_api.doctor() -> 'diagnostics') diagnostic
        WHERE diagnostic ->> 'code' = 'M20_CONDITION_DRIFT') THEN
        RAISE EXCEPTION 'M20 drift diagnostic disappeared: %', pgreact_api.doctor();
    END IF;
END
$$;

SET SESSION AUTHORIZATION m20_reader;
DO $$
BEGIN
    IF (pgreact_api.status('m20_app.high_risk') ->> 'contract_version') <> '8'
       OR (pgreact_api.shared_condition_matches('m20_app.high_risk') ->> 'condition') <> 'm20_app.high_risk' THEN
        RAISE EXCEPTION 'M20 reader boundary changed: %', pgreact_api.status('m20_app.high_risk');
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m20_operator;
SELECT pgreact_api.pause_rule('m20.review');
SELECT pgreact_api.pause_rule('m20.audit');
SELECT pgreact_api.remove_rule('m20.review');
SELECT pgreact_api.remove_rule('m20.audit');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m20_author;
SELECT pgreact_api.remove_shared_condition('m20_app.high_risk');
RESET SESSION AUTHORIZATION;

SELECT 'M20 shared condition, consumers, replacement, drift, security, and removal gate passed';
