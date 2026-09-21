\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $v0460$
DECLARE
    actual jsonb;
    expected jsonb := jsonb_build_object(
        'pg_react', '0.46.0',
        'pg_trickle', '0.105.2',
        'scheduler', 'off',
        'cdc', 'trigger',
        'differential_max_change_ratio', 1.0,
        'coordination', 'LEGACY_EXPLICIT');
BEGIN
    SELECT jsonb_build_object(
        'pg_react', (SELECT extversion FROM pg_extension WHERE extname = 'pg_react'),
        'pg_trickle', (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle'),
        'scheduler', current_setting('pg_trickle.enabled'),
        'cdc', current_setting('pg_trickle.cdc_mode'),
        'differential_max_change_ratio', current_setting('pg_trickle.differential_max_change_ratio')::numeric,
        'coordination', pgreact_internal.pgtrickle_integration_status() ->> 'coordination_mode')
    INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.46.0 runtime contract mismatch: %', actual;
    END IF;
    PERFORM pgreact_internal.require_pgtrickle_runtime();
END
$v0460$;

DO $v0460_health$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('code', diagnostic ->> 'code',
                                        'severity', diagnostic ->> 'severity')
                     ORDER BY diagnostic ->> 'code')
    INTO actual
    FROM jsonb_array_elements(pgreact_api.doctor() -> 'diagnostics') diagnostic
    WHERE diagnostic ->> 'code' LIKE 'PGT_%';
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('code', 'PGT_DELTA_AVAILABLE', 'severity', 'INFO'),
        jsonb_build_object('code', 'PGT_GRAPH_AVAILABLE', 'severity', 'INFO')) THEN
        RAISE EXCEPTION 'v0.46.0 healthy doctor transcript changed: %', actual;
    END IF;
END
$v0460_health$;

SELECT 'v0.46.0 runtime and explicit-coordination contract passed' AS result;
