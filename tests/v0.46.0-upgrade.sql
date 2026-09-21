\set ON_ERROR_STOP on

DO $v0460_upgrade$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'pg_react', (SELECT extversion FROM pg_extension WHERE extname = 'pg_react'),
        'pg_trickle', (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle'),
        'declarations', (SELECT count(*) FROM pgreact_internal.api_declarations),
        'history', (SELECT count(*) FROM pgreact.execution_history()),
        'upgrade_sentinel', (SELECT count(*) FROM pgreact_internal.runtime_events
                             WHERE event_type = 'V046_UPGRADE_SENTINEL'
                               AND detail = '{"preserve":true}'::jsonb))
    INTO actual;
    IF actual ->> 'pg_react' <> '0.46.0'
       OR actual ->> 'pg_trickle' <> '0.105.2' THEN
        RAISE EXCEPTION 'v0.45.0 to v0.46.0 upgrade state changed: %', actual;
    END IF;
    IF (actual ->> 'upgrade_sentinel')::bigint <> 1 THEN
        RAISE EXCEPTION 'v0.45.0 to v0.46.0 upgrade lost retained state: %', actual;
    END IF;
END
$v0460_upgrade$;

SELECT 'v0.45.0 to v0.46.0 adjacent upgrade contract passed' AS result;
