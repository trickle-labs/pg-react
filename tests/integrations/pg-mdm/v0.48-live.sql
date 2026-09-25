\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
DO $runner$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'mdm_m2_runner') THEN
        CREATE ROLE mdm_m2_runner LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT
            NOCREATEDB NOCREATEROLE NOREPLICATION;
    END IF;
END
$runner$;
ALTER ROLE mdm_m2_runner LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT
    NOCREATEDB NOCREATEROLE NOREPLICATION;
\ir ../../../integrations/pg-mdm/sql/request-store.sql
\ir ../../../integrations/pg-mdm/sql/intent-worker.sql
GRANT pgreact_mdm_worker TO mdm_m2_runner WITH SET TRUE, INHERIT FALSE;
GRANT USAGE ON SCHEMA pgreact_mdm
    TO mdm_legacy_administrator, mdm_administrator;
SELECT pgreact_mdm.configure_intent_deployer('mdm_m2_runner');
CREATE EXTENSION IF NOT EXISTS dblink;

SELECT case_row.entity_name::text AS queue_entity_name,
       entity.execution_role_name AS queue_entity_execution_role,
       case_row.reason_code AS queue_reason_code
FROM mdm_steward.policy_cases_v1 AS case_row
JOIN mdm_internal.entities AS entity
  ON entity.entity_name = case_row.entity_name
WHERE case_row.status = 'open'
  AND case_row.entity_name = 'review_admission_live'
  AND NOT case_row.pending_stewardship
  AND NOT case_row.manual_assignment_protected
  AND 'ASSIGN_QUEUE' = ANY(case_row.permitted_actions)
  AND case_row.assigned_queue IS DISTINCT FROM 'm2-ready'::name
ORDER BY case_row.case_key
LIMIT 1
\gset

SELECT case_row.entity_name::text AS escalation_entity_name,
       entity.execution_role_name AS escalation_entity_execution_role,
       case_row.reason_code AS escalation_reason,
       case_row.case_key AS escalation_case_key
FROM mdm_steward.policy_cases_v1 AS case_row
JOIN mdm_internal.entities AS entity
  ON entity.entity_name = case_row.entity_name
WHERE case_row.entity_name = 'policy_qualification'
  AND case_row.status = 'open'
  AND NOT case_row.pending_stewardship
  AND case_row.due_at < statement_timestamp()
  AND case_row.opened_at IS NOT NULL
  AND case_row.escalation_level = 1
  AND 'ESCALATE' = ANY(case_row.permitted_actions)
ORDER BY case_row.case_key
LIMIT 1
\gset

SELECT pgreact_mdm.publish_intent_package(
    'v0.48-live-policy',
    jsonb_build_object(
        'deadline', jsonb_build_object(
            'duration_seconds', 86400, 'min_seconds', 60, 'max_seconds', 86400,
            'replace_existing_deadline', false),
        'routes', jsonb_build_array(
            jsonb_build_object(
                'reason_code', :'queue_reason_code', 'entity_name', :'queue_entity_name',
                'queue', 'm2-ready', 'priority', 0),
            jsonb_build_object(
                'reason_code', :'escalation_reason', 'entity_name', :'escalation_entity_name',
                'action', 'ESCALATE', 'level', 2, 'priority', 0)))) AS publication;

SET SESSION AUTHORIZATION mdm_m2_runner;
DO $deploy$
DECLARE
    declaration pgreact_api.declaration;
    preview jsonb;
    review text;
BEGIN
    declaration := pgreact_mdm.intent_declaration(
        'v0.48-live-worker', 'pgreact_mdm.intent_deployer_policy_cases_v1'::regclass,
        statement_timestamp());
    preview := pgreact.preview(declaration);
    review := pgreact.review_token(preview);
    PERFORM pgreact.deploy(declaration, review);
END
$deploy$;
RESET SESSION AUTHORIZATION;
SELECT pgreact_mdm.configure_intent_deployer('mdm_m2_runner');
DO $dispatcher_owner$
DECLARE
    worker_oid oid;
    runner_oid oid;
BEGIN
    SELECT oid INTO STRICT worker_oid
    FROM pg_catalog.pg_roles WHERE rolname = 'pgreact_mdm_worker';
    SELECT oid INTO STRICT runner_oid
    FROM pg_catalog.pg_roles WHERE rolname = 'mdm_m2_runner';
    IF (SELECT count(*) FROM pgreact.rules
        WHERE rule_name IN (
            'v0.48-live-worker-queue',
            'v0.48-live-worker-due',
            'v0.48-live-worker-escalation')
          AND state = 'ACTIVE') <> 3
       OR EXISTS (
           SELECT 1
           FROM pgreact.rules AS rule
           JOIN pgreact_internal.rule_versions AS version USING (rule_version_id)
           JOIN pg_catalog.pg_proc AS dispatcher
             ON dispatcher.oid = version.dispatcher_oid
           WHERE rule.rule_name IN (
               'v0.48-live-worker-queue',
               'v0.48-live-worker-due',
               'v0.48-live-worker-escalation')
             AND (version.owner_oid <> runner_oid
                  OR dispatcher.proowner <> worker_oid
                  OR NOT dispatcher.prosecdef)) THEN
        RAISE EXCEPTION 'runner must own reviewed rules while the worker owns their episode dispatchers';
    END IF;
END
$dispatcher_owner$;

SET SESSION AUTHORIZATION mdm_test_login;
SET ROLE :"queue_entity_execution_role";
SELECT binding_id AS v048_policy_binding_id, binding_version AS v048_policy_binding_version
FROM pgreact_mdm.create_intent_binding(
    :'queue_entity_name', 'v0.48-live-policy',
    ARRAY['ASSIGN_QUEUE']::text[],
    ARRAY['m2-ready']::text[], NULL, 0)
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE :"escalation_entity_execution_role";
SELECT binding_id AS v048_escalation_binding_id,
       binding_version AS v048_escalation_binding_version
FROM pgreact_mdm.create_intent_binding(
    :'escalation_entity_name', 'v0.48-live-policy',
    ARRAY['ESCALATE', 'SET_DUE_AT']::text[], ARRAY[]::text[], interval '1 day', 2)
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

CREATE TEMP TABLE v048_expected_intents AS
SELECT 'ASSIGN_QUEUE'::text AS action, intent.case_key, intent.arguments,
       intent.binding_id, binding.entity_name
FROM pgreact_mdm.intent_queue_candidates AS intent
JOIN pgreact_mdm.policy_intent_bindings AS binding USING (binding_id)
UNION ALL
SELECT 'SET_DUE_AT', intent.case_key, intent.arguments,
       intent.binding_id, binding.entity_name
