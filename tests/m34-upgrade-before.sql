\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m34_upgrade_reference;
CREATE TABLE m34_upgrade_reference.orders (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    label text NOT NULL
);
INSERT INTO m34_upgrade_reference.orders VALUES
    (100, 10, 'review'), (200, 20, 'review');
CREATE VIEW m34_upgrade_reference.orders_match AS
SELECT order_id, customer_id, label FROM m34_upgrade_reference.orders;
CREATE TABLE m34_upgrade_reference.customer_gate (customer_id bigint PRIMARY KEY);
INSERT INTO m34_upgrade_reference.customer_gate VALUES (10);

DO $m34upgrade$
DECLARE
    member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    member_preview jsonb;
    policy_preview jsonb;
    deployed jsonb;
BEGIN
    member := pgreact_api.declaration('rule', 'm34-upgrade-rule', jsonb_build_object(
        'condition', 'm34_upgrade_reference.orders_match',
        'semantic_key', 'order_id',
        'kind', 'CONSTRAINT',
        'delegate', true));
    member_preview := pgreact_api.preview(member);
    deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', member_preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M34 upgrade rule setup failed: %', deployed;
    END IF;

    policy_set := pgreact_api.declaration('policy_set', 'm34-upgrade-set', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule',
            'name', 'm34-upgrade-rule',
            'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation',
            'relation', 'm34_upgrade_reference.customer_gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2026-01-01 00:00:00+00',
        'evidence_limit', 10));
    policy_preview := pgreact_api.preview(policy_set);
    deployed := pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', policy_preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M34 upgrade policy-set setup failed: %', deployed;
    END IF;
END
$m34upgrade$;

CREATE TABLE m34_upgrade_reference.expected AS
SELECT set.policy_set_id,
       version.policy_set_version_id,
       version.version,
       version.eligible_subject_count,
       version.migration_state
FROM pgreact_internal.policy_set_versions version
JOIN pgreact_internal.policy_sets set USING (policy_set_id)
WHERE set.set_name = 'm34-upgrade-set';
