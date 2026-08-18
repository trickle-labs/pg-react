\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $m34upgrade$
DECLARE
    expected_row record;
    actual_row record;
BEGIN
    SELECT * INTO expected_row
    FROM m34_upgrade_reference.expected;
    SELECT set.policy_set_id,
           version.policy_set_version_id,
           version.version,
           version.eligible_subject_count,
           version.migration_state
    INTO actual_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = 'm34-upgrade-set';
    IF actual_row.policy_set_id IS DISTINCT FROM expected_row.policy_set_id
       OR actual_row.policy_set_version_id IS DISTINCT FROM expected_row.policy_set_version_id
       OR actual_row.version IS DISTINCT FROM expected_row.version
       OR actual_row.eligible_subject_count IS DISTINCT FROM expected_row.eligible_subject_count
       OR actual_row.migration_state IS DISTINCT FROM expected_row.migration_state THEN
        RAISE EXCEPTION 'M34 upgrade changed populated policy-set state: % / %',
            expected_row, actual_row;
    END IF;
END
$m34upgrade$;

SELECT 'M34_UPGRADE_PRESERVED_OK' AS result;
