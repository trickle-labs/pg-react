\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.17.0' THEN
        RAISE EXCEPTION 'M20 upgrade version changed';
    END IF;
END
$$;
SET SESSION AUTHORIZATION m20_upgrade_author;
CREATE VIEW m20_upgrade.active_v2 AS SELECT id FROM m20_upgrade.source WHERE enabled;
SELECT pgreact_api.deploy_shared_condition(jsonb_build_object(
    'name', 'm20_upgrade.condition', 'version', 1,
    'source', 'm20_upgrade.active_v2', 'row_type', 'm20_upgrade.row_value',
    'key', ARRAY['id'], 'maintenance_mode', 'SCHEDULED'));
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m20_upgrade_reader;
DO $$
BEGIN
    IF (pgreact_api.shared_condition_status('m20_upgrade.condition') #>> '{conditions,0,version}') <> '1' THEN
        RAISE EXCEPTION 'M20 populated upgrade condition changed';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
SELECT 'M20 direct 0.16.0 to 0.17.0 upgrade gate passed';
