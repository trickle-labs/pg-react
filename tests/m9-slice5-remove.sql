\set ON_ERROR_STOP on
\o /dev/null

CREATE TEMP TABLE removal AS
SELECT jsonb_set(
           jsonb_set(definition, '{version}', to_jsonb('5'::text)),
           '{programs}', '[]'::jsonb) || jsonb_build_object(
               'remove_programs', jsonb_build_array(jsonb_build_object(
                   'name', 'm9.slice4'))) AS definition,
       mappings
FROM m9_slice5.manifests
WHERE version = 3;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'action', action,
        'name', rule_name,
        'dependencies', dependencies,
        'generated', generated_object_changes,
        'risks', lifecycle_risks,
        'details', details) ORDER BY action_order)
    INTO actual
    FROM pgreact.preview_pack(
        (SELECT definition FROM removal),
        (SELECT mappings FROM removal))
    WHERE rule_name = 'm9.slice4';
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'action', 'REMOVE',
        'name', 'm9.slice4',
        'dependencies', '[]'::jsonb,
        'generated', jsonb_build_object('object_kind', 'DERIVATION_PROGRAM'),
        'risks', jsonb_build_array(
            'all member supports and facts retract atomically'),
        'details', '{}'::jsonb)) THEN
        RAISE EXCEPTION 'M9 slice 5 removal preview changed: %', actual;
    END IF;
END
$$;

CREATE TEMP TABLE removal_preview AS
SELECT min(plan_digest) AS digest
FROM pgreact.preview_pack(
    (SELECT definition FROM removal),
    (SELECT mappings FROM removal));

SELECT pgreact.deploy_pack(
    (SELECT definition FROM removal),
    (SELECT digest FROM removal_preview),
    (SELECT mappings FROM removal));

DO $$
DECLARE actual jsonb := m9_slice5.state();
DECLARE expected jsonb := jsonb_build_object(
    'packs', jsonb_build_array(
        '1:SUPERSEDED', '2:SUPERSEDED', '3:SUPERSEDED', '5:ACTIVE'),
    'programs', jsonb_build_array(
        jsonb_build_object('version', 1, 'state', 'REMOVED', 'frontier', 7),
        jsonb_build_object('version', 2, 'state', 'REMOVED', 'frontier', 1),
        jsonb_build_object('version', 3, 'state', 'REMOVED', 'frontier', 1)),
    'graph', '[]'::jsonb,
    'strata', '[]'::jsonb,
    'facts', '[]'::jsonb,
    'supports', '[]'::jsonb,
    'orphaned_supports', '[]'::jsonb,
    'negative_inputs', '[]'::jsonb);
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 slice 5 removal state changed: %', actual;
    END IF;
END
$$;

\o
SELECT 'M9 slice 5 complete stratified-program removal gate passed' AS result;
