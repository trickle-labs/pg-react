\set ON_ERROR_STOP on
\set m8_seed_left false
\set m8_seed_right true
\ir /tmp/m8-setup.sql

CREATE VIEW m8_ref.a_to_c_nested AS SELECT id FROM m8_ref.a_to_c;
UPDATE m8_ref.manifests
SET mappings = mappings || jsonb_build_object(
    'objects', mappings -> 'objects' ||
               jsonb_build_object('m8.a_to_c', 'm8_ref.a_to_c_nested'))
WHERE version = 3;

CREATE FUNCTION m8_ref.pack_state()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_build_object(
    'pack', (SELECT version FROM pgreact.pack_history('m8-reference-pack')
             WHERE status = 'ACTIVE'),
    'program', (SELECT jsonb_build_object(
        'name', program_name || '@' || program_version,
        'state', state, 'frontier', frontier)
        FROM pgreact.derivation_programs WHERE state = 'ACTIVE'),
    'components', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'relations', format('[%s]', (SELECT string_agg(
            upper(regexp_replace(regexp_replace(name, '^.*\.', ''), '@.*$', '')),
            ',' ORDER BY name)
            FROM unnest(c.target_relations) AS name)),
        'cyclic', cyclic, 'frontier', frontier) ORDER BY component_order)
        FROM pgreact.derivation_components c
        WHERE program_version_id = current_setting('m8.program')::uuid), '[]'::jsonb),
    'facts', COALESCE((SELECT jsonb_agg(format('%s(%s)', relation, id)
                                       ORDER BY relation, id)
        FROM (SELECT 'A' relation, id FROM m8_ref.a
              UNION ALL SELECT 'B', id FROM m8_ref.b
              UNION ALL SELECT 'C', id FROM m8_ref.c
              UNION ALL SELECT 'D', id FROM m8_ref.d) facts), '[]'::jsonb),
    'support_counts', COALESCE((SELECT jsonb_agg(format('%s(%s)=%s',
        upper(regexp_replace(relation_name, '^.*\.', '')), semantic_key, support_count)
        ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts
        WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
        '[]'::jsonb),
    'events', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'event', event_kind, 'generation', generation) ORDER BY event_id)
        FROM pgreact_internal.lifecycle_events
        WHERE rule_version_id = current_setting('m8.observer')::uuid), '[]'::jsonb)
)
$$;

CREATE FUNCTION m8_ref.expected_pack_state(
    pack_version text, program_version integer, expected_frontier bigint,
    expected_a_supports integer, expected_c_supports integer,
    component_names text[], component_cycles boolean[]
) RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $$
SELECT jsonb_build_object(
    'pack', pack_version,
    'program', jsonb_build_object(
        'name', 'm8.reference@' || program_version, 'state', 'ACTIVE',
        'frontier', expected_frontier),
    'components', (SELECT jsonb_agg(jsonb_build_object(
        'relations', component_names[i], 'cyclic', component_cycles[i],
        'frontier', expected_frontier) ORDER BY i)
        FROM generate_subscripts(component_names, 1) i),
    'facts', jsonb_build_array('A(7)', 'B(7)', 'C(7)', 'D(7)'),
    'support_counts', jsonb_build_array(
        format('A(7)=%s', expected_a_supports), 'B(7)=1',
        format('C(7)=%s', expected_c_supports), 'D(7)=1'),
    'events', jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'generation', 1))
)
$$;

CREATE FUNCTION m8_ref.rule_identities()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT COALESCE(jsonb_object_agg(r.rule_name, r.rule_version_id ORDER BY r.rule_name), '{}'::jsonb)
FROM pgreact_internal.derivation_program_rules r
WHERE r.program_version_id = current_setting('m8.program')::uuid
$$;

CREATE FUNCTION m8_ref.component_identities()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT COALESCE(jsonb_object_agg(relations, component_id ORDER BY relations), '{}'::jsonb)
FROM (
    SELECT c.component_id, format('[%s]', (SELECT string_agg(
        upper(regexp_replace(regexp_replace(name, '^.*\.', ''), '@.*$', '')),
        ',' ORDER BY name) FROM unnest(c.target_relations) AS name)) AS relations
    FROM pgreact.derivation_components c
    WHERE c.program_version_id = current_setting('m8.program')::uuid
) identities
$$;

CREATE FUNCTION m8_ref.normalized_preview(target_version integer)
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_agg(jsonb_build_object(
    'order', action_order, 'action', action, 'name', rule_name,
    'dependencies', dependencies, 'generated', generated_object_changes,
    'risks', lifecycle_risks,
    'details', details - 'prior_relation_version_id' - 'prior_program_version_id')
    ORDER BY action_order)
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = target_version),
    (SELECT mappings FROM m8_ref.manifests WHERE version = target_version))
