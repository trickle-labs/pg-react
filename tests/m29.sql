\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m29_reference;
CREATE TABLE m29_reference.customer_gate (customer_id bigint PRIMARY KEY);
INSERT INTO m29_reference.customer_gate VALUES (10), (20);
CREATE TABLE m29_reference.duplicate_gate (customer_id bigint);
INSERT INTO m29_reference.duplicate_gate VALUES (10), (10);

DO $m29$
DECLARE member pgreact_api.declaration;
    member_preview jsonb;
    member_deployed jsonb;
    set_declaration pgreact_api.declaration;
    invalid pgreact_api.declaration;
    validation jsonb;
    preview jsonb;
    deployed jsonb;
    status_before jsonb;
    explained jsonb;
    diagnosed jsonb;
    refreshed jsonb;
    removed jsonb;
    digest text;
BEGIN
    member := pgreact_api.declaration('rule', 'm29-member', jsonb_build_object(
        'condition', 'm29_reference.customer_gate', 'semantic_key', 'customer_id',
        'kind', 'CONSTRAINT', 'delegate', false));
    member_preview := pgreact_api.preview(member);
    member_deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', member_preview -> 'summary' ->> 'preview_digest'));
    IF member_deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M29 member setup failed: %', member_deployed;
    END IF;

    set_declaration := pgreact_api.declaration('policy_set', 'm29-customers', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm29-member', 'version', '1')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm29_reference.customer_gate',
            'subject_key', 'customer_id'),
        'valid_from', '2026-01-01 00:00:00+00', 'evidence_limit', 10));
    validation := pgreact_api.validate(set_declaration);
    preview := pgreact_api.preview(set_declaration);
    IF validation ->> 'contract_version' <> '17'
       OR validation ->> 'state' <> 'ready'
       OR validation -> 'findings' <> '[]'::jsonb
       OR preview -> 'summary' ->> 'preview_digest' IS NULL
       OR preview -> 'summary' ->> 'eligible_subject_count' <> '2' THEN
        RAISE EXCEPTION 'M29 validation/preview mismatch: % / %', validation, preview;
    END IF;
    digest := preview -> 'summary' ->> 'preview_digest';
    deployed := pgreact_api.deploy(set_declaration, jsonb_build_object('preview_digest', digest));
    status_before := pgreact_api.status(pgreact_api.target('policy_set', 'm29-customers', '1'));
    explained := pgreact_api.explain(pgreact_api.target('policy_set', 'm29-customers', '1'),
                                     jsonb_build_object('customer_id', 10));
    diagnosed := pgreact_api.doctor(pgreact_api.target('policy_set', 'm29-customers', '1'));
    IF deployed ->> 'state' <> 'deployed'
       OR status_before ->> 'state' <> 'deployed'
       OR status_before -> 'summary' ->> 'eligible_subject_count' <> '2'
       OR explained -> 'evidence' ->> 'eligible' <> 'true'
       OR diagnosed -> 'diagnostics' -> 0 ->> 'code' <> 'M29_POLICY_SET_READY' THEN
        RAISE EXCEPTION 'M29 deployed inspection mismatch: % / % / % / %',
            deployed, status_before, explained, diagnosed;
    END IF;
    IF (SELECT count(*) FROM pgreact.policy_set_members WHERE set_name = 'm29-customers') <> 1
       OR (SELECT count(*) FROM pgreact.policy_set_eligible_subjects WHERE set_name = 'm29-customers') <> 2 THEN
        RAISE EXCEPTION 'M29 inspection views are incomplete';
    END IF;

    INSERT INTO m29_reference.customer_gate VALUES (30);
    IF pgreact_api.doctor(pgreact_api.target('policy_set', 'm29-customers', '1'))
       -> 'diagnostics' -> 0 ->> 'code' <> 'M29_SOURCE_DRIFT' THEN
        RAISE EXCEPTION 'M29 source drift was not detected';
    END IF;
    refreshed := pgreact_api.run(pgreact_api.target('policy_set', 'm29-customers', '1'),
                                 '2026-02-01 00:00:00+00');
    IF refreshed -> 'summary' ->> 'eligible_subject_count' <> '3' THEN
        RAISE EXCEPTION 'M29 refresh did not capture the new eligible subject: %', refreshed;
    END IF;

    invalid := pgreact_api.declaration('policy_set', 'm29-invalid', jsonb_build_object(
        'version', '1', 'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm29-member', 'version', '1')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm29_reference.duplicate_gate',
            'subject_key', 'customer_id'), 'valid_from', '2026-01-01+00'));
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pgreact_api.validate(invalid) -> 'findings') finding
                   WHERE finding ->> 'code' = 'M29_SUBJECT_DUPLICATE') THEN
        RAISE EXCEPTION 'M29 duplicate subject was accepted: %', pgreact_api.validate(invalid);
    END IF;
    removed := pgreact_api.remove(pgreact_api.target('policy_set', 'm29-customers', '1'));
    IF removed ->> 'state' <> 'removed'
       OR pgreact_api.status(pgreact_api.target('policy_set', 'm29-customers', '1')) ->> 'state' <> 'removed' THEN
        RAISE EXCEPTION 'M29 removal mismatch: %', removed;
    END IF;
END
$m29$;

SELECT 'M29_POLICY_SET_GATE_OK' AS result;
