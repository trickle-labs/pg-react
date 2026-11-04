\set ON_ERROR_STOP on
-- Run with a superuser in a fresh disposable PostgreSQL database.

CREATE SCHEMA pgreact_mdm;
CREATE SCHEMA mdm_steward;
CREATE SCHEMA pgreact;
CREATE ROLE v050_entity_a NOLOGIN;
CREATE ROLE v050_entity_b NOLOGIN;
CREATE ROLE v050_entity_a_login LOGIN INHERIT;
CREATE ROLE v050_unrelated_login LOGIN;
GRANT v050_entity_a TO v050_entity_a_login;
GRANT USAGE ON SCHEMA pgreact_mdm TO v050_entity_a_login, v050_unrelated_login;

CREATE TABLE pgreact_mdm.policy_intent_bindings (
    binding_id uuid PRIMARY KEY,
    entity_name name NOT NULL,
    entity_execution_role name NOT NULL
);
CREATE TABLE pgreact_mdm.intent_requests (
    binding_id uuid NOT NULL,
    request_key bytea NOT NULL,
    work_ref text NOT NULL,
    case_key bigint NOT NULL,
    request_body jsonb NOT NULL,
    escalation_level integer NOT NULL,
    created_at timestamptz NOT NULL,
    first_episode_id bigint NOT NULL,
    policy_revision text NOT NULL,
    action_revision bigint NOT NULL
);
CREATE TABLE pgreact_mdm.intent_attempts (
    episode_id bigint NOT NULL,
    attempt_no integer NOT NULL,
    binding_id uuid NOT NULL,
    request_key bytea NOT NULL,
    attempted_at timestamptz NOT NULL,
    outcome text NOT NULL,
    reason_code text,
    receipt_id uuid
);
CREATE TABLE pgreact_mdm.intent_holds (
    binding_id uuid NOT NULL,
    case_key bigint NOT NULL,
    policy_revision text NOT NULL,
    action text NOT NULL,
    expected_action_revision bigint NOT NULL,
    reason_code text NOT NULL,
    held_at timestamptz NOT NULL
);
CREATE TABLE pgreact.work (
    kind text NOT NULL,
    work_id text NOT NULL,
    state text NOT NULL
);
CREATE TABLE mdm_steward.policy_receipts_v1 (
    receipt_id uuid PRIMARY KEY,
    outcome text NOT NULL,
    reason_code text,
    resulting_publication_revision bigint
);
CREATE TABLE mdm_steward.policy_cases_v1 (
    entity_name name NOT NULL,
    case_key bigint NOT NULL,
    status text NOT NULL,
    publication_revision bigint NOT NULL,
    pending_stewardship boolean NOT NULL
);

INSERT INTO pgreact_mdm.policy_intent_bindings VALUES
    ('00000000-0000-0000-0000-000000000001', 'entity_a', 'v050_entity_a'),
    ('00000000-0000-0000-0000-000000000002', 'entity_b', 'v050_entity_b');
INSERT INTO pgreact_mdm.intent_requests VALUES
    ('00000000-0000-0000-0000-000000000001', decode(repeat('01', 32), 'hex'),
     'work-a-applied', 101, '{"action":"ESCALATE","arguments":{"level":1},"private":"omit"}',
     1, '2026-11-04 10:00:00+00', 201, 'policy-a', 3),
    ('00000000-0000-0000-0000-000000000001', decode(repeat('02', 32), 'hex'),
     'work-a-held', 102, '{"action":"SET_DUE_AT","arguments":{"due_at":"2026-11-05T00:00:00Z"}}',
     0, '2026-11-04 10:01:00+00', 202, 'policy-a', 4),
    ('00000000-0000-0000-0000-000000000002', decode(repeat('03', 32), 'hex'),
     'work-b-hidden', 201, '{"action":"ESCALATE","arguments":{"level":2}}',
     2, '2026-11-04 10:02:00+00', 203, 'policy-b', 5);
INSERT INTO pgreact_mdm.intent_attempts VALUES
    (201, 1, '00000000-0000-0000-0000-000000000001', decode(repeat('01', 32), 'hex'),
     '2026-11-04 10:03:00+00', 'APPLIED_CONTROL', NULL,
     '10000000-0000-0000-0000-000000000001');
INSERT INTO pgreact_mdm.intent_holds VALUES
    ('00000000-0000-0000-0000-000000000001', 102, 'policy-a', 'SET_DUE_AT', 4,
     'BINDING_PAUSED', '2026-11-04 10:04:00+00');
