\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE TABLE public.issue5_joint_source (
    id bigint PRIMARY KEY,
    display_name text NOT NULL,
    email_address text NOT NULL,
    updated_at timestamptz NOT NULL
);
INSERT INTO public.issue5_joint_source VALUES
    (1, 'Joint One', 'joint-pair@example.test', statement_timestamp()),
    (2, 'Joint One', 'joint-one@example.test', statement_timestamp()),
    (3, 'Joint Two', 'joint-pair@example.test', statement_timestamp()),
    (4, 'Joint Two', 'joint-two@example.test', statement_timestamp());
GRANT SELECT, MAINTAIN, INSERT, UPDATE, DELETE ON public.issue5_joint_source
    TO mdm_legacy_administrator;

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
WITH proposed AS (
    SELECT mdm.entity(
        name => 'issue5_joint',
        sources => ARRAY[mdm.source(
            name => 'joint_source',
            relation => 'public.issue5_joint_source'::regclass,
            source_id => ARRAY['id'],
            mode => 'tracked',
            fields => jsonb_build_object('name', 'display_name', 'email', 'email_address'),
            row_changed_at => 'updated_at')],
        fields => ARRAY[
            mdm.field(name => 'name', type => 'text', cleaner => 'company_name'),
            mdm.field(name => 'email', type => 'text', cleaner => 'email')],
        matches => ARRAY[
            mdm.match(
                name => 'same_name', fields => ARRAY['name'], comparison => 'exact',
                strength => 'identity', evidence_group => 'name',
                candidate => jsonb_build_object('kind', 'exact', 'field', 'name')),
            mdm.match(
                name => 'same_email', fields => ARRAY['email'], comparison => 'exact',
                strength => 'strong', evidence_group => 'email',
                candidate => jsonb_build_object('kind', 'exact', 'field', 'email'))],
        golden_values => ARRAY[mdm.golden_value(
            field => 'name', policy => 'prefer_source', sources => ARRAY['joint_source'])],
        execution_role => 'mdm_legacy_administrator') AS definition
)
SELECT * FROM mdm.create(
    (SELECT definition FROM proposed), NULL, 'Issue 5 isolated joint lifecycle fixture');
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT pgreact_mdm.publish_intent_package(
    's1-issue5-joint-live',
    jsonb_build_object(
        'deadline', jsonb_build_object(
            'duration_seconds', 60, 'min_seconds', 60, 'max_seconds', 86400,
            'replace_existing_deadline', true),
        'routes', jsonb_build_array(
            jsonb_build_object(
                'entity_name', 'issue5_joint', 'reason_code', 'ESTABLISHED_NEEDS_TWO_STRONG_CONNECTIONS',
                'queue', 'priority_review', 'priority', 0, 'action', 'ASSIGN_QUEUE'))));

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT binding_id AS joint_binding_id, binding_version AS joint_binding_version
FROM pgreact_mdm.create_intent_binding(
    'issue5_joint', 's1-issue5-joint-live',
    ARRAY['ASSIGN_QUEUE', 'SET_DUE_AT']::text[],
    ARRAY['priority_review']::text[], interval '1 day', 0)
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT runtime_version AS joint_runtime_version
FROM pgreact_mdm.policy_intent_runtime
WHERE binding_id = :'joint_binding_id'::uuid
\gset
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT pgreact_mdm.reconcile_intent_binding(
    :'joint_binding_id'::uuid, :joint_runtime_version);
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT pgreact_mdm.sync_intent_case_identities();

SET SESSION AUTHORIZATION mdm_s1_runner;
DO $deploy_joint_policy$
DECLARE declaration pgreact_api.declaration; preview jsonb;
BEGIN
    declaration := pgreact_mdm.intent_declaration(
        's1-issue5-joint-live',
        'pgreact_mdm.intent_deployer_policy_cases_v1'::regclass,
        statement_timestamp());
    preview := pgreact.preview(declaration);
    PERFORM pgreact.deploy(declaration, pgreact.review_token(preview));
END
$deploy_joint_policy$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
DO $initial_publication$
DECLARE result jsonb;
BEGIN
    result := mdm.refresh('issue5_joint', 'ALLOW');
    IF result->>'changed' IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'ambiguous review fixture did not publish: %', result;
    END IF;
END
$initial_publication$;
RESET ROLE;
RESET SESSION AUTHORIZATION;
SELECT pgreact_mdm.sync_intent_case_identities();
DO $one_ambiguous_open_review$
BEGIN
    IF (SELECT count(*) FROM mdm_steward.policy_cases_v1
        WHERE entity_name = 'issue5_joint' AND status = 'open') <> 1 THEN
        RAISE EXCEPTION 'fixture did not publish exactly one ambiguous open review';
    END IF;
    IF (SELECT permitted_actions FROM mdm_steward.policy_cases_v1
        WHERE entity_name = 'issue5_joint' AND status = 'open') IS DISTINCT FROM
       ARRAY['ASSIGN_QUEUE', 'ESCALATE', 'SET_DUE_AT']::text[] THEN
        RAISE EXCEPTION 'fixture lacks the required allowed actions';
    END IF;
END
$one_ambiguous_open_review$;
SELECT case_key, reason_code, review_id, opened_at, publication_revision,
       permitted_actions
FROM mdm_steward.policy_cases_v1
WHERE entity_name = 'issue5_joint' AND status = 'open'
\gset joint_

SELECT jsonb_build_object(
    'case_key', :'joint_case_key'::bigint,
    'review_id', :'joint_review_id'::uuid,
    'reason_code', :'joint_reason_code',
    'allowed_actions', :'joint_permitted_actions'::text[],
    'binding_id', :'joint_binding_id'::uuid,
    'policy_revision', 's1-issue5-joint-live',
    'initial_case', to_jsonb(c),
    'binding', to_jsonb(b),
    'queue_candidates', (SELECT COALESCE(jsonb_agg(to_jsonb(i)), '[]'::jsonb)
                         FROM pgreact_mdm.intent_queue_candidates i
                         WHERE i.case_key = c.case_key),
    'due_candidates', (SELECT COALESCE(jsonb_agg(to_jsonb(i)), '[]'::jsonb)
                       FROM pgreact_mdm.intent_due_candidates i
                       WHERE i.case_key = c.case_key),
    'escalation_candidates', (SELECT COALESCE(jsonb_agg(to_jsonb(i)), '[]'::jsonb)
                              FROM pgreact_mdm.intent_escalation_candidates i
                              WHERE i.case_key = c.case_key)) AS setup_evidence
FROM mdm_steward.policy_cases_v1 c
JOIN pgreact_mdm.policy_intent_bindings b
  ON b.binding_id = :'joint_binding_id'::uuid
WHERE c.case_key = :'joint_case_key'::bigint;
