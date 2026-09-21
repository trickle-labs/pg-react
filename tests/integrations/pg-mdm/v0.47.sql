\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

\ir ../../../showcase/mdm-stewardship/01-fixture.sql
\ir ../../../integrations/pg-mdm/sql/policy-inputs.sql
\ir ../../../integrations/pg-mdm/sql/routing.sql
\ir ../../../integrations/pg-mdm/sql/deadline-preview.sql
\ir ../../../integrations/pg-mdm/sql/comparison.sql

SELECT pgreact_mdm.publish_package(
    'policy-1',
    '{
       "applicability": {},
       "deadline": {"duration_seconds":3600,"min_seconds":60,"max_seconds":86400,"replace_existing_deadline":false},
       "routes": [
         {"reason_code":"POSSIBLE_DUPLICATE","queue":"priority","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"TIED_ROUTE","queue":"alpha","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"TIED_ROUTE","queue":"beta","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"MANUAL_ROUTE","queue":"protected","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"DEADLINE_ONLY","queue":"deadline","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"EXISTING_DEADLINE","queue":"deadline","priority":1,"action":"ASSIGN_QUEUE"}
       ]
     }'::jsonb) AS published
\gset

SELECT pgreact_mdm.publish_package(
    'policy-2',
    '{
       "applicability": {},
       "deadline": {"duration_seconds":7200,"min_seconds":60,"max_seconds":86400,"replace_existing_deadline":true},
       "routes": [
         {"reason_code":"POSSIBLE_DUPLICATE","queue":"urgent","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"TIED_ROUTE","queue":"alpha","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"TIED_ROUTE","queue":"beta","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"MANUAL_ROUTE","queue":"protected","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"DEADLINE_ONLY","queue":"deadline","priority":1,"action":"ASSIGN_QUEUE"},
         {"reason_code":"EXISTING_DEADLINE","queue":"deadline","priority":1,"action":"ASSIGN_QUEUE"}
       ]
     }'::jsonb) AS published
\gset

DO $$
DECLARE
    actual jsonb;
BEGIN
    SELECT pgreact_mdm.validate_inputs('mdm_fixture.policy_cases_v1'::regclass)
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'state', 'valid',
        'findings', jsonb_build_array(jsonb_build_object(
            'code', 'MDM_INPUT_OPENING_UNKNOWN',
            'rows', 1,
            'message', 'open cases without an authorized opening time cannot receive a due-date proposal')),
        'source_relation', 'mdm_fixture.policy_cases_v1') THEN
        RAISE EXCEPTION 'v0.47 input validation transcript mismatch: %', actual;
    END IF;
END
$$;

DROP VIEW IF EXISTS mdm_fixture.rls_policy_view;
DROP TABLE IF EXISTS mdm_fixture.rls_policy_cases;
CREATE TABLE mdm_fixture.rls_policy_cases (LIKE mdm_fixture.policy_cases_v1 INCLUDING ALL);
ALTER TABLE mdm_fixture.rls_policy_cases ENABLE ROW LEVEL SECURITY;
CREATE OR REPLACE VIEW mdm_fixture.rls_policy_view AS
SELECT * FROM mdm_fixture.rls_policy_cases;

DO $$
BEGIN
    BEGIN
        PERFORM pgreact_mdm.validate_inputs('mdm_fixture.rls_policy_view'::regclass);
        RAISE EXCEPTION 'v0.47 RLS source unexpectedly accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'MDM_INPUT_RLS_UNSUPPORTED: mdm_fixture.rls_policy_view uses row-level security' THEN
            RAISE;
        END IF;
    END;
END
$$;

DO $$
BEGIN
    BEGIN
        PERFORM pgreact_mdm.publish_package(
            'policy-1',
            '{"routes":[{"reason_code":"POSSIBLE_DUPLICATE","queue":"other","priority":1}],"deadline":{"duration_seconds":3600,"min_seconds":60,"max_seconds":86400,"replace_existing_deadline":false}}'::jsonb);
        RAISE EXCEPTION 'v0.47 immutable package unexpectedly changed';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE 'MDM_POLICY_IMMUTABLE:%' THEN
            RAISE;
        END IF;
    END;
END
$$;

DO $$
DECLARE
    actual jsonb;