FROM pgreact_mdm.intent_due_candidates AS intent
JOIN pgreact_mdm.policy_intent_bindings AS binding USING (binding_id)
UNION ALL
SELECT 'ESCALATE', intent.case_key, intent.arguments,
       intent.binding_id, binding.entity_name
FROM pgreact_mdm.intent_escalation_candidates AS intent
JOIN pgreact_mdm.policy_intent_bindings AS binding USING (binding_id);

DO $limits$
DECLARE
    active_binding uuid;
    escalation_binding uuid;
    queues text[];
    due_limit interval;
    escalation_limit integer;
BEGIN
    SELECT binding_id, allowed_queues
    INTO STRICT active_binding, queues
    FROM pgreact_mdm.policy_intent_bindings
    WHERE policy_revision = 'v0.48-live-policy'
      AND entity_name = 'review_admission_live' AND enabled;
    SELECT binding_id, max_due_interval, max_escalation_level
    INTO STRICT escalation_binding, due_limit, escalation_limit
    FROM pgreact_mdm.policy_intent_bindings
    WHERE policy_revision = 'v0.48-live-policy'
      AND entity_name = 'policy_qualification' AND enabled;
    IF NOT EXISTS (SELECT 1 FROM v048_expected_intents WHERE action = 'ASSIGN_QUEUE')
       OR NOT EXISTS (SELECT 1 FROM v048_expected_intents WHERE action = 'SET_DUE_AT')
       OR NOT EXISTS (SELECT 1 FROM v048_expected_intents WHERE action = 'ESCALATE') THEN
        RAISE EXCEPTION 'fixture must provide a candidate for each bounded intent';
    END IF;

    UPDATE pgreact_mdm.policy_intent_bindings
    SET allowed_queues = ARRAY['not-allowed']::text[]
    WHERE binding_id = active_binding;
    IF EXISTS (SELECT 1 FROM pgreact_mdm.intent_queue_candidates) THEN
        RAISE EXCEPTION 'worker ignored the configured queue allowlist';
    END IF;
    UPDATE pgreact_mdm.policy_intent_bindings
    SET allowed_queues = queues
    WHERE binding_id = active_binding;

    UPDATE pgreact_mdm.policy_intent_bindings
    SET max_due_interval = interval '1 second'
    WHERE binding_id = escalation_binding;
    IF EXISTS (SELECT 1 FROM pgreact_mdm.intent_due_candidates) THEN
        RAISE EXCEPTION 'worker ignored the configured due-date limit';
    END IF;
    UPDATE pgreact_mdm.policy_intent_bindings
    SET max_due_interval = due_limit
    WHERE binding_id = escalation_binding;

    UPDATE pgreact_mdm.policy_intent_bindings
    SET max_escalation_level = 0
    WHERE binding_id = escalation_binding;
    IF EXISTS (SELECT 1 FROM pgreact_mdm.intent_escalation_candidates) THEN
        RAISE EXCEPTION 'worker ignored the configured escalation limit';
    END IF;
    UPDATE pgreact_mdm.policy_intent_bindings
    SET max_escalation_level = escalation_limit
    WHERE binding_id = escalation_binding;
END
$limits$;

BEGIN;
DO $missing_receipt_recovery$
DECLARE
    queue_candidate pgreact_mdm.intent_queue_candidates%ROWTYPE;
    binding pgreact_mdm.policy_intent_bindings%ROWTYPE;
    policy_case pgreact_mdm.authorized_policy_cases_v1%ROWTYPE;
    deployer_case pgreact_mdm.intent_deployer_policy_cases_v1%ROWTYPE;
    context pgreact.activation_context;
    context_rule_id uuid;
    context_rule_version_id uuid;
    work_ref text;
    synthetic_request_key bytea;
    request_body jsonb;
    request_digest bytea;
    fake_receipt_id uuid := '00000000-0000-0000-0000-000000000001';
    control_before jsonb;
    control_after jsonb;
    retained_request pgreact_mdm.intent_requests%ROWTYPE;
    blocked_attempt pgreact_mdm.intent_attempts%ROWTYPE;
