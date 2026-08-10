\set ON_ERROR_STOP on

BEGIN;
SELECT pgreact.refresh_derivation_program(program_version_id)
FROM m8_ref.pack_control;
SELECT pg_sleep(30);
COMMIT;
