-- Read-only operator projection for v0.50 operational reporting.
-- Each request/attempt row is visible only to its entity execution role.
CREATE OR REPLACE VIEW pgreact_mdm.operational_activity_v1
WITH (security_barrier = true) AS
SELECT binding.binding_id,
       binding.entity_name::text AS entity_name,
       request.work_ref,
       request.case_key,
       request.request_body ->> 'action' AS action,
       request.escalation_level,
       CASE WHEN request.request_body ->> 'action' = 'SET_DUE_AT'
            THEN (request.request_body #>> '{arguments,due_at}')::timestamptz
       END AS requested_due_at,
       request.created_at AS requested_at,
       COALESCE(attempt.episode_id, request.first_episode_id) AS react_episode_id,
       work.state AS react_work_state,
       attempt.attempt_no,
       attempt.attempted_at,
       COALESCE(attempt.outcome, 'PENDING') AS delivery_outcome,
       attempt.reason_code AS delivery_reason_code,
       CASE WHEN hold.reason_code IS NULL THEN 'NONE' ELSE 'HELD' END AS remediation_state,
       hold.reason_code AS remediation_reason_code,
       attempt.receipt_id AS mdm_receipt_id,
       (receipt.receipt_id IS NOT NULL) AS mdm_receipt_retained,
       receipt.outcome AS mdm_outcome,
       receipt.reason_code AS mdm_reason_code,
       receipt.resulting_publication_revision,
       CASE
           WHEN receipt.receipt_id IS NULL THEN NULL
           WHEN receipt.outcome <> 'APPLIED_CONTROL' THEN NULL
           WHEN receipt_publication.receipt_id IS NOT NULL
               THEN receipt_publication.publication_state
           WHEN receipt.publication_tracking_started_at > receipt.created_at
               THEN 'UNKNOWN_LEGACY'
           ELSE 'PENDING_PUBLICATION'
       END AS mdm_publication_state,
       receipt_publication.publication_revision AS mdm_publication_revision,
       receipt_publication.observed_at AS mdm_publication_observed_at,
       CASE
           WHEN receipt.outcome = 'APPLIED_CONTROL'
            AND receipt_publication.receipt_id IS NULL
            AND receipt.publication_tracking_started_at <= receipt.created_at
               THEN clock_timestamp() - receipt.created_at
       END AS mdm_pending_publication_age,
       case_row.status AS current_case_status,
       case_row.publication_revision AS current_publication_revision,
       case_row.pending_stewardship AS current_pending_stewardship,
       case_row.pending_since AS current_pending_since
FROM pgreact_mdm.intent_requests AS request
JOIN pgreact_mdm.policy_intent_bindings AS binding USING (binding_id)
LEFT JOIN pgreact_mdm.intent_attempts AS attempt
  ON attempt.binding_id = request.binding_id
 AND attempt.request_key = request.request_key
LEFT JOIN pgreact.work AS work
  ON work.kind = 'rule'
 AND work.work_id = COALESCE(attempt.episode_id, request.first_episode_id)::text
LEFT JOIN mdm_steward.policy_receipts_v1 AS receipt
  ON receipt.receipt_id = attempt.receipt_id
LEFT JOIN mdm_steward.policy_receipt_publications_v1 AS receipt_publication
  ON receipt_publication.receipt_id = receipt.receipt_id
LEFT JOIN mdm_steward.policy_cases_v1 AS case_row
  ON case_row.entity_name = binding.entity_name
 AND case_row.case_key = request.case_key
LEFT JOIN LATERAL (
    SELECT saved_hold.reason_code
    FROM pgreact_mdm.intent_holds AS saved_hold
    WHERE saved_hold.binding_id = request.binding_id
      AND saved_hold.case_key = request.case_key
      AND saved_hold.policy_revision = request.policy_revision
      AND saved_hold.action = request.request_body ->> 'action'
      AND saved_hold.expected_action_revision = request.action_revision
    ORDER BY saved_hold.held_at DESC
    LIMIT 1
) AS hold ON true
WHERE pg_catalog.pg_has_role(
    session_user, binding.entity_execution_role, 'MEMBER');

COMMENT ON VIEW pgreact_mdm.operational_activity_v1 IS
    'Entity-role-scoped intent, React work-state, and receipt projection; excludes request bodies and controls.';
REVOKE ALL ON pgreact_mdm.operational_activity_v1 FROM PUBLIC;
GRANT SELECT ON pgreact_mdm.operational_activity_v1 TO PUBLIC;

CREATE OR REPLACE VIEW pgreact_mdm.pending_cases_v1
WITH (security_barrier = true) AS
SELECT binding.binding_id,
       binding.entity_name::text AS entity_name,
       case_row.case_key,
       case_row.pending_since,
       CASE WHEN case_row.pending_since IS NOT NULL
            THEN clock_timestamp() - case_row.pending_since
       END AS pending_age
FROM pgreact_mdm.policy_intent_bindings AS binding
JOIN mdm_steward.policy_cases_v1 AS case_row
  ON case_row.entity_name = binding.entity_name
WHERE case_row.pending_stewardship
  AND pg_catalog.pg_has_role(
      session_user, binding.entity_execution_role, 'MEMBER');

COMMENT ON VIEW pgreact_mdm.pending_cases_v1 IS
    'Entity-role-scoped pending stewardship cases and decision age.';
REVOKE ALL ON pgreact_mdm.pending_cases_v1 FROM PUBLIC;
GRANT SELECT ON pgreact_mdm.pending_cases_v1 TO PUBLIC;
