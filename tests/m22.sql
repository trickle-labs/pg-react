\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = warning;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm22_author') THEN CREATE ROLE m22_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm22_operator') THEN CREATE ROLE m22_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm22_worker') THEN CREATE ROLE m22_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm22_reader') THEN CREATE ROLE m22_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm22_advanced') THEN CREATE ROLE m22_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles('m22_author','m22_operator','m22_worker','m22_reader','m22_advanced');

CREATE SCHEMA m22_app;
CREATE TYPE m22_app.fact_row AS (patient_id bigint);
CREATE TABLE m22_app.positive_tests(
    patient_id bigint PRIMARY KEY, test_name text NOT NULL, positive boolean NOT NULL);
CREATE TABLE m22_app.temperatures(
    patient_id bigint PRIMARY KEY, temperature_c numeric(4,1) NOT NULL);
CREATE VIEW m22_app.positive AS
SELECT patient_id, test_name, positive FROM m22_app.positive_tests WHERE positive;
CREATE VIEW m22_app.hot AS
SELECT patient_id, temperature_c FROM m22_app.temperatures WHERE temperature_c >= 38.0;

SELECT pgreact.create_derived_relation(
    'm22_app.fever', 'm22_app.fact_row'::regtype, ARRAY['patient_id'], 1)
    AS relation_version_id \gset
SELECT pgreact.create_derivation_rule(
    'm22_app.positive', 'm22_app.positive'::regclass, ARRAY['patient_id'],
    :'relation_version_id'::uuid, 1) AS positive_rule_id \gset
SELECT pgreact.create_derivation_rule(
    'm22_app.hot', 'm22_app.hot'::regclass, ARRAY['patient_id'],
    :'relation_version_id'::uuid, 1) AS hot_rule_id \gset

INSERT INTO m22_app.positive_tests VALUES (42, 'influenza_a', true);
INSERT INTO m22_app.temperatures VALUES (42, 39.2);
SELECT pgreact.refresh_derived_relation(:'relation_version_id'::uuid);

SELECT set_config('m22.relation', :'relation_version_id', false);

DO $$
DECLARE actual jsonb; validation jsonb; status jsonb; first_page jsonb; second_page jsonb;
    token text; first_support uuid; second_support uuid;
BEGIN
    validation := pgreact_api.provenance_validate(current_setting('m22.relation')::uuid);
    status := pgreact_api.provenance_status(current_setting('m22.relation')::uuid);
    actual := pgreact_api.explain_provenance(current_setting('m22.relation')::uuid, 42);
    IF validation ->> 'status' <> 'ready'
       OR (status #>> '{relations,0,active_supports}')::bigint <> 2
       OR actual ->> 'contract_version' <> '10'
       OR actual ->> 'status' <> 'GROUNDED'
       OR (actual ->> 'total_supports')::bigint <> 2
       OR (actual #>> '{proof,nodes,0,state}') <> 'GROUNDED'
       OR (actual #>> '{proof,total_nodes}') <> '1'
       OR jsonb_array_length(actual -> 'supports') <> 2 THEN
        RAISE EXCEPTION 'M22 typed provenance shape changed: % / % / %', validation, status, actual;
    END IF;
    IF NOT EXISTS (
        SELECT 1
          FROM jsonb_array_elements(actual -> 'supports') support,
               jsonb_array_elements(support -> 'bindings') binding
         WHERE binding ->> 'name' = 'test_name'
           AND binding ->> 'type' = 'text'
           AND binding ->> 'canonical_value' = 'influenza_a')
       OR NOT EXISTS (
        SELECT 1
          FROM jsonb_array_elements(actual -> 'supports') support,
               jsonb_array_elements(support -> 'bindings') binding
         WHERE binding ->> 'name' = 'temperature_c'
           AND binding ->> 'type' = 'numeric(4,1)'
           AND binding ->> 'canonical_value' = '39.2') THEN
        RAISE EXCEPTION 'M22 typed binding output changed: %', actual -> 'supports';
    END IF;

    first_page := pgreact_api.explain_provenance(
        current_setting('m22.relation')::uuid, 42, 1, NULL);
    token := first_page ->> 'continuation';
    second_page := pgreact_api.explain_provenance(
        current_setting('m22.relation')::uuid, 42, 1, token);
    first_support := (first_page #>> '{supports,0,support_id}')::uuid;
    second_support := (second_page #>> '{supports,0,support_id}')::uuid;
    IF token IS NULL OR first_support = second_support
       OR (first_page ->> 'omitted_supports')::bigint <> 1
       OR (second_page ->> 'omitted_supports')::bigint <> 0
       OR second_page ->> 'continuation' IS NOT NULL THEN
        RAISE EXCEPTION 'M22 continuation changed: % / %', first_page, second_page;
    END IF;

    IF (pgreact_api.provenance_doctor() ->> 'status') <> 'ready' THEN
        RAISE EXCEPTION 'M22 doctor did not report ready';
    END IF;
END
$$;

SET SESSION AUTHORIZATION m22_reader;
DO $$
DECLARE explanation jsonb;
BEGIN
    explanation := pgreact_api.explain_provenance(current_setting('m22.relation')::uuid, 42);
    IF explanation ->> 'status' <> 'GROUNDED' THEN
        RAISE EXCEPTION 'M22 reader explanation changed: %', explanation;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m22_advanced;
DO $$
BEGIN
    IF (pgreact_api.explain_provenance_advanced(current_setting('m22.relation')::uuid, 42)
        ->> 'reader_class') <> 'advanced' THEN
        RAISE EXCEPTION 'M22 advanced-reader explanation was not authorized';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

DELETE FROM m22_app.temperatures WHERE patient_id = 42;
SELECT pgreact.refresh_derived_relation(current_setting('m22.relation')::uuid);

DO $$
DECLARE actual jsonb; inactive_count bigint;
BEGIN
    actual := pgreact_api.explain_provenance(current_setting('m22.relation')::uuid, 42);
    SELECT count(*) INTO inactive_count
      FROM pgreact_internal.support_provenance_bindings binding
      JOIN pgreact_internal.derived_supports support USING (support_id)
     WHERE support.relation_version_id = current_setting('m22.relation')::uuid
       AND NOT binding.active;
    IF (actual ->> 'total_supports')::bigint <> 1 OR inactive_count <> 2
       OR (pgreact_api.provenance_validate(current_setting('m22.relation')::uuid) ->> 'status') <> 'ready' THEN
        RAISE EXCEPTION 'M22 withdrawal provenance changed: % / %', actual, inactive_count;
    END IF;
END
$$;

SELECT 'M22 typed bounded provenance, maintenance, continuation, security, and withdrawal gate passed';
