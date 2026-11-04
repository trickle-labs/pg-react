ALTER TABLE pgreact_mdm.policy_intent_bindings
    ADD COLUMN policy_revision text,
    ADD COLUMN allowed_actions text[];
UPDATE pgreact_mdm.policy_intent_bindings
SET policy_revision = 'policy-a', allowed_actions = ARRAY['SET_DUE_AT']::text[]
WHERE binding_id = '00000000-0000-0000-0000-000000000001';
UPDATE pgreact_mdm.policy_intent_bindings
SET policy_revision = 'policy-b', allowed_actions = ARRAY[]::text[]
WHERE binding_id = '00000000-0000-0000-0000-000000000002';

ALTER TABLE mdm_steward.policy_cases_v1
    ADD COLUMN permitted_actions text[],
    ADD COLUMN due_at timestamptz,
    ADD COLUMN opened_at timestamptz,
    ADD COLUMN opened_at_source text;
UPDATE mdm_steward.policy_cases_v1
SET permitted_actions = ARRAY['SET_DUE_AT']::text[],
    due_at = clock_timestamp() - interval '1 hour',
    opened_at = clock_timestamp() - interval '2 hours',
    opened_at_source = 'publication'
WHERE entity_name = 'entity_a' AND case_key = 101;
UPDATE mdm_steward.policy_cases_v1
SET permitted_actions = ARRAY['SET_DUE_AT']::text[], opened_at_source = 'publication'
WHERE entity_name = 'entity_a' AND case_key = 102;
UPDATE mdm_steward.policy_cases_v1
SET permitted_actions = ARRAY['SET_DUE_AT']::text[],
    opened_at = clock_timestamp() - interval '2 hours',
    opened_at_source = 'publication'
WHERE entity_name = 'entity_a' AND case_key = 103;
UPDATE mdm_steward.policy_cases_v1
SET permitted_actions = ARRAY[]::text[], opened_at_source = 'unknown'
WHERE entity_name = 'entity_b';

ALTER TABLE pgreact.work ADD COLUMN name text;
UPDATE pgreact.work SET name = 'mdm-route';
INSERT INTO pgreact.work (kind, work_id, state, name) VALUES
    ('rule', '204', 'RETRY_WAIT', 'mdm-route'),
    ('rule', '205', 'LEASED', 'mdm-route');

CREATE TABLE pgreact.attempts (
    episode_id bigint NOT NULL,
    started_at timestamptz NOT NULL,
    status text NOT NULL,
    error_code text
);
INSERT INTO pgreact.attempts VALUES
    (204, clock_timestamp() - interval '1 minute', 'FAILED', 'WORKER_TIMEOUT');

CREATE TABLE pgreact.operational_status (
    rule_name text NOT NULL,
    state text NOT NULL,
    outstanding_episodes bigint NOT NULL,
    oldest_eligible_at timestamptz,
    failed_episodes bigint NOT NULL,
    claims_blocked boolean NOT NULL
);
INSERT INTO pgreact.operational_status VALUES
    ('mdm-route', 'ACTIVE', 3, '2026-11-04 10:00:00+00', 1, false);

CREATE FUNCTION pgreact_mdm.deadline_preview(
    source_relation regclass,
    target_revision text,
    captured_at timestamptz,
    target_entity text
)
RETURNS TABLE(case_key bigint, existing_due_at timestamptz, decision text)
LANGUAGE sql
STABLE
AS $function$
    SELECT policy_case.case_key, policy_case.due_at,
           CASE WHEN policy_case.due_at IS NULL THEN 'PROPOSED' ELSE 'PRESERVED' END
    FROM mdm_steward.policy_cases_v1 AS policy_case
    WHERE policy_case.entity_name::text = target_entity
$function$;

INSERT INTO pgreact_mdm.intent_attempts VALUES
    (202, 1, '00000000-0000-0000-0000-000000000001', decode(repeat('02', 32), 'hex'),
     '2026-11-04 10:04:00+00', 'STALE_CASE', 'STALE_CASE', NULL);