$$;

CREATE FUNCTION m8_ref.expected_preview(
    prior_version integer, next_version integer, component_count integer,
    rule_names text[]
) RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $$
WITH relation_rows AS (
    SELECT ordinal, jsonb_build_object(
        'order', ordinal, 'action', 'KEEP', 'name', 'm8.' || relation,
        'dependencies', '[]'::jsonb,
        'generated', jsonb_build_object(
            'object_kind', 'DERIVED_RELATION',
            'public_view', 'm8_ref.' || relation, 'row_type', 'm8_ref.fact_row'),
        'risks', '[]'::jsonb,
        'details', jsonb_build_object('prior_version', 1, 'next_version', 1)) AS value
    FROM unnest(ARRAY['a', 'b', 'c', 'd']) WITH ORDINALITY r(relation, ordinal)
), relation_array AS (
    SELECT jsonb_agg(value ORDER BY ordinal) AS value FROM relation_rows
)
SELECT value || jsonb_build_array(jsonb_build_object(
    'order', 5, 'action', 'REPLACE', 'name', 'm8.reference',
    'dependencies', to_jsonb(rule_names),
    'generated', jsonb_build_object(
        'object_kind', 'DERIVATION_PROGRAM', 'components', component_count),
    'risks', jsonb_build_array(
        'the complete program is rebuilt and commits at one frontier'),
    'details', jsonb_build_object(
        'prior_version', prior_version, 'next_version', next_version,
        'max_iterations', 16, 'max_facts', 64)))
FROM relation_array
$$;

SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);

DO $$
BEGIN
    IF m8_ref.pack_state() IS DISTINCT FROM m8_ref.expected_pack_state(
        '1', 1, 1, 1, 3, ARRAY['[A]', '[B]', '[C,D]'], ARRAY[false, false, true]) THEN
        RAISE EXCEPTION 'M8 V1 pack state changed: %', m8_ref.pack_state();
    END IF;
END $$;

CREATE TEMP TABLE v1_identity AS
SELECT program_id, m8_ref.rule_identities() AS rules,
       m8_ref.component_identities() AS components
FROM pgreact.derivation_programs
WHERE program_version_id = current_setting('m8.program')::uuid;

DO $$
DECLARE actual text[];
BEGIN
    SELECT array_agg(code ORDER BY code) INTO actual
    FROM pgreact.validate_pack(
        (SELECT definition FROM m8_ref.manifests WHERE version = 2),
        (SELECT mappings FROM m8_ref.manifests WHERE version = 2));
    IF actual IS DISTINCT FROM ARRAY['OK'] THEN
        RAISE EXCEPTION 'M8 V2 pack validation changed: %', actual;
    END IF;
    IF m8_ref.normalized_preview(2) IS DISTINCT FROM m8_ref.expected_preview(
        1, 2, 4, ARRAY['m8.left_to_a', 'm8.right_to_a', 'm8.a_to_b',
                       'm8.b_to_c', 'm8.c_to_d']) THEN
        RAISE EXCEPTION 'M8 V2 pack preview changed: %', m8_ref.normalized_preview(2);
    END IF;
END $$;
SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 2),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 2)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 2), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 2));
SELECT program_version_id AS program_version_id FROM pgreact.derivation_programs
WHERE program_name = 'm8.reference' AND state = 'ACTIVE' \gset
SELECT set_config('m8.program', :'program_version_id', false);
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 1 AS frontier_ok \gset
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
DO $$
BEGIN
    IF m8_ref.pack_state() IS DISTINCT FROM m8_ref.expected_pack_state(
        '2', 2, 1, 1, 1,
        ARRAY['[A]', '[B]', '[C]', '[D]'], ARRAY[false, false, false, false]) THEN
        RAISE EXCEPTION 'M8 V2 component split changed: %', m8_ref.pack_state();
    END IF;
    IF (SELECT program_id FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m8.program')::uuid) IS DISTINCT FROM
       (SELECT program_id FROM v1_identity)
       OR m8_ref.rule_identities() IS DISTINCT FROM
          ((SELECT rules FROM v1_identity) - 'm8.a_to_c' - 'm8.d_to_c')
       OR (m8_ref.component_identities() -> '[A]') IS DISTINCT FROM
          ((SELECT components FROM v1_identity) -> '[A]')
       OR (m8_ref.component_identities() -> '[B]') IS DISTINCT FROM
          ((SELECT components FROM v1_identity) -> '[B]') THEN
        RAISE EXCEPTION 'M8 V2 stable identities changed: rules %, components %',
            m8_ref.rule_identities(), m8_ref.component_identities();
    END IF;
END $$;

CREATE TEMP TABLE v2_snapshot AS SELECT m8_ref.pack_state() AS state;
DO $$
BEGIN
    IF m8_ref.normalized_preview(3) IS DISTINCT FROM m8_ref.expected_preview(
        2, 3, 3, ARRAY['m8.left_to_a', 'm8.right_to_a', 'm8.a_to_b',
                       'm8.a_to_c', 'm8.b_to_c', 'm8.c_to_d', 'm8.d_to_c']) THEN
        RAISE EXCEPTION 'M8 V3 pack preview changed: %', m8_ref.normalized_preview(3);
    END IF;
END $$;
SELECT min(plan_digest) AS failed_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 3),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 3)) \gset
SELECT set_config('m8.failed_digest', :'failed_digest', false);
DO $$
BEGIN
    BEGIN
        PERFORM set_config('pgreact.test_fail_pack_phase', 'programs', true);
        PERFORM pgreact.deploy_pack(
            (SELECT definition FROM m8_ref.manifests WHERE version = 3),
            current_setting('m8.failed_digest'),
            (SELECT mappings FROM m8_ref.manifests WHERE version = 3));
        RAISE EXCEPTION 'injected M8 pack deployment unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'injected rule-pack failure after programs phase' THEN RAISE; END IF;
    END;
    IF m8_ref.pack_state() IS DISTINCT FROM (SELECT state FROM v2_snapshot) THEN
        RAISE EXCEPTION 'injected M8 pack deployment changed V2';
    END IF;
