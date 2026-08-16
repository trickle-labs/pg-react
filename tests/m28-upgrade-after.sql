\set ON_ERROR_STOP on
SELECT extversion FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.25.0';
SELECT value FROM m28_upgrade.state WHERE name = 'before';
SELECT pgreact_api.status(pgreact_api.target('rule', 'm28-upgrade-missing')) ->> 'state';