BEGIN
    SELECT * INTO STRICT queue_candidate
    FROM pgreact_mdm.intent_queue_candidates
    ORDER BY case_key
    LIMIT 1;
    SELECT * INTO STRICT binding
    FROM pgreact_mdm.policy_intent_bindings
    WHERE binding_id = queue_candidate.binding_id;
    SELECT * INTO STRICT policy_case
    FROM pgreact_mdm.authorized_policy_cases_v1
    WHERE case_key = queue_candidate.case_key
      AND entity_name = binding.entity_name;
    PERFORM pgreact_mdm.sync_intent_case_identities();
    SELECT * INTO STRICT deployer_case
    FROM pgreact_mdm.intent_deployer_policy_cases_v1
    WHERE case_key = queue_candidate.case_key
      AND entity_name = binding.entity_name;
    SELECT rule.rule_id, rule.rule_version_id
    INTO STRICT context_rule_id, context_rule_version_id
    FROM pgreact.rules AS rule
    WHERE rule.rule_name = 'v0.48-live-worker-queue'
      AND rule.state = 'ACTIVE';

    context := ROW(
        '00000000-0000-0000-0000-000000000048'::uuid,
        900000048::bigint,
        context_rule_id,
        context_rule_version_id,
        1::bigint,
        1::bigint,
        'INSERT'::text,
        2::integer,
        statement_timestamp(),
        'v0.48-missing-receipt'::text,
        'v0.48-missing-receipt'::text
    )::pgreact.activation_context;
    work_ref := 'pgreact:' || context_rule_version_id::text || ':' ||
                (context).episode_id::text;
    synthetic_request_key := pgreact_mdm.intent_request_key(
        binding.binding_id, binding.policy_revision, policy_case.case_key,
        (context).generation, policy_case.action_revision,
        queue_candidate.consequence_identity, queue_candidate.escalation_level);
    request_body := pgreact_mdm.intent_request_body(
        binding.binding_id, policy_case.case_key, queue_candidate.action,
        queue_candidate.arguments, policy_case.review_version,
        policy_case.definition_version, policy_case.publication_revision,
        policy_case.stewardship_epoch, policy_case.evidence_basis_digest,
        policy_case.action_revision, binding.policy_digest,
        binding.policy_revision, 'pgreact:' || (context).activation_id::text,
        work_ref);
    request_digest := pgreact_mdm.intent_request_digest(request_body);
    control_before := to_jsonb(policy_case) - ARRAY['last_observed_at'];

    INSERT INTO pgreact_mdm.intent_requests(
        binding_id, request_key, request_digest, request_body, work_ref,
        policy_revision, case_key, lifecycle_generation, action_revision,
        consequence_identity, escalation_level, first_episode_id)
    VALUES (
        binding.binding_id, synthetic_request_key, request_digest, request_body, work_ref,
        binding.policy_revision, policy_case.case_key, (context).generation,
        policy_case.action_revision, queue_candidate.consequence_identity,
        queue_candidate.escalation_level, (context).episode_id);
    INSERT INTO pgreact_mdm.intent_attempts(
        episode_id, attempt_no, binding_id, request_key, request_digest,
        request_body, work_ref, receipt_id, outcome, reason_code,
        case_key, action_revision)
    VALUES (
        (context).episode_id, 1, binding.binding_id, synthetic_request_key,
        request_digest, request_body, work_ref, fake_receipt_id,
        'APPLIED_CONTROL', 'CONTROL_APPLIED', policy_case.case_key,
        policy_case.action_revision);
    IF pgreact_mdm.intent_receipt_exists(
           binding.binding_id, synthetic_request_key, fake_receipt_id) THEN
        RAISE EXCEPTION 'missing-receipt fixture unexpectedly exists in MDM';
    END IF;

    PERFORM set_config('role', 'pgreact_mdm_worker', true);
    PERFORM pgreact_mdm.submit_queue_intent(context, deployer_case);

    SELECT * INTO STRICT retained_request
    FROM pgreact_mdm.intent_requests AS request
    WHERE request.binding_id = binding.binding_id
      AND request.request_key = synthetic_request_key;
    SELECT * INTO STRICT blocked_attempt
    FROM pgreact_mdm.intent_attempts
    WHERE episode_id = (context).episode_id
      AND attempt_no = 2;
    SELECT to_jsonb(current_case) - ARRAY['last_observed_at']
    INTO STRICT control_after
    FROM pgreact_mdm.authorized_policy_cases_v1 AS current_case
    WHERE current_case.case_key = policy_case.case_key
      AND current_case.entity_name = policy_case.entity_name;
    IF retained_request.request_body IS DISTINCT FROM request_body
       OR retained_request.request_key IS DISTINCT FROM synthetic_request_key
       OR retained_request.request_digest IS DISTINCT FROM request_digest
       OR blocked_attempt.outcome IS DISTINCT FROM 'RECOVERY_BLOCKED'
       OR blocked_attempt.reason_code IS DISTINCT FROM 'MDM_RECEIPT_MISSING'
       OR blocked_attempt.receipt_id IS NOT NULL
       OR control_after IS DISTINCT FROM control_before
       OR NOT EXISTS (
           SELECT 1 FROM pgreact_mdm.intent_holds AS hold
           WHERE hold.binding_id = binding.binding_id
             AND hold.case_key = policy_case.case_key
             AND hold.policy_revision = binding.policy_revision
             AND hold.action = queue_candidate.action
             AND hold.expected_action_revision = policy_case.action_revision
             AND hold.reason_code = 'MDM_RECEIPT_MISSING') THEN
        RAISE EXCEPTION 'missing-receipt recovery changed request or control state, retried MDM, or failed to hold work';
    END IF;
END
$missing_receipt_recovery$;
ROLLBACK;
SELECT 'v0.48 missing-receipt recovery blocked without resubmission: PASS' AS result;

CREATE TEMP TABLE v048_case_baseline AS
SELECT DISTINCT case_row.case_key, case_row.entity_name, case_row.action_revision,
       case_row.publication_revision, case_row.status, case_row.resolved_at,
       entity.decision_epoch,
       entity.publication_revision AS entity_publication_revision
FROM mdm_steward.policy_cases_v1 AS case_row
JOIN mdm_internal.entities AS entity
  ON entity.entity_name = case_row.entity_name
JOIN v048_expected_intents AS expected
  ON expected.case_key = case_row.case_key
 AND expected.entity_name = case_row.entity_name;

CREATE TEMP TABLE v048_disabled_snapshot AS
SELECT
    (SELECT jsonb_agg(to_jsonb(case_row) ORDER BY case_row.case_key)
     FROM mdm_steward.policy_cases_v1 AS case_row) AS cases,
    (SELECT jsonb_agg(to_jsonb(receipt) ORDER BY receipt.receipt_id)
     FROM mdm_steward.policy_receipts_v1 AS receipt) AS receipts,
    (SELECT jsonb_agg(to_jsonb(request) ORDER BY request.binding_id, request.request_key)
     FROM pgreact_mdm.intent_requests AS request) AS requests,
    (SELECT jsonb_agg(to_jsonb(attempt) ORDER BY attempt.episode_id, attempt.attempt_no)
     FROM pgreact_mdm.intent_attempts AS attempt) AS attempts;

SELECT runtime.runtime_version AS v048_policy_runtime_version
FROM pgreact_mdm.policy_intent_runtime AS runtime
WHERE runtime.binding_id = :'v048_policy_binding_id'::uuid
\gset
SET SESSION AUTHORIZATION mdm_test_login;
SET ROLE :"queue_entity_execution_role";
SELECT pgreact_mdm.pause_intent_binding(
           :'v048_policy_binding_id'::uuid, :'v048_policy_runtime_version'::bigint)
       AS v048_paused_runtime
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION mdm_m2_runner;
DO $disabled_binding$
DECLARE
    rule_id uuid;
    episode_id bigint;
    iterations integer := 0;
BEGIN
    SELECT rule_version_id INTO STRICT rule_id
    FROM pgreact.rules
    WHERE rule_name = 'v0.48-live-worker-queue' AND state = 'ACTIVE';
    IF EXISTS (
        SELECT 1 FROM pgreact_mdm.intent_queue_candidates
        WHERE binding_id = (
            SELECT binding_id FROM pgreact_mdm.policy_intent_bindings
            WHERE entity_name = 'review_admission_live'
              AND policy_revision = 'v0.48-live-policy')) THEN
        RAISE EXCEPTION 'paused binding still produced queue candidates';
    END IF;
    PERFORM pgreact.refresh_rule(rule_id);
    PERFORM set_config('role', 'pgreact_mdm_worker', true);
    LOOP
        episode_id := pgreact_mdm.execute_intent_episode(
            rule_id, 'v0.48-disabled-binding');
        EXIT WHEN episode_id IS NULL;
        iterations := iterations + 1;
        IF iterations > 100 THEN
            RAISE EXCEPTION 'paused-binding work did not drain within 100 episodes';
        END IF;
    END LOOP;
END
$disabled_binding$;
RESET SESSION AUTHORIZATION;

DO $shadow_no_effect$
DECLARE
    comparison jsonb;
    expected_keys bigint[];
    compared_keys bigint[];
