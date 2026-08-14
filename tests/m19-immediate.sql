\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = warning;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_author') THEN CREATE ROLE m19_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_operator') THEN CREATE ROLE m19_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_worker') THEN CREATE ROLE m19_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_reader') THEN CREATE ROLE m19_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_advanced') THEN CREATE ROLE m19_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm19_author', 'm19_operator', 'm19_worker', 'm19_reader', 'm19_advanced');

CREATE SCHEMA m19_app AUTHORIZATION m19_author;
SET SESSION AUTHORIZATION m19_author;
CREATE TABLE m19_app.source(id bigint PRIMARY KEY, enabled boolean NOT NULL);
CREATE TABLE m19_app.other(id bigint PRIMARY KEY);
CREATE VIEW m19_app.active AS SELECT id FROM m19_app.source WHERE enabled;
CREATE VIEW m19_app.joined AS
SELECT source_a.id FROM m19_app.source source_a
JOIN m19_app.source source_b ON source_b.id = source_a.id;
CREATE VIEW m19_app.aggregated AS
SELECT id, count(*)::bigint AS total FROM m19_app.source GROUP BY id;
GRANT SELECT, INSERT, UPDATE, DELETE ON m19_app.source TO m19_operator;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'contract_version', contract_version, 'code', code, 'severity', severity,
        'object_identity', object_identity, 'message', message, 'hint', hint,
        'details', details) ORDER BY code)
    INTO actual FROM pgreact_api.validate_immediate_rule('m19_app.joined', 'id');
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 7, 'code', 'M19_QUERY_UNSUPPORTED', 'severity', 'ERROR',
        'object_identity', 'm19_app.joined',
        'message', 'immediate rules require a finite single-table positive query',
        'hint', 'Use a direct SELECT from one base table; joins, aggregates, windows, recursion, and subqueries remain scheduled.',
        'details', '{}'::jsonb)) THEN
        RAISE EXCEPTION 'M19 join rejection changed: %', actual;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'contract_version', contract_version, 'code', code, 'severity', severity,
        'object_identity', object_identity, 'message', message, 'hint', hint,
        'details', details) ORDER BY code)
    INTO actual FROM pgreact_api.validate_immediate_rule('m19_app.aggregated', 'id');
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 7, 'code', 'M19_KEY_NOT_DIRECT', 'severity', 'ERROR',
        'object_identity', 'm19_app.aggregated',
        'message', 'immediate rules require one direct semantic key projected from the source table',
        'hint', 'Project one stored bigint key unchanged from the source table.',
        'details', jsonb_build_object('semantic_key', 'id'))) THEN
        RAISE EXCEPTION 'M19 aggregate rejection changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.author_immediate_rule(
    'm19.immediate', 'm19_app.active', 'id');
SELECT pgreact_api.replace_immediate_rule(
    'm19.immediate', 'm19_app.active', 'id');
SELECT pgreact_api.author_rule(
    rule_name => 'm19.scheduled', condition => 'm19_app.active'::regclass,
    semantic_key => 'id', kind => 'CONSTRAINT');
RESET SESSION AUTHORIZATION;

BEGIN;
INSERT INTO m19_app.source VALUES (1, true);
DO $$
BEGIN
    BEGIN
        INSERT INTO m19_app.source VALUES (1, true);
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;
END
$$;
ROLLBACK;
DO $$
BEGIN
    IF pgreact_api.matches('m19.immediate') IS DISTINCT FROM jsonb_build_object(
        'contract_version', 7, 'matches', jsonb_build_array()) THEN
        RAISE EXCEPTION 'M19 failed statement left state: %', pgreact_api.matches('m19.immediate');
    END IF;
END
$$;

BEGIN;
INSERT INTO m19_app.source VALUES (1, true);
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.matches('m19.immediate');
    actual := jsonb_set(actual, '{matches}', (
        SELECT COALESCE(jsonb_agg(item.value - 'matched_at' - 'observed_at'), '[]'::jsonb)
        FROM jsonb_array_elements(actual -> 'matches') item), true);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 7,
        'matches', jsonb_build_array(jsonb_build_object(
            'key', 1, 'rule', 'm19.immediate', 'maintenance_mode', 'IMMEDIATE'))) THEN
        RAISE EXCEPTION 'M19 same-statement match changed: %', actual;
    END IF;
    IF pgreact_api.status('m19.immediate') IS DISTINCT FROM jsonb_build_object(
        'contract_version', 7,
        'rules', jsonb_build_array(jsonb_build_object(
            'rule', 'm19.immediate', 'condition', 'm19_app.active', 'key', 'id',
            'state', 'active', 'actions', jsonb_build_array(),
            'maintenance_mode', 'IMMEDIATE'))) THEN
        RAISE EXCEPTION 'M19 same-statement status changed: %', pgreact_api.status('m19.immediate');
    END IF;
END
$$;
SAVEPOINT m19_toggle;
UPDATE m19_app.source SET enabled = false WHERE id = 1;
DO $$
BEGIN
    IF pgreact_api.matches('m19.immediate') IS DISTINCT FROM jsonb_build_object(
        'contract_version', 7, 'matches', jsonb_build_array()) THEN
        RAISE EXCEPTION 'M19 same-key deactivation changed: %', pgreact_api.matches('m19.immediate');
    END IF;
