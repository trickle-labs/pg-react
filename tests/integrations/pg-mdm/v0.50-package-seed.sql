\set ON_ERROR_STOP on
\ir ../../../integrations/pg-mdm/sql/policy-inputs.sql

-- shortcut: seeds the v0.48 migration prerequisite until this lane can run v0.47 in an MDM-absent database.
SELECT pgreact_mdm.publish_package(
    'v0.47-upgrade-seed',
    '{"deadline":{"duration_seconds":60,"min_seconds":60,"max_seconds":3600,"replace_existing_deadline":false},"routes":[{"reason_code":"UPGRADE_SEED","queue":"seed","priority":1,"action":"ASSIGN_QUEUE"}]}'::jsonb);
