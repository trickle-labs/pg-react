\set ON_ERROR_STOP on
\ir ../../../integrations/pg-mdm/sql/request-store.sql
\ir ../../../integrations/pg-mdm/sql/intent-worker.sql
GRANT USAGE ON SCHEMA mdm_admin
    TO mdm_legacy_administrator, mdm_administrator;
GRANT EXECUTE ON FUNCTION mdm_admin.rebind(text)
    TO mdm_legacy_administrator, mdm_administrator;
SELECT pgreact_mdm.configure_policy_worker_privileges();
SELECT pgreact_mdm.configure_intent_deployer('mdm_m2_runner');
