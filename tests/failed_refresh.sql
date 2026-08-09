\set ON_ERROR_STOP on
SELECT pgreact_internal.begin_refresh(
    (SELECT rule_version_id FROM pgreact_internal.rule_versions
     WHERE source_view_name = 'rule_def.high_value_risky_order'),
    :refresh_id
);
SELECT pgreact_internal.refresh_rule(
    (SELECT rule_version_id FROM pgreact_internal.rule_versions
     WHERE source_view_name = 'rule_def.high_value_risky_order')
);