BEGIN
    SELECT array_agg(DISTINCT case_key ORDER BY case_key)
    INTO expected_keys
    FROM v048_expected_intents;
    comparison := pgreact_mdm.compare_population(
        'mdm_steward.policy_cases_v1'::regclass,
        'v0.48-live-policy', 'v0.48-live-policy', statement_timestamp(),
        jsonb_build_object(
            'id', 'v0.48-live-shadow',
            'membership', to_jsonb(expected_keys),
            'expected_count', cardinality(expected_keys)));
    SELECT array_agg((item.value ->> 'case_key')::bigint ORDER BY (item.value ->> 'case_key')::bigint)
    INTO compared_keys
    FROM jsonb_array_elements(comparison -> 'rows') AS item(value);
    IF comparison ->> 'state' IS DISTINCT FROM 'complete'
       OR comparison ->> 'read_only' IS DISTINCT FROM 'true'
       OR compared_keys IS DISTINCT FROM expected_keys
       OR EXISTS (
           SELECT 1 FROM jsonb_array_elements(comparison -> 'rows') AS item(value)
           WHERE item.value ->> 'changed' IS DISTINCT FROM 'false')
       OR EXISTS (
           SELECT 1
           FROM v048_disabled_snapshot AS before
           WHERE before.cases IS DISTINCT FROM (
                     SELECT jsonb_agg(to_jsonb(case_row) ORDER BY case_row.case_key)
                     FROM mdm_steward.policy_cases_v1 AS case_row)
              OR before.receipts IS DISTINCT FROM (
                     SELECT jsonb_agg(to_jsonb(receipt) ORDER BY receipt.receipt_id)
                     FROM mdm_steward.policy_receipts_v1 AS receipt)
              OR before.requests IS DISTINCT FROM (
                     SELECT jsonb_agg(to_jsonb(request)
                                      ORDER BY request.binding_id, request.request_key)
                     FROM pgreact_mdm.intent_requests AS request)
              OR before.attempts IS DISTINCT FROM (
                     SELECT jsonb_agg(to_jsonb(attempt)
                                      ORDER BY attempt.episode_id, attempt.attempt_no)
                     FROM pgreact_mdm.intent_attempts AS attempt)) THEN
        RAISE EXCEPTION 'disabled or shadow evaluation changed candidates, controls, receipts, or request state';
    END IF;
END
$shadow_no_effect$;

SET SESSION AUTHORIZATION mdm_test_login;
SET ROLE :"queue_entity_execution_role";
SELECT pgreact_mdm.reconcile_intent_binding(
           :'v048_policy_binding_id'::uuid, :'v048_paused_runtime'::bigint) AS v048_reconciled_runtime;
RESET ROLE;
RESET SESSION AUTHORIZATION;

DO $disabled_binding_restored$
DECLARE
    expected_queue text[];
    actual_queue text[];
BEGIN
    SELECT array_agg(case_key::text || ':' || pgreact_mdm.canonical_json(arguments) ORDER BY case_key)
    INTO expected_queue
    FROM v048_expected_intents
    WHERE binding_id = (
        SELECT binding_id FROM pgreact_mdm.policy_intent_bindings
        WHERE entity_name = 'review_admission_live'
          AND policy_revision = 'v0.48-live-policy')
      AND action = 'ASSIGN_QUEUE';
    SELECT array_agg(case_key::text || ':' || pgreact_mdm.canonical_json(arguments) ORDER BY case_key)
    INTO actual_queue
    FROM pgreact_mdm.intent_queue_candidates
    WHERE binding_id = (
        SELECT binding_id FROM pgreact_mdm.policy_intent_bindings
        WHERE entity_name = 'review_admission_live'
          AND policy_revision = 'v0.48-live-policy');
    IF actual_queue IS DISTINCT FROM expected_queue THEN
        RAISE EXCEPTION 're-enabled binding did not restore its exact candidate output';
    END IF;
END
$disabled_binding_restored$;

CREATE TEMP TABLE v048_stale_hold_probe AS
SELECT expected.binding_id, expected.case_key, expected.entity_name, expected.action,
       baseline.action_revision AS current_action_revision,
       baseline.action_revision - 1 AS held_action_revision
FROM v048_expected_intents AS expected
JOIN v048_case_baseline AS baseline
  ON baseline.case_key = expected.case_key
 AND baseline.entity_name = expected.entity_name
WHERE baseline.action_revision > 1
ORDER BY expected.action, expected.case_key
LIMIT 1;
DO $stale_hold_probe$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM v048_stale_hold_probe) THEN
        RAISE EXCEPTION 'fixture lacks a queue case with an older action revision';
    END IF;
    INSERT INTO pgreact_mdm.intent_holds(
        binding_id, case_key, policy_revision, action,
        expected_action_revision, reason_code)
    SELECT binding_id, case_key, 'v0.48-live-policy', action,
           held_action_revision, 'FRESHNESS_TOKEN_MISMATCH'
    FROM v048_stale_hold_probe;
END
$stale_hold_probe$;

SET SESSION AUTHORIZATION mdm_m2_runner;
DO $refresh_bound_cases$
DECLARE rule_id uuid;
BEGIN
    PERFORM pgreact_mdm.sync_intent_case_identities();
    FOR rule_id IN
        SELECT rule.rule_version_id
        FROM pgreact.rules AS rule
        WHERE rule.rule_name IN (
            'v0.48-live-worker-queue',
            'v0.48-live-worker-due',
            'v0.48-live-worker-escalation')
          AND rule.state = 'ACTIVE'
    LOOP
        PERFORM pgreact.refresh_rule(rule_id);
    END LOOP;
END
$refresh_bound_cases$;
RESET SESSION AUTHORIZATION;

SELECT rule_version_id AS v048_queue_rule
FROM pgreact.rules
WHERE rule_name = 'v0.48-live-worker-queue' AND state = 'ACTIVE'
\gset

CREATE TEMP TABLE v048_failure_baseline AS
SELECT
    (SELECT count(*) FROM pgreact_mdm.intent_requests) AS request_count,
    (SELECT count(*) FROM pgreact_mdm.intent_attempts) AS attempt_count,
    (SELECT count(*) FROM mdm_steward.policy_receipts_v1) AS receipt_count;
CREATE TEMP TABLE v048_failure_controls AS
SELECT case_row.case_key, case_row.assigned_queue
FROM mdm_steward.policy_cases_v1 AS case_row
JOIN v048_expected_intents AS expected USING (case_key)
WHERE expected.action = 'ASSIGN_QUEUE';
UPDATE pgreact_internal.agenda
SET available_at = clock_timestamp()
WHERE rule_version_id = :'v048_queue_rule'::uuid AND state = 'PENDING';

CREATE OR REPLACE FUNCTION pgreact_mdm.v048_fail_after_submit()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    RAISE EXCEPTION USING ERRCODE = 'PZ004', MESSAGE = 'v048 injected post-submit failure';
END
$function$;
CREATE TRIGGER v048_fail_after_submit
BEFORE INSERT ON pgreact_mdm.intent_attempts
FOR EACH ROW EXECUTE FUNCTION pgreact_mdm.v048_fail_after_submit();
SET SESSION AUTHORIZATION mdm_m2_runner;
DO $post_submit_rollback$
DECLARE
    failure_seen boolean := false;
    failure_message text;
    episode_id bigint;
    rule_id uuid;
    executed integer := 0;
