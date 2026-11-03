\set ON_ERROR_STOP on
DROP EVENT TRIGGER IF EXISTS pgre_mdm_history_guard_ddl;
\ir request-store.sql
\ir intent-worker.sql
\ir retention-guard.sql
\echo PASS: MDM adapter SQL reapplied after restore
