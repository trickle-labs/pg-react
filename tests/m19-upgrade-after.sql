\set ON_ERROR_STOP on
SET client_min_messages = warning;
DO $$
DECLARE actual jsonb;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.16.0' THEN
        RAISE EXCEPTION 'M19 direct upgrade version changed';
    END IF;
    actual := pgreact_api.status('m19.upgrade.scheduled');
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5,
        'rules', jsonb_build_array(jsonb_build_object(
            'rule', 'm19.upgrade.scheduled', 'condition', 'm19_upgrade.active',
            'key', 'id', 'state', 'active', 'actions', jsonb_build_array()))) THEN
        RAISE EXCEPTION 'M19 scheduled state changed across upgrade: %', actual;
    END IF;
END
$$;
SET SESSION AUTHORIZATION m19_author;
SELECT pgreact_api.author_immediate_rule(
    'm19.upgrade.immediate', 'm19_upgrade.active', 'id');
RESET SESSION AUTHORIZATION;
SELECT 'M19 direct 0.15.0 to 0.16.0 upgrade preserved scheduled state and enabled immediate opt-in';
