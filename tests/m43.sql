\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m43_reference;
CREATE TABLE m43_reference.payment_rows (
    payment_id bigint PRIMARY KEY,
    state text NOT NULL
);
INSERT INTO m43_reference.payment_rows VALUES (10, 'open');
CREATE VIEW m43_reference.payments AS
SELECT payment_id, state
FROM m43_reference.payment_rows;
CREATE VIEW m43_reference.routes AS
SELECT 10::bigint AS account_id, 1000::bigint AS route_id,
       1::bigint AS priority, 'manual'::text AS result,
       'active'::text AS state;
CREATE TABLE m43_reference.accounts (account_id bigint PRIMARY KEY);
CREATE TABLE m43_reference.accounts_next (account_id bigint PRIMARY KEY);
INSERT INTO m43_reference.accounts VALUES (10);
INSERT INTO m43_reference.accounts_next VALUES (10);
CREATE VIEW m43_reference.account_conditions AS
SELECT account_id
FROM m43_reference.accounts;

DO $m43$
DECLARE deployed pgreact_api.declaration;
    proposed pgreact_api.declaration;
    result jsonb;
    expected jsonb;
    before_count bigint;
    after_count bigint;
BEGIN
    IF pgreact_internal.m43_field_kind('rule', 'spec.salience') <> 'scalar' THEN
        RAISE EXCEPTION 'M43 field inventory mismatch for salience';
    END IF;
    IF pgreact_internal.m43_field_kind('rule', 'spec.on_activate') <> 'function_identity'
       OR pgreact_internal.m43_field_kind('decision_program', 'spec.results') <> 'result_binding' THEN
        RAISE EXCEPTION 'M43 field inventory mismatch for opaque categories';
    END IF;
    deployed := pgreact_api.declaration('rule', 'm43-payment-review', jsonb_build_object(
        'condition', 'm43_reference.payments', 'semantic_key', 'payment_id',
        'kind', 'CONSTRAINT', 'salience', 10));
    PERFORM pgreact_api.deploy(deployed);
    proposed := pgreact_api.declaration('rule', 'm43-payment-review', jsonb_build_object(
        'condition', '"m43_reference"."payments"', 'semantic_key', 'payment_id',
        'kind', 'CONSTRAINT', 'salience', 30));
    SELECT count(*) INTO before_count FROM pgreact_internal.api_declarations;
    result := pgreact_api.semantic_diff(
        proposed, pgreact_api.target('rule', 'm43-payment-review', '1'));
    SELECT count(*) INTO after_count FROM pgreact_internal.api_declarations;
    expected := jsonb_build_object(
        'field_path', 'spec.salience', 'field_kind', 'scalar', 'change_kind', 'changed',
        'before', jsonb_build_object('type', 'number', 'json_type', 'number', 'present', true, 'value', 10),
        'after', jsonb_build_object('type', 'number', 'json_type', 'number', 'present', true, 'value', 30),
        'complete', true);
    IF result ->> 'contract_version' <> '43'
       OR result ->> 'operation' <> 'semantic_diff'
       OR result ->> 'state' <> 'complete'
       OR result -> 'target' <> '{"kind":"rule","name":"m43-payment-review","version":"1"}'::jsonb
       OR jsonb_array_length(result -> 'differences') <> 1
       OR result -> 'differences' -> 0 IS DISTINCT FROM expected
       OR result ->> 'proposed_declaration_digest' IS NULL
       OR result ->> 'deployed_declaration_digest' IS NULL
       OR result -> 'completeness' ->> 'complete' <> 'true'
       OR result ->> 'read_only' <> 'true'
       OR result ->> 'truncated' <> 'false'
       OR result -> 'cost' ->> 'fields_compared' <> '5'
       OR before_count <> after_count
       OR result ->> 'semantic_digest' IS DISTINCT FROM pgreact_internal.m43_digest(
           jsonb_build_object(
               'target', result -> 'target',
               'proposed_declaration_digest', result -> 'proposed_declaration_digest',
               'deployed_declaration_digest', result -> 'deployed_declaration_digest',
               'differences', result -> 'differences', 'opaque', result -> 'opaque',
               'completeness', result -> 'completeness')) THEN
        RAISE EXCEPTION 'M43 rule semantic diff mismatch: %', result;
    END IF;

    result := pgreact_api.semantic_diff(
        pgreact_api.declaration('rule', 'm43-payment-review', jsonb_build_object(
            'condition', 'm43_reference.payments', 'semantic_key', 'payment_id',
            'salience', 10)),
        pgreact_api.target('rule', 'm43-payment-review', '1'));
    IF result ->> 'state' <> 'complete'
       OR result -> 'differences' <> '[]'::jsonb
       OR result -> 'findings' -> 0 ->> 'code' <> 'M43_NO_DIFFERENCE' THEN
        RAISE EXCEPTION 'M43 normalized equivalent mismatch: %', result;
    END IF;

    result := pgreact_api.semantic_diff(
        pgreact_api.declaration('rule', 'm43-payment-review', jsonb_build_object(
            'condition', 'm43_reference.payments', 'semantic_key', 'payment_id',
            'salience', 20, 'agenda_group', 'review')),
        pgreact_api.target('rule', 'm43-payment-review', '1'),
        jsonb_build_object('max_differences', 1));
    IF result ->> 'state' <> 'partial'
       OR result -> 'limits' -> 'reached' IS DISTINCT FROM '["max_differences"]'::jsonb
       OR result -> 'findings' -> -1 ->> 'code' <> 'M43_LIMIT' THEN
        RAISE EXCEPTION 'M43 difference limit mismatch: %', result;
    END IF;

    CREATE OR REPLACE VIEW m43_reference.payments AS
    SELECT payment_id, state || '' AS state
    FROM m43_reference.payment_rows;
    result := pgreact_api.semantic_diff(
        pgreact_api.declaration('rule', 'm43-payment-review', jsonb_build_object(
            'condition', 'm43_reference.payments', 'semantic_key', 'payment_id',
            'salience', 10)),
        pgreact_api.target('rule', 'm43-payment-review', '1'));
    IF result ->> 'state' <> 'complete'
       OR result -> 'differences' <> '[]'::jsonb
       OR jsonb_array_length(result -> 'opaque') <> 1
       OR result -> 'opaque' -> 0 ->> 'field_path' <> 'spec.condition'
       OR result -> 'opaque' -> 0 ->> 'field_kind' <> 'relation_identity'
       OR result -> 'opaque' -> 0 ->> 'change_kind' <> 'opaque'
       OR result -> 'opaque' -> 0 ->> 'identity' <> 'm43_reference.payments'
       OR result -> 'opaque' -> 0 ->> 'before_digest' IS NULL
       OR result -> 'opaque' -> 0 ->> 'after_digest' IS NULL
       OR result -> 'findings' -> 0 ->> 'code' <> 'M43_OPAQUE_CHANGE' THEN
        RAISE EXCEPTION 'M43 opaque evidence mismatch: %', result;
    END IF;
