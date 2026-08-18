\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m32_reference;
CREATE TABLE m32_reference.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    label text NOT NULL
);
INSERT INTO m32_reference.orders VALUES
    (1, 10, 'review'), (2, 20, 'review');
CREATE VIEW m32_reference.orders_match AS
SELECT order_id, customer_id, label FROM m32_reference.orders;
CREATE TABLE m32_reference.candidates (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m32_reference.candidates VALUES (10, 100, 1, 'approve');
CREATE TABLE m32_reference.gate (customer_id bigint PRIMARY KEY);
INSERT INTO m32_reference.gate VALUES (10);

CREATE FUNCTION m32_reference.stale_replacement_rejected()
RETURNS boolean
LANGUAGE plpgsql AS $m32$
DECLARE ignored jsonb;
BEGIN
    ignored := pgreact.deploy(
        pgreact.rule('m32-order-rule', 'm32_reference.orders_match'::regclass,
                     'order_id'::name, 'CONSTRAINT'),
        jsonb_build_object('allow_create', false,
                           'expected_current_digest', 'stale'));
    RETURN false;
EXCEPTION WHEN OTHERS THEN
    RETURN true;
END
$m32$;

DO $m32$
DECLARE
    rule_declaration pgreact_api.declaration;
    decision_declaration pgreact_api.declaration;
    set_declaration pgreact_api.declaration;
    invalid jsonb;
    preview jsonb;
    deployed jsonb;
    exported jsonb;
    policy_export jsonb;
    imported jsonb;
    doctor jsonb;
    before_count bigint;
    after_count bigint;
    finding jsonb;
    stale_rejected boolean := false;
BEGIN
    rule_declaration := pgreact.rule(
        'm32-order-rule', 'm32_reference.orders_match'::regclass, 'order_id'::name);
    decision_declaration := pgreact.decision(
        'm32-decision', 'm32_reference.candidates'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-01-01 00:00:00+00');
    set_declaration := pgreact.policy_set(
        'm32-customers', '1',
        ARRAY[rule_declaration, decision_declaration],
        'm32_reference.gate'::regclass, ARRAY['customer_id']::name[],
        '2026-01-01 00:00:00+00');
    IF (set_declaration).spec -> 'members' -> 0 ->> 'kind' <> 'rule'
       OR (set_declaration).spec -> 'members' -> 1 ->> 'kind' <> 'decision_program'
       OR (set_declaration).spec -> 'members' -> 0 ? 'disposition'
       OR (set_declaration).spec -> 'members' -> 1 ? 'disposition' THEN
        RAISE EXCEPTION 'M32 policy-set constructor produced invalid typed members: %',
            set_declaration;
    END IF;
    IF pgreact_internal.m32_stable_code('M31_ACTION_DRIFT') <> 'M32_ACTION_DRIFT'
       OR pgreact_internal.m32_stable_code('M31_INCOMPLETE_FRONTIER') <>
          'M32_INCOMPLETE_FRONTIER'
       OR pgreact_internal.m32_stable_code('M31_RUNTIME_NOT_READY') <>
          'M32_RUNTIME_NOT_READY'
       OR pgreact_internal.m32_stable_code('M28_API_READY') <> 'M32_RUNTIME_READY' THEN
        RAISE EXCEPTION 'M32 delegated finding mapping is unstable';
    END IF;

    invalid := pgreact.validate(pgreact.rule(
        '', 'm32_reference.orders_match'::regclass, 'order_id'::name));
    finding := invalid -> 'findings' -> 0;
    IF invalid ->> 'state' <> 'attention'
       OR finding ->> 'code' <> 'M32_INVALID_DECLARATION'
       OR NOT (finding ?& ARRAY['code', 'severity', 'blocking', 'target', 'field',
                                'message', 'hint', 'details'])
       OR NOT (finding -> 'details' ? 'source_code')
       OR finding ->> 'code' IS NULL THEN
        RAISE EXCEPTION 'M32 invalid finding shape mismatch: %', invalid;
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact.api_declarations WHERE name = '') THEN
        RAISE EXCEPTION 'M32 validation changed state';
    END IF;

    preview := pgreact.preview(rule_declaration);
    IF preview -> 'summary' ->> 'deployment' <> 'create'
       OR preview -> 'summary' ->> 'current_state' <> 'ABSENT'
       OR preview -> 'summary' ? 'current_declaration_digest' IS NOT TRUE THEN
        RAISE EXCEPTION 'M32 create preview metadata mismatch: %', preview;
    END IF;
    deployed := pgreact.deploy(rule_declaration, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M32 rule deployment failed: %', deployed;
    END IF;
    preview := pgreact.preview(rule_declaration);
    IF preview -> 'summary' ->> 'deployment' <> 'replacement'
       OR preview -> 'summary' ->> 'current_state' <> 'deployed'
       OR preview -> 'summary' ->> 'current_declaration_digest' IS NULL THEN
        RAISE EXCEPTION 'M32 replacement preview metadata mismatch: %', preview;
    END IF;
    preview := pgreact.preview(decision_declaration);
    deployed := pgreact.deploy(decision_declaration, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M32 decision deployment failed: %', deployed;
    END IF;
    preview := pgreact.preview(set_declaration);
    deployed := pgreact.deploy(set_declaration, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M32 policy-set deployment failed: %', deployed;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pgreact.rules WHERE name = 'm32-order-rule')
       OR NOT EXISTS (SELECT 1 FROM pgreact.decisions WHERE name = 'm32-decision')
       OR NOT EXISTS (SELECT 1 FROM pgreact.policy_sets WHERE name = 'm32-customers') THEN
        RAISE EXCEPTION 'M32 names-first views are incomplete';
    END IF;
    PERFORM pgreact.status('m32-order-rule');
    PERFORM pgreact.status('m32-order-rule', '{}'::jsonb);
    PERFORM pgreact_api.status(
        pgreact_api.target('rule', 'm32-order-rule', NULL));
    PERFORM pgreact.explain('m32-order-rule');
    PERFORM pgreact.doctor('m32-order-rule');
    doctor := pgreact.doctor();
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(doctor -> 'diagnostics') diagnostic
        WHERE diagnostic ->> 'severity' = 'INFO'
          AND diagnostic ->> 'code' = 'M32_INVALID_DECLARATION'
    ) THEN
        RAISE EXCEPTION 'M32 healthy INFO diagnostic was mapped to an error code: %', doctor;
    END IF;
    PERFORM pgreact.run('2026-02-01 00:00:00+00');

    exported := pgreact.export('m32-order-rule');
    IF exported <> pgreact.export('m32-order-rule') THEN
        RAISE EXCEPTION 'M32 export is not deterministic';
    END IF;
    policy_export := pgreact.export('m32-customers');
    IF policy_export <> pgreact.export('m32-customers') THEN
        RAISE EXCEPTION 'M32 policy-set export is not deterministic';
    END IF;
    SELECT pgreact.remove('m32-customers') INTO imported;
    imported := pgreact.import(policy_export, jsonb_build_object(
        'allow_create', false,
        'expected_current_digest', policy_export ->> 'declaration_digest'));
    IF imported ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M32 import failed: %', imported;
    END IF;

    SELECT count(*) INTO before_count
    FROM pgreact.api_declarations WHERE name = 'm32-order-rule' AND state = 'DEPLOYED';
    stale_rejected := m32_reference.stale_replacement_rejected();
    IF NOT stale_rejected THEN
        RAISE EXCEPTION 'M32 stale replacement was accepted';
    END IF;
    SELECT count(*) INTO after_count
    FROM pgreact.api_declarations WHERE name = 'm32-order-rule' AND state = 'DEPLOYED';
    IF before_count <> after_count THEN
        RAISE EXCEPTION 'M32 stale replacement changed state';
    END IF;

    SELECT pgreact.remove('m32-customers') INTO imported;
END
$m32$;
