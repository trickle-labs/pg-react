\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m31_authorization_reference;
CREATE TABLE m31_authorization_reference.facts(
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL);
CREATE VIEW m31_authorization_reference.facts_match AS
SELECT order_id, customer_id FROM m31_authorization_reference.facts;
CREATE TABLE m31_authorization_reference.customer_gate(
    customer_id bigint PRIMARY KEY);
INSERT INTO m31_authorization_reference.facts VALUES (1, 7);
INSERT INTO m31_authorization_reference.customer_gate VALUES (7);

DO $m31_authorization_roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm31auth_runtime') THEN
        CREATE ROLE m31auth_runtime NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm31auth_author') THEN
        CREATE ROLE m31auth_author NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm31auth_worker') THEN
        CREATE ROLE m31auth_worker NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm31auth_reader') THEN
        CREATE ROLE m31auth_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm31auth_advanced') THEN
        CREATE ROLE m31auth_advanced NOLOGIN;
    END IF;
END
$m31_authorization_roles$;
SELECT pgreact_api.configure_roles(
    'm31auth_author', 'm31auth_runtime', 'm31auth_worker',
    'm31auth_reader', 'm31auth_advanced');
GRANT USAGE ON SCHEMA m31_authorization_reference TO m31auth_runtime;
GRANT SELECT ON m31_authorization_reference.facts_match,
    m31_authorization_reference.customer_gate TO m31auth_runtime;

DO $m31_authorization_setup$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    preview jsonb;
    deployed jsonb;
BEGIN
    member := pgreact_api.declaration('rule', 'm31-authorization-rule', jsonb_build_object(
        'condition', 'm31_authorization_reference.facts_match',
        'semantic_key', 'order_id', 'kind', 'CONSTRAINT', 'delegate', true));
    preview := pgreact_api.preview(member);
    deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 authorization rule deployment changed: %', deployed;
    END IF;
    policy_set := pgreact_api.declaration('policy_set', 'm31-authorization-set',
        jsonb_build_object(
            'version', '1',
            'members', jsonb_build_array(jsonb_build_object(
                'kind', 'rule', 'name', 'm31-authorization-rule', 'version', '1',
                'match_keys', jsonb_build_array('order_id'),
                'subject_keys', jsonb_build_array('customer_id'),
                'scope_mode', 'POLICY_SET_REQUIRED')),
            'applicability', jsonb_build_object(
                'source_kind', 'relation',
                'relation', 'm31_authorization_reference.customer_gate',
                'subject_keys', jsonb_build_array('customer_id')),
            'valid_from', '2026-01-01 00:00:00+00'));
    preview := pgreact_api.preview(policy_set);
    deployed := pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 authorization policy-set deployment changed: %', deployed;
    END IF;
END
$m31_authorization_setup$;

REVOKE SELECT ON m31_authorization_reference.customer_gate FROM m31auth_runtime;
SET SESSION AUTHORIZATION m31auth_runtime;
DO $m31_authorization_unauthorized$
DECLARE runtime jsonb;
    barrier_code text;
BEGIN
    runtime := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-authorization-set', '1'),
        '2026-01-01 00:00:00+00');
    SELECT barrier.code INTO barrier_code
    FROM pgreact.policy_set_runtime_barriers barrier
    WHERE barrier.set_name = 'm31-authorization-set'
      AND barrier.cleared_at IS NULL;
    IF runtime -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR barrier_code <> 'M31_SOURCE_UNAUTHORIZED' THEN
        RAISE EXCEPTION 'M31 unauthorized source did not fail closed: % / %',
            runtime, barrier_code;
    END IF;
END
$m31_authorization_unauthorized$;
RESET SESSION AUTHORIZATION;

GRANT SELECT ON m31_authorization_reference.customer_gate TO m31auth_runtime;
ALTER TABLE m31_authorization_reference.customer_gate ENABLE ROW LEVEL SECURITY;
SET SESSION AUTHORIZATION m31auth_runtime;
DO $m31_authorization_rls$
DECLARE runtime jsonb;
    barrier_code text;
BEGIN
    runtime := pgreact_api.run(
        pgreact_api.target('policy_set', 'm31-authorization-set', '1'),
        '2026-01-01 00:00:00+00');
    SELECT barrier.code INTO barrier_code
    FROM pgreact.policy_set_runtime_barriers barrier
    WHERE barrier.set_name = 'm31-authorization-set'
      AND barrier.cleared_at IS NULL;
    IF runtime -> 'runtime' ->> 'runtime_state' <> 'BLOCKED'
       OR barrier_code <> 'M31_SOURCE_RLS_PROTECTED' THEN
        RAISE EXCEPTION 'M31 RLS source did not fail closed: % / %',
            runtime, barrier_code;
    END IF;
END
$m31_authorization_rls$;
RESET SESSION AUTHORIZATION;

SELECT 'M31 authorization and protected-source matrix passed' AS result;