END
$m43$;

DO $m43$
DECLARE deployed pgreact_api.declaration;
    proposed pgreact_api.declaration;
    result jsonb;
    version_preview jsonb;
BEGIN
    deployed := pgreact_api.declaration('decision_program', 'm43-routing', jsonb_build_object(
        'candidate_relation', 'm43_reference.routes', 'subject_key', 'account_id',
        'candidate_key', 'route_id', 'priority', 'priority',
        'results', jsonb_build_array('result'), 'valid_from', '2026-01-01 00:00:00+00'));
    version_preview := pgreact_api.preview(deployed);
    PERFORM pgreact_api.deploy(deployed, jsonb_build_object(
        'preview_digest', version_preview -> 'summary' ->> 'preview_digest'));
    proposed := pgreact_api.declaration('decision_program', 'm43-routing', jsonb_build_object(
        'candidate_relation', '"m43_reference"."routes"', 'subject_key', 'account_id',
        'candidate_key', 'route_id', 'priority', 'priority',
        'results', jsonb_build_array('result', 'state'),
        'valid_from', '2026-02-01 00:00:00+00', 'valid_to', '2026-12-31 00:00:00+00'));
    result := pgreact_api.semantic_diff(
        proposed, pgreact_api.target('decision_program', 'm43-routing', '1'));
    IF result ->> 'state' <> 'complete'
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'differences') d
                      WHERE d ->> 'field_path' = 'spec.results'
                        AND d ->> 'field_kind' = 'result_binding'
                        AND d ->> 'change_kind' = 'changed'
                        AND d -> 'before' ->> 'type' = 'jsonb_array')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'differences') d
                      WHERE d ->> 'field_path' = 'spec.valid_from'
                        AND d ->> 'field_kind' = 'time_bound')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'differences') d
                      WHERE d ->> 'field_path' = 'spec.valid_to'
                        AND d ->> 'change_kind' = 'added') THEN
        RAISE EXCEPTION 'M43 decision semantic diff mismatch: %', result;
    END IF;