BEGIN
    SELECT rule_version_id INTO STRICT rule_id
    FROM pgreact.rules
    WHERE rule_name = 'v0.48-live-worker-queue' AND state = 'ACTIVE';
    PERFORM set_config('role', 'pgreact_mdm_worker', true);
    LOOP
        BEGIN
            episode_id := pgreact_mdm.execute_intent_episode(
                rule_id, 'v0.48-post-submit-failure');
        EXCEPTION WHEN SQLSTATE 'PZ004' THEN
            GET STACKED DIAGNOSTICS failure_message = MESSAGE_TEXT;
            IF failure_message <> 'v048 injected post-submit failure' THEN RAISE; END IF;
            failure_seen := true;
        END;
        EXIT WHEN failure_seen OR episode_id IS NULL;
        executed := executed + 1;
        IF executed > 100 THEN
            RAISE EXCEPTION 'worker did not reach the injected post-submit failure within 100 episodes';
        END IF;
    END LOOP;
    IF NOT failure_seen THEN
        RAISE EXCEPTION 'worker did not reach the injected post-submit failure';
    END IF;
END
$post_submit_rollback$;
RESET SESSION AUTHORIZATION;
DROP TRIGGER v048_fail_after_submit ON pgreact_mdm.intent_attempts;
DROP FUNCTION pgreact_mdm.v048_fail_after_submit();
DO $post_submit_rollback_state$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM v048_failure_baseline AS baseline
        WHERE baseline.request_count <> (SELECT count(*) FROM pgreact_mdm.intent_requests)
           OR baseline.attempt_count <> (SELECT count(*) FROM pgreact_mdm.intent_attempts)
           OR baseline.receipt_count <> (SELECT count(*) FROM mdm_steward.policy_receipts_v1))
       OR EXISTS (
           SELECT 1
           FROM v048_failure_controls AS baseline
           JOIN mdm_steward.policy_cases_v1 AS case_row USING (case_key)
           WHERE case_row.assigned_queue IS DISTINCT FROM baseline.assigned_queue) THEN
        RAISE EXCEPTION 'post-submit failure committed an intent, receipt, or queue control';
    END IF;
END
$post_submit_rollback_state$;

SELECT dblink_connect(
    'm2_worker_a', format('dbname=%s user=mdm_m2_runner', current_database()));
SELECT dblink_connect(
    'm2_worker_b', format('dbname=%s user=mdm_m2_runner', current_database()));
SELECT dblink_send_query('m2_worker_a', format(
    'WITH worker AS MATERIALIZED '
    '(SELECT set_config(''role'', ''pgreact_mdm_worker'', false)), '
    'delay AS MATERIALIZED (SELECT pg_sleep(0.5) FROM worker) '
    'SELECT pgreact_mdm.execute_intent_episode(%L::uuid, %L) IS NOT NULL FROM delay',
    :'v048_queue_rule', 'm2-concurrent-a'));
SELECT dblink_send_query('m2_worker_b', format(
    'WITH worker AS MATERIALIZED '
    '(SELECT set_config(''role'', ''pgreact_mdm_worker'', false)), '
    'delay AS MATERIALIZED (SELECT pg_sleep(0.5) FROM worker) '
    'SELECT pgreact_mdm.execute_intent_episode(%L::uuid, %L) IS NOT NULL FROM delay',
    :'v048_queue_rule', 'm2-concurrent-b'));
CREATE TEMP TABLE v048_concurrency_results(executed boolean NOT NULL);
INSERT INTO v048_concurrency_results
SELECT * FROM dblink_get_result('m2_worker_a') AS result(executed boolean);
INSERT INTO v048_concurrency_results
SELECT * FROM dblink_get_result('m2_worker_b') AS result(executed boolean);
SELECT dblink_disconnect('m2_worker_a');
SELECT dblink_disconnect('m2_worker_b');
DO $concurrency$
BEGIN
    IF (SELECT count(*) FROM v048_concurrency_results) <> 2
       OR NOT EXISTS (SELECT 1 FROM v048_concurrency_results WHERE executed) THEN
        RAISE EXCEPTION 'concurrent pg-react workers did not complete a queue episode';
    END IF;
END
$concurrency$;

SET SESSION AUTHORIZATION mdm_m2_runner;
DO $work$
DECLARE
    rule_row record;
    episode_id bigint;
    attempts integer;
    rules_seen integer := 0;
    passes integer := 0;
    pass_has_work boolean;
    original_role text := current_setting('role');
BEGIN
    PERFORM pgreact_mdm.sync_intent_case_identities();
    SELECT count(*) INTO rules_seen
    FROM pgreact.rules AS rule
    WHERE rule.rule_name IN (
        'v0.48-live-worker-queue',
        'v0.48-live-worker-due',
        'v0.48-live-worker-escalation')
      AND rule.state = 'ACTIVE';
    IF rules_seen <> 3 THEN
        RAISE EXCEPTION 'v0.48 deploy did not create all three intent rules';
    END IF;
    LOOP
        pass_has_work := false;
        FOR rule_row IN
            SELECT rule.rule_version_id, rule.rule_name
            FROM pgreact.rules AS rule
            WHERE rule.rule_name IN (
                'v0.48-live-worker-queue',
                'v0.48-live-worker-due',
                'v0.48-live-worker-escalation')
              AND rule.state = 'ACTIVE'
            ORDER BY CASE rule.rule_name
                WHEN 'v0.48-live-worker-queue' THEN 1
                WHEN 'v0.48-live-worker-due' THEN 2
                ELSE 3 END
        LOOP
            attempts := 0;
            LOOP
                PERFORM pgreact.refresh_rule(rule_row.rule_version_id);
                PERFORM set_config('role', 'pgreact_mdm_worker', true);
                episode_id := pgreact_mdm.execute_intent_episode(
                    rule_row.rule_version_id, 'v0.48-live-worker');
                PERFORM set_config('role', original_role, true);
                EXIT WHEN episode_id IS NULL;
                pass_has_work := true;
                attempts := attempts + 1;
                IF attempts > 100 THEN
                    RAISE EXCEPTION 'v0.48 worker did not drain its episode queue';
                END IF;
        END LOOP;
        END LOOP;
        EXIT WHEN NOT pass_has_work;
        passes := passes + 1;
        IF passes > 100 THEN
            RAISE EXCEPTION 'v0.48 worker did not reach a quiescent episode queue';
        END IF;
    END LOOP;
END
$work$;
RESET SESSION AUTHORIZATION;

