\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $m30upgrade$
DECLARE expected_row record;
    actual_row record;
BEGIN
    SELECT * INTO expected_row FROM m30_upgrade_reference.expected;
    SELECT version.policy_set_id, version.policy_set_version_id, version.version,
           version.eligible_subject_count
    INTO actual_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm30-upgrade-set';
    IF actual_row.policy_set_id IS DISTINCT FROM expected_row.policy_set_id
       OR actual_row.policy_set_version_id IS DISTINCT FROM expected_row.policy_set_version_id
       OR actual_row.version IS DISTINCT FROM expected_row.version
       OR actual_row.eligible_subject_count IS DISTINCT FROM expected_row.eligible_subject_count THEN
        RAISE EXCEPTION 'M30 upgrade changed policy-set identity or evidence: % / %',
            expected_row, actual_row;
    END IF;
    IF (SELECT migration_state FROM pgreact_internal.policy_set_versions
        WHERE policy_set_version_id = expected_row.policy_set_version_id)
       <> 'NEEDS_SCOPE_MIGRATION'
       OR (SELECT state FROM pgreact_internal.declaration_migrations
           WHERE kind = 'policy_set' AND object_name = 'm30-upgrade-set'
             AND object_version = '1') <> 'NEEDS_SCOPE_MIGRATION'
       OR (SELECT count(*) FROM pgreact_internal.policy_set_scope_supports
           WHERE policy_set_version_id = expected_row.policy_set_version_id) <> 0
       OR (SELECT count(*) FROM pgreact_internal.policy_set_eligibility
           WHERE policy_set_version_id = expected_row.policy_set_version_id) <> 2 THEN
        RAISE EXCEPTION 'M30 upgrade migration classification or relational preservation failed';
    END IF;
END
$m30upgrade$;

SELECT 'M30_UPGRADE_PRESERVED_OK' AS result;