END
$m43$;

DO $m43$
DECLARE member pgreact_api.declaration;
    deployed pgreact_api.declaration;
    proposed pgreact_api.declaration;
    result jsonb;
BEGIN
    member := pgreact_api.declaration('rule', 'm43-account-control', jsonb_build_object(
        'condition', 'm43_reference.account_conditions', 'semantic_key', 'account_id'));
    PERFORM pgreact_api.deploy(member);
    deployed := pgreact.policy_set(
        'm43-controls', '2026-08', ARRAY[member], 'm43_reference.accounts'::regclass,
        ARRAY['account_id'::name], '2026-01-01 00:00:00+00');
    PERFORM pgreact_api.deploy(deployed);
    proposed := pgreact_api.declaration('policy_set', 'm43-controls', jsonb_build_object(
        'version', '2026-09',
        'members', jsonb_build_array(
            jsonb_build_object('version','1','name','m43-account-control','kind','rule',
                               'match_keys', jsonb_build_array('account_id'),
                               'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind','relation', 'relation','"m43_reference"."accounts_next"',
            'subject_key','account_id'),
        'valid_from', '2026-01-01 00:00:00+00'));
    result := pgreact_api.semantic_diff(
        proposed, pgreact_api.target('policy_set', 'm43-controls', '2026-08'));
    IF result ->> 'state' <> 'complete'
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'differences') d
                      WHERE d ->> 'field_path' = 'spec.applicability.relation'
                        AND d ->> 'field_kind' = 'relation_identity'
                        AND d ->> 'change_kind' = 'changed')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'differences') d
                      WHERE d ->> 'field_path' = 'spec.version'
                        AND d ->> 'change_kind' = 'changed')
       OR result ->> 'read_only' <> 'true' THEN
        RAISE EXCEPTION 'M43 policy-set semantic diff mismatch: %', result;
    END IF;
END
$m43$;

DO $m43$
DECLARE result jsonb;
BEGIN
    result := pgreact_api.semantic_diff(
        pgreact_api.declaration('rule', 'm43-never-deployed', jsonb_build_object(
            'condition', 'm43_reference.payments', 'semantic_key', 'payment_id')),
        pgreact_api.target('rule', 'm43-never-deployed', '1'));
    IF result ->> 'state' <> 'unavailable'
       OR result ->> 'target' IS NOT NULL
       OR result -> 'differences' <> '[]'::jsonb
       OR result -> 'opaque' <> '[]'::jsonb
       OR result -> 'findings' -> 0 ->> 'code' <> 'M43_TARGET_UNAVAILABLE' THEN
        RAISE EXCEPTION 'M43 fail-closed mismatch: %', result;
    END IF;
END
$m43$;
