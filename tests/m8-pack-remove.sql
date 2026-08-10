\set ON_ERROR_STOP on

INSERT INTO m8_ref.manifests
SELECT 6,
       jsonb_set(jsonb_set(jsonb_set(definition, '{version}', '"6"'),
                           '{programs}', '[]'::jsonb),
                 '{remove_programs}', jsonb_build_array(jsonb_build_object(
                     'name', 'm8.reference'))), mappings
FROM m8_ref.manifests WHERE version = 3;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    actual := m8_ref.normalized_preview(6);
    expected := (m8_ref.expected_preview(3, 3, 3, ARRAY[]::text[]) - 4) ||
        jsonb_build_array(jsonb_build_object(
            'order', 5, 'action', 'REMOVE', 'name', 'm8.reference',
            'dependencies', '[]'::jsonb,
            'generated', jsonb_build_object('object_kind', 'DERIVATION_PROGRAM'),
            'risks', jsonb_build_array(
                'all member supports and facts retract atomically'),
            'details', '{}'::jsonb));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 removal preview changed: %', actual;
    END IF;
END $$;

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 6),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 6)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 6), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 6));
SELECT pgreact.refresh_rule((SELECT observer_version_id FROM m8_ref.pack_control));

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'pack', (SELECT version FROM pgreact.pack_history('m8-reference-pack')
                 WHERE status = 'ACTIVE'),
        'programs', (SELECT jsonb_agg(format('%s:%s', program_version, state)
                                     ORDER BY program_version)
                     FROM pgreact.derivation_programs
                     WHERE program_name = 'm8.reference'),
        'facts', COALESCE((SELECT jsonb_agg(fact ORDER BY relation_name, semantic_key)
            FROM pgreact.derived_facts
            WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
            '[]'::jsonb),
        'supports', COALESCE((SELECT jsonb_agg(source_binding ORDER BY support_id)
            FROM pgreact.support_history
            WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')
              AND active), '[]'::jsonb),
        'rows', jsonb_build_object(
            'A', COALESCE((SELECT jsonb_agg(to_jsonb(a)) FROM m8_ref.a a), '[]'::jsonb),
            'B', COALESCE((SELECT jsonb_agg(to_jsonb(b)) FROM m8_ref.b b), '[]'::jsonb),
            'C', COALESCE((SELECT jsonb_agg(to_jsonb(c)) FROM m8_ref.c c), '[]'::jsonb),
            'D', COALESCE((SELECT jsonb_agg(to_jsonb(d)) FROM m8_ref.d d), '[]'::jsonb)),
        'events', (SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind, 'generation', generation) ORDER BY event_id)
            FROM pgreact_internal.lifecycle_events
            WHERE rule_version_id = (SELECT observer_version_id FROM m8_ref.pack_control))
    ) INTO actual;
    expected := jsonb_build_object(
        'pack', '6',
        'programs', jsonb_build_array('1:REMOVED', '2:REMOVED', '3:REMOVED'),
        'facts', '[]'::jsonb, 'supports', '[]'::jsonb,
        'rows', jsonb_build_object(
            'A', '[]'::jsonb, 'B', '[]'::jsonb, 'C', '[]'::jsonb, 'D', '[]'::jsonb),
        'events', jsonb_build_array(
            jsonb_build_object('event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('event', 'DEACTIVATE', 'generation', 1)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 pack removal changed: %', actual;
    END IF;
END $$;

SELECT 'M8 rule-pack removal retracted the complete recursive program exactly' AS result;