BEGIN
    SELECT pgreact_mdm.compare_population(
        'mdm_fixture.policy_cases_v1'::regclass,
        'policy-1', 'policy-2',
        '2026-09-21 12:00:00+00',
        '{"id":"fixture-replacement","key_min":1,"key_max":7,"expected_count":7}'::jsonb)
    INTO actual;
    IF actual ->> 'state' <> 'complete'
       OR actual -> 'rows' -> 0 ->> 'changed' <> 'true'
       OR actual -> 'rows' -> 1 ->> 'changed' <> 'false'
       OR actual -> 'rows' -> 6 ->> 'changed' <> 'true' THEN
        RAISE EXCEPTION 'v0.47 replacement comparison transcript mismatch: %', actual;
    END IF;
END
$$;

DO $$
DECLARE
    actual jsonb;
    expected jsonb := $expected$[
      {"action":"ASSIGN_QUEUE","case_key":1,"decision":"WINNER","priority":1,"review_id":"40000000-0000-4000-8000-000000000001","competitors":[{"queue":"priority","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"POSSIBLE_DUPLICATE"}],"explanation":{"case_key":1,"decision":"WINNER","review_id":"40000000-0000-4000-8000-000000000001","competitors":[{"queue":"priority","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"POSSIBLE_DUPLICATE"}],"selected_queue":"priority","applicable":true,"reason":"best allowed candidate","pending_stewardship":false,"manual_assignment_protected":false},"reason_code":"POSSIBLE_DUPLICATE","current_queue":"general","selected_queue":"priority","policy_revision":"policy-1"},
      {"action":null,"case_key":2,"decision":"AMBIGUOUS","priority":null,"review_id":"40000000-0000-4000-8000-000000000002","competitors":[{"queue":"alpha","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"TIED_ROUTE"},{"queue":"beta","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"TIED_ROUTE"}],"explanation":{"case_key":2,"decision":"AMBIGUOUS","review_id":"40000000-0000-4000-8000-000000000002","competitors":[{"queue":"alpha","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"TIED_ROUTE"},{"queue":"beta","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"TIED_ROUTE"}],"selected_queue":null,"applicable":true,"reason":"equal best priorities","pending_stewardship":false,"manual_assignment_protected":false},"reason_code":"TIED_ROUTE","current_queue":null,"selected_queue":null,"policy_revision":"policy-1"},
      {"action":null,"case_key":3,"decision":"NO_CANDIDATE","priority":null,"review_id":"40000000-0000-4000-8000-000000000003","competitors":[],"explanation":{"case_key":3,"decision":"NO_CANDIDATE","review_id":"40000000-0000-4000-8000-000000000003","competitors":[],"selected_queue":null,"applicable":true,"reason":"no applicable route candidate","pending_stewardship":false,"manual_assignment_protected":false},"reason_code":"UNMATCHED","current_queue":null,"selected_queue":null,"policy_revision":"policy-1"},
      {"action":null,"case_key":4,"decision":"PROTECTED","priority":null,"review_id":"40000000-0000-4000-8000-000000000004","competitors":[{"queue":"protected","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"MANUAL_ROUTE"}],"explanation":{"case_key":4,"decision":"PROTECTED","review_id":"40000000-0000-4000-8000-000000000004","competitors":[{"queue":"protected","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"MANUAL_ROUTE"}],"selected_queue":null,"applicable":true,"reason":"manual assignment is protected","pending_stewardship":false,"manual_assignment_protected":true},"reason_code":"MANUAL_ROUTE","current_queue":"manual","selected_queue":null,"policy_revision":"policy-1"},
      {"action":null,"case_key":5,"decision":"NO_CANDIDATE","priority":null,"review_id":"40000000-0000-4000-8000-000000000005","competitors":[],"explanation":{"case_key":5,"decision":"NO_CANDIDATE","review_id":"40000000-0000-4000-8000-000000000005","competitors":[],"selected_queue":null,"applicable":true,"reason":"no applicable route candidate","pending_stewardship":false,"manual_assignment_protected":false},"reason_code":"DEADLINE_ONLY","current_queue":null,"selected_queue":null,"policy_revision":"policy-1"},
      {"action":null,"case_key":6,"decision":"NO_CANDIDATE","priority":null,"review_id":"40000000-0000-4000-8000-000000000006","competitors":[],"explanation":{"case_key":6,"decision":"NO_CANDIDATE","review_id":"40000000-0000-4000-8000-000000000006","competitors":[],"selected_queue":null,"applicable":true,"reason":"no applicable route candidate","pending_stewardship":false,"manual_assignment_protected":false},"reason_code":"EXISTING_DEADLINE","current_queue":null,"selected_queue":null,"policy_revision":"policy-1"},
      {"action":null,"case_key":7,"decision":"NO_OP","priority":null,"review_id":"40000000-0000-4000-8000-000000000007","competitors":[{"queue":"priority","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"POSSIBLE_DUPLICATE"}],"explanation":{"case_key":7,"decision":"NO_OP","review_id":"40000000-0000-4000-8000-000000000007","competitors":[{"queue":"priority","action":"ASSIGN_QUEUE","priority":1,"entity_name":null,"reason_code":"POSSIBLE_DUPLICATE"}],"selected_queue":null,"applicable":true,"reason":"selected queue matches current queue","pending_stewardship":false,"manual_assignment_protected":false},"reason_code":"POSSIBLE_DUPLICATE","current_queue":"priority","selected_queue":null,"policy_revision":"policy-1"}
    ]$expected$::jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(result) ORDER BY result.case_key)
    INTO actual
    FROM pgreact_mdm.route_cases('mdm_fixture.policy_cases_v1'::regclass, 'policy-1') AS result;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.47 routing transcript mismatch: %', actual;
    END IF;
END
$$;

DO $$
DECLARE
    actual jsonb;
BEGIN
    SELECT jsonb_object_agg(case_key::text, jsonb_build_object(
        'decision', decision,
        'proposed_due_at', proposed_due_at,
        'reason', reason,
        'existing_due_at', existing_due_at))
    INTO actual
    FROM (
        SELECT * FROM pgreact_mdm.deadline_preview(
            'mdm_fixture.policy_cases_v1'::regclass,
            'policy-1',
            '2026-09-21 12:00:00+00')
        WHERE case_key IN (1, 5, 6)
    ) selected;
    IF actual IS DISTINCT FROM jsonb_build_object(
        '1', jsonb_build_object('decision', 'PROPOSED', 'proposed_due_at', '2026-09-21 09:00:00+00'::timestamptz, 'reason', 'elapsed duration from immutable occurrence opening time', 'existing_due_at', NULL),
        '5', jsonb_build_object('decision', 'OPENED_AT_UNKNOWN', 'proposed_due_at', NULL, 'reason', 'opening time is unavailable or unaudited', 'existing_due_at', NULL),
        '6', jsonb_build_object('decision', 'PRESERVED', 'proposed_due_at', NULL, 'reason', 'existing deadline is preserved', 'existing_due_at', '2026-09-21 10:00:00+00'::timestamptz)) THEN
        RAISE EXCEPTION 'v0.47 deadline transcript mismatch: %', actual;
    END IF;
END
$$;

DO $$
DECLARE
    actual jsonb;
BEGIN
    SELECT pgreact_mdm.compare_population(
        'mdm_fixture.policy_cases_v1'::regclass,
        'policy-1', 'policy-1',
        '2026-09-21 12:00:00+00',
        '{"id":"fixture-all","key_min":1,"key_max":7,"expected_count":7}'::jsonb)
    INTO actual;
    IF actual ->> 'state' <> 'complete'
       OR actual -> 'coverage' IS DISTINCT FROM jsonb_build_object(
           'population_id', 'fixture-all', 'key_min', 1, 'key_max', 7,
           'expected_count', 7, 'observed_count', 7, 'partial', false,
           'snapshot', 'one READ COMMITTED statement per read')
       OR actual -> 'no_effect' IS DISTINCT FROM jsonb_build_object(
           'mdm_writes', 0, 'react_work_writes', 0,
           'react_lifecycle_writes', 0, 'intent_submissions', 0,
           'refresh_calls', 0)
       OR jsonb_array_length(actual -> 'rows') <> 7 THEN
        RAISE EXCEPTION 'v0.47 comparison transcript mismatch: %', actual;
    END IF;
END
$$;

DO $$
DECLARE
    actual jsonb;
BEGIN
    SELECT pgreact_mdm.compare_population(
        'mdm_fixture.policy_cases_v1'::regclass,
        'policy-1', 'policy-1',
        '2026-09-21 12:00:00+00',
        '{"id":"fixture-partial","key_min":1,"key_max":7,"expected_count":8}'::jsonb)
    INTO actual;
    IF actual ->> 'state' <> 'partial'
       OR actual -> 'coverage' ->> 'observed_count' <> '7'
       OR actual -> 'coverage' ->> 'partial' <> 'true' THEN
        RAISE EXCEPTION 'v0.47 partial comparison transcript mismatch: %', actual;
    END IF;
END
$$;

SELECT 'v0.47 read-only policy package passed' AS result;
