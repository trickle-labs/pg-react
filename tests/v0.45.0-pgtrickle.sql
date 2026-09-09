\set ON_ERROR_STOP on
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_internal.pgtrickle_capability_report(jsonb_build_array(
        jsonb_build_object('name', 'external_graph_refresh', 'major', 1, 'minor', 0,
                           'enabled', false, 'status', 'experimental'),
        jsonb_build_object('name', 'future_capability', 'major', 9, 'minor', 4,
                           'enabled', true, 'status', 'experimental')));
    IF actual IS DISTINCT FROM jsonb_build_object(
        'external_graph_refresh', jsonb_build_object(
            'major', 1, 'minor', 0, 'enabled', false, 'status', 'experimental',
            'raw', jsonb_build_object('name', 'external_graph_refresh', 'major', 1,
                                      'minor', 0, 'enabled', false, 'status', 'experimental')),
        'future_capability', jsonb_build_object(
            'major', 9, 'minor', 4, 'enabled', true, 'status', 'experimental',
            'raw', jsonb_build_object('name', 'future_capability', 'major', 9,
                                      'minor', 4, 'enabled', true, 'status', 'experimental'))) THEN
        RAISE EXCEPTION 'pg_trickle capability report changed: %', actual;
    END IF;

    BEGIN
        PERFORM pgreact_internal.pgtrickle_capability_report(jsonb_build_array(
            jsonb_build_object('name', 'duplicate', 'major', 1, 'minor', 0, 'enabled', false),
            jsonb_build_object('name', 'duplicate', 'major', 1, 'minor', 0, 'enabled', false)));
        RAISE EXCEPTION 'duplicate capability unexpectedly accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%capability is duplicated%' THEN RAISE; END IF;
    END;

    BEGIN
        PERFORM pgreact_internal.pgtrickle_capability_report(jsonb_build_array(
            jsonb_build_object('name', 'malformed', 'major', 'one', 'minor', 0, 'enabled', false)));
        RAISE EXCEPTION 'malformed capability unexpectedly accepted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%capability row is malformed%' THEN RAISE; END IF;
    END;
END
$$;

SELECT 'v0.45.0 pg_trickle capability boundary assertions passed';
