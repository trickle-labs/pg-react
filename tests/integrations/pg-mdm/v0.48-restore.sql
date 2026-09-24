\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $durable$
DECLARE
    active_binding uuid;
    restored_entity_name name;
    correlated_receipts bigint;
    restored_database_oid oid;
    worker_oid oid;
BEGIN
    SELECT binding.binding_id, binding.entity_name
    INTO STRICT active_binding, restored_entity_name
    FROM pgreact_mdm.policy_intent_bindings AS binding
    WHERE binding.enabled
      AND binding.policy_revision = 'v0.48-live-policy'
      AND binding.entity_name = 'policy_qualification';

    SELECT oid INTO STRICT restored_database_oid
    FROM pg_catalog.pg_database WHERE datname = current_database();
    SELECT oid INTO STRICT worker_oid
    FROM pg_catalog.pg_roles WHERE rolname = 'pgreact_mdm_worker';
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_mdm.intent_requests
        WHERE binding_id = active_binding)
       OR NOT EXISTS (
        SELECT 1 FROM pgreact_mdm.intent_attempts
        WHERE binding_id = active_binding AND outcome = 'APPLIED_CONTROL')
       OR NOT EXISTS (
        SELECT 1 FROM mdm_steward.policy_receipts_v1
        WHERE binding_id = active_binding AND outcome = 'APPLIED_CONTROL') THEN
        RAISE EXCEPTION 'restore lost durable intent bindings, requests, attempts, or receipts';
    END IF;
    SELECT count(*) INTO correlated_receipts
    FROM pgreact_mdm.intent_requests AS request
    JOIN pgreact_mdm.intent_attempts AS attempt
      ON attempt.binding_id = request.binding_id
     AND attempt.request_key = request.request_key
    JOIN mdm_steward.policy_receipts_v1 AS receipt
      ON receipt.binding_id = attempt.binding_id
     AND receipt.request_key = attempt.request_key
    WHERE request.binding_id = active_binding
      AND attempt.outcome = 'APPLIED_CONTROL'
      AND attempt.receipt_id = receipt.receipt_id
      AND attempt.request_body = request.request_body
      AND request.request_body = receipt.request_body
      AND request.request_digest = receipt.request_digest
      AND attempt.request_digest = request.request_digest
      AND attempt.work_ref = request.work_ref
      AND attempt.case_key = receipt.case_key
      AND attempt.action_revision = receipt.action_revision
      AND attempt.control IS NOT DISTINCT FROM receipt.control
      AND attempt.resulting_publication_revision IS NOT DISTINCT FROM
          receipt.resulting_publication_revision;
    IF correlated_receipts < 3 THEN
        RAISE EXCEPTION 'restore lost exact request/attempt/receipt correlations: %',
            correlated_receipts;
    END IF;

    IF EXISTS (
        SELECT 1 FROM mdm_internal.policy_binding_runtime AS runtime
        WHERE runtime.binding_id = active_binding
          AND (runtime.state <> 'paused'
               OR runtime.database_oid = restored_database_oid
               OR runtime.automation_role_oid = worker_oid)) THEN
        RAISE EXCEPTION 'restored MDM runtime is active or matches the restored database and worker';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_mdm.policy_intent_runtime AS runtime
        WHERE runtime.binding_id = active_binding
          AND runtime.database_oid <> restored_database_oid
          AND runtime.worker_role_oid <> worker_oid) THEN
        RAISE EXCEPTION 'restored React runtime did not retain the old database and worker OIDs';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_mdm.authorized_policy_cases_v1 AS policy_case
        WHERE policy_case.entity_name = restored_entity_name)
       OR EXISTS (SELECT 1 FROM pgreact_mdm.intent_queue_candidates)
       OR EXISTS (SELECT 1 FROM pgreact_mdm.intent_due_candidates)
       OR EXISTS (SELECT 1 FROM pgreact_mdm.intent_escalation_candidates) THEN
        RAISE EXCEPTION 'restore exposed worker cases or candidate intents before reconciliation';
    END IF;
END
$durable$;

