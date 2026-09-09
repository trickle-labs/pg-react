\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $v0450$
DECLARE
    actual jsonb;
    expected jsonb := jsonb_build_object(
        'pg_react', '0.45.0',
        'pg_trickle', '0.98.0',
        'scheduler', 'off',
        'cdc', 'trigger',
        'coordination', 'LEGACY_EXPLICIT');
BEGIN
    SELECT jsonb_build_object(
        'pg_react', (SELECT extversion FROM pg_extension WHERE extname = 'pg_react'),
        'pg_trickle', (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle'),
        'scheduler', current_setting('pg_trickle.enabled'),
        'cdc', current_setting('pg_trickle.cdc_mode'),
        'coordination', 'LEGACY_EXPLICIT')
    INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.45.0 runtime contract mismatch: %', actual;
    END IF;
END
$v0450$;

DO $v0450_capabilities$
DECLARE
    actual jsonb;
    expected jsonb := $json$[
      {"name":"external_graph_refresh","major":1,"minor":0,"enabled":false,"status":"experimental"},
      {"name":"output_delta_consumer","major":1,"minor":0,"enabled":false,"status":"experimental"}
    ]$json$::jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(row_value) ORDER BY to_jsonb(row_value)::text)
    INTO actual
    FROM pgtrickle.integration_capabilities() row_value;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.45.0 capability transcript changed: %', actual;
    END IF;
END
$v0450_capabilities$;

DO $v0450_health$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.doctor();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 7,
        'status', 'ready',
        'diagnostics', jsonb_build_array(
            jsonb_build_object('code', 'PGT_GRAPH_DISABLED', 'severity', 'INFO'),
            jsonb_build_object('code', 'PGT_DELTA_DISABLED', 'severity', 'INFO'))) THEN
        RAISE EXCEPTION 'v0.45.0 healthy doctor transcript changed: %', actual;
    END IF;
END
$v0450_health$;

DO $v0450_negative$
DECLARE graph_enabled boolean; delta_enabled boolean;
BEGIN
    SELECT (to_jsonb(row_value) ->> 'enabled')::boolean INTO graph_enabled
    FROM pgtrickle.integration_capabilities() row_value
    WHERE COALESCE(to_jsonb(row_value) ->> 'capability', to_jsonb(row_value) ->> 'name') =
        'external_graph_refresh';
    SELECT (to_jsonb(row_value) ->> 'enabled')::boolean INTO delta_enabled
    FROM pgtrickle.integration_capabilities() row_value
    WHERE COALESCE(to_jsonb(row_value) ->> 'capability', to_jsonb(row_value) ->> 'name') =
        'output_delta_consumer';
    IF graph_enabled OR delta_enabled THEN
        RAISE EXCEPTION 'v0.45.0 admitted a disabled Graph or Delta capability';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE proname IN (
        'set_orchestration_mode', 'graph_contract', 'refresh_graph_strict',
        'register_output_delta_consumer') AND prokind = 'p') THEN
        RAISE NOTICE 'disabled Graph/Delta entry points are present but were not called';
    END IF;
END
$v0450_negative$;

SELECT 'v0.45.0 capability, health, and legacy coordination contract passed' AS result;
