\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
DROP EVENT TRIGGER IF EXISTS pgre_mdm_history_guard_ddl;
\ir ../../../../integrations/pg-mdm/sql/policy-inputs.sql
\ir ../../../../integrations/pg-mdm/sql/routing.sql
\ir ../../../../integrations/pg-mdm/sql/deadline-preview.sql
\ir ../../../../integrations/pg-mdm/sql/comparison.sql
\ir ../../../../integrations/pg-mdm/sql/typed-flow.sql
\ir ../../../../integrations/pg-mdm/sql/request-store.sql
\ir ../../../../integrations/pg-mdm/sql/intent-worker.sql
\ir ../../../../integrations/pg-mdm/sql/retention-guard.sql
GRANT USAGE ON SCHEMA pgreact_mdm TO mdm_legacy_administrator, mdm_administrator;

CREATE ROLE mdm_s1_runner LOGIN NOSUPERUSER NOBYPASSRLS NOINHERIT;
CREATE ROLE mdm_s1_runtime LOGIN NOSUPERUSER NOBYPASSRLS INHERIT;
CREATE ROLE s1_operator NOLOGIN;
CREATE ROLE s1_reader NOLOGIN;
CREATE ROLE s1_advanced_reader NOLOGIN;
CREATE ROLE pgreact_admin NOLOGIN;
CREATE ROLE s1_recovery_operator LOGIN INHERIT NOSUPERUSER NOBYPASSRLS;
GRANT pgreact_admin TO s1_recovery_operator;
GRANT s1_operator TO s1_recovery_operator WITH SET TRUE, INHERIT FALSE;
GRANT USAGE ON SCHEMA pgreact TO pgreact_admin;
GRANT EXECUTE ON FUNCTION pgreact.prepare_recovery(), pgreact.rebuild_transient_metadata()
    TO pgreact_admin;
GRANT pgreact_mdm_worker TO mdm_s1_runner WITH SET TRUE, INHERIT FALSE;
GRANT pgreact_mdm_worker TO mdm_s1_runtime WITH SET TRUE, INHERIT TRUE;
GRANT CONNECT ON DATABASE s1_idle TO mdm_s1_runtime;
SELECT pgreact_api.configure_roles('mdm_s1_runner', 's1_operator',
    'pgreact_mdm_worker', 's1_reader', 's1_advanced_reader');
SELECT pgreact_mdm.configure_intent_deployer('mdm_s1_runner');
DO $assert_escalation_clock_privilege$
BEGIN
    IF NOT pg_catalog.has_function_privilege(
        'mdm_s1_runner', 'pgreact_mdm.ensure_intent_escalation_clock()', 'EXECUTE') THEN
        RAISE EXCEPTION 'configured deployer must be able to install the M31 escalation clock';
    END IF;
END
$assert_escalation_clock_privilege$;
CREATE SCHEMA s1_audit;
CREATE TABLE s1_audit.source (
    case_key bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW s1_audit.candidate AS
SELECT policy_case.case_key, policy_case.due_at AS deadline
FROM pgreact_mdm.intent_deployer_policy_cases_v1 AS policy_case
-- shortcut: the pinned producer drops USING while expanding nested views; use ON until that path qualifies.
JOIN s1_audit.source AS selected_case ON selected_case.case_key = policy_case.case_key;
GRANT USAGE, CREATE ON SCHEMA s1_audit TO mdm_s1_runner;
GRANT SELECT ON s1_audit.source, s1_audit.candidate TO mdm_s1_runner;
ALTER VIEW s1_audit.candidate OWNER TO mdm_s1_runner;

SELECT case_key, reason_code, action_revision, COALESCE(assigned_queue::text, '') AS assigned_queue,
       escalation_level, manual_assignment_protected,
       clock_timestamp() + interval '45 seconds' AS deadline
FROM mdm_steward.policy_cases_v1
WHERE entity_name = 'policy_qualification' AND status = 'open'
  AND NOT pending_stewardship AND opened_at IS NOT NULL
  AND escalation_level = 1 AND 'ESCALATE' = ANY(permitted_actions)
ORDER BY case_key LIMIT 1
\gset
INSERT INTO s1_audit.source VALUES (:case_key, :'deadline');
SELECT pgreact_mdm.publish_intent_package('s1-idle-feasibility',
    jsonb_build_object('routes', jsonb_build_array(jsonb_build_object(
        'entity_name', 'policy_qualification', 'reason_code', :'reason_code',
        'action', 'ESCALATE', 'level', 2, 'priority', 0))));

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :case_key, NULLIF(:'assigned_queue', '')::name, :'deadline'::timestamptz,
    :escalation_level, :'manual_assignment_protected'::boolean,
    :action_revision, 'S1 future-deadline fixture');
