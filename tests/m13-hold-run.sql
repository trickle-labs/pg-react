\set ON_ERROR_STOP on
BEGIN;
SELECT pgreact_api.run('2033-01-01 00:00:00+00');
SELECT pg_sleep(3);
COMMIT;
