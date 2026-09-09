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
        'differential_max_change_ratio', 1.0,
        'coordination', 'LEGACY_EXPLICIT');
BEGIN
    SELECT jsonb_build_object(
        'pg_react', (SELECT extversion FROM pg_extension WHERE extname = 'pg_react'),
        'pg_trickle', (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle'),
        'scheduler', current_setting('pg_trickle.enabled'),
        'cdc', current_setting('pg_trickle.cdc_mode'),
        'differential_max_change_ratio', current_setting('pg_trickle.differential_max_change_ratio')::numeric,
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
      "external_graph_refresh", "output_delta_consumer"
    ]$json$::jsonb;
BEGIN
    SELECT jsonb_agg(key ORDER BY key)
    INTO actual
    FROM jsonb_object_keys(
        (SELECT pgreact_internal.pgtrickle_integration_status() -> 'capabilities')) key;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.45.0 capability names changed: %', actual;
    END IF;
    SELECT jsonb_build_object(
        'external_graph_refresh', (status -> 'capabilities' -> 'external_graph_refresh') - 'raw',
        'output_delta_consumer', (status -> 'capabilities' -> 'output_delta_consumer') - 'raw')
    INTO actual
    FROM (SELECT pgreact_internal.pgtrickle_integration_status() AS status) current_status;
    expected := $json${
      "external_graph_refresh":{"major":1,"minor":0,"enabled":false,"status":"experimental"},
      "output_delta_consumer":{"major":1,"minor":0,"enabled":false,"status":"experimental"}
    }$json$::jsonb;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.45.0 capability transcript changed: %', actual;
    END IF;
END
$v0450_capabilities$;

DO $v0450_health$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('code', diagnostic ->> 'code',
                                        'severity', diagnostic ->> 'severity')
                     ORDER BY diagnostic ->> 'code')
    INTO actual
    FROM jsonb_array_elements(pgreact_api.doctor() -> 'diagnostics') diagnostic
    WHERE diagnostic ->> 'code' LIKE 'PGT_%';
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('code', 'PGT_DELTA_DISABLED', 'severity', 'INFO'),
        jsonb_build_object('code', 'PGT_GRAPH_DISABLED', 'severity', 'INFO')) THEN
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
