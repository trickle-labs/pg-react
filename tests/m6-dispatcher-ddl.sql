\set ON_ERROR_STOP on

SET lock_timeout = '100ms';
DO $$
DECLARE target text;
BEGIN
    SELECT b.dispatcher_identity INTO STRICT target
    FROM pgreact_internal.consequence_bindings b
    JOIN m6_concurrency.control c USING (rule_version_id)
    WHERE b.event_kind = 'ACTIVATE';
    EXECUTE format('ALTER FUNCTION %s COST 101', target);
END
$$;
