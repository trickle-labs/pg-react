\set ON_ERROR_STOP on

DO $v0450_concurrency$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'coordination', 'LEGACY_EXPLICIT',
        'scheduler', current_setting('pg_trickle.enabled'),
        'pending_work', (SELECT count(*) FROM pgreact.work
                         WHERE state IN ('PENDING', 'RETRY_WAIT')),
        'active_refresh_lock', EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'advisory' AND granted))
    INTO actual;
    IF actual ->> 'coordination' <> 'LEGACY_EXPLICIT'
       OR actual ->> 'scheduler' <> 'off' THEN
        RAISE EXCEPTION 'v0.45.0 concurrency coordination changed: %', actual;
    END IF;
END
$v0450_concurrency$;

SELECT 'v0.45.0 concurrent explicit-coordination contract passed' AS result;
