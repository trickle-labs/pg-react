\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SELECT pgreact_api.pause_rule(rule_name)
FROM pgreact.rules
WHERE rule_name IN ('s1-future-idle', 's1-callback-failure') AND state = 'ACTIVE';

CREATE SCHEMA s1_statement_retry;
CREATE TABLE s1_statement_retry.prior_issues AS
SELECT DISTINCT issue_key
FROM mdm_steward.policy_cases_v1
WHERE entity_name = 'policy_qualification';
INSERT INTO public.policy_qualification_source VALUES
    (9001, 'Statement Retry', 'statement-retry-one@example.test', statement_timestamp()),
    (9002, 'Statement Retry', 'statement-retry-pair@example.test', statement_timestamp()),
    (9003, 'Statement Retry Two', 'statement-retry-two@example.test', statement_timestamp()),
    (9004, 'Statement Retry Two', 'statement-retry-pair@example.test', statement_timestamp());
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm.refresh('policy_qualification', 'ALLOW');
RESET ROLE;
RESET SESSION AUTHORIZATION;

CREATE TABLE s1_statement_retry.new_cases AS
SELECT case_key
FROM mdm_steward.policy_cases_v1
WHERE entity_name = 'policy_qualification'
  AND status = 'open'
  AND issue_key NOT IN (SELECT issue_key FROM s1_statement_retry.prior_issues);
DO $one_new_case$
BEGIN
    IF (SELECT count(*) FROM s1_statement_retry.new_cases) <> 1 THEN
        RAISE EXCEPTION 'expected one new statement-retry case, found %',
            (SELECT count(*) FROM s1_statement_retry.new_cases);
    END IF;
END
$one_new_case$;

SELECT policy_case.case_key,
       policy_case.action_revision,
       COALESCE(policy_case.assigned_queue::text, '') AS assigned_queue,
       policy_case.manual_assignment_protected,
       clock_timestamp() + interval '25 seconds' AS retry_deadline
FROM mdm_steward.policy_cases_v1 AS policy_case
JOIN s1_statement_retry.new_cases USING (case_key)
\gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :case_key, NULLIF(:'assigned_queue', '')::name, :'retry_deadline'::timestamptz,
    1, :'manual_assignment_protected'::boolean, :action_revision,
    'S1 fresh-statement retry regression');
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT pgreact_mdm.sync_intent_case_identities();