END $$;

SELECT min(plan_digest) AS stale_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 3),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 3)) \gset
CREATE OR REPLACE VIEW m8_ref.a_to_c AS
SELECT id FROM m8_ref.a WHERE id IS NOT NULL;
SELECT min(plan_digest) AS current_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 3),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 3)) \gset
SELECT set_config('m8.stale_digest', :'stale_digest', false);
SELECT set_config('m8.current_digest', :'current_digest', false);
DO $$
DECLARE
    failure_detail text;
    failure_hint text;
BEGIN
    BEGIN
        PERFORM pgreact.deploy_pack(
            (SELECT definition FROM m8_ref.manifests WHERE version = 3),
            current_setting('m8.stale_digest'),
            (SELECT mappings FROM m8_ref.manifests WHERE version = 3));
        RAISE EXCEPTION 'stale M8 preview unexpectedly deployed';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rule-pack preview is stale' THEN RAISE; END IF;
        GET STACKED DIAGNOSTICS
            failure_detail = PG_EXCEPTION_DETAIL,
            failure_hint = PG_EXCEPTION_HINT;
        IF failure_detail IS DISTINCT FROM format(
            'expected %s, current %s',
            current_setting('m8.stale_digest'),
            current_setting('m8.current_digest'))
           OR failure_hint IS DISTINCT FROM
              'Run pgreact.preview_pack again after concurrent DDL, support, or deployment changes.' THEN
            RAISE EXCEPTION 'stale M8 preview diagnostic mismatch: detail=%, hint=%',
                failure_detail, failure_hint;
        END IF;
    END;
    IF m8_ref.pack_state() IS DISTINCT FROM (SELECT state FROM v2_snapshot) THEN
        RAISE EXCEPTION 'stale M8 preview changed V2';
    END IF;
END $$;

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 3),
    (SELECT mappings FROM m8_ref.manifests WHERE version = 3)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m8_ref.manifests WHERE version = 3), :'plan_digest',
    (SELECT mappings FROM m8_ref.manifests WHERE version = 3));