DO $delivery_inspection$
DECLARE
    expected_work_refs text[];
    inspected_work_refs text[];
BEGIN
    SELECT array_agg(work_ref ORDER BY work_ref)
    INTO expected_work_refs
    FROM pgreact_mdm.intent_requests;
    SELECT array_agg(work_ref ORDER BY work_ref)
    INTO inspected_work_refs
    FROM pgreact_mdm.delivery_inspection_v1;
    IF inspected_work_refs IS DISTINCT FROM expected_work_refs
       OR NOT EXISTS (
           SELECT 1
           FROM pgreact_mdm.delivery_inspection_v1 AS inspection
           JOIN pgreact_mdm.intent_requests AS request USING (work_ref)
           JOIN pgreact_mdm.intent_attempts AS attempt
             ON attempt.binding_id = request.binding_id
            AND attempt.request_key = request.request_key
            AND attempt.receipt_id = inspection.mdm_receipt_id
           JOIN mdm_steward.policy_receipts_v1 AS receipt
             ON receipt.receipt_id = inspection.mdm_receipt_id
           WHERE inspection.binding_id = request.binding_id
             AND inspection.policy_revision = request.policy_revision
             AND inspection.entity_name = 'policy_qualification'
             AND inspection.action = request.request_body ->> 'action'
             AND inspection.delivery_outcome = attempt.outcome
             AND inspection.mdm_outcome = receipt.outcome
             AND inspection.current_case_status IS NOT NULL
             AND inspection.current_publication_revision IS NOT NULL)
       OR NOT has_table_privilege('mdm_test_login',
              'pgreact_mdm.delivery_inspection_v1', 'SELECT')
       OR has_table_privilege('mdm_test_login',
              'pgreact_mdm.delivery_inspection_v1', 'UPDATE')
       OR EXISTS (
           SELECT 1 FROM information_schema.columns
           WHERE table_schema = 'pgreact_mdm'
             AND table_name = 'delivery_inspection_v1'
             AND column_name IN ('request_key', 'request_body')) THEN
        RAISE EXCEPTION 'versioned delivery inspection did not expose exact read-only work, receipt, case, and policy state';
    END IF;
END
$delivery_inspection$;

CREATE TEMP TABLE v048_attempt_baseline AS
SELECT count(*) AS attempt_count,
       COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                       'binding_id', request.binding_id,
                       'request_key', encode(request.request_key, 'hex'),
                       'request_digest', encode(request.request_digest, 'hex'),
                       'request_body', request.request_body)
                    ORDER BY request.binding_id, request.request_key)
           FROM pgreact_mdm.intent_requests AS request), '[]'::jsonb)
           AS request_identity;

DO $correlation$
DECLARE
    expected_work text[];
    actual_work text[];
BEGIN
    SELECT array_agg(
               binding_id::text || ':' || action || ':' || case_key::text || ':' ||
               pgreact_mdm.canonical_json(arguments)
               ORDER BY action, case_key, pgreact_mdm.canonical_json(arguments), binding_id)
    INTO expected_work
    FROM v048_expected_intents;
    SELECT array_agg(
               request.binding_id::text || ':' || (request.request_body ->> 'action') || ':' ||
               request.case_key::text || ':' ||
               pgreact_mdm.canonical_json(request.request_body -> 'arguments')
               ORDER BY request.request_body ->> 'action', request.case_key,
                        pgreact_mdm.canonical_json(request.request_body -> 'arguments'),
                        request.binding_id)
    INTO actual_work
    FROM pgreact_mdm.intent_attempts AS attempt
    JOIN pgreact_mdm.intent_requests AS request
      ON request.binding_id = attempt.binding_id
     AND request.request_key = attempt.request_key
    JOIN mdm_steward.policy_receipts_v1 AS receipt
      ON receipt.binding_id = attempt.binding_id
     AND receipt.request_key = attempt.request_key
    JOIN pgreact.episodes AS episode
      ON episode.episode_id = request.first_episode_id
    WHERE attempt.outcome = 'APPLIED_CONTROL'
      AND attempt.receipt_id = receipt.receipt_id
      AND attempt.work_ref = request.work_ref
      AND attempt.request_body = request.request_body
      AND request.request_digest = receipt.request_digest
      AND receipt.request_body = request.request_body
      AND receipt.outcome = attempt.outcome
      AND receipt.case_key = attempt.case_key
      AND receipt.action = request.request_body ->> 'action'
      AND receipt.action_revision = attempt.action_revision
      AND receipt.control IS NOT DISTINCT FROM attempt.control
      AND receipt.resulting_publication_revision IS NOT DISTINCT FROM attempt.resulting_publication_revision
      AND request.request_digest = pgreact_mdm.intent_request_digest(request.request_body)
      AND request.request_key = pgreact_mdm.intent_request_key(
          request.binding_id, request.policy_revision, request.case_key,
          request.lifecycle_generation, request.action_revision,
          request.consequence_identity, request.escalation_level)
      AND request.work_ref = 'pgreact:' || episode.rule_version_id::text || ':' || episode.episode_id::text;
    IF actual_work IS DISTINCT FROM expected_work THEN
        RAISE EXCEPTION 'v0.48 exact work/receipt vector mismatch: expected %, correlated %', expected_work, actual_work;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM v048_stale_hold_probe AS probe
        JOIN pgreact_mdm.intent_attempts AS attempt
          ON attempt.binding_id = probe.binding_id
         AND attempt.case_key = probe.case_key
         AND attempt.request_body ->> 'action' = probe.action
         AND attempt.outcome = 'APPLIED_CONTROL'
        JOIN pgreact_mdm.intent_requests AS request
          ON request.binding_id = attempt.binding_id
         AND request.request_key = attempt.request_key
        WHERE request.request_body ->> 'expected_action_revision' =
              probe.current_action_revision::text
          AND request.request_key = pgreact_mdm.intent_request_key(
              request.binding_id, request.policy_revision, request.case_key,
              request.lifecycle_generation, request.action_revision,
              request.consequence_identity, request.escalation_level)) THEN
        RAISE EXCEPTION 'older stale hold blocked work for fresh action revision';
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_mdm.intent_queue_candidates)
       OR EXISTS (SELECT 1 FROM pgreact_mdm.intent_due_candidates)
       OR EXISTS (SELECT 1 FROM pgreact_mdm.intent_escalation_candidates) THEN
        RAISE EXCEPTION 'candidate work remained after worker execution';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM v048_case_baseline AS baseline
        JOIN mdm_steward.policy_cases_v1 AS case_row USING (case_key)
        JOIN mdm_internal.entities AS entity
          ON entity.entity_name = case_row.entity_name
        WHERE case_row.action_revision <> baseline.action_revision +
                  (SELECT count(*) FROM v048_expected_intents AS expected
                   WHERE expected.case_key = baseline.case_key
                     AND expected.entity_name = baseline.entity_name)
           OR case_row.publication_revision <> baseline.publication_revision
           OR case_row.status IS DISTINCT FROM baseline.status
           OR case_row.resolved_at IS DISTINCT FROM baseline.resolved_at
           OR entity.decision_epoch <> baseline.decision_epoch
           OR entity.publication_revision <> baseline.entity_publication_revision) THEN
        RAISE EXCEPTION 'worker receipt write changed action/decision state or lost its receipt';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pgreact_mdm.intent_attempts AS attempt
        JOIN mdm_steward.policy_receipts_v1 AS receipt
          ON receipt.binding_id = attempt.binding_id
         AND receipt.request_key = attempt.request_key
        WHERE attempt.outcome = 'APPLIED_CONTROL'
          AND (attempt.resulting_publication_revision IS NOT NULL
               OR receipt.resulting_publication_revision IS NOT NULL
               OR attempt.case_key IN (
                   SELECT baseline.case_key
                   FROM v048_case_baseline AS baseline
                   JOIN mdm_steward.policy_cases_v1 AS case_row USING (case_key)
                   WHERE case_row.status <> 'open' OR case_row.resolved_at IS NOT NULL))) THEN
        RAISE EXCEPTION 'applied control was reported as publication or case resolution';
    END IF;