SELECT binding_id AS v048_binding_id,
       entity_execution_role AS v048_entity_role,
       COALESCE((SELECT runtime_version
                 FROM mdm_internal.policy_binding_runtime AS runtime
                 WHERE runtime.binding_id = binding.binding_id), 0)
           AS v048_runtime_version
FROM pgreact_mdm.policy_intent_bindings AS binding
WHERE binding.enabled AND binding.policy_revision = 'v0.48-live-policy'
  AND binding.entity_name = 'policy_qualification'
\gset

SET SESSION AUTHORIZATION mdm_m2_runner;
SET ROLE pgreact_mdm_worker;
DO $reject_stale$
DECLARE
    attempt pgreact_mdm.intent_attempts%ROWTYPE;
    request pgreact_mdm.intent_requests%ROWTYPE;
    response record;
BEGIN
    SELECT * INTO STRICT attempt
    FROM pgreact_mdm.intent_attempts
    WHERE outcome = 'APPLIED_CONTROL'
    ORDER BY attempted_at DESC, episode_id DESC, attempt_no DESC
    LIMIT 1;
    SELECT * INTO STRICT request
    FROM pgreact_mdm.intent_requests AS saved
    WHERE saved.binding_id = attempt.binding_id
      AND saved.request_key = attempt.request_key;
    BEGIN
        SELECT * INTO STRICT response
        FROM mdm_steward.submit_policy_intent(
            request.binding_id, request.request_key,
            (request.request_body ->> 'case_key')::bigint,
            request.request_body ->> 'action', request.request_body -> 'arguments',
            (request.request_body ->> 'expected_review_version')::bigint,
            (request.request_body ->> 'expected_definition_version')::bigint,
            (request.request_body ->> 'expected_publication_revision')::bigint,
            (request.request_body ->> 'expected_stewardship_epoch')::bigint,
            decode(request.request_body ->> 'expected_evidence_basis_digest', 'hex'),
            (request.request_body ->> 'expected_action_revision')::bigint,
            decode(request.request_body ->> 'expected_policy_digest', 'hex'),
            request.policy_revision, request.request_body ->> 'evaluation_ref',
            request.work_ref);
        RAISE EXCEPTION 'stale restored role read or replayed a receipt';
    EXCEPTION WHEN OTHERS THEN
        IF position('MDM_UNAUTHORIZED' IN SQLERRM) = 0 THEN RAISE; END IF;
    END;
END
$reject_stale$;
RESET ROLE;
RESET SESSION AUTHORIZATION;

SET ROLE :"v048_entity_role";
SELECT mdm_admin.rebind('policy_qualification');
RESET ROLE;
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE :"v048_entity_role";
SELECT pgreact_mdm.reconcile_intent_binding(
    :'v048_binding_id'::uuid, :v048_runtime_version) AS v048_active_version
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT binding.binding_id AS v048_escalation_binding_id,
       binding.entity_execution_role AS v048_escalation_entity_role,
       COALESCE(runtime.runtime_version, 0) AS v048_escalation_runtime_version
FROM pgreact_mdm.policy_intent_bindings AS binding
LEFT JOIN mdm_internal.policy_binding_runtime AS runtime USING (binding_id)
WHERE binding.enabled
  AND binding.policy_revision = 'v0.48-live-policy'
  AND binding.entity_name = 'review_admission_live'
\gset

RESET ROLE;
SET ROLE :"v048_escalation_entity_role";
SELECT mdm_admin.rebind('review_admission_live');
RESET ROLE;
SET SESSION AUTHORIZATION mdm_test_login;
SET ROLE :"v048_escalation_entity_role";
SELECT pgreact_mdm.reconcile_intent_binding(
    :'v048_escalation_binding_id'::uuid, :v048_escalation_runtime_version)
    AS v048_escalation_active_version
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION mdm_m2_runner;
SELECT pgreact_mdm.sync_intent_case_identities();
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION mdm_m2_runner;
SET ROLE pgreact_mdm_worker;
DO $replay$
DECLARE
    attempt pgreact_mdm.intent_attempts%ROWTYPE;
    request pgreact_mdm.intent_requests%ROWTYPE;
    response record;
    policy_case pgreact_mdm.authorized_policy_cases_v1%ROWTYPE;