CREATE TABLE s1_statement_retry.selector (case_key bigint PRIMARY KEY);
GRANT USAGE, CREATE ON SCHEMA s1_statement_retry TO mdm_s1_runner;
GRANT SELECT ON s1_statement_retry.selector TO mdm_s1_runner;
GRANT SELECT ON s1_statement_retry.selector TO pgreact_mdm_worker;
SET SESSION AUTHORIZATION mdm_s1_runner;
CREATE VIEW s1_statement_retry.candidate AS
SELECT policy_case.case_key, policy_case.due_at
FROM pgreact_mdm.intent_deployer_policy_cases_v1 AS policy_case
JOIN s1_statement_retry.selector USING (case_key);
GRANT SELECT ON s1_statement_retry.candidate TO pgreact_mdm_worker;
CREATE FUNCTION s1_statement_retry.deliver(
    context pgreact.activation_context, candidate s1_statement_retry.candidate
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $callback$
DECLARE current_case pgreact_mdm.intent_deployer_policy_cases_v1;
    binding_id uuid;
    expected_candidate jsonb;
    actual_candidate jsonb;
BEGIN
    PERFORM pg_catalog.pg_sleep(GREATEST(
        EXTRACT(EPOCH FROM ($2).due_at - clock_timestamp()) + 0.25,
        0.25)::double precision);
    SELECT policy_case.* INTO STRICT current_case
    FROM pgreact_mdm.intent_deployer_policy_cases_v1 AS policy_case
    WHERE policy_case.case_key = ($2).case_key;
    SELECT intent.binding_id, to_jsonb(intent)
    INTO STRICT binding_id, expected_candidate
    FROM pgreact_mdm.intent_escalation_candidates AS intent
    WHERE intent.case_key = current_case.case_key
    ORDER BY intent.binding_id
    LIMIT 1;
    actual_candidate := pgreact_mdm.intent_escalation_candidate_for_case(
        binding_id, current_case.case_key);
    IF actual_candidate IS DISTINCT FROM expected_candidate THEN
        RAISE EXCEPTION 'case-scoped escalation candidate differs: expected %, got %',
            expected_candidate, actual_candidate;
    END IF;
    PERFORM pgreact_mdm.submit_escalation_intent($1, current_case);
END
$callback$;
REVOKE ALL ON FUNCTION s1_statement_retry.deliver(
    pgreact.activation_context, s1_statement_retry.candidate) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION s1_statement_retry.deliver(
    pgreact.activation_context, s1_statement_retry.candidate) TO pgreact_mdm_worker;
DO $deploy$
DECLARE declaration pgreact_api.declaration;
    preview jsonb;
    review text;
BEGIN
    declaration := pgreact.rule(
        name => 's1-statement-time-retry',
        condition => 's1_statement_retry.candidate'::regclass,
        semantic_key => 'case_key', kind => 'COMMAND',
        on_activate => 's1_statement_retry.deliver(pgreact.activation_context,s1_statement_retry.candidate)'::regprocedure,
        bootstrap_policy => 'SEED_CURRENT', salience => 10,
        max_attempts => 5, initial_backoff_seconds => 1,
        backoff_multiplier => 2, max_backoff_seconds => 30);
    preview := pgreact.preview(declaration);
    review := pgreact.review_token(preview);
    PERFORM pgreact.deploy(declaration, review);
END
$deploy$;
RESET SESSION AUTHORIZATION;
REVOKE CREATE ON SCHEMA s1_statement_retry FROM mdm_s1_runner;
INSERT INTO s1_statement_retry.selector SELECT case_key FROM s1_statement_retry.new_cases;
DO $candidate_visibility$
BEGIN
    IF (SELECT count(*) FROM s1_statement_retry.candidate) <> 1 THEN
        RAISE EXCEPTION 'retry condition view did not expose the selected MDM case: %',
            (SELECT COALESCE(jsonb_agg(to_jsonb(policy_case)), '[]'::jsonb)
             FROM pgreact_mdm.intent_deployer_policy_cases_v1 AS policy_case
             JOIN s1_statement_retry.selector USING (case_key));
    END IF;
END
$candidate_visibility$;
SELECT pgreact_api.run();

CREATE TABLE s1_statement_retry.metadata AS
SELECT target.case_key,
       policy_case.due_at,
       to_jsonb(policy_case) AS case_before,
       binding.binding_id,
       binding.binding_version,
       binding.policy_revision,
       encode(binding.policy_digest, 'hex') AS policy_digest,
       rule.rule_version_id,
       agenda.episode_id,
       'pgreact:' || rule.rule_version_id::text || ':' || agenda.episode_id::text AS work_ref
FROM s1_statement_retry.new_cases AS target
JOIN mdm_steward.policy_cases_v1 AS policy_case USING (case_key)
JOIN pgreact_mdm.policy_intent_bindings AS binding
  ON binding.enabled AND binding.entity_name = policy_case.entity_name
 AND binding.policy_revision = 's1-idle-feasibility'
JOIN pgreact.rules AS rule ON rule.rule_name = 's1-statement-time-retry'
 AND rule.state = 'ACTIVE'
JOIN pgreact_internal.agenda AS agenda ON agenda.rule_version_id = rule.rule_version_id
 AND agenda.new_bindings ->> 'case_key' = target.case_key::text
WHERE agenda.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
DO $one_episode$
BEGIN
    IF (SELECT count(*) FROM s1_statement_retry.metadata) <> 1 THEN
        RAISE EXCEPTION 'expected one seeded retry episode, found %',
            (SELECT count(*) FROM s1_statement_retry.metadata);
    END IF;
    IF (SELECT due_at <= statement_timestamp() FROM s1_statement_retry.metadata) THEN
        RAISE EXCEPTION 'retry deadline elapsed before the managed callback was installed';
    END IF;
END
$one_episode$;
\echo PASS: stale-statement managed retry episode seeded before deadline
