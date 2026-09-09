\set ON_ERROR_STOP on

DO $v0450_upgrade$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'pg_react', (SELECT extversion FROM pg_extension WHERE extname = 'pg_react'),
        'pg_trickle', (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle'),
        'declarations', (SELECT count(*) FROM pgreact_internal.api_declarations),
        'history', (SELECT count(*) FROM pgreact.execution_history()))
    INTO actual;
    IF actual ->> 'pg_react' <> '0.45.0'
       OR actual ->> 'pg_trickle' <> '0.98.0' THEN
        RAISE EXCEPTION 'v0.44.0 to v0.45.0 upgrade state changed: %', actual;
    END IF;
    IF (actual ->> 'declarations')::bigint > 0
       AND (actual ->> 'history')::bigint = 0 THEN
        RAISE EXCEPTION 'v0.44.0 to v0.45.0 upgrade lost retained history: %', actual;
    END IF;
END
$v0450_upgrade$;

SELECT 'v0.44.0 to v0.45.0 adjacent upgrade contract passed' AS result;
