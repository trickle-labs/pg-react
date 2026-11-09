\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SELECT pgreact_mdm.publish_intent_package(
    's1-issue5-joint-escalation',
    jsonb_build_object(
        'routes', jsonb_build_array(jsonb_build_object(
            'entity_name', 'issue5_joint', 'reason_code', :'reason_code',
            'action', 'ESCALATE', 'level', 1, 'priority', 0))));

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT binding_id AS new_binding_id, binding_version AS new_binding_version
FROM pgreact_mdm.replace_intent_binding(
    :'old_binding_id'::uuid, :'old_binding_version'::bigint,
    's1-issue5-joint-escalation', ARRAY['ESCALATE']::text[],
    ARRAY[]::text[], NULL, 2)
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT runtime_version AS new_runtime_version
FROM pgreact_mdm.policy_intent_runtime
WHERE binding_id = :'new_binding_id'::uuid
\gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT pgreact_mdm.reconcile_intent_binding(
    :'new_binding_id'::uuid, :new_runtime_version);
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT pgreact_mdm.sync_intent_case_identities();

SET SESSION AUTHORIZATION mdm_s1_runner;
SELECT pgreact_mdm.ensure_intent_escalation_clock();
SELECT pgreact_mdm.ensure_intent_escalation_clock();
DO $assert_escalation_clock$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pgreact.rules
        WHERE rule_name = 'mdm-intent-escalation-clock'
          AND source_view_name = 'pgreact_mdm.intent_deployer_policy_cases_v1'
          AND consequence_identity = 'pgreact_mdm.submit_escalation_intent(pgreact.activation_context,pgreact_mdm.intent_deployer_policy_cases_v1)'
          AND state = 'ACTIVE') THEN
        RAISE EXCEPTION 'M31 escalation clock must be active on the deployer projection';
    END IF;
END
$assert_escalation_clock$;
DO $deploy_escalation_policy$
DECLARE declaration pgreact_api.declaration; preview jsonb;
BEGIN
    declaration := pgreact_mdm.intent_declaration(
        's1-issue5-joint-escalation',
        'pgreact_mdm.intent_deployer_policy_cases_v1'::regclass,
        statement_timestamp());
    preview := pgreact.preview(declaration);
    PERFORM pgreact.deploy(declaration, pgreact.review_token(preview));
END
$deploy_escalation_policy$;
RESET SESSION AUTHORIZATION;

SELECT jsonb_build_object(
    'new_binding_id', :'new_binding_id'::uuid,
    'new_binding_version', :'new_binding_version'::bigint,
    'binding', to_jsonb(b),
    'escalation_candidates', (SELECT COALESCE(jsonb_agg(to_jsonb(i)), '[]'::jsonb)
                              FROM pgreact_mdm.intent_escalation_candidates i
                              WHERE i.case_key = :'case_key'::bigint))
FROM pgreact_mdm.policy_intent_bindings b
WHERE b.binding_id = :'new_binding_id'::uuid;
