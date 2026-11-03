\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS dblink;
SET TIME ZONE 'UTC';
SELECT pgreact_api.pause_rule('s1-callback-failure');
SELECT pgreact_api.pause_rule('s1-future-idle');
CREATE SCHEMA s1_claimed;
CREATE ROLE s1_claimed_reader LOGIN NOSUPERUSER NOBYPASSRLS;
GRANT s1_reader TO s1_claimed_reader;
CREATE ROLE s1_unconfigured_reader LOGIN NOSUPERUSER NOBYPASSRLS;
GRANT USAGE ON SCHEMA pgreact_mdm TO s1_reader;
CREATE TABLE s1_claimed.cases (case_key bigint PRIMARY KEY);
INSERT INTO s1_claimed.cases SELECT case_key FROM s1_audit.source;
INSERT INTO public.policy_qualification_source VALUES
    (1001,'Claimed One','claimed-one@example.test',statement_timestamp()),
    (1002,'Claimed One','claimed-pair@example.test',statement_timestamp()),
    (1003,'Claimed Two','claimed-two@example.test',statement_timestamp()),
    (1004,'Claimed Two','claimed-pair@example.test',statement_timestamp());
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm.refresh('policy_qualification','ALLOW');
DO $prepare$
DECLARE c record;
BEGIN
    FOR c IN SELECT case_key,action_revision FROM mdm_steward.policy_cases_v1
             WHERE entity_name='policy_qualification' AND status='open' ORDER BY case_key
    LOOP
        PERFORM mdm_steward.set_case_controls(c.case_key,NULL,
            statement_timestamp()-interval '1 hour',1,false,c.action_revision,
            'Claimed-work deterministic concurrency setup');
    END LOOP;
END
$prepare$;
RESET ROLE;
RESET SESSION AUTHORIZATION;
INSERT INTO s1_claimed.cases SELECT case_key FROM mdm_steward.policy_cases_v1
WHERE entity_name='policy_qualification' AND status='open'
ON CONFLICT DO NOTHING;
INSERT INTO s1_audit.source SELECT case_key,due_at FROM mdm_steward.policy_cases_v1
WHERE case_key IN (SELECT case_key FROM s1_claimed.cases) ON CONFLICT DO NOTHING;
SELECT pgreact_mdm.sync_intent_case_identities();
SET SESSION AUTHORIZATION mdm_s1_runner;
SELECT pgreact_api.author_deadline_rule('s1-claimed-work',
    'pgreact_mdm.intent_deployer_policy_cases_v1'::regclass,'case_key','due_at','COMMAND',
    'pgreact_mdm.submit_escalation_intent(pgreact.activation_context,pgreact_mdm.intent_deployer_policy_cases_v1)');
RESET SESSION AUTHORIZATION;
SELECT pgreact_mdm.configure_intent_deployer('mdm_s1_runner');
SELECT pgreact_api.run();
DO $inspection_privileges$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'select',has_table_privilege('s1_claimed_reader','pgreact_mdm.delivery_inspection_v1','SELECT'),
        'insert',has_table_privilege('s1_claimed_reader','pgreact_mdm.delivery_inspection_v1','INSERT'),
        'update',has_table_privilege('s1_claimed_reader','pgreact_mdm.delivery_inspection_v1','UPDATE'),
        'delete',has_table_privilege('s1_claimed_reader','pgreact_mdm.delivery_inspection_v1','DELETE'))
    INTO actual;
    IF actual IS DISTINCT FROM '{"select":true,"insert":false,"update":false,"delete":false}'::jsonb THEN
        RAISE EXCEPTION 'delivery inspection must be reader-selectable and read-only: %',actual;
    END IF;
END
$inspection_privileges$;
SET SESSION AUTHORIZATION s1_unconfigured_reader;
DO $unconfigured_delivery_inspection$
DECLARE
    actual_sqlstate text;
    actual_message text;
