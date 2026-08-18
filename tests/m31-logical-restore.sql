\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $m31_logical$
DECLARE member pgreact_api.declaration;
    policy_set pgreact_api.declaration;
    preview jsonb;
    deployed jsonb;
    expected jsonb;
    actual jsonb;
BEGIN
    IF (SELECT COALESCE(jsonb_agg(jsonb_build_array(order_id, customer_id)
                                ORDER BY order_id), '[]'::jsonb)
        FROM m31_recovery.orders) IS DISTINCT FROM '[[100,10],[200,20]]'::jsonb
       OR (SELECT COALESCE(jsonb_agg(to_jsonb(customer_id) ORDER BY customer_id),
                          '[]'::jsonb)
           FROM m31_recovery.gate) IS DISTINCT FROM '[10]'::jsonb THEN
        RAISE EXCEPTION 'M31 logical restore did not restore reference/control data';
    END IF;

    SELECT state INTO STRICT expected FROM m31_recovery.control;
    member := pgreact_api.declaration('rule', 'm31-recovery-rule', jsonb_build_object(
        'condition', 'm31_recovery.orders_match', 'semantic_key', 'order_id',
        'kind', 'CONSTRAINT', 'delegate', true));
    preview := pgreact_api.preview(member);
    deployed := pgreact_api.deploy(member, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M31 logical restore rule did not deploy: %', deployed;
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
    actual := jsonb_build_object(
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
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M31 logical restore changed runtime state: % / %', expected, actual;
    END IF;
END
$m31_logical$;

INSERT INTO m31_recovery.gate VALUES (20);
SELECT pgreact_api.run(
    pgreact_api.target('policy_set', 'm31-recovery-set', '1'),
    '2026-01-01 00:00:00+00');

DO $m31_logical$
BEGIN
    IF (SELECT pgreact_api.status(
            pgreact_api.target('policy_set', 'm31-recovery-set', '1'))
            -> 'summary' ->> 'runtime_state') <> 'AUTHORITATIVE'
       OR (SELECT count(*) FROM pgreact.policy_set_scope_supports
           WHERE set_name = 'm31-recovery-set') <> 2
       OR (SELECT count(*) FROM pgreact.activations activation
           JOIN pgreact.rules rule USING (rule_version_id)
           WHERE rule.rule_name = 'm31-recovery-rule' AND activation.active) <> 2
       OR (SELECT COALESCE(jsonb_agg(to_jsonb(customer_id) ORDER BY customer_id),
                          '[]'::jsonb)
           FROM m31_recovery.gate) IS DISTINCT FROM '[10,20]'::jsonb
       OR (SELECT COALESCE(jsonb_agg(subject ORDER BY subject), '[]'::jsonb)
           FROM pgreact.policy_set_eligible_subjects
           WHERE set_name = 'm31-recovery-set') IS DISTINCT FROM '[10,20]'::jsonb THEN
        RAISE EXCEPTION 'M31 logical restore eligibility did not reconcile';
    END IF;
END
$m31_logical$;

SELECT 'M31 logical dump/restore preserved runtime state and reconciled eligibility';
