\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_mdm;

DO $helper_owner$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'mdm_helper_owner') THEN
        EXECUTE 'CREATE ROLE mdm_helper_owner NOLOGIN NOSUPERUSER NOBYPASSRLS '
            || 'NOCREATEDB NOCREATEROLE NOREPLICATION';
    END IF;
END
$helper_owner$;

\ir ../../../integrations/pg-mdm/sql/policy-inputs.sql
\ir ../../../integrations/pg-mdm/sql/routing.sql
\ir ../../../integrations/pg-mdm/sql/deadline-preview.sql
\ir ../../../integrations/pg-mdm/sql/comparison.sql
\ir ../../../integrations/pg-mdm/sql/typed-flow.sql
\ir ../../../integrations/pg-mdm/sql/request-store.sql
\ir ../../../integrations/pg-mdm/sql/intent-worker.sql
\ir ../../../integrations/pg-mdm/sql/operational-activity.sql

DO $source_identity$
BEGIN
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_mdm')
       IS DISTINCT FROM '0.15.0' THEN
        RAISE EXCEPTION 'expected pg_mdm 0.15.0 from the pinned source';
    END IF;
    IF to_regclass('pgreact_mdm.operational_activity_v1') IS NULL
       OR to_regclass('pgreact_mdm.pending_cases_v1') IS NULL THEN
        RAISE EXCEPTION 'v0.50 operational views were not installed';
    END IF;
END
$source_identity$;