BEGIN
    IF has_schema_privilege(current_user, 'pgreact_mdm', 'USAGE') THEN
        RAISE EXCEPTION 'unconfigured reader unexpectedly has pgreact_mdm schema usage';
    END IF;
    BEGIN
        PERFORM 1 FROM pgreact_mdm.delivery_inspection_v1 LIMIT 1;
        RAISE EXCEPTION 'unconfigured reader unexpectedly read delivery inspection';
    EXCEPTION WHEN insufficient_privilege THEN
        GET STACKED DIAGNOSTICS
            actual_sqlstate = RETURNED_SQLSTATE,
            actual_message = MESSAGE_TEXT;
        IF actual_sqlstate <> '42501'
           OR actual_message <> 'permission denied for schema pgreact_mdm' THEN
            RAISE EXCEPTION 'unconfigured reader was denied unexpectedly: % %',
                actual_sqlstate, actual_message;
        END IF;
    END;
END
$unconfigured_delivery_inspection$;
RESET SESSION AUTHORIZATION;
SELECT jsonb_build_object('unconfigured_delivery_inspection_privileges',
    jsonb_build_object('schema_usage',has_schema_privilege(
        's1_unconfigured_reader','pgreact_mdm','USAGE'),
        'query','DENIED','sqlstate','42501',
        'message','permission denied for schema pgreact_mdm'));
BEGIN;
CREATE TEMP TABLE pending_inspection_evidence(expected jsonb, actual jsonb);
DO $pending_inspection$
DECLARE
    binding pgreact_mdm.policy_intent_bindings%ROWTYPE;
    policy_case mdm_steward.policy_cases_v1%ROWTYPE;
    request_key bytea;
    request_body jsonb;
    created_at timestamptz;
    actual jsonb;
    expected jsonb;
BEGIN
    SELECT * INTO STRICT binding
    FROM pgreact_mdm.policy_intent_bindings
    WHERE enabled AND entity_name = 'policy_qualification'
    ORDER BY binding_version DESC LIMIT 1;
    SELECT c.* INTO STRICT policy_case
    FROM mdm_steward.policy_cases_v1 AS c
    WHERE c.entity_name = binding.entity_name AND c.status = 'open'
      AND c.case_key IN (SELECT case_key FROM s1_claimed.cases)
      AND NOT EXISTS (
          SELECT 1 FROM pgreact_mdm.intent_holds AS h
          WHERE h.binding_id = binding.binding_id AND h.case_key = c.case_key)
    ORDER BY c.case_key LIMIT 1;
    request_key := pgreact_mdm.intent_request_key(
        binding.binding_id, binding.policy_revision, policy_case.case_key,
        2147483647, policy_case.action_revision, 'diagnostic_fixture', 2);
    request_body := pgreact_mdm.intent_request_body(
        binding.binding_id, policy_case.case_key, 'ESCALATE', '{"level":2}'::jsonb,
        policy_case.review_version, policy_case.definition_version,
        policy_case.publication_revision, policy_case.stewardship_epoch,
        policy_case.evidence_basis_digest, policy_case.action_revision,
        binding.policy_digest, binding.policy_revision,
        'pending-inspection-fixture', 'pgreact:pending-inspection-fixture');
    INSERT INTO pgreact_mdm.intent_requests(
        binding_id, request_key, request_digest, request_body, work_ref,
        policy_revision, case_key, lifecycle_generation, action_revision,
        consequence_identity, escalation_level, first_episode_id)
    VALUES (binding.binding_id, request_key,
        pgreact_mdm.intent_request_digest(request_body), request_body,
        'pgreact:pending-inspection-fixture', binding.policy_revision,
        policy_case.case_key, 2147483647, policy_case.action_revision,
        'diagnostic_fixture', 2, 2147483647)
    RETURNING intent_requests.created_at INTO created_at;

    SELECT to_jsonb(i) INTO actual
    FROM pgreact_mdm.delivery_inspection_v1 AS i
    WHERE i.work_ref = 'pgreact:pending-inspection-fixture';
    expected := jsonb_build_object(
        'work_ref','pgreact:pending-inspection-fixture',
        'binding_id',binding.binding_id,'binding_version',binding.binding_version,
        'entity_name',binding.entity_name,'policy_revision',binding.policy_revision,
        'policy_digest',encode(binding.policy_digest,'hex'),
        'case_key',policy_case.case_key,'lifecycle_generation',2147483647,
        'action_revision',policy_case.action_revision,'action','ESCALATE',
        'requested_at',created_at,'delivery_outcome','PENDING',
        'delivery_reason_code',NULL,'attempted_at',NULL,'mdm_receipt_id',NULL,
        'mdm_outcome',NULL,'mdm_reason_code',NULL,
        'resulting_publication_revision',NULL,
        'current_case_status',policy_case.status,
        'current_publication_revision',policy_case.publication_revision,
        'remediation_state','NONE','remediation_reason_code',NULL,'remediation_at',NULL,
        'requested_due_at',NULL,'current_due_at',policy_case.due_at,
        'requested_escalation_level',2,'applied_escalation_level',NULL,
        'current_escalation_level',policy_case.escalation_level,
        'current_manual_assignment_protected',policy_case.manual_assignment_protected,
        'current_pending_stewardship',policy_case.pending_stewardship);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'pending delivery inspection: expected %, got %',expected,actual;
    END IF;
    INSERT INTO pg_temp.pending_inspection_evidence VALUES (expected,actual);