END
$correlation$;

DO $source_update$
DECLARE affected integer;
BEGIN
    UPDATE public.policy_qualification_source
    SET display_name = 'Publication Only v0.48 ' ||
                       pg_catalog.to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'),
        updated_at = statement_timestamp()
    WHERE id = 105;
    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected <> 1 THEN
        RAISE EXCEPTION 'publication-only fixture row 105 is missing';
    END IF;
END
$source_update$;
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
DO $observation$
DECLARE
    result jsonb;
BEGIN
    result := mdm.refresh('policy_qualification', 'ALLOW');
    IF result ->> 'changed' IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'observation-only update did not publish: %', result;
    END IF;
END
$observation$;
RESET ROLE;

RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION mdm_m2_runner;
DO $observation_refresh$
DECLARE
    rule_row record;
BEGIN
    PERFORM pgreact_mdm.sync_intent_case_identities();
    FOR rule_row IN
        SELECT rule.rule_version_id
        FROM pgreact.rules AS rule
        WHERE rule.rule_name IN (
            'v0.48-live-worker-queue',
            'v0.48-live-worker-due',
            'v0.48-live-worker-escalation')
          AND rule.state = 'ACTIVE'
    LOOP
        PERFORM pgreact.refresh_rule(rule_row.rule_version_id);
    END LOOP;
END
$observation_refresh$;
RESET SESSION AUTHORIZATION;

DO $observation_work$
BEGIN
    IF (SELECT attempt_count FROM v048_attempt_baseline)
       <> (SELECT count(*) FROM pgreact_mdm.intent_attempts) THEN
        RAISE EXCEPTION 'observation-only publication created worker intent attempts';
    END IF;
    IF (SELECT request_identity FROM v048_attempt_baseline) IS DISTINCT FROM
       COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                       'binding_id', request.binding_id,
                       'request_key', encode(request.request_key, 'hex'),
                       'request_digest', encode(request.request_digest, 'hex'),
                       'request_body', request.request_body)
                    ORDER BY request.binding_id, request.request_key)
           FROM pgreact_mdm.intent_requests AS request), '[]'::jsonb) THEN
        RAISE EXCEPTION 'observation-only publication changed request identity or body';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM v048_case_baseline AS baseline
        JOIN mdm_steward.policy_cases_v1 AS case_row USING (case_key)
        JOIN mdm_internal.entities AS entity
          ON entity.entity_name = case_row.entity_name
        WHERE case_row.action_revision <> baseline.action_revision +
              (SELECT count(*) FROM v048_expected_intents AS expected
              WHERE expected.case_key = baseline.case_key
                AND expected.entity_name = baseline.entity_name)
           OR case_row.publication_revision <> baseline.publication_revision
           OR case_row.status IS DISTINCT FROM baseline.status
           OR case_row.resolved_at IS DISTINCT FROM baseline.resolved_at
           OR entity.decision_epoch <> baseline.decision_epoch
           OR entity.publication_revision <> baseline.entity_publication_revision +
                 CASE WHEN baseline.entity_name = 'policy_qualification' THEN 1 ELSE 0 END) THEN
        RAISE EXCEPTION 'observation-only publication changed policy action or decision state';
    END IF;
END
$observation_work$;

CREATE TEMP TABLE v048_r10_case AS
SELECT case_row.case_key, case_row.action_revision
FROM mdm_steward.policy_cases_v1 AS case_row
WHERE case_row.entity_name = 'review_admission_live'
  AND case_row.status = 'open'
  AND case_row.assigned_queue = 'm2-ready'
ORDER BY case_row.case_key
LIMIT 1;
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
DO $r10_reopen_case$
DECLARE case_row record;
BEGIN
    SELECT * INTO STRICT case_row FROM v048_r10_case;
    PERFORM mdm_steward.set_case_controls(
        case_row.case_key, 'manual-review', NULL, 0, false,
        case_row.action_revision, 'v0.48 independent job fixture');
END
$r10_reopen_case$;
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT pgreact.refresh_rule(:'v048_queue_rule'::uuid);
CREATE TEMP TABLE v048_r10_baseline AS
SELECT (SELECT count(*) FROM pgreact_mdm.intent_requests) AS requests,
       (SELECT count(*) FROM pgreact_mdm.intent_attempts) AS attempts,
       (SELECT count(*) FROM mdm_steward.policy_receipts_v1) AS receipts;
SELECT dblink_connect(
    'm2_bad_job', format('dbname=%s user=mdm_m2_runner', current_database()));
SELECT dblink_connect(
    'm2_healthy_job', format('dbname=%s user=mdm_m2_runner', current_database()));
SELECT dblink_send_query('m2_bad_job',
    'WITH worker AS MATERIALIZED '
    '(SELECT set_config(''role'', ''pgreact_mdm_worker'', false)) '
    'SELECT pgreact_mdm.submit_intent(NULL::pgreact.activation_context, ''{}''::jsonb) IS NULL FROM worker');
SELECT dblink_send_query('m2_healthy_job', format(
    'WITH worker AS MATERIALIZED '
    '(SELECT set_config(''role'', ''pgreact_mdm_worker'', false)) '
    'SELECT pgreact_mdm.execute_intent_episode(%L::uuid, %L) IS NOT NULL FROM worker',
    :'v048_queue_rule', 'v0.48-independent-healthy-job'));
