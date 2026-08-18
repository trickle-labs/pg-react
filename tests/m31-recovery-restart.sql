\set ON_ERROR_STOP on
DO $m31_recovery$
DECLARE expected jsonb;
    actual jsonb;
BEGIN
    SELECT state INTO expected FROM m31_recovery.control;
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
                          WHERE cleared_at IS NULL)
    ) INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M31 crash restart changed runtime state: % / %', expected, actual;
    END IF;
END
$m31_recovery$;
SELECT 'M31 crash restart preserved policy-set runtime state';
