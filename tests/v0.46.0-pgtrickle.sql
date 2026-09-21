\set ON_ERROR_STOP on

DO $v0460_report$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_internal.pgtrickle_capability_report(jsonb_build_array(
        jsonb_build_object('capability', 'external_graph_refresh', 'major_version', 1,
                           'minor_version', 0, 'enabled', true, 'status', 'stable'),
        jsonb_build_object('capability', 'output_delta_consumer', 'major_version', 1,
                           'minor_version', 0, 'enabled', true, 'status', 'stable'),
        jsonb_build_object('capability', 'future_capability', 'major_version', 9,
                           'minor_version', 4, 'enabled', true, 'status', 'experimental')));
    IF (actual -> 'external_graph_refresh') - 'raw' IS DISTINCT FROM
       jsonb_build_object('major', 1, 'minor', 0, 'enabled', true, 'status', 'stable') THEN
        RAISE EXCEPTION 'pg_trickle stable Graph V1 report changed: %', actual;
    END IF;
    IF (actual -> 'future_capability') - 'raw' IS DISTINCT FROM
       jsonb_build_object('major', 9, 'minor', 4, 'enabled', true, 'status', 'experimental') THEN
        RAISE EXCEPTION 'unknown capability handling changed: %', actual;
    END IF;
    actual := pgreact_internal.pgtrickle_capability_report(jsonb_build_array(
        jsonb_build_object('capability', 'output_delta_consumer', 'major_version', 1,
                           'minor_version', 0, 'enabled', true, 'status', 'stable')));
    IF actual ? 'external_graph_refresh' THEN
        RAISE EXCEPTION 'missing Graph capability unexpectedly appeared: %', actual;
    END IF;

    BEGIN
        PERFORM pgreact_internal.pgtrickle_capability_report(jsonb_build_array(
            jsonb_build_object('name', 'duplicate', 'major', 1, 'minor', 0, 'enabled', true),
            jsonb_build_object('name', 'duplicate', 'major', 1, 'minor', 0, 'enabled', true)));
        RAISE EXCEPTION 'duplicate capability unexpectedly accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%capability is duplicated%' THEN RAISE; END IF;
    END;

    BEGIN
        PERFORM pgreact_internal.pgtrickle_capability_report(jsonb_build_array(
            jsonb_build_object('name', 'malformed', 'major', 'one', 'minor', 0, 'enabled', true)));
        RAISE EXCEPTION 'malformed capability unexpectedly accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%capability row is malformed%' THEN RAISE; END IF;
    END;
END
$v0460_report$;

DO $v0460_status$
DECLARE
    actual jsonb;
    capabilities jsonb;
    expected jsonb := jsonb_build_object(
        'extension_version', '0.105.2',
        'package_qualified', true,
        'capabilities_qualified', true,
        'qualified', true,
        'coordination_mode', 'LEGACY_EXPLICIT',
        'graph_v1_used', false,
        'delta_v1_used', false,
        'scheduler_expected', 'off',
        'cdc_expected', 'trigger');
BEGIN
    SELECT pgreact_internal.pgtrickle_integration_status() - 'capabilities'
    INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.46.0 integration status changed: %', actual;
    END IF;
    SELECT jsonb_object_agg(key, value - 'raw' ORDER BY key)
    INTO capabilities
    FROM jsonb_each(pgreact_internal.pgtrickle_integration_status() -> 'capabilities');
    expected := $json${
      "external_graph_refresh":{"major":1,"minor":0,"enabled":true,"status":"stable"},
      "output_delta_consumer":{"major":1,"minor":0,"enabled":true,"status":"stable"}
    }$json$::jsonb;
    IF capabilities IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'v0.46.0 capability transcript changed: %', capabilities;
    END IF;
END
$v0460_status$;

SELECT 'v0.46.0 pg_trickle capability boundary assertions passed' AS result;
