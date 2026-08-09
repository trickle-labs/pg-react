\set ON_ERROR_STOP on

BEGIN;
SELECT pgreact.refresh_derived_relation(relation_version_id)
FROM m7_concurrency.control;
SELECT pgreact.refresh_rule(observer_version_id)
FROM m7_concurrency.control;
SELECT pg_sleep(30);
COMMIT;
