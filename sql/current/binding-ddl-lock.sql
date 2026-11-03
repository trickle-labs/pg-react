-- Temp relations are session-local and cannot change persistent React bindings.
CREATE OR REPLACE FUNCTION pgreact_internal.binding_ddl_lock()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    call_context text;
BEGIN
    GET DIAGNOSTICS call_context = PG_CONTEXT;
    IF TG_TAG IN (
        'CREATE TABLE', 'ALTER TABLE', 'DROP TABLE',
        'CREATE VIEW', 'ALTER VIEW', 'DROP VIEW',
        'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW', 'DROP MATERIALIZED VIEW'
    ) AND (
        call_context ~* 'SQL statement "[[:space:]]*CREATE[[:space:]]+(GLOBAL[[:space:]]+|LOCAL[[:space:]]+)?(TEMP|TEMPORARY)[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW)([[:space:]]|$)'
        OR call_context ~* 'SQL statement "[[:space:]]*(CREATE[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW)|ALTER[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW)|DROP[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW))[[:space:]]+(IF[[:space:]]+(NOT[[:space:]]+)?EXISTS[[:space:]]+)?("?pg_temp(_[0-9]+)?"?[.])'
    ) THEN
        RETURN;
    END IF;

    -- Preserve the coordinator-before-binding order used by deployment.
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
END
$$;