END
$pending_inspection$;
SET SESSION AUTHORIZATION s1_claimed_reader;
SELECT to_jsonb(i) AS reader_actual
FROM pgreact_mdm.delivery_inspection_v1 AS i
WHERE i.work_ref = 'pgreact:pending-inspection-fixture'
\gset
DO $route_reader_denied$
BEGIN
    BEGIN
        PERFORM pgreact_mdm.route_cases(
            'pgreact_mdm.authorized_policy_cases_v1'::regclass,
            's1-idle-feasibility', 'policy_qualification', statement_timestamp(), 1);
        RAISE EXCEPTION 'route bypassed source privileges';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'MDM_INPUT_UNAUTHORIZED: pgreact_mdm.authorized_policy_cases_v1 is not readable by s1_claimed_reader' THEN
            RAISE;
        END IF;
    END;
END
$route_reader_denied$;
RESET SESSION AUTHORIZATION;
GRANT SELECT ON pgreact_mdm.authorized_policy_cases_v1 TO s1_claimed_reader;
SET SESSION AUTHORIZATION s1_claimed_reader;
WITH selected_case AS (
    SELECT policy_case.*
    FROM pgreact_mdm.authorized_policy_cases_v1 AS policy_case
    WHERE policy_case.entity_name = 'policy_qualification'
      AND policy_case.status = 'open'
      AND policy_case.reason_code = (
          SELECT route ->> 'reason_code'
          FROM pgreact_mdm.policy_packages AS package
          CROSS JOIN LATERAL jsonb_array_elements(package.policy_package -> 'routes') AS item(route)
          WHERE package.policy_revision = 's1-idle-feasibility'
            AND route ->> 'entity_name' = 'policy_qualification'
            AND route ->> 'action' = 'ESCALATE'
          LIMIT 1)
      AND policy_case.permitted_actions @> ARRAY['ESCALATE']::text[]
), sampled_case AS (
    SELECT selected_case.*, due_at - interval '1 microsecond' AS captured_at
    FROM selected_case
    ORDER BY case_key
    LIMIT 1
), evaluated AS (
    SELECT sampled_case.*,
           route.explanation AS actual
    FROM sampled_case
    CROSS JOIN LATERAL pgreact_mdm.route_cases(
        'pgreact_mdm.authorized_policy_cases_v1'::regclass,
        's1-idle-feasibility', 'policy_qualification',
        sampled_case.captured_at, sampled_case.case_key) AS route
)
SELECT jsonb_build_object(
    'name', 'authorized_route_explanation',
    'expected', jsonb_build_object(
        'case_key', case_key, 'review_id', review_id,
        'decision', 'INELIGIBLE', 'selected_queue', NULL, 'applicable', true,
        'reason', 'deadline has not been reached',
        'captured_at', to_jsonb(captured_at), 'due_at', to_jsonb(due_at),
        'deadline_due', false, 'current_escalation_level', escalation_level,
        'requested_escalation_level', 2,
        'manual_assignment_protected', manual_assignment_protected,
        'pending_stewardship', pending_stewardship,
        'competitors', jsonb_build_array(jsonb_build_object(
            'reason_code', reason_code, 'entity_name', entity_name::text,
            'queue', NULL, 'priority', 0, 'action', 'ESCALATE', 'level', 2))),
    'actual', actual) AS route_inspection