SELECT * FROM pgreact_mdm.create_intent_binding(
    'policy_qualification', 's1-idle-feasibility',
    ARRAY['ESCALATE']::text[], ARRAY[]::text[], NULL, 2);
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT pgreact_mdm.sync_intent_case_identities();

-- Candidate discovery uses dispatch time; a stale MDM acceptance timestamp
-- must defer the callback so the configured retry starts a fresh statement.
SELECT COALESCE(policy_case.assigned_queue::text, '') AS assigned_queue,
       policy_case.escalation_level,
       policy_case.manual_assignment_protected,
       policy_case.action_revision
FROM mdm_steward.policy_cases_v1 AS policy_case
WHERE policy_case.case_key = :case_key
\gset
SELECT clock_timestamp() + interval '5 seconds' AS dispatch_regression_deadline \gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :case_key, NULLIF(:'assigned_queue', '')::name,
    :'dispatch_regression_deadline'::timestamptz,
    :escalation_level, :'manual_assignment_protected'::boolean,
    :action_revision, 'S1 statement-time escalation regression');
RESET ROLE;
RESET SESSION AUTHORIZATION;
CREATE TEMP TABLE s1_statement_time_regression_case (case_key bigint PRIMARY KEY);
INSERT INTO s1_statement_time_regression_case VALUES (:case_key);
DO $statement_time_escalation$
DECLARE
    test_case pgreact_mdm.intent_deployer_policy_cases_v1;
    candidate pgreact_mdm.intent_escalation_candidates%ROWTYPE;
    deferred_message text;
    requests_before bigint;
    receipts_before bigint;
BEGIN
    SELECT policy_case.* INTO STRICT test_case
    FROM pgreact_mdm.intent_deployer_policy_cases_v1 AS policy_case
    JOIN pg_temp.s1_statement_time_regression_case AS selected USING (case_key);
    IF statement_timestamp() >= test_case.due_at THEN
        RAISE EXCEPTION 'statement-time escalation regression began after deadline';
    END IF;
    PERFORM pg_catalog.pg_sleep(GREATEST(
        EXTRACT(EPOCH FROM test_case.due_at - clock_timestamp()) + 0.25,
        0.25)::double precision);
    SELECT intent.* INTO candidate
    FROM pgreact_mdm.intent_escalation_candidates AS intent
    WHERE intent.case_key = test_case.case_key;
    IF NOT FOUND OR candidate.action IS DISTINCT FROM 'ESCALATE'
       OR candidate.escalation_level IS DISTINCT FROM 2 THEN
        RAISE EXCEPTION 'due escalation candidate missing after statement crossed deadline';
    END IF;
    SELECT count(*) INTO requests_before FROM pgreact_mdm.intent_requests;
    SELECT count(*) INTO receipts_before FROM mdm_steward.policy_receipts_v1;
    BEGIN
        PERFORM pgreact_mdm.submit_escalation_intent(
            NULL::pgreact.activation_context, test_case);
    EXCEPTION WHEN SQLSTATE '40001' THEN
        GET STACKED DIAGNOSTICS deferred_message = MESSAGE_TEXT;
    END;
    IF deferred_message IS DISTINCT FROM 'due escalation requires a fresh statement' THEN
        RAISE EXCEPTION 'stale escalation callback did not raise its retry signal';
    END IF;
    IF (SELECT count(*) FROM pgreact_mdm.intent_requests) <> requests_before
       OR (SELECT count(*) FROM mdm_steward.policy_receipts_v1) <> receipts_before THEN
        RAISE EXCEPTION 'stale escalation callback wrote an intent or receipt';
    END IF;
END
$statement_time_escalation$;
SELECT COALESCE(policy_case.assigned_queue::text, '') AS assigned_queue,
       policy_case.escalation_level,
       policy_case.manual_assignment_protected,
       policy_case.action_revision
FROM mdm_steward.policy_cases_v1 AS policy_case
WHERE policy_case.case_key = :case_key
\gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :case_key, NULLIF(:'assigned_queue', '')::name, :'deadline'::timestamptz,
    :escalation_level, :'manual_assignment_protected'::boolean,
    :action_revision, 'Restore S1 deadline after statement-time regression');
RESET ROLE;
RESET SESSION AUTHORIZATION;
\echo PASS: statement-time escalation defers without an intent or receipt
DROP TABLE pg_temp.s1_statement_time_regression_case;

-- The optional two-case outage qualification prepares a second *real* MDM
-- occurrence through the same authorized human control API, before the
-- deadline rule is registered.  No direct MDM case-table writes are allowed.
\if :multi
SELECT c.case_key, c.action_revision,
       COALESCE(c.assigned_queue::text, '') AS assigned_queue,
       c.manual_assignment_protected,
       (:'deadline'::timestamptz + interval '1 second')::text AS deadline
