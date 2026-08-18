\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA m31_recovery;
CREATE TABLE m31_recovery.orders(
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL);
CREATE VIEW m31_recovery.orders_match AS
SELECT order_id, customer_id FROM m31_recovery.orders;
INSERT INTO m31_recovery.orders VALUES (100, 10), (200, 20);
CREATE TABLE m31_recovery.gate(customer_id bigint PRIMARY KEY);
INSERT INTO m31_recovery.gate VALUES (10);

DO $m31_recovery$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    preview jsonb;
    deployed jsonb;
BEGIN
    member := pgreact_api.declaration('rule', 'm31-recovery-rule', jsonb_build_object(
        'condition', 'm31_recovery.orders_match', 'semantic_key', 'order_id',
        'kind', 'CONSTRAINT', 'delegate', true));
    preview := pgreact_api.preview(member);
    deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 recovery rule did not deploy: %', deployed;
    END IF;
    policy_set := pgreact_api.declaration('policy_set', 'm31-recovery-set', jsonb_build_object(
        'version', '1',
        'members', jsonb_build_array(jsonb_build_object(
            'kind', 'rule', 'name', 'm31-recovery-rule', 'version', '1',
            'match_keys', jsonb_build_array('order_id'),
            'subject_keys', jsonb_build_array('customer_id'),
            'scope_mode', 'POLICY_SET_REQUIRED')),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', 'm31_recovery.gate',
            'subject_keys', jsonb_build_array('customer_id')),
        'valid_from', '2020-01-01 00:00:00+00'));
    preview := pgreact_api.preview(policy_set);
    deployed := pgreact_api.deploy(policy_set, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    CREATE TABLE m31_recovery.control(state jsonb NOT NULL);
    INSERT INTO m31_recovery.control
    SELECT jsonb_build_object(
        'runtime_state', pgreact_api.status(
            pgreact_api.target('policy_set', 'm31-recovery-set', '1'))
            -> 'summary' ->> 'runtime_state',
        'active_count', (SELECT count(*) FROM pgreact.activations activation
                         JOIN pgreact.rules rule USING (rule_version_id)
                         WHERE rule.rule_name = 'm31-recovery-rule'
                           AND activation.active),
        'support_count', (SELECT count(*) FROM pgreact.policy_set_scope_supports
                          WHERE set_name = 'm31-recovery-set'),
        'barrier_count', (SELECT count(*) FROM pgreact_internal.policy_set_runtime_barriers
                          WHERE cleared_at IS NULL));
END
$m31_recovery$;
CHECKPOINT;
SELECT 'M31 recovery setup passed';