FROM evaluated
\gset
RESET SESSION AUTHORIZATION;
SELECT :'route_inspection'::jsonb;

CREATE TEMP TABLE route_deployer_assertion(expected jsonb, actual jsonb);
INSERT INTO route_deployer_assertion(expected)
VALUES (:'route_inspection'::jsonb -> 'expected');
SET SESSION AUTHORIZATION mdm_s1_runner;
SELECT route.explanation AS deployer_route_actual
FROM pgreact_mdm.route_cases(
    'pgreact_mdm.authorized_policy_cases_v1'::regclass,
    's1-idle-feasibility', 'policy_qualification',
    (:'route_inspection'::jsonb -> 'expected' ->> 'captured_at')::timestamptz,
    (:'route_inspection'::jsonb -> 'expected' ->> 'case_key')::bigint) AS route
\gset
RESET SESSION AUTHORIZATION;
UPDATE pg_temp.route_deployer_assertion
SET actual = :'deployer_route_actual'::jsonb;
DO $route_deployer$
DECLARE expected jsonb; actual jsonb;
BEGIN
    SELECT route_deployer_assertion.expected, route_deployer_assertion.actual
    INTO STRICT expected, actual
    FROM pg_temp.route_deployer_assertion;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'configured deployer route explanation mismatch: expected %, actual %',
            expected, actual;
    END IF;
END
$route_deployer$;

SELECT policy_case.case_key AS route_case_key
FROM mdm_steward.policy_cases_v1 AS policy_case
JOIN s1_audit.source AS selected USING (case_key)
WHERE policy_case.entity_name = 'policy_qualification'
  AND policy_case.status = 'open'
ORDER BY policy_case.case_key
LIMIT 1
\gset
CREATE TEMP TABLE protected_route_case(case_key bigint);
INSERT INTO pg_temp.protected_route_case VALUES (:'route_case_key'::bigint);
SELECT pgreact_mdm.publish_package(
    's1-route-diagnostics',
    jsonb_build_object(
        'deadline', jsonb_build_object(
            'duration_seconds', 3600, 'min_seconds', 60, 'max_seconds', 86400,
            'replace_existing_deadline', false),
        'routes', jsonb_build_array(jsonb_build_object(
            'entity_name', 'policy_qualification',
            'reason_code', (SELECT reason_code FROM mdm_steward.policy_cases_v1
                            WHERE case_key = :route_case_key),
            'queue', 'priority_review', 'priority', 1, 'action', 'ASSIGN_QUEUE'))));

SELECT action_revision AS route_action_revision, due_at AS route_due_at,
       escalation_level AS route_level
FROM mdm_steward.policy_cases_v1 WHERE case_key = :route_case_key
\gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :route_case_key, NULL::name, :'route_due_at'::timestamptz, :route_level,
    true, :route_action_revision, 'Read-only route diagnostic protected case');
RESET ROLE;
RESET SESSION AUTHORIZATION;
CREATE TEMP TABLE protected_delivery_inspection_evidence(expected jsonb, actual jsonb);
DO $protected_delivery_inspection$
DECLARE
    binding pgreact_mdm.policy_intent_bindings%ROWTYPE;
    policy_case mdm_steward.policy_cases_v1%ROWTYPE;
    request_key bytea;
    request_body jsonb;
    created_at timestamptz;
    actual jsonb;
    expected jsonb;