FROM mdm_steward.policy_cases_v1 AS c
WHERE c.entity_name = 'policy_qualification' AND c.status = 'open'
  AND c.case_key <> :case_key AND c.opened_at IS NOT NULL
  AND NOT c.pending_stewardship AND c.escalation_level = 0
  AND 'ESCALATE' = ANY(c.permitted_actions)
  AND NOT EXISTS (
      SELECT 1 FROM mdm_steward.policy_receipts_v1 AS receipt
      WHERE receipt.case_key = c.case_key AND receipt.outcome = 'APPLIED_CONTROL'
        AND receipt.request_body ->> 'action' = 'ESCALATE'
        AND receipt.request_body -> 'arguments' ->> 'level' = '2')
ORDER BY c.case_key LIMIT 1
\gset sibling_
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :sibling_case_key, NULLIF(:'sibling_assigned_queue', '')::name,
    :'sibling_deadline'::timestamptz, 1,
    :'sibling_manual_assignment_protected'::boolean,
    :sibling_action_revision, 'Two-case downtime fixture: authorized setup');
RESET ROLE;
RESET SESSION AUTHORIZATION;
INSERT INTO s1_audit.source (case_key, deadline)
VALUES (:sibling_case_key, :'sibling_deadline'::timestamptz);
\endif

CREATE TABLE s1_audit.callback_failure_rules (rule_id uuid PRIMARY KEY);
GRANT SELECT ON s1_audit.callback_failure_rules TO mdm_s1_runner;
CREATE FUNCTION s1_audit.deliver(
    context pgreact.activation_context, candidate s1_audit.candidate
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $callback$
DECLARE current_case pgreact_mdm.intent_deployer_policy_cases_v1;
BEGIN
    RAISE WARNING 'registered-S1 callback entry rule_id=% session_user=% current_user=%',
        ($1).rule_id, session_user, current_user;
    IF EXISTS (SELECT 1 FROM s1_audit.callback_failure_rules AS failure_rule
               WHERE failure_rule.rule_id = ($1).rule_id) THEN
        RAISE EXCEPTION 'injected registered S1 callback failure';
    END IF;
    SELECT policy_case.* INTO STRICT current_case
    FROM pgreact_mdm.intent_deployer_policy_cases_v1 AS policy_case
    WHERE policy_case.case_key = ($2).case_key;
    PERFORM pgreact_mdm.submit_escalation_intent($1, current_case);
END
$callback$;
ALTER FUNCTION s1_audit.deliver(pgreact.activation_context, s1_audit.candidate)
    OWNER TO mdm_s1_runner;
REVOKE CREATE ON SCHEMA s1_audit FROM mdm_s1_runner;
REVOKE ALL ON FUNCTION s1_audit.deliver(
    pgreact.activation_context, s1_audit.candidate) FROM PUBLIC;
CREATE FUNCTION s1_audit.registration_state() RETURNS jsonb
LANGUAGE sql STABLE AS $state$
    SELECT jsonb_build_object(
        'cases',(SELECT jsonb_agg(to_jsonb(c) ORDER BY case_key) FROM mdm_steward.policy_cases_v1 c),
        'receipts',(SELECT jsonb_agg(to_jsonb(r) ORDER BY created_at,receipt_id) FROM mdm_steward.policy_receipts_v1 r),
        'business_source',(SELECT jsonb_agg(to_jsonb(s) ORDER BY id) FROM public.policy_qualification_source s),
        'technical_source',(SELECT jsonb_agg(to_jsonb(s) ORDER BY case_key) FROM s1_audit.source s),
        'rules',(SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY to_jsonb(r)::text),'[]') FROM pgreact.rules r),
        'work',(SELECT COALESCE(jsonb_agg(to_jsonb(w) ORDER BY to_jsonb(w)::text),'[]') FROM pgreact.work w),
        'attempts',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY to_jsonb(a)::text),'[]') FROM pgreact.attempts a),
        'source_definition',pg_get_viewdef('s1_audit.candidate'::regclass,true))
$state$;
CREATE TABLE s1_audit.before_registration AS SELECT s1_audit.registration_state() AS vector;
SET SESSION AUTHORIZATION mdm_s1_runner;
SELECT pgreact_api.author_deadline_rule(
    's1-future-idle', 's1_audit.candidate'::regclass,
    'case_key', 'deadline', 'COMMAND',
    's1_audit.deliver(pgreact.activation_context,s1_audit.candidate)',
    NULL, NULL, 'SEED_CURRENT', NULL, 0, 'default', NULL, 5, 1, 2, 30);