CREATE TEMP TABLE v048_r10_healthy_result(executed boolean NOT NULL);
INSERT INTO v048_r10_healthy_result
SELECT * FROM dblink_get_result('m2_healthy_job') AS result(executed boolean);
DO $r10_failed_job$
DECLARE
    failure_seen boolean := false;
    failure_message text;
BEGIN
    BEGIN
        PERFORM result
        FROM dblink_get_result('m2_bad_job') AS result(value boolean);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS failure_message = MESSAGE_TEXT;
        failure_seen := failure_message = 'query returned no rows';
    END;
    IF NOT failure_seen THEN
        RAISE EXCEPTION 'malformed job did not fail at the worker boundary: %', failure_message;
    END IF;
END
$r10_failed_job$;
SELECT dblink_disconnect('m2_bad_job');
SELECT dblink_disconnect('m2_healthy_job');
DO $r10_independent_commit$
BEGIN
    IF (SELECT executed FROM v048_r10_healthy_result) IS DISTINCT FROM true
       OR (SELECT count(*) FROM pgreact_mdm.intent_requests)
          <= (SELECT requests FROM v048_r10_baseline)
       OR (SELECT count(*) FROM pgreact_mdm.intent_attempts)
          <= (SELECT attempts FROM v048_r10_baseline)
       OR (SELECT count(*) FROM mdm_steward.policy_receipts_v1)
          <= (SELECT receipts FROM v048_r10_baseline)
       OR NOT EXISTS (
           SELECT 1 FROM pgreact_mdm.delivery_inspection_v1 AS inspection
           JOIN v048_r10_case AS expected USING (case_key)
           WHERE inspection.action = 'ASSIGN_QUEUE'
             AND inspection.delivery_outcome = 'APPLIED_CONTROL'
             AND inspection.mdm_receipt_id IS NOT NULL) THEN
        RAISE EXCEPTION 'malformed job prevented the unrelated healthy job from committing';
    END IF;
END
$r10_independent_commit$;

SELECT binding.binding_version AS v048_replacement_binding_version
FROM pgreact_mdm.policy_intent_bindings AS binding
WHERE binding.binding_id = :'v048_policy_binding_id'::uuid
\gset
SELECT case_row.case_key AS v048_replacement_case_key,
       case_row.action_revision AS v048_replacement_case_revision
FROM mdm_steward.policy_cases_v1 AS case_row
WHERE case_row.entity_name = 'review_admission_live'
  AND case_row.status = 'open'
  AND case_row.assigned_queue = 'm2-ready'
ORDER BY case_row.case_key
LIMIT 1
\gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :'v048_replacement_case_key'::bigint, 'manual-review', NULL, 0, false,
    :'v048_replacement_case_revision'::bigint,
    'v0.48 policy replacement pending-work fixture');
RESET ROLE;
RESET SESSION AUTHORIZATION;

CREATE TEMP TABLE v048_replacement_candidates AS
SELECT * FROM pgreact_mdm.intent_queue_candidates
WHERE binding_id = :'v048_policy_binding_id'::uuid;
CREATE TEMP TABLE v048_replacement_ledger AS
SELECT
    (SELECT COALESCE(jsonb_agg(to_jsonb(request)
                               ORDER BY request.binding_id, request.request_key), '[]'::jsonb)
     FROM pgreact_mdm.intent_requests AS request) AS requests,
    (SELECT COALESCE(jsonb_agg(to_jsonb(attempt)
                               ORDER BY attempt.episode_id, attempt.attempt_no), '[]'::jsonb)
     FROM pgreact_mdm.intent_attempts AS attempt) AS attempts;
DO $replacement_fixture$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM v048_replacement_candidates) THEN
        RAISE EXCEPTION 'replacement fixture lacks unattempted old-binding work';
    END IF;
END
$replacement_fixture$;

DO $replacement_package$
DECLARE package jsonb;
BEGIN
    SELECT policy_package INTO STRICT package
    FROM pgreact_mdm.policy_intent_packages
    WHERE policy_revision = 'v0.48-live-policy';
    PERFORM pgreact_mdm.publish_intent_package(
        'v0.48-live-policy-r23', package);
END
$replacement_package$;
SET SESSION AUTHORIZATION mdm_test_login;
SET ROLE :"queue_entity_execution_role";
SELECT binding_id AS v048_replacement_binding_id
FROM pgreact_mdm.replace_intent_binding(
    :'v048_policy_binding_id'::uuid,
    :'v048_replacement_binding_version'::bigint,
    'v0.48-live-policy-r23',
    ARRAY['ASSIGN_QUEUE']::text[], ARRAY['m2-ready']::text[], NULL, 0)
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;
CREATE TEMP TABLE v048_replacement_ids AS
SELECT :'v048_policy_binding_id'::uuid AS old_binding_id,
       :'v048_replacement_binding_id'::uuid AS new_binding_id,
       :'v048_replacement_case_key'::bigint AS case_key;
DO $replacement_state$
DECLARE ids v048_replacement_ids%ROWTYPE;
BEGIN
    SELECT * INTO STRICT ids FROM v048_replacement_ids;
    IF EXISTS (
           SELECT 1 FROM pgreact_mdm.intent_queue_candidates
           WHERE binding_id = ids.old_binding_id)
       OR NOT EXISTS (
           SELECT 1 FROM pgreact_mdm.intent_queue_candidates
           WHERE binding_id = ids.new_binding_id
             AND case_key = ids.case_key)
       OR EXISTS (
           SELECT 1 FROM pgreact_mdm.policy_intent_bindings AS binding
           WHERE binding.binding_id = ids.old_binding_id
             AND binding.enabled)
       OR (SELECT requests FROM v048_replacement_ledger) IS DISTINCT FROM (
           SELECT COALESCE(jsonb_agg(to_jsonb(request)
                                     ORDER BY request.binding_id, request.request_key), '[]'::jsonb)
           FROM pgreact_mdm.intent_requests AS request)
       OR (SELECT attempts FROM v048_replacement_ledger) IS DISTINCT FROM (
           SELECT COALESCE(jsonb_agg(to_jsonb(attempt)
                                     ORDER BY attempt.episode_id, attempt.attempt_no), '[]'::jsonb)
           FROM pgreact_mdm.intent_attempts AS attempt) THEN
        RAISE EXCEPTION 'policy replacement lost old work, retained old candidates, or changed attempted bytes';
    END IF;
END
$replacement_state$;

SELECT 'v0.48 actual worker actions, limits, receipts, and observation stability passed' AS result;
SELECT 'v0.48 malformed job did not roll back unrelated healthy work' AS result;
SELECT 'v0.48 policy replacement withdrew old candidates and preserved attempted work' AS result;
SELECT 'v0.48 delivery did not publish or resolve cases' AS result;
SELECT 'v0.48 post-submit rollback left no MDM or React effects' AS result;