BEGIN
    SELECT * INTO STRICT binding
    FROM pgreact_mdm.policy_intent_bindings
    WHERE enabled AND entity_name = 'policy_qualification'
    ORDER BY binding_version DESC LIMIT 1;
    SELECT c.* INTO STRICT policy_case
    FROM mdm_steward.policy_cases_v1 AS c
    JOIN pg_temp.protected_route_case AS fixture USING (case_key);
    IF NOT policy_case.manual_assignment_protected THEN
        RAISE EXCEPTION 'protected delivery inspection fixture is not protected';
    END IF;
    request_key := pgreact_mdm.intent_request_key(
        binding.binding_id, binding.policy_revision, policy_case.case_key,
        2147483646, policy_case.action_revision, 'protected_inspection_fixture', 2);
    request_body := pgreact_mdm.intent_request_body(
        binding.binding_id, policy_case.case_key, 'ESCALATE', '{"level":2}'::jsonb,
        policy_case.review_version, policy_case.definition_version,
        policy_case.publication_revision, policy_case.stewardship_epoch,
        policy_case.evidence_basis_digest, policy_case.action_revision,
        binding.policy_digest, binding.policy_revision,
        'protected-inspection-fixture', 'pgreact:protected-inspection-fixture');
    INSERT INTO pgreact_mdm.intent_requests(
        binding_id, request_key, request_digest, request_body, work_ref,
        policy_revision, case_key, lifecycle_generation, action_revision,
        consequence_identity, escalation_level, first_episode_id)
    VALUES (binding.binding_id, request_key,
        pgreact_mdm.intent_request_digest(request_body), request_body,
        'pgreact:protected-inspection-fixture', binding.policy_revision,
        policy_case.case_key, 2147483646, policy_case.action_revision,
        'protected_inspection_fixture', 2, 2147483646)
    RETURNING intent_requests.created_at INTO created_at;

    SELECT to_jsonb(i) INTO actual
    FROM pgreact_mdm.delivery_inspection_v1 AS i
    WHERE i.work_ref = 'pgreact:protected-inspection-fixture';
    expected := jsonb_build_object(
        'work_ref','pgreact:protected-inspection-fixture',
        'binding_id',binding.binding_id,'binding_version',binding.binding_version,
        'entity_name',binding.entity_name,'policy_revision',binding.policy_revision,
        'policy_digest',encode(binding.policy_digest,'hex'),
        'case_key',policy_case.case_key,'lifecycle_generation',2147483646,
        'action_revision',policy_case.action_revision,'action','ESCALATE',
        'requested_at',created_at,'delivery_outcome','PENDING',
        'delivery_reason_code',NULL,'attempted_at',NULL,'mdm_receipt_id',NULL,
        'mdm_outcome',NULL,'mdm_reason_code',NULL,
        'resulting_publication_revision',NULL,
        'current_case_status',policy_case.status,
        'current_publication_revision',policy_case.publication_revision,
        'remediation_state','NONE','remediation_reason_code',NULL,'remediation_at',NULL,
        'requested_due_at',NULL,'current_due_at',policy_case.due_at,
        'requested_escalation_level',2,'applied_escalation_level',NULL,
        'current_escalation_level',policy_case.escalation_level,
        'current_manual_assignment_protected',true,
        'current_pending_stewardship',policy_case.pending_stewardship);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'protected delivery inspection: expected %, got %',expected,actual;
    END IF;
    INSERT INTO pg_temp.protected_delivery_inspection_evidence(expected)
    VALUES (expected);
END
$protected_delivery_inspection$;
SET SESSION AUTHORIZATION s1_claimed_reader;
SELECT to_jsonb(i) AS protected_reader_actual
FROM pgreact_mdm.delivery_inspection_v1 AS i
WHERE i.work_ref = 'pgreact:protected-inspection-fixture'
\gset
RESET SESSION AUTHORIZATION;
UPDATE pg_temp.protected_delivery_inspection_evidence
SET actual = :'protected_reader_actual'::jsonb;
SELECT jsonb_build_object('name','protected_delivery_inspection',
    'expected',expected,'actual',actual)
FROM pg_temp.protected_delivery_inspection_evidence;
SET SESSION AUTHORIZATION s1_claimed_reader;
WITH selected_case AS (
    SELECT policy_case.*, statement_timestamp() AS captured_at
    FROM pgreact_mdm.authorized_policy_cases_v1 AS policy_case
    WHERE policy_case.case_key = :route_case_key
), evaluated AS (
    SELECT selected_case.*,
           route.explanation AS actual
    FROM selected_case
    CROSS JOIN LATERAL pgreact_mdm.route_cases(
        'pgreact_mdm.authorized_policy_cases_v1'::regclass,
        's1-route-diagnostics', 'policy_qualification',
        selected_case.captured_at, selected_case.case_key) AS route
)
SELECT jsonb_build_object(
    'name', 'authorized_route_protected',
    'expected', jsonb_build_object(
        'case_key', case_key, 'review_id', review_id,
        'decision', 'PROTECTED', 'selected_queue', NULL, 'applicable', true,
        'reason', 'manual assignment is protected',
        'captured_at', to_jsonb(captured_at), 'due_at', to_jsonb(due_at),
        'deadline_due', due_at <= captured_at,
        'current_escalation_level', escalation_level,
        'requested_escalation_level', NULL,
        'manual_assignment_protected', manual_assignment_protected,
        'pending_stewardship', pending_stewardship,
        'competitors', jsonb_build_array(jsonb_build_object(
            'reason_code', reason_code, 'entity_name', entity_name::text,
            'queue', 'priority_review', 'priority', 1, 'action', 'ASSIGN_QUEUE'))),
    'actual', actual) AS route_inspection
