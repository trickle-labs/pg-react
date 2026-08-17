\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m30_reference;
CREATE TABLE m30_reference.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    label text NOT NULL
);
INSERT INTO m30_reference.orders VALUES
    (100, 10, 'review'), (101, 10, 'review'), (200, 20, 'review');
CREATE TABLE m30_reference.customer_gate (
    customer_id bigint PRIMARY KEY,
    region text COLLATE "C" NOT NULL
);
INSERT INTO m30_reference.customer_gate VALUES (10, 'NO'), (20, 'SE');
CREATE TABLE m30_reference.duplicate_gate (customer_id bigint);
INSERT INTO m30_reference.duplicate_gate VALUES (10), (10);

DO $m30$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    invalid pgreact_api.declaration;
    validation jsonb;
    preview jsonb;
    deployed jsonb;
    status_before jsonb;
    status_after jsonb;
    explained jsonb;
    diagnosed jsonb;
    refreshed jsonb;
    digest text;
    before_rows bigint;
    after_rows bigint;
    expected_identity bytea;
BEGIN
    member := pgreact_api.declaration('rule', 'm30-member', jsonb_build_object(
        'condition', 'm30_reference.orders', 'semantic_key', 'order_id',
        'kind', 'CONSTRAINT', 'delegate', false));
    IF (pgreact_api.deploy(member,
        jsonb_build_object('preview_digest',
            pgreact_api.preview(member) -> 'summary' ->> 'preview_digest')) ->> 'state')
        <> 'deployed' THEN
        RAISE EXCEPTION 'M30 member setup failed';
    END IF;

    policy_set := pgreact_api.declaration('policy_set', 'm30-customers', jsonb_build_object(
        'version', '2',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm30-member', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm30_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01 00:00:00+00', 'evidence_limit', 10));
    validation := pgreact_api.validate(policy_set);
    preview := pgreact_api.preview(policy_set);
    IF validation ->> 'contract_version' <> '18'
       OR validation ->> 'state' <> 'ready'
       OR validation -> 'findings' <> '[]'::jsonb
       OR validation -> 'evidence' -> 'normalized_declaration'
          -> 'spec' -> 'members' -> 0 ->> 'scope_mode' <> 'POLICY_SET_REQUIRED'
       OR preview -> 'summary' ->> 'preview_digest' IS NULL
       OR preview -> 'summary' ->> 'eligible_subject_count' <> '2' THEN
        RAISE EXCEPTION 'M30 validation/preview mismatch: % / %', validation, preview;
    END IF;
    digest := preview -> 'summary' ->> 'preview_digest';
    deployed := pgreact_api.deploy(policy_set, jsonb_build_object('preview_digest', digest));
    status_before := pgreact_api.status(pgreact_api.target('policy_set', 'm30-customers', '2'));
    explained := pgreact_api.explain(
        pgreact_api.target('policy_set', 'm30-customers', '2'),
        jsonb_build_object('customer_id', 10));
    diagnosed := pgreact_api.doctor(pgreact_api.target('policy_set', 'm30-customers', '2'));
    IF deployed ->> 'state' <> 'deployed'
       OR status_before ->> 'contract_version' <> '18'
       OR status_before -> 'summary' ->> 'migration_state' <> 'READY'
       OR status_before -> 'summary' ->> 'runtime_state' <> 'FOUNDATION_ONLY'
       OR status_before -> 'summary' ->> 'eligible_subject_count' <> '2'
       OR explained -> 'evidence' ->> 'eligible' <> 'true'
       OR diagnosed -> 'diagnostics' -> 0 ->> 'code' <> 'M30_FOUNDATION_READY' THEN
        RAISE EXCEPTION 'M30 deployed inspection mismatch: % / % / % / %',
            deployed, status_before, explained, diagnosed;
    END IF;
    IF (SELECT count(*) FROM pgreact.policy_set_eligible_subjects
        WHERE set_name = 'm30-customers') <> 2
       OR (SELECT count(*) FROM pgreact.policy_set_scope_supports
           WHERE set_name = 'm30-customers') <> 0 THEN
        RAISE EXCEPTION 'M30 relational inspection state is incomplete';
    END IF;
    expected_identity := pgreact_internal.m30_key_identity(
        ARRAY['bigint', 'text'], '[10, "NO"]'::jsonb);
    IF expected_identity = pgreact_internal.m30_key_identity(
        ARRAY['text', 'bigint'], '["10", 1]'::jsonb)
       OR expected_identity <> pgreact_internal.m30_key_identity(
           ARRAY['bigint', 'text'], '[10, "NO"]'::jsonb) THEN
        RAISE EXCEPTION 'M30 codec-v2 identity is not deterministic and typed';
    END IF;

    SELECT count(*) INTO before_rows
    FROM pgreact_internal.policy_set_eligibility eligibility
    JOIN pgreact_internal.policy_set_versions version
      USING (policy_set_version_id)
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm30-customers';
    INSERT INTO m30_reference.customer_gate VALUES (30, 'DK');
    IF (SELECT count(*) FROM pgreact_internal.policy_set_eligibility eligibility
        JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = 'm30-customers') <> before_rows THEN
        RAISE EXCEPTION 'M30 source change rewrote eligibility before coordinated refresh';
    END IF;
    refreshed := pgreact_api.run(
        pgreact_api.target('policy_set', 'm30-customers', '2'),
        '2026-02-01 00:00:00+00');
    SELECT count(*) INTO after_rows
    FROM pgreact.policy_set_eligible_subjects
    WHERE set_name = 'm30-customers';
    IF refreshed ->> 'foundation_refreshed' <> 'true' OR after_rows <> 3 THEN
        RAISE EXCEPTION 'M30 relational refresh mismatch: % / %', refreshed, after_rows;
    END IF;

    invalid := pgreact_api.declaration('policy_set', 'm30-invalid', jsonb_build_object(
        'version', '2',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm30-member', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm30_reference.duplicate_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01+00'));
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(pgreact_api.validate(invalid) -> 'findings') finding
        WHERE finding ->> 'code' = 'M30_SUBJECT_DUPLICATE') THEN
        RAISE EXCEPTION 'M30 duplicate subject was accepted: %', pgreact_api.validate(invalid);
    END IF;
END
$m30$;

SELECT 'M30_APPLICABILITY_FOUNDATION_OK' AS result;