RESET SESSION AUTHORIZATION;
DO $retry_policy$
DECLARE binding pgreact_internal.consequence_bindings%ROWTYPE;
BEGIN
    SELECT consequence.* INTO STRICT binding
    FROM pgreact_internal.rules AS rule
    JOIN pgreact_internal.rule_versions AS version USING (rule_id)
    JOIN pgreact_internal.consequence_bindings AS consequence USING (rule_version_id)
    WHERE rule.rule_name = 's1-future-idle'
      AND version.state = 'ACTIVE'
      AND consequence.event_kind = 'ACTIVATE';
    IF ROW(binding.max_attempts, binding.initial_backoff_seconds,
           binding.backoff_multiplier, binding.max_backoff_seconds)
       IS DISTINCT FROM ROW(5, 1, 2::numeric, 30) THEN
        RAISE EXCEPTION 's1-future-idle retry policy is %, %, %, %',
            binding.max_attempts, binding.initial_backoff_seconds,
            binding.backoff_multiplier, binding.max_backoff_seconds;
    END IF;
END
$retry_policy$;

CREATE ROLE mdm_s1_rotated_worker NOLOGIN;
DO $worker_grants$
DECLARE
    stream_relation oid;
    stream_owner name;
BEGIN
    SELECT version.match_relid,
           pg_catalog.pg_get_userbyid(relation.relowner)
      INTO STRICT stream_relation, stream_owner
    FROM pgreact_internal.rule_versions AS version
    JOIN pg_catalog.pg_class AS relation ON relation.oid = version.match_relid
    WHERE version.match_name LIKE 'pgreact_runtime.%';

    IF stream_owner <> 'mdm_s1_runner'
       OR NOT pg_catalog.has_table_privilege('pgreact_mdm_worker', stream_relation, 'MAINTAIN')
       OR NOT pg_catalog.has_table_privilege('pgreact_mdm_worker',
            'pgreact_mdm.intent_deployer_policy_cases_v1', 'SELECT')
       OR pg_catalog.has_table_privilege('pgreact_mdm_worker', 's1_audit.source', 'SELECT')
       OR pg_catalog.has_schema_privilege('pgreact_mdm_worker', 's1_audit', 'USAGE') THEN
        RAISE EXCEPTION 'worker refresh grant must preserve stream owner and withhold source access';
    END IF;
END
$worker_grants$;

SELECT pgreact_api.configure_roles('mdm_s1_runner', 's1_operator',
    'mdm_s1_rotated_worker', 's1_reader', 's1_advanced_reader');
DO $worker_rotation$
DECLARE stream_relation oid;
BEGIN
    SELECT match_relid INTO STRICT stream_relation
    FROM pgreact_internal.rule_versions
    WHERE match_name LIKE 'pgreact_runtime.%';

    IF pg_catalog.has_table_privilege('pgreact_mdm_worker', stream_relation, 'MAINTAIN')
       OR NOT pg_catalog.has_table_privilege('mdm_s1_rotated_worker', stream_relation, 'MAINTAIN')
       OR pg_catalog.has_table_privilege('mdm_s1_rotated_worker', 's1_audit.source', 'SELECT') THEN
        RAISE EXCEPTION 'worker rotation did not move only stream MAINTAIN';
    END IF;
END
$worker_rotation$;

SELECT pgreact_api.configure_roles('mdm_s1_runner', 's1_operator',
    'pgreact_mdm_worker', 's1_reader', 's1_advanced_reader');
DO $worker_restore$
DECLARE stream_relation oid;
BEGIN
    SELECT match_relid INTO STRICT stream_relation
    FROM pgreact_internal.rule_versions
    WHERE match_name LIKE 'pgreact_runtime.%';

    IF NOT pg_catalog.has_table_privilege('pgreact_mdm_worker', stream_relation, 'MAINTAIN')
       OR pg_catalog.has_table_privilege('mdm_s1_rotated_worker', stream_relation, 'MAINTAIN') THEN
        RAISE EXCEPTION 'restored worker role vector differs';
    END IF;
END
$worker_restore$;

DO $before$
BEGIN
    IF EXISTS (SELECT 1 FROM mdm_steward.policy_receipts_v1
        WHERE request_body->>'policy_revision' = 's1-idle-feasibility')
       OR EXISTS (SELECT 1 FROM s1_audit.source WHERE deadline <= clock_timestamp()) THEN
        RAISE EXCEPTION 'S1 requires an unexpired future deadline and no prior audit receipt';
    END IF;
END
$before$;
SET SESSION AUTHORIZATION mdm_s1_runner;
SELECT pgreact_api.author_deadline_rule(
    's1-callback-failure', 's1_audit.candidate'::regclass,
    'case_key', 'deadline', 'COMMAND',
    's1_audit.deliver(pgreact.activation_context,s1_audit.candidate)');
RESET SESSION AUTHORIZATION;
INSERT INTO s1_audit.callback_failure_rules
SELECT rule.rule_id FROM pgreact_internal.rules AS rule
WHERE rule.rule_name = 's1-callback-failure';