BEGIN
    SELECT * INTO STRICT attempt
    FROM pgreact_mdm.intent_attempts
    WHERE outcome = 'APPLIED_CONTROL'
    ORDER BY attempted_at DESC, episode_id DESC, attempt_no DESC
    LIMIT 1;
    SELECT * INTO STRICT request
    FROM pgreact_mdm.intent_requests AS saved
    WHERE saved.binding_id = attempt.binding_id
      AND saved.request_key = attempt.request_key;
    SELECT * INTO STRICT response
    FROM mdm_steward.submit_policy_intent(
        request.binding_id, request.request_key,
        (request.request_body ->> 'case_key')::bigint,
        request.request_body ->> 'action', request.request_body -> 'arguments',
        (request.request_body ->> 'expected_review_version')::bigint,
        (request.request_body ->> 'expected_definition_version')::bigint,
        (request.request_body ->> 'expected_publication_revision')::bigint,
        (request.request_body ->> 'expected_stewardship_epoch')::bigint,
        decode(request.request_body ->> 'expected_evidence_basis_digest', 'hex'),
        (request.request_body ->> 'expected_action_revision')::bigint,
        decode(request.request_body ->> 'expected_policy_digest', 'hex'),
        request.policy_revision, request.request_body ->> 'evaluation_ref',
        request.work_ref);
    IF response.receipt_id IS DISTINCT FROM attempt.receipt_id
       OR response.outcome IS DISTINCT FROM attempt.outcome
       OR response.reason_code IS DISTINCT FROM attempt.reason_code
       OR response.action_revision IS DISTINCT FROM attempt.action_revision
       OR response.control IS DISTINCT FROM attempt.control
       OR response.resulting_publication_revision IS DISTINCT FROM
          attempt.resulting_publication_revision THEN
        RAISE EXCEPTION 'reconciled restore did not replay the exact durable receipt';
    END IF;
    SELECT * INTO STRICT policy_case
    FROM pgreact_mdm.authorized_policy_cases_v1
    WHERE case_key = attempt.case_key;
    IF policy_case.action_revision <> attempt.action_revision THEN
        RAISE EXCEPTION 'restore receipt replay changed the case action revision';
    END IF;
END
$replay$;
RESET ROLE;
RESET SESSION AUTHORIZATION;

DO $active$
DECLARE
    active_binding uuid;
    current_database_oid oid;
    current_worker_oid oid;
BEGIN
    SELECT binding_id INTO STRICT active_binding
    FROM pgreact_mdm.policy_intent_bindings
    WHERE enabled AND policy_revision = 'v0.48-live-policy'
      AND entity_name = 'policy_qualification';
    SELECT oid INTO STRICT current_database_oid
    FROM pg_catalog.pg_database WHERE datname = current_database();
    SELECT oid INTO STRICT current_worker_oid
    FROM pg_catalog.pg_roles WHERE rolname = 'pgreact_mdm_worker';
    IF NOT EXISTS (
        SELECT 1 FROM mdm_internal.policy_binding_runtime AS runtime
        WHERE runtime.binding_id = active_binding
          AND runtime.state = 'active'
          AND runtime.database_oid = current_database_oid
          AND runtime.automation_role_oid = current_worker_oid)
       OR NOT EXISTS (
        SELECT 1 FROM pgreact_mdm.policy_intent_runtime AS runtime
        WHERE runtime.binding_id = active_binding
          AND runtime.database_oid = current_database_oid
          AND runtime.worker_role_oid = current_worker_oid)
       OR NOT EXISTS (
        SELECT 1 FROM pgreact_mdm.authorized_policy_cases_v1 AS policy_case
        JOIN pgreact_mdm.policy_intent_bindings AS binding
          ON binding.entity_name = policy_case.entity_name
        WHERE binding.binding_id = active_binding) THEN
        RAISE EXCEPTION 'entity-role reconciliation did not restore the current runtime identity';
    END IF;
END
$active$;

SELECT 'v0.48 logical restore and OID reconciliation passed' AS result;
