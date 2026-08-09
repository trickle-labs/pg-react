\set ON_ERROR_STOP on
SELECT pgreact_internal.begin_refresh(
    (SELECT rule_version_id FROM pgreact_internal.rule_versions
     WHERE source_view_name = 'rule_def.high_value_risky_order'),
    9000
);
SELECT pg_sleep(1);
SELECT pgreact_internal.clear_refresh_barrier(
    (SELECT rule_version_id FROM pgreact_internal.rule_versions
     WHERE source_view_name = 'rule_def.high_value_risky_order')
);
SELECT pgreact_internal.release_refresh_lock();
