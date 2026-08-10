\set ON_ERROR_STOP on
\ir /tmp/m8-setup.sql

CREATE FUNCTION m8_ref.optional_state()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_build_object(
    'packs', (SELECT jsonb_agg(version || ':' || status ORDER BY deployed_at)
              FROM pgreact.pack_history('m8-reference-pack')),
    'programs', COALESCE((SELECT jsonb_agg(
        program_version || ':' || state ORDER BY program_version)
        FROM pgreact.derivation_programs
        WHERE program_name = 'm8.reference'), '[]'::jsonb),
    'active_program', (SELECT jsonb_build_object(
        'name', program_name || '@' || program_version,
        'frontier', frontier, 'owner', owner)
        FROM pgreact.derivation_programs WHERE state = 'ACTIVE'),
    'components', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'relations', format('[%s]', (SELECT string_agg(
            upper(regexp_replace(regexp_replace(name, '^.*\.', ''), '@.*$', '')),
            ',' ORDER BY name) FROM unnest(c.target_relations) name)),
        'cyclic', c.cyclic, 'frontier', c.frontier, 'iterations', c.iterations,
        'facts', c.fact_count, 'supports', c.support_count) ORDER BY c.component_order)
        FROM pgreact.derivation_components c
        JOIN pgreact.derivation_programs p USING (program_version_id)
        WHERE p.state = 'ACTIVE'), '[]'::jsonb),
    'facts', COALESCE((SELECT jsonb_agg(format('%s(%s)=%s',
        upper(regexp_replace(relation_name, '^.*\.', '')), semantic_key, support_count)
        ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts
        WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
        '[]'::jsonb),
    'supports', COALESCE((SELECT jsonb_agg(r.rule_name ORDER BY r.rule_name)
        FROM pgreact_internal.derived_supports s
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = s.program_version_id
         AND r.rule_version_id = s.rule_version_id
        WHERE s.active), '[]'::jsonb),
    'rows', jsonb_build_object(
        'A', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM m8_ref.a a), '[]'::jsonb),
        'B', COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY id) FROM m8_ref.b b), '[]'::jsonb),
        'C', COALESCE((SELECT jsonb_agg(to_jsonb(c) ORDER BY id) FROM m8_ref.c c), '[]'::jsonb),
        'D', COALESCE((SELECT jsonb_agg(to_jsonb(d) ORDER BY id) FROM m8_ref.d d), '[]'::jsonb))
)
$$;

INSERT INTO m8_ref.manifests
SELECT 20,
       jsonb_set(definition, '{version}', '"20"') - 'remove_programs', mappings
FROM m8_ref.manifests WHERE version = 2;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(d) ORDER BY code, object_identity) INTO actual
    FROM pgreact.validate_pack(
        (SELECT definition FROM m8_ref.manifests WHERE version = 20),
        (SELECT mappings FROM m8_ref.manifests WHERE version = 20)) d;
    expected := jsonb_build_array(jsonb_build_object(
        'contract_version', 3, 'code', 'OK', 'severity', 'INFO',
        'object_identity', 'm8-reference-pack',
        'message', 'M8 pack and derivation programs are valid',
        'hint', 'Preview and deploy with the exact plan digest.',
        'details', jsonb_build_object('programs', 1, 'remove_programs', 0)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'programs-only validation changed: %', actual;
    END IF;
END $$;
SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 20),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 20)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 20), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 20));

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    actual := m8_ref.optional_state();
    expected := jsonb_build_object(
        'packs', jsonb_build_array('0:SUPERSEDED', '1:SUPERSEDED', '20:ACTIVE'),
        'programs', jsonb_build_array('1:REMOVED', '2:ACTIVE'),
        'active_program', jsonb_build_object(
            'name', 'm8.reference@2', 'frontier', 1, 'owner', current_user),
        'components', jsonb_build_array(
            jsonb_build_object('relations', '[A]', 'cyclic', false, 'frontier', 1,
                               'iterations', 2, 'facts', 1, 'supports', 2),
            jsonb_build_object('relations', '[B]', 'cyclic', false, 'frontier', 1,
                               'iterations', 2, 'facts', 1, 'supports', 1),
            jsonb_build_object('relations', '[C]', 'cyclic', false, 'frontier', 1,
                               'iterations', 2, 'facts', 1, 'supports', 1),
            jsonb_build_object('relations', '[D]', 'cyclic', false, 'frontier', 1,
                               'iterations', 2, 'facts', 1, 'supports', 1)),
        'facts', jsonb_build_array('A(7)=2', 'B(7)=1', 'C(7)=1', 'D(7)=1'),
        'supports', jsonb_build_array(
            'm8.a_to_b', 'm8.b_to_c', 'm8.c_to_d',
            'm8.left_to_a', 'm8.right_to_a'),
        'rows', jsonb_build_object(
            'A', jsonb_build_array(jsonb_build_object('id', 7)),
            'B', jsonb_build_array(jsonb_build_object('id', 7)),
            'C', jsonb_build_array(jsonb_build_object('id', 7)),
            'D', jsonb_build_array(jsonb_build_object('id', 7))));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'programs-only deployment changed: %', actual;
    END IF;
END $$;

INSERT INTO m8_ref.manifests
SELECT 21,
       jsonb_set(jsonb_set(definition, '{version}', '"21"'),
                 '{remove_programs}',
                 jsonb_build_array(jsonb_build_object('name', 'm8.reference')))
           - 'programs', mappings
FROM m8_ref.manifests WHERE version = 20;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(d) ORDER BY code, object_identity) INTO actual
    FROM pgreact.validate_pack(
        (SELECT definition FROM m8_ref.manifests WHERE version = 21),
        (SELECT mappings FROM m8_ref.manifests WHERE version = 21)) d;
    expected := jsonb_build_array(jsonb_build_object(
        'contract_version', 3, 'code', 'OK', 'severity', 'INFO',
        'object_identity', 'm8-reference-pack',
        'message', 'M8 pack and derivation programs are valid',
        'hint', 'Preview and deploy with the exact plan digest.',
        'details', jsonb_build_object('programs', 0, 'remove_programs', 1)));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'remove_programs-only validation changed: %', actual;
    END IF;
END $$;
SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 21),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 21)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 21), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 21));

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    actual := m8_ref.optional_state();
    expected := jsonb_build_object(
        'packs', jsonb_build_array(
            '0:SUPERSEDED', '1:SUPERSEDED', '20:SUPERSEDED', '21:ACTIVE'),
        'programs', jsonb_build_array('1:REMOVED', '2:REMOVED'),
        'active_program', NULL, 'components', '[]'::jsonb,
        'facts', '[]'::jsonb, 'supports', '[]'::jsonb,
        'rows', jsonb_build_object(
            'A', '[]'::jsonb, 'B', '[]'::jsonb,
            'C', '[]'::jsonb, 'D', '[]'::jsonb));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'remove_programs-only deployment changed: %', actual;
    END IF;
END $$;

SELECT 'M8 independently optional program arrays passed' AS result;
