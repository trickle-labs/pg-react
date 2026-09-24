\set ON_ERROR_STOP on
SELECT pg_catalog.to_regnamespace('pgreact_mdm') IS NOT NULL AS v048_has_worker_schema \gset
REASSIGN OWNED BY pgreact_mdm_worker TO postgres;
DROP OWNED BY pgreact_mdm_worker;
\if :v048_has_worker_schema
SET ROLE mdm_helper_owner;
REVOKE ALL PRIVILEGES ON TABLE
    pgreact_mdm.authorized_policy_cases_v1,
    pgreact_mdm.intent_due_candidates,
    pgreact_mdm.intent_escalation_candidates,
    pgreact_mdm.intent_queue_candidates,
    pgreact_mdm.policy_packages
    FROM pgreact_mdm_worker;
REVOKE ALL PRIVILEGES ON FUNCTION
    pgreact_mdm.change_due_intent(
        pgreact.activation_context,
        pgreact_mdm.intent_deployer_policy_cases_v1,
        pgreact_mdm.intent_deployer_policy_cases_v1),
    pgreact_mdm.change_escalation_intent(
        pgreact.activation_context,
        pgreact_mdm.intent_deployer_policy_cases_v1,
        pgreact_mdm.intent_deployer_policy_cases_v1),
    pgreact_mdm.change_queue_intent(
        pgreact.activation_context,
        pgreact_mdm.intent_deployer_policy_cases_v1,
        pgreact_mdm.intent_deployer_policy_cases_v1),
    pgreact_mdm.execute_intent_episode(uuid, text),
    pgreact_mdm.submit_due_intent(
        pgreact.activation_context,
        pgreact_mdm.intent_deployer_policy_cases_v1),
    pgreact_mdm.submit_escalation_intent(
        pgreact.activation_context,
        pgreact_mdm.intent_deployer_policy_cases_v1),
    pgreact_mdm.submit_queue_intent(
        pgreact.activation_context,
        pgreact_mdm.intent_deployer_policy_cases_v1)
    FROM pgreact_mdm_worker;
REVOKE USAGE ON SCHEMA pgreact, pgreact_mdm, mdm_steward
    FROM pgreact_mdm_worker;
RESET ROLE;
\endif
