\set ON_ERROR_STOP on
\ir /tmp/m7-upgrade.sql

CREATE TEMP TABLE m8_pre_upgrade AS
SELECT jsonb_build_object(
    'rules', (SELECT jsonb_agg(to_jsonb(r) ORDER BY rule_id) FROM pgreact_internal.rules r),
    'versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY rule_version_id)
                 FROM pgreact_internal.rule_versions v),
    'episodes', (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM pgreact.episodes e),
    'batches', (SELECT jsonb_agg(to_jsonb(b) ORDER BY batch_id)
                FROM pgreact_internal.execution_batches b),
    'relations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY relation_id)
                  FROM pgreact_internal.derived_relations r),
    'relation_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY relation_version_id)
                          FROM pgreact_internal.derived_relation_versions v),
    'derivations', (SELECT jsonb_agg(to_jsonb(d) ORDER BY rule_version_id)
                    FROM pgreact_internal.derivation_rule_versions d),
    'supports', (SELECT jsonb_agg(
                     to_jsonb(s) - ARRAY[
                         'program_version_id', 'grounded', 'support_frontier',
                         'logical_support_id']
                     ORDER BY support_id)
                 FROM pgreact_internal.derived_supports s),
    'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY fact_id)
              FROM pgreact_internal.derived_facts f),
    'frontiers', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_version_id)
                  FROM pgreact_internal.derived_frontiers f)
) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.5.0';

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.5.0'
       OR NOT pgreact.worker_protocol_compatible(1)
       OR NOT pgreact.worker_protocol_compatible(2)
       OR pgreact.worker_protocol_compatible(3) THEN
        RAISE EXCEPTION 'M8 upgrade version or worker compatibility changed';
    END IF;
    SELECT jsonb_build_object(
        'rules', (SELECT jsonb_agg(to_jsonb(r) ORDER BY rule_id) FROM pgreact_internal.rules r),
        'versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY rule_version_id)
                     FROM pgreact_internal.rule_versions v),
        'episodes', (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM pgreact.episodes e),
        'batches', (SELECT jsonb_agg(to_jsonb(b) ORDER BY batch_id)
                    FROM pgreact_internal.execution_batches b),
        'relations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY relation_id)
                      FROM pgreact_internal.derived_relations r),
        'relation_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY relation_version_id)
                              FROM pgreact_internal.derived_relation_versions v),
        'derivations', (SELECT jsonb_agg(to_jsonb(d) ORDER BY rule_version_id)
                        FROM pgreact_internal.derivation_rule_versions d),
        'supports', (SELECT jsonb_agg(
                         to_jsonb(s) - ARRAY[
                             'program_version_id', 'grounded', 'support_frontier',
                             'logical_support_id']
                         ORDER BY support_id)
                     FROM pgreact_internal.derived_supports s),
        'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY fact_id)
                  FROM pgreact_internal.derived_facts f),
        'frontiers', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_version_id)
                      FROM pgreact_internal.derived_frontiers f)
    ) INTO actual;
    SELECT state INTO STRICT expected FROM m8_pre_upgrade;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M7 state changed across direct M8 upgrade: %', actual;
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact.derivation_programs) THEN
        RAISE EXCEPTION 'M8 program catalog was not empty after upgrade';
    END IF;
END $$;

\set m8_seed_left false
\set m8_seed_right true
\ir /tmp/m8-setup.sql

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', (SELECT jsonb_agg(format('%s(%s)', relation, id) ORDER BY relation)
            FROM (SELECT 'A' relation, id FROM m8_ref.a
                  UNION ALL SELECT 'B', id FROM m8_ref.b
                  UNION ALL SELECT 'C', id FROM m8_ref.c
                  UNION ALL SELECT 'D', id FROM m8_ref.d) q),
        'supports', (SELECT jsonb_agg(format('%s(%s)=%s',
            upper(regexp_replace(relation_name, '^.*\.', '')), semantic_key, support_count)
            ORDER BY relation_name)
            FROM pgreact.derived_facts
            WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
        'program', (SELECT program_name || '@' || program_version
                    FROM pgreact.derivation_programs WHERE state = 'ACTIVE'),
        'frontier', (SELECT frontier FROM pgreact.derivation_programs WHERE state = 'ACTIVE')
    ) INTO actual;
    expected := jsonb_build_object(
        'facts', jsonb_build_array('A(7)', 'B(7)', 'C(7)', 'D(7)'),
        'supports', jsonb_build_array('A(7)=1', 'B(7)=1', 'C(7)=3', 'D(7)=1'),
        'program', 'm8.reference@1', 'frontier', 1);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 post-upgrade recursive workflow changed: %', actual;
    END IF;
END $$;

SELECT 'M8 direct 0.4.0 to 0.5.0 upgrade preserved exact inherited state' AS result;
