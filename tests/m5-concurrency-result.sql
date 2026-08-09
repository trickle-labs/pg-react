\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('version', version, 'status', status) ORDER BY deployed_at)
      INTO actual FROM pgreact.pack_history('risk-pack');
    IF actual IS DISTINCT FROM '[
        {"version": "1", "status": "SUPERSEDED"},
        {"version": "2", "status": "SUPERSEDED"},
        {"version": "3", "status": "SUPERSEDED"},
        {"version": "4", "status": "ACTIVE"}
    ]'::jsonb THEN
        RAISE EXCEPTION 'concurrent deployment history changed: %', actual;
    END IF;
END
$$;

SELECT 'M5 deployment and DDL serialization checks passed' AS result;
