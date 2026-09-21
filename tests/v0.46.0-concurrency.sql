\set ON_ERROR_STOP on

DO $v0460_concurrency$
DECLARE actual jsonb;
    expected jsonb := jsonb_build_object(
        'coordination', 'LEGACY_EXPLICIT',
        'scheduler', 'off',
        'pending_work', 0,
        'active_refresh_lock', false);
BEGIN
    SELECT jsonb_build_object(
        'coordination', pgreact_internal.pgtrickle_integration_status() ->> 'coordination_mode',
        'scheduler', current_setting('pg_trickle.enabled'),
        'pending_work', (SELECT count(*) FROM pgreact.work
                         WHERE state IN ('PENDING', 'RETRY_WAIT')),
        'active_refresh_lock', EXISTS (
            SELECT 1 FROM pg_locks
            WHERE locktype = 'advisory' AND granted))
    INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.46.0 concurrency coordination changed: %', actual;
    END IF;
END
$v0460_concurrency$;

SELECT 'v0.46.0 concurrent explicit-coordination contract passed' AS result;
