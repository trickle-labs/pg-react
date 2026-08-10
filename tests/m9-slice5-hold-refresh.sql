\set ON_ERROR_STOP on

BEGIN;
SELECT pgreact.refresh_derivation_program(program_version_id)
FROM m9_slice5.concurrent_control;
SELECT pg_sleep(30);
COMMIT;
