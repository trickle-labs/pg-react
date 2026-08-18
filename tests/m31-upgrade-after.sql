\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $m31upgrade$
DECLARE support_count bigint;
    runtime_function regprocedure;
    migration_state text;
BEGIN
    SELECT to_regprocedure('pgreact_internal.m31_reconcile_policy_set(uuid,timestamptz)')
    INTO runtime_function;
    SELECT version.migration_state
    INTO migration_state
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm30-upgrade-set';
    SELECT count(*) INTO support_count
    FROM pgreact_internal.policy_set_scope_supports support
    JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm30-upgrade-set' AND version.version = '1';
    IF runtime_function IS NULL
       OR migration_state <> 'NEEDS_SCOPE_MIGRATION'
       OR support_count <> 0 THEN
        RAISE EXCEPTION 'M31 upgrade runtime or no-silent-gating check failed: %, %, %',
            runtime_function, migration_state, support_count;
    END IF;
END
$m31upgrade$;

SELECT 'M31_UPGRADE_PRESERVED_OK' AS result;
