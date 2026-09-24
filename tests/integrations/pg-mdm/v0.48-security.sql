\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SELECT current_database() AS v048_database \gset
\connect :v048_database mdm_m2_runner
SET ROLE pgreact_mdm_worker;

DO $security$
DECLARE
    runner pg_catalog.pg_roles%ROWTYPE;
    runner_oid oid;
    worker pg_catalog.pg_roles%ROWTYPE;
    worker_oid oid;
    entity_role name;
    request_row pgreact_mdm.intent_requests%ROWTYPE;
    attempt_row pgreact_mdm.intent_attempts%ROWTYPE;
    response record;
    conflict_response record;
    replay_response record;
    stale_response record;
    changed_arguments jsonb;
    stale_key bytea;
    visible_case pgreact_mdm.authorized_policy_cases_v1%ROWTYPE;
BEGIN
    SELECT * INTO STRICT runner
    FROM pg_catalog.pg_roles
    WHERE rolname = session_user;
    runner_oid := runner.oid;
    SELECT * INTO STRICT worker
    FROM pg_catalog.pg_roles
    WHERE rolname = current_user;
    worker_oid := worker.oid;
    IF NOT runner.rolcanlogin OR runner.rolsuper OR runner.rolbypassrls
       OR runner.rolinherit
       OR NOT pg_catalog.pg_has_role(runner_oid, worker_oid, 'SET')
       OR pg_catalog.pg_has_role(runner_oid, 'mdm_helper_owner', 'MEMBER')
       OR EXISTS (
           SELECT 1
           FROM pgreact_mdm.policy_intent_bindings AS binding
           JOIN pg_catalog.pg_roles AS entity
             ON entity.rolname = binding.entity_execution_role
           WHERE pg_catalog.pg_has_role(runner_oid, entity.oid, 'MEMBER')) THEN
        RAISE EXCEPTION 'pg-react runner must only be able to set the automation role';
    END IF;
    IF NOT pg_catalog.has_table_privilege(runner_oid,
           'mdm_steward.policy_cases_v1', 'SELECT')
       OR pg_catalog.has_table_privilege(runner_oid,
           'mdm_steward.policy_bindings_v1', 'SELECT')
       OR pg_catalog.has_table_privilege(runner_oid,
           'mdm_steward.policy_receipts_v1', 'SELECT') THEN
        RAISE EXCEPTION 'pg-react runner may read only the policy case projection';
    END IF;
    IF worker.rolcanlogin OR worker.rolsuper OR worker.rolbypassrls
       OR worker.rolinherit OR worker.rolcreatedb OR worker.rolcreaterole
       OR worker.rolreplication THEN
        RAISE EXCEPTION 'worker role attributes are not least-privilege';
    END IF;
    IF pg_catalog.pg_has_role(worker_oid, 'mdm_helper_owner', 'MEMBER')
       OR EXISTS (
           SELECT 1
           FROM pgreact_mdm.policy_intent_bindings AS binding
           JOIN pg_catalog.pg_roles AS entity
             ON entity.rolname = binding.entity_execution_role
           WHERE pg_catalog.pg_has_role(worker_oid, entity.oid, 'MEMBER')) THEN
        RAISE EXCEPTION 'worker can become an MDM helper or entity execution role';
    END IF;

    IF NOT pg_catalog.has_table_privilege(worker_oid,
           'pgreact_mdm.authorized_policy_cases_v1', 'SELECT')
       OR pg_catalog.has_table_privilege(worker_oid,
           'mdm_steward.policy_cases_v1', 'SELECT')
       OR pg_catalog.has_table_privilege(worker_oid,
           'mdm_steward.policy_bindings_v1', 'SELECT')
       OR pg_catalog.has_table_privilege(worker_oid,
           'mdm_steward.policy_receipts_v1', 'SELECT')
       OR EXISTS (
           SELECT 1
           FROM pg_catalog.pg_class AS relation
           JOIN pg_catalog.pg_namespace AS namespace
             ON namespace.oid = relation.relnamespace
           WHERE namespace.nspname = 'mdm_internal'
             AND relation.relname = 'policy_binding_runtime'
             AND pg_catalog.has_table_privilege(worker_oid, relation.oid, 'SELECT')) THEN
        RAISE EXCEPTION 'worker MDM relation privileges are broader than the authorized case view';
    END IF;
    IF NOT pg_catalog.has_function_privilege(worker_oid,
           'mdm_steward.submit_policy_intent(uuid,bytea,bigint,text,jsonb,bigint,bigint,bigint,bigint,bytea,bigint,bytea,text,text,text)',
           'EXECUTE')
       OR pg_catalog.has_schema_privilege(worker_oid, 'mdm_admin', 'USAGE')
       OR pg_catalog.has_schema_privilege(worker_oid, 'mdm_internal', 'USAGE') THEN
        RAISE EXCEPTION 'worker cannot reach only the bound intent API';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc AS procedure
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = procedure.pronamespace
        WHERE namespace.nspname = 'mdm_internal'
          AND pg_catalog.has_function_privilege(worker_oid, procedure.oid, 'EXECUTE')
          AND procedure.prosecdef
    ) THEN
        RAISE EXCEPTION 'worker can execute a privileged MDM SECURITY DEFINER helper';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_proc AS procedure
        JOIN pg_catalog.pg_namespace AS namespace
          ON namespace.oid = procedure.pronamespace
        WHERE ((namespace.nspname = 'mdm_admin'
                AND procedure.proname = ANY(ARRAY[
                    'create_policy_binding', 'replace_policy_binding',
                    'set_policy_binding_state']))
            OR (namespace.nspname = 'mdm_steward'
                AND procedure.proname = 'set_case_controls'))
          AND pg_catalog.has_function_privilege(worker_oid, procedure.oid, 'EXECUTE')
    ) THEN
        RAISE EXCEPTION 'worker has direct privileges on MDM binding or human-control APIs';
    END IF;
    BEGIN
        PERFORM 1 FROM mdm_steward.policy_cases_v1;
        RAISE EXCEPTION 'worker read the unfiltered MDM case table';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        PERFORM 1 FROM mdm_steward.policy_bindings_v1;
        RAISE EXCEPTION 'worker read the MDM binding table';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        PERFORM 1 FROM mdm_steward.policy_receipts_v1;
        RAISE EXCEPTION 'worker read the MDM receipt table';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    BEGIN
        PERFORM 1 FROM mdm_internal.policy_binding_runtime;
        RAISE EXCEPTION 'worker read the MDM binding runtime table';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    BEGIN
        PERFORM pg_catalog.set_config('role', 'mdm_helper_owner', true);
        RAISE EXCEPTION 'worker changed role to mdm_helper_owner';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    SELECT entity_execution_role INTO STRICT entity_role
    FROM pgreact_mdm.policy_intent_bindings
    WHERE enabled
    ORDER BY binding_id
    LIMIT 1;
    BEGIN
        PERFORM pg_catalog.set_config('role', entity_role::text, true);
        RAISE EXCEPTION 'worker changed role to %', entity_role;
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;

    SELECT * INTO STRICT attempt_row
    FROM pgreact_mdm.intent_attempts
    WHERE outcome = 'APPLIED_CONTROL'
    ORDER BY attempted_at DESC, episode_id DESC, attempt_no DESC
    LIMIT 1;
    SELECT * INTO STRICT request_row
    FROM pgreact_mdm.intent_requests AS request
    WHERE request.binding_id = attempt_row.binding_id
      AND request.request_key = attempt_row.request_key;
    IF attempt_row.receipt_id IS NULL
       OR attempt_row.request_body IS DISTINCT FROM request_row.request_body
       OR attempt_row.request_digest <> request_row.request_digest
       OR request_row.request_digest <> pgreact_mdm.intent_request_digest(request_row.request_body)
       OR request_row.request_key <> pgreact_mdm.intent_request_key(
           request_row.binding_id, request_row.policy_revision, request_row.case_key,
           request_row.lifecycle_generation, request_row.action_revision,
           request_row.consequence_identity, request_row.escalation_level) THEN
        RAISE EXCEPTION 'saved request and applied attempt do not correlate exactly';
    END IF;

    SELECT * INTO STRICT response
    FROM mdm_steward.submit_policy_intent(
        request_row.binding_id, request_row.request_key,
        (request_row.request_body ->> 'case_key')::bigint,
        request_row.request_body ->> 'action', request_row.request_body -> 'arguments',
        (request_row.request_body ->> 'expected_review_version')::bigint,
        (request_row.request_body ->> 'expected_definition_version')::bigint,
        (request_row.request_body ->> 'expected_publication_revision')::bigint,
        (request_row.request_body ->> 'expected_stewardship_epoch')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_evidence_basis_digest', 'hex'),
        (request_row.request_body ->> 'expected_action_revision')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_policy_digest', 'hex'),
        request_row.request_body ->> 'policy_revision',
        request_row.request_body ->> 'evaluation_ref',
        request_row.request_body ->> 'work_ref');
    IF response.receipt_id IS DISTINCT FROM attempt_row.receipt_id
       OR response.outcome IS DISTINCT FROM attempt_row.outcome
       OR response.reason_code IS DISTINCT FROM attempt_row.reason_code
       OR response.case_key IS DISTINCT FROM attempt_row.case_key
       OR response.action_revision IS DISTINCT FROM attempt_row.action_revision
       OR response.control IS DISTINCT FROM attempt_row.control
       OR response.resulting_publication_revision IS DISTINCT FROM attempt_row.resulting_publication_revision THEN
        RAISE EXCEPTION 'identical worker retry did not return the exact saved receipt result';
    END IF;
    changed_arguments := CASE request_row.request_body ->> 'action'
        WHEN 'ASSIGN_QUEUE' THEN jsonb_set(
            request_row.request_body -> 'arguments', '{queue}',
            to_jsonb((request_row.request_body -> 'arguments' ->> 'queue') || '-changed'))
        WHEN 'SET_DUE_AT' THEN jsonb_set(
            request_row.request_body -> 'arguments', '{due_at}',
            to_jsonb(((request_row.request_body -> 'arguments' ->> 'due_at')::timestamptz
                      + interval '1 second')::text))
        WHEN 'ESCALATE' THEN jsonb_set(
            request_row.request_body -> 'arguments', '{level}',
            to_jsonb((request_row.request_body -> 'arguments' ->> 'level')::integer + 1))
    END;
    SELECT * INTO STRICT conflict_response
    FROM mdm_steward.submit_policy_intent(
        request_row.binding_id, request_row.request_key,
        (request_row.request_body ->> 'case_key')::bigint,
        request_row.request_body ->> 'action', changed_arguments,
        (request_row.request_body ->> 'expected_review_version')::bigint,
        (request_row.request_body ->> 'expected_definition_version')::bigint,
        (request_row.request_body ->> 'expected_publication_revision')::bigint,
        (request_row.request_body ->> 'expected_stewardship_epoch')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_evidence_basis_digest', 'hex'),
        (request_row.request_body ->> 'expected_action_revision')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_policy_digest', 'hex'),
        request_row.request_body ->> 'policy_revision',
        request_row.request_body ->> 'evaluation_ref',
        request_row.request_body ->> 'work_ref');
    IF conflict_response.receipt_id IS NOT NULL
       OR conflict_response.outcome IS DISTINCT FROM 'IDEMPOTENCY_CONFLICT'
       OR conflict_response.reason_code IS DISTINCT FROM 'REQUEST_KEY_BODY_MISMATCH'
       OR conflict_response.case_key IS DISTINCT FROM attempt_row.case_key
       OR conflict_response.action_revision IS DISTINCT FROM
          (request_row.request_body ->> 'expected_action_revision')::bigint
       OR conflict_response.control IS NOT NULL
       OR conflict_response.resulting_publication_revision IS NOT NULL THEN
        RAISE EXCEPTION 'changed-body retry did not return the exact idempotency conflict';
    END IF;
    SELECT * INTO STRICT replay_response
    FROM mdm_steward.submit_policy_intent(
        request_row.binding_id, request_row.request_key,
        (request_row.request_body ->> 'case_key')::bigint,
        request_row.request_body ->> 'action', request_row.request_body -> 'arguments',
        (request_row.request_body ->> 'expected_review_version')::bigint,
        (request_row.request_body ->> 'expected_definition_version')::bigint,
        (request_row.request_body ->> 'expected_publication_revision')::bigint,
        (request_row.request_body ->> 'expected_stewardship_epoch')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_evidence_basis_digest', 'hex'),
        (request_row.request_body ->> 'expected_action_revision')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_policy_digest', 'hex'),
        request_row.request_body ->> 'policy_revision',
        request_row.request_body ->> 'evaluation_ref',
        request_row.request_body ->> 'work_ref');
    IF replay_response.receipt_id IS DISTINCT FROM attempt_row.receipt_id
       OR replay_response.outcome IS DISTINCT FROM attempt_row.outcome
       OR replay_response.reason_code IS DISTINCT FROM attempt_row.reason_code
       OR replay_response.action_revision IS DISTINCT FROM attempt_row.action_revision
       OR replay_response.control IS DISTINCT FROM attempt_row.control THEN
        RAISE EXCEPTION 'changed-body conflict altered the original durable receipt';
    END IF;
    SELECT * INTO STRICT visible_case
    FROM pgreact_mdm.authorized_policy_cases_v1
    WHERE case_key = attempt_row.case_key;
    IF visible_case.action_revision IS DISTINCT FROM attempt_row.action_revision THEN
        RAISE EXCEPTION 'same-body retry changed action_revision';
    END IF;

    BEGIN
        PERFORM * FROM mdm_steward.decide(
            'policy_qualification', '40000000-0000-4000-8000-000000000001',
            '40000000-0000-4000-8000-000000000002', 'MATCH', 1,
            'worker must not decide identity');
        RAISE EXCEPTION 'worker invoked the human decision API';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    WHEN OTHERS THEN
        IF pg_catalog.strpos(SQLERRM, 'MDM_UNAUTHORIZED') = 0 THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM * FROM mdm_steward.override_golden(
            'policy_qualification', '40000000-0000-4000-8000-000000000001',
            'name', '"unauthorized"'::jsonb, 0, 'worker must not override identity');
        RAISE EXCEPTION 'worker invoked the golden-override API';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    WHEN OTHERS THEN
        IF pg_catalog.strpos(SQLERRM, 'MDM_UNAUTHORIZED') = 0 THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM * FROM mdm_steward.clear_golden_override(
            'policy_qualification', '40000000-0000-4000-8000-000000000001',
            'name', 0, 'worker must not clear identity override');
        RAISE EXCEPTION 'worker invoked the clear-override API';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    WHEN OTHERS THEN
        IF pg_catalog.strpos(SQLERRM, 'MDM_UNAUTHORIZED') = 0 THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM mdm.refresh('policy_qualification', 'ALLOW');
        RAISE EXCEPTION 'worker invoked MDM refresh';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    WHEN OTHERS THEN
        IF pg_catalog.strpos(SQLERRM, 'MDM_UNAUTHORIZED') = 0 THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM mdm_admin.rebuild('policy_qualification', 'ALLOW');
        RAISE EXCEPTION 'worker invoked MDM rebuild';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    WHEN OTHERS THEN
        IF pg_catalog.strpos(SQLERRM, 'MDM_UNAUTHORIZED') = 0 THEN RAISE; END IF;
    END;

    stale_key := pgreact_mdm.intent_request_key(
        request_row.binding_id, request_row.policy_revision, request_row.case_key,
        request_row.lifecycle_generation + 1, visible_case.action_revision,
        'stale-token-probe', request_row.escalation_level);
    SELECT * INTO STRICT stale_response
    FROM mdm_steward.submit_policy_intent(
        request_row.binding_id, stale_key, request_row.case_key,
        request_row.request_body ->> 'action', request_row.request_body -> 'arguments',
        (request_row.request_body ->> 'expected_review_version')::bigint,
        (request_row.request_body ->> 'expected_definition_version')::bigint,
        (request_row.request_body ->> 'expected_publication_revision')::bigint,
        (request_row.request_body ->> 'expected_stewardship_epoch')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_evidence_basis_digest', 'hex'),
        (request_row.request_body ->> 'expected_action_revision')::bigint,
        pg_catalog.decode(request_row.request_body ->> 'expected_policy_digest', 'hex'),
        request_row.policy_revision, 'pgreact:test-stale-token',
        'pgreact:test-stale-token:' || request_row.case_key::text);
    IF stale_response.receipt_id IS NULL
       OR stale_response.outcome IS DISTINCT FROM 'STALE_CASE'
       OR stale_response.reason_code IS DISTINCT FROM 'FRESHNESS_TOKEN_MISMATCH'
       OR stale_response.action_revision IS DISTINCT FROM visible_case.action_revision
       OR stale_response.control IS DISTINCT FROM jsonb_build_object(
           'assigned_queue', visible_case.assigned_queue::text,
           'due_at', visible_case.due_at::text,
           'escalation_level', visible_case.escalation_level,
           'manual_assignment_protected', visible_case.manual_assignment_protected) THEN
        RAISE EXCEPTION 'worker token-stale intent did not return the exact no-change receipt';
    END IF;
    SELECT * INTO STRICT visible_case
    FROM pgreact_mdm.authorized_policy_cases_v1
    WHERE case_key = attempt_row.case_key;
    IF visible_case.action_revision IS DISTINCT FROM attempt_row.action_revision THEN
        RAISE EXCEPTION 'stale token changed the case action_revision';
    END IF;
END
$security$;

RESET ROLE;
SELECT 'v0.48 actual worker privileges and retry passed' AS result;
