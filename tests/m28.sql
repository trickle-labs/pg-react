\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m28_reference;
CREATE TABLE m28_reference.events (id bigint PRIMARY KEY, label text NOT NULL);
INSERT INTO m28_reference.events VALUES (1, 'one');

DO $m28$
DECLARE
    declaration pgreact_api.declaration;
    reordered pgreact_api.declaration;
    invalid pgreact_api.declaration;
    target pgreact_api.target;
    validation jsonb;
    preview jsonb;
    deployed jsonb;
    status_before jsonb;
    status_after jsonb;
    explained jsonb;
    diagnosed jsonb;
    ran jsonb;
    removed jsonb;
    digest text;
    before_count bigint;
    after_count bigint;
BEGIN
    declaration := pgreact_api.declaration('rule', 'm28-events', jsonb_build_object(
        'condition', 'm28_reference.events', 'semantic_key', 'id',
        'kind', 'CONSTRAINT', 'delegate', false));
    reordered := pgreact_api.declaration('rule', 'm28-events', jsonb_build_object(
        'delegate', false, 'kind', 'CONSTRAINT', 'semantic_key', 'id',
        'condition', 'm28_reference.events'));
    invalid := pgreact_api.declaration('rule', 'm28-events-invalid', jsonb_build_object(
        'condition', 'm28_reference.events', 'semantic_key', 'id', 'unknown', true));
    target := pgreact_api.target('rule', 'm28-events');

    SELECT count(*) INTO before_count FROM pgreact_internal.api_declarations;
    validation := pgreact_api.validate(declaration);
    preview := pgreact_api.preview(reordered);
    SELECT count(*) INTO after_count FROM pgreact_internal.api_declarations;
    IF validation ->> 'contract_version' <> '16'
       OR validation ->> 'state' <> 'ready'
       OR validation -> 'findings' <> '[]'::jsonb
       OR validation -> 'evidence' -> 'normalized_declaration'
          IS DISTINCT FROM preview -> 'evidence' -> 'normalized_declaration'
       OR preview -> 'summary' ->> 'preview_digest' IS NULL
       OR before_count <> after_count THEN
        RAISE EXCEPTION 'M28 read-only validation/preview output mismatch: % / %', validation, preview;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pgreact.api_inventory
        WHERE identity LIKE '%pgreact_api.validate%' AND classification = 'ordinary'
          AND contract_version = 16 AND security_definer) THEN
        RAISE EXCEPTION 'M28 public inventory is missing the ordinary validate surface';
    END IF;
    IF (pgreact_api.validate(invalid) -> 'findings')
       IS DISTINCT FROM jsonb_build_array(pgreact_internal.m28_finding(
           'M28_FIELD_UNKNOWN', 'ERROR', 'm28-events-invalid', 'spec.unknown',
           'declaration contains an unknown field',
           'Remove the field or use a newer supported API version',
           jsonb_build_object('field', 'unknown'))) THEN
        RAISE EXCEPTION 'M28 unknown-field result changed: %', pgreact_api.validate(invalid);
    END IF;

    digest := preview -> 'summary' ->> 'preview_digest';
    ALTER TABLE m28_reference.events ADD COLUMN extra text;
    BEGIN
        PERFORM pgreact_api.deploy(declaration, jsonb_build_object('preview_digest', digest));
        RAISE EXCEPTION 'M28 stale preview was accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'M28_PREVIEW_STALE%' THEN
            RAISE;
        END IF;
    END;
    preview := pgreact_api.preview(declaration);
    digest := preview -> 'summary' ->> 'preview_digest';
    deployed := pgreact_api.deploy(declaration, jsonb_build_object('preview_digest', digest));
    status_before := pgreact_api.status(target);
    ran := pgreact_api.run(target, '2026-01-01 00:00:00+00'::timestamptz);
    explained := pgreact_api.explain(target, jsonb_build_object('id', 1));
    diagnosed := pgreact_api.doctor(target);
    IF deployed ->> 'state' <> 'deployed'
       OR status_before ->> 'state' <> 'deployed'
       OR status_before -> 'summary' ->> 'declaration_digest' IS NULL
       OR ran ->> 'operation' <> 'run'
       OR explained ->> 'operation' <> 'explain'
       OR diagnosed ->> 'operation' <> 'doctor'
       OR diagnosed -> 'diagnostics' -> 0 ->> 'code' <> 'M28_API_READY' THEN
        RAISE EXCEPTION 'M28 deployed inspection output mismatch: % / % / % / % / %',
            deployed, status_before, ran, explained, diagnosed;
    END IF;
    removed := pgreact_api.remove(target);
    status_after := pgreact_api.status(target);
    IF removed ->> 'state' <> 'removed' OR status_after ->> 'state' <> 'removed' THEN
        RAISE EXCEPTION 'M28 removal output mismatch: % / %', removed, status_after;
    END IF;
END
$m28$;

SELECT 'M28_CANONICAL_FACADE_OK' AS result;