FROM evaluated
\gset
RESET SESSION AUTHORIZATION;
SELECT :'route_inspection'::jsonb;

SELECT action_revision AS route_action_revision, due_at AS route_due_at,
       escalation_level AS route_level
FROM mdm_steward.policy_cases_v1 WHERE case_key = :route_case_key
\gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :route_case_key, 'priority_review'::name, :'route_due_at'::timestamptz,
    :route_level, false, :route_action_revision,
    'Read-only route diagnostic no-op case');
RESET ROLE;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION s1_claimed_reader;
WITH selected_case AS (
    SELECT policy_case.*, statement_timestamp() AS captured_at
    FROM pgreact_mdm.authorized_policy_cases_v1 AS policy_case
    WHERE policy_case.case_key = :route_case_key
), evaluated AS (
    SELECT selected_case.*,
           route.explanation AS actual
    FROM selected_case
    CROSS JOIN LATERAL pgreact_mdm.route_cases(
        'pgreact_mdm.authorized_policy_cases_v1'::regclass,
        's1-route-diagnostics', 'policy_qualification',
        selected_case.captured_at, selected_case.case_key) AS route
)
SELECT jsonb_build_object(
    'name', 'authorized_route_no_op',
    'expected', jsonb_build_object(
        'case_key', case_key, 'review_id', review_id,
        'decision', 'NO_OP', 'selected_queue', NULL, 'applicable', true,
        'reason', 'selected queue matches current queue',
        'captured_at', to_jsonb(captured_at), 'due_at', to_jsonb(due_at),
        'deadline_due', due_at <= captured_at,
        'current_escalation_level', escalation_level,
        'requested_escalation_level', NULL,
        'manual_assignment_protected', manual_assignment_protected,
        'pending_stewardship', pending_stewardship,
        'competitors', jsonb_build_array(jsonb_build_object(
            'reason_code', reason_code, 'entity_name', entity_name::text,
            'queue', 'priority_review', 'priority', 1, 'action', 'ASSIGN_QUEUE'))),
    'actual', actual) AS route_inspection
FROM evaluated
\gset
RESET SESSION AUTHORIZATION;
SELECT :'route_inspection'::jsonb;

UPDATE pg_temp.pending_inspection_evidence
SET actual = :'reader_actual'::jsonb;
SELECT jsonb_build_object('name','pending_delivery_inspection',
    'expected',expected,'actual',actual)
FROM pg_temp.pending_inspection_evidence;
ROLLBACK;
CREATE FUNCTION s1_claimed.state() RETURNS jsonb LANGUAGE sql AS $state$
SELECT jsonb_build_object(
    'cases',(SELECT jsonb_agg(to_jsonb(c) ORDER BY case_key) FROM mdm_steward.policy_cases_v1 c),
    'receipts',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id),'[]') FROM mdm_steward.policy_receipts_v1 r),
    'requests',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY work_ref),'[]') FROM pgreact_mdm.intent_requests r),
    'intent_attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id,attempt_no),'[]') FROM pgreact_mdm.intent_attempts a),
    'work',(SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY work_id),'[]') FROM pgreact.work w),
    'attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY execution_id),'[]') FROM pgreact.attempts a),
    'holds',(SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY case_key),'[]') FROM pgreact_mdm.intent_holds h),
    'source',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM public.policy_qualification_source s),
    'technical_source',(SELECT jsonb_agg(to_jsonb(s) ORDER BY case_key) FROM s1_audit.source s))
$state$;
