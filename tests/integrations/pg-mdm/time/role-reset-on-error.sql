BEGIN;
SET ROLE pgreact_mdm_worker;
SELECT pgreact_api.managed_cycle();
ROLLBACK;
SELECT session_user::text || '|' || current_user::text;
