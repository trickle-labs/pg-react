\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m30_upgrade_reference;
CREATE TABLE m30_upgrade_reference.customer_gate (customer_id bigint PRIMARY KEY);
INSERT INTO m30_upgrade_reference.customer_gate VALUES (10), (20);

DO $m30upgrade$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    member_result jsonb;
    preview_result jsonb;
    deployed_result jsonb;
BEGIN
    member := pgreact_api.declaration('rule', 'm30-upgrade-member', jsonb_build_object(
        'condition', 'm30_upgrade_reference.customer_gate',
        'semantic_key', 'customer_id', 'kind', 'CONSTRAINT', 'delegate', false));
    preview_result := pgreact_api.preview(member);
    member_result := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview_result -> 'summary' ->> 'preview_digest'));
    IF member_result ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M30 upgrade member setup failed: %', member_result;
    END IF;
    policy_set := pgreact_api.declaration('policy_set', 'm30-upgrade-set', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm30-upgrade-member', 'version', '1')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation',
            'relation', 'm30_upgrade_reference.customer_gate',
            'subject_key', 'customer_id'),
        'valid_from', '2026-01-01 00:00:00+00'));
    preview_result := pgreact_api.preview(policy_set);
    deployed_result := pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', preview_result -> 'summary' ->> 'preview_digest'));
    IF deployed_result ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M30 upgrade policy-set setup failed: %', deployed_result;
    END IF;
END
$m30upgrade$;

CREATE TABLE m30_upgrade_reference.expected AS
SELECT policy_set_id, policy_set_version_id, version, eligible_subject_count
FROM pgreact_internal.policy_set_versions version
JOIN pgreact_internal.policy_sets set USING (policy_set_id)
WHERE set.set_name = 'm30-upgrade-set';
