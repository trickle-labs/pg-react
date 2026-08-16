\set ON_ERROR_STOP on
SELECT extversion FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.26.0';
SELECT value FROM m29_upgrade.state WHERE name = 'before';
SELECT count(*) FROM pgreact.policy_sets;
SELECT pgreact_api.status(pgreact_api.target('policy_set', 'm29-upgrade-missing')) ->> 'state';