END
$$;
ROLLBACK TO SAVEPOINT m19_toggle;
DO $$
BEGIN
    IF (pgreact_api.matches('m19.immediate') #>> '{matches,0,key}') <> '1' THEN
        RAISE EXCEPTION 'M19 savepoint rollback changed: %', pgreact_api.matches('m19.immediate');
    END IF;
END
$$;
ROLLBACK;

BEGIN;
INSERT INTO m19_app.source VALUES (2, true);
DO $$
BEGIN
    BEGIN
        INSERT INTO m19_app.source VALUES (2, true);
    EXCEPTION WHEN unique_violation THEN
        NULL;
    END;
    IF (pgreact_api.matches('m19.immediate') #>> '{matches,0,key}') <> '2' THEN
        RAISE EXCEPTION 'M19 failed statement rollback changed: %', pgreact_api.matches('m19.immediate');
    END IF;
END
$$;
ROLLBACK;

CREATE SCHEMA m19_chain AUTHORIZATION m19_author;
SET SESSION AUTHORIZATION m19_author;
CREATE TYPE m19_chain.fact_row AS (id bigint);
CREATE TABLE m19_chain.seeds(id bigint PRIMARY KEY);
CREATE VIEW m19_chain.seed_source AS SELECT id FROM m19_chain.seeds;
SELECT pgreact_api.declare_derived_relation(
    'm19_chain.a', 'm19_chain.fact_row'::regtype, 'id');
SELECT pgreact_api.declare_derived_relation(
    'm19_chain.b', 'm19_chain.fact_row'::regtype, 'id');
CREATE VIEW m19_chain.a_to_b AS SELECT id FROM m19_chain.a;
DO $$
DECLARE definition jsonb := jsonb_build_object(
    'name', 'm19.chain', 'version', 1, 'max_iterations', 8, 'max_facts', 16,
    'rules', jsonb_build_array(
        jsonb_build_object('name', 'm19.seed_to_a', 'definition', 'm19_chain.seed_source',
                           'key', 'id', 'target', 'm19_chain.a', 'version', 1),
        jsonb_build_object('name', 'm19.a_to_b', 'definition', 'm19_chain.a_to_b',
                           'key', 'id', 'target', 'm19_chain.b', 'version', 1)));
    preview jsonb;
BEGIN
    preview := pgreact_api.preview_immediate_program(definition);
    IF preview ->> 'maintenance_mode' <> 'IMMEDIATE'
       OR preview ->> 'contract_version' <> '7'
       OR preview #>> '{program,rules,1,inputs,0,relation}' <> 'm19_chain.a' THEN
        RAISE EXCEPTION 'M19 immediate preview changed: %', preview;
    END IF;
    PERFORM pgreact_api.deploy_immediate_program(definition, preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;

BEGIN;
INSERT INTO m19_chain.seeds VALUES (10);
DO $$
BEGIN
    IF (SELECT jsonb_agg(jsonb_build_object('id', id) ORDER BY id) FROM m19_chain.a)
           IS DISTINCT FROM '[{"id":10}]'::jsonb
       OR (SELECT jsonb_agg(jsonb_build_object('id', id) ORDER BY id) FROM m19_chain.b)
           IS DISTINCT FROM '[{"id":10}]'::jsonb THEN
        RAISE EXCEPTION 'M19 derivation closure changed: % / %',
            (SELECT jsonb_agg(jsonb_build_object('id', id) ORDER BY id) FROM m19_chain.a),
            (SELECT jsonb_agg(jsonb_build_object('id', id) ORDER BY id) FROM m19_chain.b);
    END IF;
END
$$;
UPDATE m19_chain.seeds SET id = 11 WHERE id = 10;
DO $$
BEGIN
    IF (SELECT jsonb_agg(jsonb_build_object('id', id) ORDER BY id) FROM m19_chain.b)
           IS DISTINCT FROM '[{"id":11}]'::jsonb THEN
        RAISE EXCEPTION 'M19 repeated-key derivation changed: %',
            (SELECT jsonb_agg(jsonb_build_object('id', id) ORDER BY id) FROM m19_chain.b);
    END IF;
END
$$;
ROLLBACK;

SET SESSION AUTHORIZATION m19_reader;
DO $$
BEGIN
    IF pgreact_api.matches('m19.immediate') ->> 'contract_version' <> '7'
       OR (pgreact_api.doctor() ->> 'status' <> CASE
               WHEN (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') = '0.16.0'
               THEN 'ready' ELSE 'attention' END)
       OR EXISTS (
           SELECT 1 FROM jsonb_array_elements(pgreact_api.doctor() -> 'diagnostics') diagnostic
           WHERE diagnostic ->> 'code' <> 'M19_EXTENSION_VERSION'
             AND (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.16.0') THEN
        RAISE EXCEPTION 'M19 reader diagnostics changed: %', pgreact_api.doctor();
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m19_operator;
SELECT pgreact_api.pause_rule('m19.immediate');
SELECT pgreact_api.remove_rule('m19.immediate');
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF jsonb_array_length(pgreact_api.status('m19.immediate') -> 'rules') <> 0 THEN
        RAISE EXCEPTION 'M19 immediate removal changed: %', pgreact_api.status('m19.immediate');
    END IF;
END
$$;

SELECT 'M19 immediate constraint, closure, rollback, rejection, and public-observer gate passed';
