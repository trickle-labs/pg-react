\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm14_author') THEN CREATE ROLE m14_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm14_operator') THEN CREATE ROLE m14_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm14_worker') THEN CREATE ROLE m14_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm14_reader') THEN CREATE ROLE m14_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm14_advanced') THEN CREATE ROLE m14_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm14_author', 'm14_operator', 'm14_worker', 'm14_reader', 'm14_advanced');

CREATE SCHEMA m14_app AUTHORIZATION m14_author;
CREATE TYPE m14_app.fact_row AS (id bigint);
CREATE TABLE m14_app.seed (id bigint PRIMARY KEY);
CREATE VIEW m14_app.seed_to_fact AS SELECT id FROM m14_app.seed;
INSERT INTO m14_app.seed VALUES (42);
ALTER TYPE m14_app.fact_row OWNER TO m14_author;
ALTER TABLE m14_app.seed OWNER TO m14_author;
ALTER VIEW m14_app.seed_to_fact OWNER TO m14_author;

SET SESSION AUTHORIZATION m14_author;

SELECT pgreact_api.declare_derived_relation(
    'm14_app.fact', 'm14_app.fact_row'::regtype, 'id') AS relation_version_id \gset

DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm14.program', 'version', 1, 'max_iterations', 8, 'max_facts', 16,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm14.seed_to_fact', 'definition', 'm14_app.seed_to_fact',
            'key', 'id', 'target', 'm14_app.fact', 'version', 1)));
    actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'contract_version', contract_version, 'code', code, 'severity', severity,
        'object_identity', object_identity, 'message', message, 'hint', hint)
        ORDER BY code, object_identity)
    INTO actual FROM pgreact_api.validate_program(definition);
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 4, 'code', 'OK', 'severity', 'INFO',
        'object_identity', 'm14.program',
        'message', 'derivation program is a closed positive key-preserving graph',
        'hint', 'Preview and deploy the containing pack.')) THEN
        RAISE EXCEPTION 'M14 inferred validation changed: %', actual;
    END IF;
    SELECT pgreact_api.preview_program(definition) - 'plan_digest' INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 4,
        'program', jsonb_build_object(
            'name', 'm14.program', 'version', 1, 'max_iterations', 8, 'max_facts', 16,
            'rules', jsonb_build_array(jsonb_build_object(
                'name', 'm14.seed_to_fact', 'definition', 'm14_app.seed_to_fact',
                'key', 'id', 'target', 'm14_app.fact', 'version', 1,
                'inputs', '[]'::jsonb)))) THEN
        RAISE EXCEPTION 'M14 preview changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE definition jsonb := jsonb_build_object(
    'name', 'm14.program', 'version', 1, 'max_iterations', 8, 'max_facts', 16,
    'rules', jsonb_build_array(jsonb_build_object(
        'name', 'm14.seed_to_fact', 'definition', 'm14_app.seed_to_fact',
        'key', 'id', 'target', 'm14_app.fact', 'version', 1)));
BEGIN
    PERFORM pgreact_api.deploy_program(
        definition, pgreact_api.preview_program(definition) ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;

SELECT pgreact_api.run('2040-01-01 00:00:00+00');

SET SESSION AUTHORIZATION m14_reader;
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.doctor();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 4, 'status', 'ready', 'diagnostics', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M14 clean doctor changed: %', actual;
    END IF;
    actual := pgreact_api.explain('m14_app.fact', 42);
    IF actual -> 'contract_version' IS DISTINCT FROM '4'::jsonb
       OR actual -> 'target' IS DISTINCT FROM jsonb_build_object(
            'kind', 'fact', 'name', 'm14_app.fact', 'key', 42)
       OR actual #> '{evidence,fact}' IS DISTINCT FROM jsonb_build_object('id', 42) THEN
        RAISE EXCEPTION 'M14 fact explanation changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SELECT 'M14 diagnosis, inferred authoring, and unified explanation gate passed';
