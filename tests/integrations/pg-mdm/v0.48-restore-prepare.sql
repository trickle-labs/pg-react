\set ON_ERROR_STOP on

SELECT binding.binding_id AS v048_binding_id,
       binding.entity_execution_role AS v048_entity_role,
       COALESCE(runtime.runtime_version, 0) AS v048_runtime_version
FROM pgreact_mdm.policy_intent_bindings AS binding
LEFT JOIN mdm_internal.policy_binding_runtime AS runtime
  USING (binding_id)
WHERE binding.enabled
  AND binding.entity_name = 'policy_qualification'
ORDER BY binding.binding_version DESC
LIMIT 1
\gset

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE :"v048_entity_role";
SELECT mdm_admin.set_policy_binding_state(
    :'v048_binding_id'::uuid, :v048_runtime_version,
    'paused', 'pg-react v0.48 restore qualification') AS v048_paused_version
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT binding.binding_id AS v048_escalation_binding_id,
       binding.entity_execution_role AS v048_escalation_entity_role,
       COALESCE(runtime.runtime_version, 0) AS v048_escalation_runtime_version
FROM pgreact_mdm.policy_intent_bindings AS binding
LEFT JOIN mdm_internal.policy_binding_runtime AS runtime USING (binding_id)
WHERE binding.enabled
  AND binding.entity_name = 'review_admission_live'
ORDER BY binding.binding_version DESC
LIMIT 1
\gset

SET SESSION AUTHORIZATION mdm_test_login;
SET ROLE :"v048_escalation_entity_role";
SELECT mdm_admin.set_policy_binding_state(
    :'v048_escalation_binding_id'::uuid, :v048_escalation_runtime_version,
    'paused', 'pg-react v0.48 restore qualification') AS v048_escalation_paused_version
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT 'v0.48 restore source paused' AS result;