INSERT INTO pgreact.work VALUES ('rule', '201', 'COMPLETED'), ('rule', '202', 'PENDING');
INSERT INTO mdm_steward.policy_receipts_v1 VALUES
    ('10000000-0000-0000-0000-000000000001', 'APPLIED_CONTROL', 'CONTROL_APPLIED', NULL);
INSERT INTO mdm_steward.policy_cases_v1 VALUES
    ('entity_a', 101, 'open', 6, false),
    ('entity_a', 102, 'open', 5, true),
    ('entity_b', 201, 'open', 3, false);

\ir ../../../integrations/pg-mdm/sql/operational-activity.sql

CREATE TEMP TABLE v050_activity_assertions (scenario text, actual jsonb);
GRANT INSERT, SELECT ON v050_activity_assertions TO PUBLIC;

SET SESSION AUTHORIZATION v050_entity_a_login;
INSERT INTO v050_activity_assertions
SELECT 'authorized entity sees only its exact public projection',
       coalesce(jsonb_agg(to_jsonb(activity) ORDER BY activity.work_ref), '[]'::jsonb)
FROM pgreact_mdm.operational_activity_v1 AS activity;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION v050_unrelated_login;
INSERT INTO v050_activity_assertions
SELECT 'unrelated role sees no rows',
       coalesce(jsonb_agg(to_jsonb(activity)), '[]'::jsonb)
FROM pgreact_mdm.operational_activity_v1 AS activity;
RESET SESSION AUTHORIZATION;

DO $assertions$
DECLARE
    authorized jsonb;
    unauthorized jsonb;
BEGIN
    SELECT actual INTO STRICT authorized
    FROM v050_activity_assertions
    WHERE scenario = 'authorized entity sees only its exact public projection';
    IF authorized <> jsonb_build_array(
        jsonb_build_object(
            'binding_id', '00000000-0000-0000-0000-000000000001'::uuid,
            'entity_name', 'entity_a',
            'work_ref', 'work-a-applied',
            'case_key', 101,
            'action', 'ESCALATE',
            'escalation_level', 1,
            'requested_due_at', NULL,
            'requested_at', '2026-11-04 10:00:00+00'::timestamptz,
            'react_episode_id', 201,
            'react_work_state', 'COMPLETED',
            'attempt_no', 1,
            'attempted_at', '2026-11-04 10:03:00+00'::timestamptz,
            'delivery_outcome', 'APPLIED_CONTROL',
            'delivery_reason_code', NULL,
            'remediation_state', 'NONE',
            'remediation_reason_code', NULL,
            'mdm_receipt_id', '10000000-0000-0000-0000-000000000001'::uuid,
            'mdm_receipt_retained', true,
            'mdm_outcome', 'APPLIED_CONTROL',
            'mdm_reason_code', 'CONTROL_APPLIED',
            'resulting_publication_revision', NULL,
            'current_case_status', 'open',
            'current_publication_revision', 6,
            'current_pending_stewardship', false
        ),
        jsonb_build_object(
            'binding_id', '00000000-0000-0000-0000-000000000001'::uuid,
            'entity_name', 'entity_a',
            'work_ref', 'work-a-held',
            'case_key', 102,
            'action', 'SET_DUE_AT',
            'escalation_level', 0,
            'requested_due_at', '2026-11-05 00:00:00+00'::timestamptz,
            'requested_at', '2026-11-04 10:01:00+00'::timestamptz,
            'react_episode_id', 202,
            'react_work_state', 'PENDING',
            'attempt_no', NULL,
            'attempted_at', NULL,
            'delivery_outcome', 'PENDING',
            'delivery_reason_code', NULL,
            'remediation_state', 'HELD',
            'remediation_reason_code', 'BINDING_PAUSED',
            'mdm_receipt_id', NULL,
            'mdm_receipt_retained', false,
            'mdm_outcome', NULL,
            'mdm_reason_code', NULL,
            'resulting_publication_revision', NULL,
            'current_case_status', 'open',
            'current_publication_revision', 5,
            'current_pending_stewardship', true
        )
    ) THEN
        RAISE EXCEPTION 'authorized projection did not match its complete expected output: %', authorized;
    END IF;

    SELECT actual INTO STRICT unauthorized
    FROM v050_activity_assertions
    WHERE scenario = 'unrelated role sees no rows';
    IF unauthorized <> '[]'::jsonb THEN
        RAISE EXCEPTION 'unrelated role saw operational rows: %', unauthorized;
    END IF;
END
$assertions$;

SELECT scenario FROM v050_activity_assertions ORDER BY scenario;
