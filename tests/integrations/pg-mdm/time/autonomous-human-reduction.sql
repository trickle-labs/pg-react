\set ON_ERROR_STOP on

SELECT c.case_key, c.action_revision,
       COALESCE(c.assigned_queue::text, '') AS assigned_queue,
       c.due_at::text AS due_at,
       c.manual_assignment_protected
FROM mdm_steward.policy_cases_v1 AS c
JOIN s1_auto.issue AS i ON i.issue_key = c.issue_key
WHERE c.entity_name = 'policy_qualification'
  AND c.status = 'open'
  AND c.occurrence = 2
  AND c.escalation_level = 2
\gset human_

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :human_case_key,
    NULLIF(:'human_assigned_queue', '')::name,
    :'human_due_at'::timestamptz,
    1,
    :'human_manual_assignment_protected'::boolean,
    :human_action_revision,
    'Autonomous recurrence: human lowers an already applied level')
AS action_revision;
RESET ROLE;
RESET SESSION AUTHORIZATION;

\echo PASS: authorized human edit lowered the existing occurrence without changing its deadline