SELECT program_version_id AS program_version_id FROM pgreact.derivation_programs
WHERE program_name = 'm8.reference' AND state = 'ACTIVE' \gset
SELECT set_config('m8.program', :'program_version_id', false);
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 1 AS frontier_ok \gset
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
DO $$
BEGIN
    IF m8_ref.pack_state() IS DISTINCT FROM m8_ref.expected_pack_state(
        '3', 3, 1, 1, 3, ARRAY['[A]', '[B]', '[C,D]'], ARRAY[false, false, true]) THEN
        RAISE EXCEPTION 'M8 V3 component merge changed: %', m8_ref.pack_state();
    END IF;
    IF (SELECT program_id FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m8.program')::uuid) IS DISTINCT FROM
       (SELECT program_id FROM v1_identity)
       OR (m8_ref.rule_identities() - 'm8.a_to_c' - 'm8.d_to_c') IS DISTINCT FROM
          ((SELECT rules FROM v1_identity) - 'm8.a_to_c' - 'm8.d_to_c')
       OR m8_ref.component_identities() IS DISTINCT FROM
          (SELECT components FROM v1_identity) THEN
        RAISE EXCEPTION 'M8 V3 stable identities changed: rules %, components %',
            m8_ref.rule_identities(), m8_ref.component_identities();
    END IF;
END $$;

CREATE TEMP TABLE v3_snapshot AS SELECT m8_ref.pack_state() AS state;
INSERT INTO m8_ref.left_seed VALUES (7);
DO $$
DECLARE phase text; result bigint;
BEGIN
    FOREACH phase IN ARRAY ARRAY['after_empty', 'after_iteration', 'before_commit'] LOOP
        PERFORM set_config('pgreact.test_fail_program_phase', phase, true);
        result := pgreact.refresh_derivation_program(current_setting('m8.program')::uuid);
        IF result IS NOT NULL THEN
            RAISE EXCEPTION 'injected % refresh unexpectedly returned %', phase, result;
        END IF;
        IF m8_ref.pack_state() IS DISTINCT FROM (SELECT state FROM v3_snapshot) THEN
            RAISE EXCEPTION 'injected % refresh changed V3', phase;
        END IF;
    END LOOP;
END $$;
DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations, 'fact_count', fact_count,
        'support_count', support_count, 'status', status,
        'error_sqlstate', error_sqlstate, 'error_message', error_message,
        'error_detail', error_detail, 'error_hint', error_hint,
        'requested_by', requested_by) ORDER BY run_id)
    INTO actual
    FROM pgreact_internal.derivation_program_runs
    WHERE program_version_id = current_setting('m8.program')::uuid
      AND status = 'FAILED';
    SELECT jsonb_agg(jsonb_build_object(
        'prior_frontier', 1, 'committed_frontier', 1,
        'iterations', 0, 'fact_count', NULL, 'support_count', NULL,
        'status', 'FAILED', 'error_sqlstate', 'P0001',
        'error_message', 'injected derivation-program failure after ' || phase || ' phase',
        'error_detail', NULL, 'error_hint', NULL,
        'requested_by', current_user) ORDER BY ordinal)
    INTO expected
    FROM unnest(ARRAY['after_empty', 'after_iteration', 'before_commit'])
         WITH ORDINALITY failures(phase, ordinal);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'injected refresh FAILED runs changed: %', actual;
    END IF;
END $$;
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 2 AS frontier_ok \gset
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
DO $$
BEGIN
    IF m8_ref.pack_state() IS DISTINCT FROM m8_ref.expected_pack_state(
        '3', 3, 2, 2, 3, ARRAY['[A]', '[B]', '[C,D]'], ARRAY[false, false, true]) THEN
        RAISE EXCEPTION 'M8 V3 frontier 2 changed: %', m8_ref.pack_state();
    END IF;
END $$;

INSERT INTO m8_ref.manifests
SELECT 4,
       jsonb_set(jsonb_set(jsonb_set(definition, '{version}', '"4"'),
                           '{programs,0,version}', '4'),
                 '{programs,0,max_iterations}', '1'), mappings
FROM m8_ref.manifests WHERE version = 3;
INSERT INTO m8_ref.manifests
SELECT 5,
       jsonb_set(jsonb_set(jsonb_set(definition, '{version}', '"5"'),
                           '{programs,0,version}', '5'),
                 '{programs,0,max_facts}', '3'), mappings
FROM m8_ref.manifests WHERE version = 3;
CREATE TEMP TABLE v3_frontier_2 AS SELECT m8_ref.pack_state() AS state;

DO $$
DECLARE limited_version integer; digest text;
BEGIN
    FOREACH limited_version IN ARRAY ARRAY[4, 5] LOOP
        SELECT min(plan_digest) INTO digest FROM pgreact.preview_pack(
            (SELECT definition FROM m8_ref.manifests WHERE version = limited_version),
            (SELECT mappings FROM m8_ref.manifests WHERE version = limited_version));
        BEGIN
            PERFORM pgreact.deploy_pack(
                (SELECT definition FROM m8_ref.manifests WHERE version = limited_version),
                digest,
                (SELECT mappings FROM m8_ref.manifests WHERE version = limited_version));
            RAISE EXCEPTION 'resource-limited M8 pack % unexpectedly deployed', limited_version;
        EXCEPTION WHEN OTHERS THEN
            IF SQLERRM NOT LIKE (CASE limited_version
                WHEN 4 THEN '%did not converge within 1 iterations'
                ELSE '%exceeded max_facts 3' END) THEN RAISE; END IF;
        END;
        IF m8_ref.pack_state() IS DISTINCT FROM (SELECT state FROM v3_frontier_2) THEN
            RAISE EXCEPTION 'resource-limited M8 pack % changed V3', limited_version;
        END IF;
    END LOOP;
END $$;

CREATE TABLE m8_ref.pack_control AS
SELECT current_setting('m8.program')::uuid AS program_version_id,
       current_setting('m8.observer')::uuid AS observer_version_id;

SELECT 'M8 exact split, merge, drift, injected, and resource rollback checks passed' AS result;
