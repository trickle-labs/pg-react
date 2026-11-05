\set ON_ERROR_STOP on
-- Keep e2e_policy's trusted-opening case available for the separate due-date candidate.
SELECT case_row.case_key,
       entity.execution_role_name,
       COALESCE(case_row.assigned_queue::text, '') AS assigned_queue,
       statement_timestamp() - INTERVAL '1 hour' AS due_at,
       case_row.manual_assignment_protected,
       case_row.action_revision
FROM mdm_steward.policy_cases_v1 AS case_row
JOIN mdm_internal.entities AS entity USING (entity_name)
WHERE case_row.entity_name = 'policy_qualification'
  AND case_row.status = 'open'
  AND NOT case_row.pending_stewardship
  AND case_row.opened_at IS NULL
  AND case_row.opened_at_source = 'unknown'
  AND 'ESCALATE' = ANY(case_row.permitted_actions)
ORDER BY case_row.case_key
LIMIT 1
\gset v050_escalation_

SET SESSION AUTHORIZATION mdm_test_login;
SET ROLE :"v050_escalation_execution_role_name";
SELECT action_revision AS seed_action_revision
FROM mdm_steward.set_case_controls(
    :v050_escalation_case_key,
    NULLIF(:'v050_escalation_assigned_queue', '')::name,
    :'v050_escalation_due_at'::timestamptz,
    1,
    :'v050_escalation_manual_assignment_protected'::boolean,
    :v050_escalation_action_revision,
    'v0.50 populated v0.48 escalation fixture')
\gset v050_escalation_
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT case_row.action_revision >= :v050_escalation_action_revision
   AND case_row.action_revision = :v050_escalation_seed_action_revision
   AND case_row.due_at = :'v050_escalation_due_at'::timestamptz
   AND case_row.due_at < statement_timestamp()
   AND case_row.escalation_level = 1 AS seed_ok
FROM mdm_steward.policy_cases_v1 AS case_row
WHERE case_row.case_key = :v050_escalation_case_key
\gset v050_escalation_
\if :v050_escalation_seed_ok
\echo v0.50 populated v0.48 escalation prerequisite: PASS
\else
\quit 1
\endif
