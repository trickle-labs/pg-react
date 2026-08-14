\set ON_ERROR_STOP on
\ir /tmp/m8-setup.sql

CREATE VIEW m8_ref.negative_not_exists AS
SELECT a.id FROM m8_ref.a a
WHERE NOT EXISTS (SELECT 1 FROM m8_ref.b b WHERE b.id = a.id);
CREATE VIEW m8_ref.negative_aggregate AS SELECT min(id) AS id FROM m8_ref.a;
CREATE VIEW m8_ref.negative_outer_join AS
SELECT a.id FROM m8_ref.a a LEFT JOIN m8_ref.b b USING (id);
CREATE VIEW m8_ref.negative_anti_join AS
SELECT a.id FROM m8_ref.a a
WHERE NOT EXISTS (SELECT 1 FROM m8_ref.b b WHERE b.id = a.id);
CREATE VIEW m8_ref.negative_recursive_cte AS
WITH RECURSIVE walk(id) AS (
    SELECT id FROM m8_ref.left_seed
    UNION ALL SELECT id FROM walk WHERE false
) SELECT id FROM walk;
CREATE VIEW m8_ref.negative_window_inner AS
SELECT id, row_number() OVER (ORDER BY id) AS rn FROM m8_ref.left_seed;
CREATE VIEW m8_ref.negative_anonymous_window AS
SELECT id FROM m8_ref.negative_window_inner WHERE rn = 1;
CREATE VIEW m8_ref.negative_all_subquery AS
SELECT l.id FROM m8_ref.left_seed l
WHERE l.id <> ALL (SELECT r.id FROM m8_ref.right_seed r);
CREATE VIEW m8_ref.negative_current_date AS
SELECT id FROM m8_ref.left_seed WHERE CURRENT_DATE IS NOT NULL;
CREATE VIEW m8_ref.negative_tablesample AS
SELECT id FROM m8_ref.left_seed TABLESAMPLE SYSTEM (100);
CREATE VIEW m8_ref.negative_scalar_sublink AS
SELECT l.id FROM m8_ref.left_seed l
WHERE l.id = (SELECT r.id FROM m8_ref.right_seed r WHERE r.id = l.id);
CREATE VIEW m8_ref.negative_having AS
SELECT l.id FROM m8_ref.left_seed l GROUP BY l.id HAVING l.id > 0;
CREATE VIEW m8_ref.positive_exists AS
SELECT l.id FROM m8_ref.left_seed l
WHERE EXISTS (SELECT 1 FROM m8_ref.right_seed r WHERE r.id = l.id);
CREATE VIEW m8_ref.positive_any AS
SELECT l.id FROM m8_ref.left_seed l
WHERE l.id = ANY (SELECT r.id FROM m8_ref.right_seed r);
CREATE TABLE m8_ref.rls_base (id bigint PRIMARY KEY);
ALTER TABLE m8_ref.rls_base ENABLE ROW LEVEL SECURITY;
ALTER TABLE m8_ref.rls_base FORCE ROW LEVEL SECURITY;
CREATE VIEW m8_ref.rls_inner AS SELECT id FROM m8_ref.rls_base;
CREATE VIEW m8_ref.negative_nested_rls AS SELECT id FROM m8_ref.rls_inner;
CREATE VIEW m8_ref.negative_set_generator AS
SELECT seed.id FROM m8_ref.left_seed seed CROSS JOIN LATERAL generate_series(1, 2);
CREATE VIEW m8_ref.negative_values_source AS
SELECT seed.id FROM m8_ref.left_seed seed CROSS JOIN (VALUES (1)) extra(n);
CREATE VIEW m8_ref.negative_xmltable_source AS
SELECT seed.id
FROM m8_ref.left_seed seed
CROSS JOIN LATERAL XMLTABLE(
    '/rows/row'
    PASSING BY VALUE XMLPARSE(DOCUMENT '<rows><row/></rows>')
    COLUMNS n integer PATH '.') extra;
CREATE VIEW m8_ref.negative_invented_key AS SELECT id + 1 AS id FROM m8_ref.a;
CREATE VIEW m8_ref.negative_derived_abs_key AS SELECT abs(id) AS id FROM m8_ref.a;
CREATE VIEW m8_ref.negative_derived_case_key AS
SELECT CASE WHEN id > 0 THEN id ELSE -id END AS id FROM m8_ref.a;
CREATE VIEW m8_ref.negative_derived_cast_key AS
SELECT id::numeric::bigint AS id FROM m8_ref.a;
CREATE VIEW m8_ref.negative_abs_key AS SELECT abs(id) AS id FROM m8_ref.left_seed;
CREATE VIEW m8_ref.negative_nested_abs_key AS SELECT id FROM m8_ref.negative_abs_key;
CREATE VIEW m8_ref.negative_case_key AS
SELECT CASE WHEN id IS NULL THEN id ELSE id END AS id FROM m8_ref.left_seed;
CREATE VIEW m8_ref.negative_cast_key AS
SELECT id::numeric::bigint AS id FROM m8_ref.left_seed;
CREATE VIEW m8_ref.nested_a AS SELECT id FROM m8_ref.a;
CREATE VIEW m8_ref.negative_undeclared_nested AS SELECT id FROM m8_ref.nested_a;
CREATE VIEW m8_ref.negative_union AS
SELECT id FROM m8_ref.a UNION SELECT id FROM m8_ref.b;
CREATE VIEW m8_ref.positive_inner_join AS
SELECT a.id FROM m8_ref.a a INNER JOIN m8_ref.b b USING (id);
CREATE VIEW m8_ref.negative_cross_input_key AS
SELECT a.id FROM m8_ref.a a CROSS JOIN m8_ref.b b;
CREATE VIEW m8_ref.negative_or_input_key AS
SELECT a.id
FROM m8_ref.a a INNER JOIN m8_ref.b b
ON (a.id = b.id OR b.id IS NOT NULL);
CREATE VIEW m8_ref.negative_self_join_key AS
SELECT first_a.id FROM m8_ref.a first_a CROSS JOIN m8_ref.a second_a;
CREATE VIEW m8_ref.negative_derived_exists_key AS
SELECT a.id FROM m8_ref.a a
WHERE EXISTS (SELECT 1 FROM m8_ref.b b WHERE b.id = a.id);
CREATE VIEW m8_ref.negative_derived_any_key AS
SELECT a.id FROM m8_ref.a a
WHERE a.id = ANY (SELECT b.id FROM m8_ref.b b);
CREATE TYPE m8_ref.function_row AS (id bigint, magnitude bigint);
CREATE TABLE m8_ref.function_seed (
    id bigint PRIMARY KEY,
    magnitude bigint NOT NULL
);
CREATE VIEW m8_ref.positive_nonkey_function AS
SELECT id, abs(magnitude) AS magnitude FROM m8_ref.function_seed;
CREATE TABLE m8_ref.filter_seed (
    id bigint PRIMARY KEY,
    magnitude bigint NOT NULL,
    "not" boolean NOT NULL
);
CREATE VIEW m8_ref.positive_not_filter AS
SELECT id, magnitude FROM m8_ref.filter_seed
WHERE "not" AND 'not' = 'not' AND magnitude + 1 > 0;
CREATE MATERIALIZED VIEW m8_ref.positive_materialized_key AS
SELECT id FROM m8_ref.left_seed;
CREATE VIEW m8_ref.positive_materialized_source AS
SELECT id FROM m8_ref.positive_materialized_key;
CREATE MATERIALIZED VIEW m8_ref.negative_materialized_abs AS
SELECT abs(id) AS id FROM m8_ref.left_seed;
CREATE VIEW m8_ref.negative_materialized_abs_source AS
SELECT id FROM m8_ref.negative_materialized_abs;
SELECT pgreact.create_derived_relation(
    'm8_ref.function_result', 'm8_ref.function_row'::regtype, ARRAY['id'], 1);
SELECT pgreact.create_derived_relation(
    'm8_ref.materialized_result', 'm8_ref.fact_row'::regtype, ARRAY['id'], 1);
SELECT pgreact.create_derived_relation(
    'm8_ref.e', 'm8_ref.fact_row'::regtype, ARRAY['id'], 1);
SELECT pgreact.create_derived_relation(
    'm8_ref.f', 'm8_ref.fact_row'::regtype, ARRAY['id'], 1);
UPDATE m8_ref.manifests
SET mappings = mappings || jsonb_build_object(
    'objects', mappings -> 'objects' || jsonb_build_object(
        'm8.e', 'm8_ref.e', 'm8.f', 'm8_ref.f'));

INSERT INTO m8_ref.manifests
SELECT 20,
       jsonb_set(jsonb_set(definition, '{version}', '"20"'),
                 '{programs,0,rules,3}', jsonb_build_object(
                     'name', 'm8.ab_to_c', 'definition', 'm8.ab_to_c',
                     'key', 'id', 'target', 'm8.c', 'version', 1,
                     'inputs', jsonb_build_array(
                         jsonb_build_object('relation', 'm8.a', 'key', 'id'),
                         jsonb_build_object('relation', 'm8.b', 'key', 'id')))),
       mappings || jsonb_build_object(
           'objects', mappings -> 'objects' ||
                      jsonb_build_object('m8.ab_to_c', 'm8_ref.positive_inner_join'))
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
        RAISE EXCEPTION 'M8 positive multi-input replacement changed: %', actual;
    END IF;
END $$;

DO $$
DECLARE fixture record; actual jsonb; expected jsonb;
BEGIN
    FOR fixture IN
        SELECT * FROM (VALUES
            ('positive_nonkey_function', 'm8_ref.positive_nonkey_function'),
            ('positive_not_filter', 'm8_ref.positive_not_filter')
        ) fixtures(program_name, source_name)
    LOOP
        SELECT to_jsonb(d) INTO STRICT actual
        FROM pgreact.validate_derivation_program(jsonb_build_object(
            'name', fixture.program_name, 'version', 1,
            'max_iterations', 16, 'max_facts', 64,
            'rules', jsonb_build_array(jsonb_build_object(
                'name', fixture.program_name || '.rule',
                'definition', fixture.source_name,
                'key', 'id', 'target', 'm8_ref.function_result',
                'version', 1, 'inputs', '[]'::jsonb)))) d;
        expected := jsonb_build_object(
            'contract_version', 3, 'code', 'OK', 'severity', 'INFO',
            'object_identity', fixture.program_name,
            'message', 'derivation program is a closed positive key-preserving graph',
            'hint', 'Preview and deploy the containing pack.',
            'details', jsonb_build_object(
                'version', 1, 'rules', 1,
                'max_iterations', 16, 'max_facts', 64));
        IF actual IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'M8 positive % validation changed: %',
                fixture.program_name, actual;
        END IF;
    END LOOP;
END $$;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT to_jsonb(d) INTO STRICT actual
    FROM pgreact.validate_derivation_program(jsonb_build_object(
        'name', 'positive_materialized_key', 'version', 1,
        'max_iterations', 16, 'max_facts', 64,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'positive_materialized_key.rule',
            'definition', 'm8_ref.positive_materialized_source',
            'key', 'id', 'target', 'm8_ref.materialized_result',
            'version', 1, 'inputs', '[]'::jsonb)))) d;
    expected := jsonb_build_object(
        'contract_version', 3, 'code', 'OK', 'severity', 'INFO',
        'object_identity', 'positive_materialized_key',
        'message', 'derivation program is a closed positive key-preserving graph',
        'hint', 'Preview and deploy the containing pack.',
        'details', jsonb_build_object(
            'version', 1, 'rules', 1, 'max_iterations', 16, 'max_facts', 64));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 materialized direct-key validation changed: %', actual;
    END IF;
END $$;

DO $$
DECLARE fixture record; actual jsonb; expected jsonb;
BEGIN
    FOR fixture IN
        SELECT * FROM (VALUES
            ('positive_exists', 'm8_ref.positive_exists'),
            ('positive_any', 'm8_ref.positive_any')
        ) fixtures(program_name, source_name)
    LOOP
        SELECT to_jsonb(d) INTO STRICT actual
        FROM pgreact.validate_derivation_program(jsonb_build_object(
            'name', fixture.program_name, 'version', 1,
            'max_iterations', 16, 'max_facts', 64,
            'rules', jsonb_build_array(jsonb_build_object(
                'name', fixture.program_name || '.rule',
                'definition', fixture.source_name,
                'key', 'id', 'target', 'm8_ref.materialized_result',
                'version', 1, 'inputs', '[]'::jsonb)))) d;
        expected := jsonb_build_object(
            'contract_version', 3, 'code', 'OK', 'severity', 'INFO',
            'object_identity', fixture.program_name,
            'message', 'derivation program is a closed positive key-preserving graph',
            'hint', 'Preview and deploy the containing pack.',
            'details', jsonb_build_object(
                'version', 1, 'rules', 1,
                'max_iterations', 16, 'max_facts', 64));
        IF actual IS DISTINCT FROM expected THEN
            RAISE EXCEPTION 'M8 positive % validation changed: %',
                fixture.program_name, actual;
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION m8_ref.candidate(
    candidate_name text, source_name text, declared_inputs jsonb
) RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $$
SELECT jsonb_build_object(
    'name', candidate_name, 'version', 1, 'max_iterations', 16, 'max_facts', 64,
    'rules', jsonb_build_array(jsonb_build_object(
        'name', candidate_name || '.rule', 'definition', source_name,
        'key', 'id', 'target', 'm8_ref.c', 'version', 1, 'inputs', declared_inputs)))
$$;

CREATE TEMP TABLE validator_before AS
SELECT jsonb_build_object(
    'packs', (SELECT jsonb_agg(to_jsonb(p) ORDER BY pack_id)
              FROM pgreact_internal.rule_packs p),
    'pack_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY pack_version_id)
                      FROM pgreact_internal.rule_pack_versions v),
    'pack_members', (SELECT jsonb_agg(to_jsonb(m) ORDER BY pack_version_id, rule_name)
                     FROM pgreact_internal.rule_pack_members m),
    'pack_actions', (SELECT jsonb_agg(to_jsonb(a) ORDER BY pack_version_id, action_order)
                     FROM pgreact_internal.rule_pack_actions a),
    'pack_relations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY pack_version_id, relation_name)
                       FROM pgreact_internal.rule_pack_derived_relations r),
    'pack_derivations', (SELECT jsonb_agg(to_jsonb(d) ORDER BY pack_version_id, rule_name)
                         FROM pgreact_internal.rule_pack_derivations d),
    'pack_derived_actions', (SELECT jsonb_agg(to_jsonb(a) ORDER BY pack_version_id, action_order)
                             FROM pgreact_internal.rule_pack_derived_actions a),
    'pack_programs', (SELECT jsonb_agg(to_jsonb(p) ORDER BY pack_version_id, program_name)
                      FROM pgreact_internal.rule_pack_programs p),
    'programs', (SELECT jsonb_agg(to_jsonb(p) ORDER BY program_id)
                 FROM pgreact_internal.derivation_programs p),
    'versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY program_version_id)
                 FROM pgreact_internal.derivation_program_versions v),
    'components', (SELECT jsonb_agg(to_jsonb(c) ORDER BY program_version_id, component_order)
                   FROM pgreact_internal.derivation_program_components c),
    'rules', (SELECT jsonb_agg(to_jsonb(r) ORDER BY program_version_id, rule_order)
              FROM pgreact_internal.derivation_program_rules r),
    'inputs', (SELECT jsonb_agg(to_jsonb(i)
               ORDER BY program_version_id, rule_version_id, input_order)
               FROM pgreact_internal.derivation_program_inputs i),
    'rule_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY rule_version_id)
                      FROM pgreact_internal.rule_versions v),
    'barriers', (SELECT jsonb_agg(to_jsonb(b) ORDER BY rule_version_id)
                 FROM pgreact_internal.rule_barriers b),
    'activations', (SELECT jsonb_agg(to_jsonb(a) ORDER BY rule_version_id, activation_id)
                    FROM pgreact_internal.activation_state a),
    'events', (SELECT jsonb_agg(to_jsonb(e) ORDER BY event_id)
               FROM pgreact_internal.lifecycle_events e),
    'agenda', (SELECT jsonb_agg(to_jsonb(a) ORDER BY episode_id)
               FROM pgreact_internal.agenda a),
    'reconciliations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY reconciliation_id)
                        FROM pgreact_internal.reconciliation_audit r),
    'bindings', (SELECT jsonb_agg(to_jsonb(b) ORDER BY rule_version_id, event_kind)
                 FROM pgreact_internal.consequence_bindings b),
    'batch_declarations', (SELECT jsonb_agg(to_jsonb(b) ORDER BY rule_version_id, event_kind)
                           FROM pgreact_internal.batch_declarations b),
    'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_version_id, fact_id)
              FROM pgreact_internal.derived_facts f),
    'supports', (SELECT jsonb_agg(to_jsonb(s) ORDER BY support_id)
                 FROM pgreact_internal.derived_supports s)
) AS state;

CREATE TEMP TABLE program_overlap_candidates (
    fixture text PRIMARY KEY,
    definition jsonb NOT NULL,
    diagnostic jsonb NOT NULL
);
WITH base AS (
    SELECT definition, mappings
    FROM m8_ref.manifests WHERE version = 1
), programs AS (
    SELECT 'active_rule' AS fixture, 40 AS pack_version,
           jsonb_build_array(jsonb_build_object(
               'name', 'm8.other', 'version', 1,
               'max_iterations', 16, 'max_facts', 64,
               'rules', jsonb_build_array(jsonb_build_object(
                   'name', 'm8.a_to_b', 'definition', 'm8.left_to_a',
                   'key', 'id', 'target', 'm8.a', 'version', 1,
                   'inputs', '[]'::jsonb)))) AS programs,
           jsonb_build_object(
               'contract_version', 3, 'code', 'PROGRAM_RULE_OVERLAP',
               'severity', 'ERROR', 'object_identity', 'm8.a_to_b',
               'message', 'rule name is owned by another active derivation program',
               'hint', 'Replace that owning program or choose a different rule name.',
               'details', jsonb_build_object(
                   'program', 'm8.other', 'owner_program', 'm8.reference')) AS diagnostic
    UNION ALL
    SELECT 'active_target', 41,
           jsonb_build_array(jsonb_build_object(
               'name', 'm8.other', 'version', 1,
               'max_iterations', 16, 'max_facts', 64,
               'rules', jsonb_build_array(jsonb_build_object(
                   'name', 'm8.other_left_to_a', 'definition', 'm8.left_to_a',
                   'key', 'id', 'target', 'm8.a', 'version', 1,
                   'inputs', '[]'::jsonb)))),
           jsonb_build_object(
               'contract_version', 3, 'code', 'PROGRAM_TARGET_OVERLAP',
               'severity', 'ERROR', 'object_identity', 'm8_ref.a',
               'message', 'target relation is owned by another active derivation program',
               'hint', 'Replace that owning program or choose a different target relation.',
               'details', jsonb_build_object(
                   'program', 'm8.other', 'owner_program', 'm8.reference'))
    UNION ALL
    SELECT 'sibling_rule', 42,
           jsonb_build_array(
               m8_ref.program(1, false),
               jsonb_build_object(
                   'name', 'm8.alpha', 'version', 1,
                   'max_iterations', 16, 'max_facts', 64,
                   'rules', jsonb_build_array(jsonb_build_object(
                       'name', 'm8.shared', 'definition', 'm8.left_to_a',
                       'key', 'id', 'target', 'm8.e', 'version', 1,
                       'inputs', '[]'::jsonb))),
               jsonb_build_object(
                   'name', 'm8.beta', 'version', 1,
                   'max_iterations', 16, 'max_facts', 64,
                   'rules', jsonb_build_array(jsonb_build_object(
                       'name', 'm8.shared', 'definition', 'm8.left_to_a',
                       'key', 'id', 'target', 'm8.f', 'version', 1,
                       'inputs', '[]'::jsonb)))),
           jsonb_build_object(
               'contract_version', 3, 'code', 'PROGRAM_RULE_OVERLAP',
               'severity', 'ERROR', 'object_identity', 'm8.shared',
               'message', 'rule name is shared by multiple derivation programs in the same pack',
               'hint', 'Give every derivation-program rule one owning program.',
               'details', jsonb_build_object(
                   'programs', jsonb_build_array('m8.alpha', 'm8.beta')))
    UNION ALL
    SELECT 'sibling_target', 43,
           jsonb_build_array(
               m8_ref.program(1, false),
               jsonb_build_object(
                   'name', 'm8.alpha', 'version', 1,
                   'max_iterations', 16, 'max_facts', 64,
                   'rules', jsonb_build_array(jsonb_build_object(
                       'name', 'm8.alpha_left_to_a', 'definition', 'm8.left_to_a',
                       'key', 'id', 'target', 'm8.e', 'version', 1,
                       'inputs', '[]'::jsonb))),
               jsonb_build_object(
                   'name', 'm8.beta', 'version', 1,
                   'max_iterations', 16, 'max_facts', 64,
                   'rules', jsonb_build_array(jsonb_build_object(
                       'name', 'm8.beta_left_to_a', 'definition', 'm8.left_to_a',
                       'key', 'id', 'target', 'm8.e', 'version', 1,
                       'inputs', '[]'::jsonb)))),
           jsonb_build_object(
               'contract_version', 3, 'code', 'PROGRAM_TARGET_OVERLAP',
               'severity', 'ERROR', 'object_identity', 'm8_ref.e',
               'message', 'target relation is shared by multiple derivation programs in the same pack',
               'hint', 'Give every target relation one owning derivation program.',
               'details', jsonb_build_object(
                   'programs', jsonb_build_array('m8.alpha', 'm8.beta')))
)
INSERT INTO program_overlap_candidates
SELECT fixture,
       jsonb_set(
           jsonb_set(jsonb_set(base.definition, '{version}', to_jsonb(pack_version::text)),
                     '{programs}', programs),
           '{remove_programs}',
           CASE WHEN fixture LIKE 'active_%'
                THEN jsonb_build_array(jsonb_build_object('name', 'm8.reference'))
                ELSE '[]'::jsonb END),
       diagnostic
FROM programs CROSS JOIN base;

DO $$
DECLARE candidate record; actual jsonb; exception_hint text;
BEGIN
    FOR candidate IN SELECT * FROM program_overlap_candidates ORDER BY fixture LOOP
        IF candidate.fixture LIKE 'active_%' THEN
            SELECT to_jsonb(d) INTO STRICT actual
            FROM pgreact.validate_derivation_program(
                pgreact_internal.m8_program_definition(
                    candidate.definition #> '{programs,0}',
                    (SELECT mappings FROM m8_ref.manifests WHERE version = 1))) d;
        ELSE
            SELECT to_jsonb(d) INTO STRICT actual
            FROM pgreact.validate_pack(
                candidate.definition,
                (SELECT mappings FROM m8_ref.manifests WHERE version = 1)) d;
        END IF;
        IF actual IS DISTINCT FROM candidate.diagnostic THEN
            RAISE EXCEPTION 'program overlap guard % changed: %', candidate.fixture, actual;
        END IF;
        CONTINUE WHEN candidate.fixture LIKE 'active_%';
        BEGIN
            PERFORM pgreact.deploy_pack(
                candidate.definition, 'blocked',
                (SELECT mappings FROM m8_ref.manifests WHERE version = 1));
            RAISE EXCEPTION 'program overlap guard % unexpectedly deployed', candidate.fixture;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
            IF SQLERRM <> format(
                   'pg-react pack validation %s for %s: %s',
                   candidate.diagnostic ->> 'code',
                   candidate.diagnostic ->> 'object_identity',
                   candidate.diagnostic ->> 'message')
               OR exception_hint IS DISTINCT FROM candidate.diagnostic ->> 'hint' THEN
                RAISE;
            END IF;
        END;
    END LOOP;
END $$;

CREATE TEMP TABLE cross_pack_candidates (
    fixture text PRIMARY KEY,
    definition jsonb NOT NULL,
    diagnostic jsonb NOT NULL
);
WITH base(definition) AS (
    VALUES (jsonb_build_object(
        'format_version', 1, 'pack', 'm8-foreign-pack', 'version', '1',
        'owner', 'owner', 'rules', '[]'::jsonb, 'remove', '[]'::jsonb,
        'derived_relations', '[]'::jsonb, 'derivations', '[]'::jsonb,
        'remove_derivations', '[]'::jsonb,
        'remove_derived_relations', '[]'::jsonb,
        'programs', '[]'::jsonb, 'remove_programs', '[]'::jsonb))
)
INSERT INTO cross_pack_candidates
SELECT 'replace',
       jsonb_set(definition, '{programs}',
                 jsonb_build_array(m8_ref.program(2, true))),
       jsonb_build_object(
           'contract_version', 3, 'code', 'PROGRAM_PACK_OWNERSHIP',
           'severity', 'ERROR', 'object_identity', 'm8.reference',
           'message', 'active derivation program cannot be replaced by another logical pack',
           'hint', 'Deploy the next version through its owning logical pack.',
           'details', jsonb_build_object(
               'action', 'REPLACE', 'incoming_pack', 'm8-foreign-pack',
               'owner_pack', 'm8-reference-pack'))
FROM base
UNION ALL
SELECT 'remove',
       jsonb_set(definition, '{remove_programs}',
                 jsonb_build_array(jsonb_build_object('name', 'm8.reference'))),
       jsonb_build_object(
           'contract_version', 3, 'code', 'PROGRAM_PACK_OWNERSHIP',
           'severity', 'ERROR', 'object_identity', 'm8.reference',
           'message', 'active derivation program cannot be removed by another logical pack',
           'hint', 'Remove the program through its owning logical pack.',
           'details', jsonb_build_object(
               'action', 'REMOVE', 'incoming_pack', 'm8-foreign-pack',
               'owner_pack', 'm8-reference-pack'))
FROM base;

DO $$
DECLARE candidate record; actual jsonb; exception_hint text;
BEGIN
    FOR candidate IN SELECT * FROM cross_pack_candidates ORDER BY fixture LOOP
        SELECT to_jsonb(d) INTO STRICT actual
        FROM pgreact.validate_pack(
            candidate.definition,
            (SELECT mappings FROM m8_ref.manifests WHERE version = 1)) d;
        IF actual IS DISTINCT FROM candidate.diagnostic THEN
            RAISE EXCEPTION 'cross-pack guard % changed: %', candidate.fixture, actual;
        END IF;
        BEGIN
            PERFORM pgreact.deploy_pack(
                candidate.definition, 'blocked',
                (SELECT mappings FROM m8_ref.manifests WHERE version = 1));
            RAISE EXCEPTION 'cross-pack guard % unexpectedly deployed', candidate.fixture;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
            IF SQLERRM <> format('pg-react pack validation %s for %s: %s',
                                 candidate.diagnostic ->> 'code',
                                 candidate.diagnostic ->> 'object_identity',
                                 candidate.diagnostic ->> 'message')
               OR exception_hint IS DISTINCT FROM candidate.diagnostic ->> 'hint' THEN
                RAISE;
            END IF;
        END;
    END LOOP;
END $$;

CREATE TEMP TABLE legacy_pack_candidates (
    fixture text PRIMARY KEY,
    definition jsonb NOT NULL,
    diagnostic jsonb NOT NULL
);
WITH legacy AS (
    SELECT definition - 'programs' - 'remove_programs' AS definition
    FROM m8_ref.manifests WHERE version = 1
)
INSERT INTO legacy_pack_candidates VALUES
    ('replace_program_target',
     (SELECT jsonb_set(jsonb_set(definition, '{version}', '"30"'),
                       '{derived_relations,0,version}', '2') FROM legacy),
     jsonb_build_object(
         'contract_version', 3, 'code', 'PROGRAM_OBJECT_MANAGED',
         'severity', 'ERROR', 'object_identity', 'm8_ref.a',
         'message', 'active program target relations cannot be replaced through legacy pack fields',
         'hint', 'Replace the complete derivation program.', 'details', '{}'::jsonb)),
    ('remove_program_target',
     (SELECT jsonb_set(jsonb_set(definition, '{version}', '"31"'),
                       '{remove_derived_relations}',
                       jsonb_build_array(jsonb_build_object('name', 'm8.a')))
      FROM legacy),
     jsonb_build_object(
         'contract_version', 3, 'code', 'PROGRAM_OBJECT_MANAGED',
         'severity', 'ERROR', 'object_identity', 'm8_ref.a',
         'message', 'active program target relations cannot be removed through legacy pack fields',
         'hint', 'Remove the complete derivation program first.',
         'details', '{}'::jsonb)),
    ('associate_program_member',
     (SELECT jsonb_set(jsonb_set(definition, '{version}', '"32"'),
                       '{derivations}',
                       jsonb_build_array(jsonb_build_object('name', 'm8.a_to_b')))
      FROM legacy),
     jsonb_build_object(
         'contract_version', 3, 'code', 'PROGRAM_OBJECT_MANAGED',
         'severity', 'ERROR', 'object_identity', 'm8.a_to_b',
         'message', 'active program members cannot be associated, replaced, or removed through legacy pack fields',
         'hint', 'Replace or remove the complete derivation program.',
         'details', jsonb_build_object('field_kind', 'derivation'))),
    ('retire_program_member',
     (SELECT jsonb_set(jsonb_set(definition, '{version}', '"33"'),
                       '{remove_derivations}',
                       jsonb_build_array(jsonb_build_object('name', 'm8.a_to_b')))
      FROM legacy),
     jsonb_build_object(
         'contract_version', 3, 'code', 'PROGRAM_OBJECT_MANAGED',
         'severity', 'ERROR', 'object_identity', 'm8.a_to_b',
         'message', 'active program members cannot be associated, replaced, or removed through legacy pack fields',
         'hint', 'Replace or remove the complete derivation program.',
         'details', jsonb_build_object('field_kind', 'remove_derivation')));

DO $$
DECLARE candidate record; actual jsonb; exception_hint text;
BEGIN
    FOR candidate IN SELECT * FROM legacy_pack_candidates ORDER BY fixture LOOP
        SELECT to_jsonb(d) INTO STRICT actual
        FROM pgreact.validate_pack(
            candidate.definition,
            (SELECT mappings FROM m8_ref.manifests WHERE version = 1)) d;
        IF actual IS DISTINCT FROM candidate.diagnostic THEN
            RAISE EXCEPTION 'legacy pack guard % changed: %', candidate.fixture, actual;
        END IF;
        BEGIN
            PERFORM pgreact.deploy_pack(
                candidate.definition, 'blocked',
                (SELECT mappings FROM m8_ref.manifests WHERE version = 1));
            RAISE EXCEPTION 'legacy pack guard % unexpectedly deployed', candidate.fixture;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
            IF SQLERRM <> format('pg-react pack validation PROGRAM_OBJECT_MANAGED for %s: %s',
                                 candidate.diagnostic ->> 'object_identity',
                                 candidate.diagnostic ->> 'message')
               OR exception_hint IS DISTINCT FROM candidate.diagnostic ->> 'hint' THEN
                RAISE;
            END IF;
        END;
    END LOOP;
END $$;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT to_jsonb(d) INTO STRICT actual
    FROM pgreact.validate_derivation_program(m8_ref.candidate(
        'negative_union', 'm8_ref.negative_union',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))) d;
    expected := jsonb_build_object(
        'contract_version', 3, 'code', 'PROGRAM_NOT_POSITIVE', 'severity', 'ERROR',
        'object_identity', 'negative_union.rule',
        'message', 'program sources permit only positive inner-join, filter, and projection SQL',
        'hint', 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
        'details', jsonb_build_object('source', 'm8_ref.negative_union'));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 standalone UNION diagnostic changed: %', actual;
    END IF;
END $$;

DO $$
DECLARE
    program_version uuid := current_setting('m8.program')::uuid;
    target_relation uuid;
    member_rule uuid;
    exception_hint text;
BEGIN
    SELECT relation_version_id INTO STRICT target_relation
    FROM pgreact.derived_relations
    WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE';
    SELECT rule_version_id INTO STRICT member_rule
    FROM pgreact_internal.derivation_program_rules
    WHERE program_version_id = program_version AND rule_name = 'm8.b_to_c';

    BEGIN
        PERFORM pgreact.create_derivation_rule(
            'm8.illegal_independent', 'm8_ref.b_to_c'::regclass,
            ARRAY['id']::name[], target_relation, 2, 'SEED_CURRENT');
        RAISE EXCEPTION 'independent producer on a program relation unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
        IF SQLERRM <> format(
               'program relation %s cannot accept an independent producer', target_relation)
           OR exception_hint <> 'Replace the complete derivation program through its rule pack.' THEN
            RAISE;
        END IF;
    END;
    BEGIN
        PERFORM pgreact.replace_derivation_rule(
            member_rule, 'm8_ref.b_to_c'::regclass,
            ARRAY['id']::name[], 2, 'SEED_CURRENT');
        RAISE EXCEPTION 'independent program-member replacement unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
        IF SQLERRM <> format('program member %s cannot be replaced independently', member_rule)
           OR exception_hint <>
              'Replace the complete derivation program through its rule pack.' THEN
            RAISE;
        END IF;
    END;
    BEGIN
        PERFORM pgreact.remove_derivation_rule(member_rule);
        RAISE EXCEPTION 'independent program-member removal unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
        IF SQLERRM <> format('program member %s cannot be removed independently', member_rule)
           OR exception_hint <>
              'Replace or remove the complete derivation program through its rule pack.' THEN
            RAISE;
        END IF;
    END;
    BEGIN
        PERFORM pgreact.remove_derivation_program(program_version);
        RAISE EXCEPTION 'direct pack-owned program removal unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
        IF SQLERRM <> format(
               'active pack-owned program %s cannot be removed directly', program_version)
           OR exception_hint <>
              'Deploy the next pack version with the program in remove_programs.' THEN
            RAISE;
        END IF;
    END;
END $$;

DO $$
DECLARE member_rule uuid; operation record; exception_hint text;
BEGIN
    SELECT rule_version_id INTO STRICT member_rule
    FROM pgreact_internal.derivation_program_rules
    WHERE program_version_id = current_setting('m8.program')::uuid
      AND rule_name = 'm8.b_to_c';
    FOR operation IN
        SELECT * FROM (VALUES
            (format('SELECT pgreact.pause_rule(%L::uuid)', member_rule),
             'paused', 'Manage program rules through the complete derivation-program pack.'),
            ('SELECT pgreact.pause_rule(''m8.b_to_c''::text)',
             'paused', 'Manage program rules through the complete derivation-program pack.'),
            (format('SELECT pgreact.resume_rule(%L::uuid)', member_rule),
             'resumed', 'Manage program rules through the complete derivation-program pack.'),
            ('SELECT pgreact.resume_rule(''m8.b_to_c''::text)',
             'resumed', 'Manage program rules through the complete derivation-program pack.'),
            (format('SELECT pgreact.replace_rule(%L::uuid, ''m8_ref.b_to_c''::regclass, ARRAY[''id'']::name[], NULL::regprocedure, ''SEED_CURRENT'', NULL::regprocedure, NULL::regprocedure, ''DRAIN_OLD'')', member_rule),
             'replaced', 'Replace the complete derivation program through its rule pack.'),
            (format('SELECT pgreact.remove_rule(%L::uuid)', member_rule),
             'removed', 'Replace or remove the complete derivation program through its rule pack.'),
            (format('SELECT pgreact.reconcile_rule(%L::uuid, ''STATE_ONLY'')', member_rule),
             'reconciled', 'Use pgreact.reconcile_derivation_program.'),
            (format('SELECT pgreact.begin_refresh(%L::uuid, 99)', member_rule),
             'refresh-barrier managed', 'Use pgreact.refresh_derivation_program.'),
            (format('SELECT pgreact.clear_refresh_barrier(%L::uuid)', member_rule),
             'refresh-barrier managed', 'Use pgreact.refresh_derivation_program.'),
            (format('SELECT pgreact.begin_reconciliation(%L::uuid)', member_rule),
             'reconciliation-barrier managed', 'Use pgreact.reconcile_derivation_program.'),
            (format('SELECT pgreact.bind_outbox_consequence(%L::uuid, ''ACTIVATE'', ''pgreact.refresh_rule(uuid)''::regprocedure, 3, 1, 2, 60)', member_rule),
             'bound to an agenda consequence', 'Manage program rules through the complete derivation-program pack.'),
            (format('SELECT pgreact.declare_batch_safe(%L::uuid, ''ACTIVATE'')', member_rule),
             'declared batch-safe', 'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.'),
            (format('SELECT * FROM pgreact.claim_episode(%L::uuid, ''m8-worker'', 60)', member_rule),
             'agenda-claimed', 'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.'),
            (format('SELECT * FROM pgreact.claim_batch(%L::uuid, ''ACTIVATE'', ''m8-worker'', 2, interval ''60 seconds'')', member_rule),
             'batch-claimed', 'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.'),
            (format('SELECT pgreact.sweep_expired_leases(%L::uuid)', member_rule),
             'lease-swept', 'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.'),
            (format('SELECT pgreact.refresh_rule(%L::uuid)', member_rule),
             'refreshed', 'Use pgreact.refresh_derivation_program.')
        ) operations(statement, action, hint)
    LOOP
        BEGIN
            EXECUTE operation.statement;
            RAISE EXCEPTION 'generic % unexpectedly mutated a program member', operation.action;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
            IF SQLERRM <> format('program member %s cannot be %s independently',
                                 member_rule, operation.action)
               OR exception_hint IS DISTINCT FROM operation.hint THEN
                RAISE;
            END IF;
        END;
    END LOOP;
END $$;

DO $$
DECLARE
    member_rule uuid;
    member_rule_id uuid;
    injected_event bigint;
    injected_episode bigint;
    injected_batch constant uuid := '88888888-0000-0000-0000-000000000008';
    injected_activation constant uuid := '88888888-0000-0000-0000-000000000007';
    injected_lease constant uuid := '88888888-0000-0000-0000-000000000009';
    operation record;
    exception_hint text;
BEGIN
    SELECT v.rule_version_id, v.rule_id
    INTO STRICT member_rule, member_rule_id
    FROM pgreact_internal.derivation_program_rules p
    JOIN pgreact_internal.rule_versions v USING (rule_version_id)
    WHERE p.program_version_id = current_setting('m8.program')::uuid
      AND p.rule_name = 'm8.b_to_c';

    INSERT INTO pgreact_internal.lifecycle_events (
        rule_id, rule_version_id, activation_id, generation, event_kind,
        new_bindings, idempotency_key
    ) VALUES (
        member_rule_id, member_rule, injected_activation, 1, 'ACTIVATE',
        '{"id": 7}'::jsonb, 'm8-boundary-program-event'
    ) RETURNING event_id INTO injected_event;
    INSERT INTO pgreact_internal.agenda (
        event_id, rule_id, rule_version_id, activation_id,
        activation_generation, state, new_bindings, idempotency_key
    ) VALUES (
        injected_event, member_rule_id, member_rule, injected_activation,
        1, 'PENDING', '{"id": 7}'::jsonb, 'm8-boundary-program-episode'
    ) RETURNING episode_id INTO injected_episode;
    INSERT INTO pgreact_internal.execution_batches (
        batch_id, rule_version_id, event_kind, worker_id, max_items,
        function_oid, function_identity, function_digest,
        dispatcher_oid, dispatcher_identity, dispatcher_digest,
        execution_role_oid, execution_role, recheck_policy, state
    ) VALUES (
        injected_batch, member_rule, 'ACTIVATE', 'm8-worker', 2,
        'pgreact.refresh_rule(uuid)'::regprocedure::oid,
        'pgreact.refresh_rule(uuid)', decode('00', 'hex'),
        'pgreact.refresh_rule(uuid)'::regprocedure::oid,
        'pgreact.refresh_rule(uuid)', decode('00', 'hex'),
        (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = current_user),
        current_user, 'FRESH', 'CLAIMED'
    );

    FOR operation IN
        SELECT * FROM (VALUES
            ('SELECT * FROM pgreact.claim(''m8-worker'', 1, interval ''60 seconds'', NULL::text[])',
             'agenda-claimed'),
            (format('SELECT pgreact.heartbeat_episode(%s, ''m8-worker'', %L::uuid, interval ''60 seconds'')',
                    injected_episode, injected_lease),
             'agenda-lease managed'),
            (format('SELECT pgreact.requeue_episode(%s)', injected_episode),
             'agenda-requeued'),
            (format('SELECT pgreact.cancel_episode(%s)', injected_episode),
             'agenda-cancelled'),
            (format('SELECT pgreact.execute_claimed_episode(%s, ''m8-worker'', %L::uuid)',
                    injected_episode, injected_lease),
             'agenda-executed'),
            (format('SELECT * FROM pgreact.execute_claimed_batch(%L::uuid, ''m8-worker'')',
                    injected_batch),
             'batch-executed')
        ) operations(statement, action)
    LOOP
        BEGIN
            EXECUTE operation.statement;
            RAISE EXCEPTION 'generic % unexpectedly mutated a program member', operation.action;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS exception_hint = PG_EXCEPTION_HINT;
            IF SQLERRM <> format('program member %s cannot be %s independently',
                                 member_rule, operation.action)
               OR exception_hint IS DISTINCT FROM
                  'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.' THEN
                RAISE;
            END IF;
        END;
    END LOOP;

    DELETE FROM pgreact_internal.execution_batches WHERE batch_id = injected_batch;
    DELETE FROM pgreact_internal.agenda WHERE episode_id = injected_episode;
    DELETE FROM pgreact_internal.lifecycle_events WHERE event_id = injected_event;
END $$;

CREATE TEMP TABLE validator_results (fixture text PRIMARY KEY, diagnostic jsonb NOT NULL);
INSERT INTO validator_results
SELECT fixture, (SELECT to_jsonb(d) FROM pgreact.validate_derivation_program(program) d)
FROM (VALUES
    ('negative_not_exists', m8_ref.candidate(
        'negative_not_exists', 'm8_ref.negative_not_exists',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))),
    ('negative_aggregate', m8_ref.candidate(
        'negative_aggregate', 'm8_ref.negative_aggregate',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id')))),
    ('negative_outer_join', m8_ref.candidate(
        'negative_outer_join', 'm8_ref.negative_outer_join',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))),
    ('negative_anti_join', m8_ref.candidate(
        'negative_anti_join', 'm8_ref.negative_anti_join',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))),
    ('negative_recursive_cte', m8_ref.candidate(
        'negative_recursive_cte', 'm8_ref.negative_recursive_cte', '[]'::jsonb)),
    ('negative_anonymous_window', m8_ref.candidate(
        'negative_anonymous_window', 'm8_ref.negative_anonymous_window', '[]'::jsonb)),
    ('negative_all_subquery', m8_ref.candidate(
        'negative_all_subquery', 'm8_ref.negative_all_subquery', '[]'::jsonb)),
    ('negative_current_date', m8_ref.candidate(
        'negative_current_date', 'm8_ref.negative_current_date', '[]'::jsonb)),
    ('negative_tablesample', m8_ref.candidate(
        'negative_tablesample', 'm8_ref.negative_tablesample', '[]'::jsonb)),
    ('negative_scalar_sublink', m8_ref.candidate(
        'negative_scalar_sublink', 'm8_ref.negative_scalar_sublink', '[]'::jsonb)),
    ('negative_having', m8_ref.candidate(
        'negative_having', 'm8_ref.negative_having', '[]'::jsonb)),
    ('negative_nested_rls', m8_ref.candidate(
        'negative_nested_rls', 'm8_ref.negative_nested_rls', '[]'::jsonb)),
    ('negative_set_generator', m8_ref.candidate(
        'negative_set_generator', 'm8_ref.negative_set_generator', '[]'::jsonb)),
    ('negative_values_source', m8_ref.candidate(
        'negative_values_source', 'm8_ref.negative_values_source', '[]'::jsonb)),
    ('negative_xmltable_source', m8_ref.candidate(
        'negative_xmltable_source', 'm8_ref.negative_xmltable_source', '[]'::jsonb)),
    ('negative_invented_key', m8_ref.candidate(
        'negative_invented_key', 'm8_ref.negative_invented_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id')))),
    ('negative_derived_abs_key', m8_ref.candidate(
        'negative_derived_abs_key', 'm8_ref.negative_derived_abs_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id')))),
    ('negative_derived_case_key', m8_ref.candidate(
        'negative_derived_case_key', 'm8_ref.negative_derived_case_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id')))),
    ('negative_derived_cast_key', m8_ref.candidate(
        'negative_derived_cast_key', 'm8_ref.negative_derived_cast_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id')))),
    ('negative_cross_input_key', m8_ref.candidate(
        'negative_cross_input_key', 'm8_ref.negative_cross_input_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))),
    ('negative_or_input_key', m8_ref.candidate(
        'negative_or_input_key', 'm8_ref.negative_or_input_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))),
    ('negative_self_join_key', m8_ref.candidate(
        'negative_self_join_key', 'm8_ref.negative_self_join_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id')))),
    ('negative_derived_exists_key', m8_ref.candidate(
        'negative_derived_exists_key', 'm8_ref.negative_derived_exists_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))),
    ('negative_derived_any_key', m8_ref.candidate(
        'negative_derived_any_key', 'm8_ref.negative_derived_any_key',
        jsonb_build_array(jsonb_build_object('relation', 'm8_ref.a', 'key', 'id'),
                          jsonb_build_object('relation', 'm8_ref.b', 'key', 'id')))),
    ('negative_abs_key', m8_ref.candidate(
        'negative_abs_key', 'm8_ref.negative_abs_key', '[]'::jsonb)),
    ('negative_nested_abs_key', m8_ref.candidate(
        'negative_nested_abs_key', 'm8_ref.negative_nested_abs_key', '[]'::jsonb)),
    ('negative_case_key', m8_ref.candidate(
        'negative_case_key', 'm8_ref.negative_case_key', '[]'::jsonb)),
    ('negative_cast_key', m8_ref.candidate(
        'negative_cast_key', 'm8_ref.negative_cast_key', '[]'::jsonb)),
    ('negative_materialized_abs', m8_ref.candidate(
        'negative_materialized_abs',
        'm8_ref.negative_materialized_abs_source', '[]'::jsonb)),
    ('negative_unresolved_nested', m8_ref.candidate(
        'negative_unresolved_nested', 'm8_ref.missing_nested', '[]'::jsonb)),
    ('negative_undeclared_nested', m8_ref.candidate(
        'negative_undeclared_nested', 'm8_ref.negative_undeclared_nested', '[]'::jsonb))
) fixtures(fixture, program);

DO $$
DECLARE actual jsonb; expected jsonb; after_state jsonb;
        m9 boolean := (SELECT extversion IN ('0.6.0', '0.7.0', '0.8.0', '0.9.0', '0.10.0', '0.11.0', '0.12.0', '0.13.0', '0.14.0', '0.15.0') FROM pg_extension
                       WHERE extname = 'pg_react');
BEGIN
    SELECT jsonb_object_agg(fixture, diagnostic ORDER BY fixture) INTO actual
    FROM validator_results;
    expected := jsonb_build_object(
        'negative_not_exists', jsonb_build_object(
            'contract_version', 3,
            'code', CASE WHEN m9 THEN 'PROGRAM_ABSENCE_UNSUPPORTED'
                         ELSE 'PROGRAM_NOT_POSITIVE' END,
            'severity', 'ERROR',
            'object_identity', 'negative_not_exists.rule',
            'message', CASE WHEN m9 THEN 'absence must be declared with negative_inputs'
                            ELSE 'program sources permit only positive inner-join, filter, and projection SQL' END,
            'hint', CASE WHEN m9 THEN 'Remove NOT EXISTS, outer joins, and EXCEPT from the source SQL.'
                         ELSE 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.' END,
            'details', jsonb_build_object('source', 'm8_ref.negative_not_exists')),
        'negative_aggregate', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_AGGREGATE_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'negative_aggregate.rule',
            'message', 'aggregate derivation is outside the monotone M8 subset',
            'hint', 'Use non-aggregate positive rows.', 'details', '{}'::jsonb),
        'negative_outer_join', jsonb_build_object(
            'contract_version', 3,
            'code', CASE WHEN m9 THEN 'PROGRAM_ABSENCE_UNSUPPORTED'
                         ELSE 'PROGRAM_NOT_POSITIVE' END,
            'severity', 'ERROR',
            'object_identity', 'negative_outer_join.rule',
            'message', CASE WHEN m9 THEN 'absence must be declared with negative_inputs'
                            ELSE 'program sources permit only positive inner-join, filter, and projection SQL' END,
            'hint', CASE WHEN m9 THEN 'Remove NOT EXISTS, outer joins, and EXCEPT from the source SQL.'
                         ELSE 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.' END,
            'details', jsonb_build_object('source', 'm8_ref.negative_outer_join')),
        'negative_anti_join', jsonb_build_object(
            'contract_version', 3,
            'code', CASE WHEN m9 THEN 'PROGRAM_ABSENCE_UNSUPPORTED'
                         ELSE 'PROGRAM_NOT_POSITIVE' END,
            'severity', 'ERROR',
            'object_identity', 'negative_anti_join.rule',
            'message', CASE WHEN m9 THEN 'absence must be declared with negative_inputs'
                            ELSE 'program sources permit only positive inner-join, filter, and projection SQL' END,
            'hint', CASE WHEN m9 THEN 'Remove NOT EXISTS, outer joins, and EXCEPT from the source SQL.'
                         ELSE 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.' END,
            'details', jsonb_build_object('source', 'm8_ref.negative_anti_join')),
        'negative_recursive_cte', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_NOT_POSITIVE', 'severity', 'ERROR',
            'object_identity', 'negative_recursive_cte.rule',
            'message', 'program sources permit only positive inner-join, filter, and projection SQL',
            'hint', 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
            'details', jsonb_build_object('source', 'm8_ref.negative_recursive_cte')),
        'negative_anonymous_window', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_NOT_POSITIVE', 'severity', 'ERROR',
            'object_identity', 'negative_anonymous_window.rule',
            'message', 'program sources permit only positive inner-join, filter, and projection SQL',
            'hint', 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
            'details', jsonb_build_object('source', 'm8_ref.negative_anonymous_window')),
        'negative_all_subquery', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_NOT_POSITIVE', 'severity', 'ERROR',
            'object_identity', 'negative_all_subquery.rule',
            'message', 'program sources permit only positive inner-join, filter, and projection SQL',
            'hint', 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
            'details', jsonb_build_object('source', 'm8_ref.negative_all_subquery')),
        'negative_current_date', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_FUNCTION_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'negative_current_date.rule',
            'message', 'program sources may use only immutable pg_catalog functions',
            'hint', 'Remove stable, volatile, or user-defined executable dependencies.',
            'details', '{}'::jsonb),
        'negative_tablesample', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_NOT_POSITIVE', 'severity', 'ERROR',
            'object_identity', 'negative_tablesample.rule',
            'message', 'program sources permit only positive inner-join, filter, and projection SQL',
            'hint', 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
            'details', jsonb_build_object('source', 'm8_ref.negative_tablesample')),
        'negative_scalar_sublink', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_NOT_POSITIVE', 'severity', 'ERROR',
            'object_identity', 'negative_scalar_sublink.rule',
            'message', 'program sources permit only positive inner-join, filter, and projection SQL',
            'hint', 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
            'details', jsonb_build_object('source', 'm8_ref.negative_scalar_sublink')),
        'negative_having', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_NOT_POSITIVE', 'severity', 'ERROR',
            'object_identity', 'negative_having.rule',
            'message', 'program sources permit only positive inner-join, filter, and projection SQL',
            'hint', 'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
            'details', jsonb_build_object('source', 'm8_ref.negative_having')),
        'negative_nested_rls', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_SOURCE_INVALID', 'severity', 'ERROR',
            'object_identity', 'negative_nested_rls.rule',
            'message', 'program source violates the inherited rule-source contract',
            'hint', 'RLS-protected sources are unsupported in M1',
            'details', jsonb_build_object(
                'source_code', 'RLS_UNSUPPORTED',
                'source', 'm8_ref.negative_nested_rls')),
        'negative_set_generator', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_UNBOUNDED_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'negative_set_generator.rule',
            'message', 'set-returning or additive value invention is outside the range-restricted M8 subset',
            'hint', 'Project keys from finite input rows without + or set-returning functions.',
            'details', '{}'::jsonb),
        'negative_values_source', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_UNBOUNDED_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'negative_values_source.rule',
            'message', 'set-returning or additive value invention is outside the range-restricted M8 subset',
            'hint', 'Project keys from finite input rows without + or set-returning functions.',
            'details', '{}'::jsonb),
        'negative_xmltable_source', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_UNBOUNDED_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'negative_xmltable_source.rule',
            'message', 'set-returning or additive value invention is outside the range-restricted M8 subset',
            'hint', 'Project keys from finite input rows without + or set-returning functions.',
            'details', '{}'::jsonb),
        'negative_invented_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_UNBOUNDED_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'negative_invented_key.rule',
            'message', 'set-returning or additive value invention is outside the range-restricted M8 subset',
            'hint', 'Project keys from finite input rows without + or set-returning functions.',
            'details', '{}'::jsonb),
        'negative_derived_abs_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_derived_abs_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_derived_case_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_derived_case_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_derived_cast_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_derived_cast_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_cross_input_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_cross_input_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_or_input_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_or_input_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_self_join_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_self_join_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_derived_exists_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_derived_exists_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_derived_any_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_derived_any_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_abs_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_abs_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_nested_abs_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_nested_abs_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_case_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_case_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_cast_key', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_cast_key.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_materialized_abs', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_KEY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_materialized_abs.rule',
            'message', 'program output key must match its target relation key',
            'hint', 'Project the target key unchanged.',
            'details', jsonb_build_object(
                'expected', 'direct source column',
                'received', 'computed key projection')),
        'negative_unresolved_nested', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_OBJECT_UNRESOLVED', 'severity', 'ERROR',
            'object_identity', 'm8_ref.missing_nested',
            'message', 'program source view does not resolve',
            'hint', 'Create the owned source view before validation.', 'details', '{}'::jsonb),
        'negative_undeclared_nested', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_DEPENDENCY_MISMATCH', 'severity', 'ERROR',
            'object_identity', 'negative_undeclared_nested.rule',
            'message', 'declared derived inputs do not exactly match nested view dependencies',
            'hint', 'Declare every discovered derived relation once and no others.',
            'details', jsonb_build_object('declared', jsonb_build_array(),
                                          'discovered', jsonb_build_array('m8_ref.a')))
    );
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 validator diagnostics changed: %', actual;
    END IF;

    SELECT jsonb_build_object(
        'packs', (SELECT jsonb_agg(to_jsonb(p) ORDER BY pack_id)
                  FROM pgreact_internal.rule_packs p),
        'pack_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY pack_version_id)
                          FROM pgreact_internal.rule_pack_versions v),
        'pack_members', (SELECT jsonb_agg(to_jsonb(m) ORDER BY pack_version_id, rule_name)
                         FROM pgreact_internal.rule_pack_members m),
        'pack_actions', (SELECT jsonb_agg(to_jsonb(a) ORDER BY pack_version_id, action_order)
                         FROM pgreact_internal.rule_pack_actions a),
        'pack_relations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY pack_version_id, relation_name)
                           FROM pgreact_internal.rule_pack_derived_relations r),
        'pack_derivations', (SELECT jsonb_agg(to_jsonb(d) ORDER BY pack_version_id, rule_name)
                             FROM pgreact_internal.rule_pack_derivations d),
        'pack_derived_actions', (SELECT jsonb_agg(to_jsonb(a) ORDER BY pack_version_id, action_order)
                                 FROM pgreact_internal.rule_pack_derived_actions a),
        'pack_programs', (SELECT jsonb_agg(to_jsonb(p) ORDER BY pack_version_id, program_name)
                          FROM pgreact_internal.rule_pack_programs p),
        'programs', (SELECT jsonb_agg(to_jsonb(p) ORDER BY program_id)
                     FROM pgreact_internal.derivation_programs p),
        'versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY program_version_id)
                     FROM pgreact_internal.derivation_program_versions v),
        'components', (SELECT jsonb_agg(to_jsonb(c) ORDER BY program_version_id, component_order)
                       FROM pgreact_internal.derivation_program_components c),
        'rules', (SELECT jsonb_agg(to_jsonb(r) ORDER BY program_version_id, rule_order)
                  FROM pgreact_internal.derivation_program_rules r),
        'inputs', (SELECT jsonb_agg(to_jsonb(i)
                   ORDER BY program_version_id, rule_version_id, input_order)
                   FROM pgreact_internal.derivation_program_inputs i),
        'rule_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY rule_version_id)
                          FROM pgreact_internal.rule_versions v),
        'barriers', (SELECT jsonb_agg(to_jsonb(b) ORDER BY rule_version_id)
                     FROM pgreact_internal.rule_barriers b),
        'activations', (SELECT jsonb_agg(to_jsonb(a) ORDER BY rule_version_id, activation_id)
                        FROM pgreact_internal.activation_state a),
        'events', (SELECT jsonb_agg(to_jsonb(e) ORDER BY event_id)
                   FROM pgreact_internal.lifecycle_events e),
        'agenda', (SELECT jsonb_agg(to_jsonb(a) ORDER BY episode_id)
                   FROM pgreact_internal.agenda a),
        'reconciliations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY reconciliation_id)
                            FROM pgreact_internal.reconciliation_audit r),
        'bindings', (SELECT jsonb_agg(to_jsonb(b) ORDER BY rule_version_id, event_kind)
                     FROM pgreact_internal.consequence_bindings b),
        'batch_declarations', (SELECT jsonb_agg(to_jsonb(b) ORDER BY rule_version_id, event_kind)
                               FROM pgreact_internal.batch_declarations b),
        'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_version_id, fact_id)
                  FROM pgreact_internal.derived_facts f),
        'supports', (SELECT jsonb_agg(to_jsonb(s) ORDER BY support_id)
                     FROM pgreact_internal.derived_supports s)
    ) INTO after_state;
    IF after_state IS DISTINCT FROM (SELECT state FROM validator_before) THEN
        RAISE EXCEPTION 'M8 validation mutated catalog or runtime state: %', after_state;
    END IF;
END $$;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_object_agg(fixture, diagnostic ORDER BY fixture) INTO actual
    FROM (
        SELECT fixture, (SELECT to_jsonb(d)
                         FROM pgreact.validate_derivation_program(program) d) AS diagnostic
        FROM (VALUES
            ('oversized_version', jsonb_set(
                m8_ref.program(2, true), '{version}', to_jsonb(repeat('9', 100)))),
            ('oversized_max_iterations', jsonb_set(
                m8_ref.program(2, true), '{max_iterations}', to_jsonb(repeat('9', 100)))),
            ('oversized_max_facts', jsonb_set(
                m8_ref.program(2, true), '{max_facts}', to_jsonb(repeat('9', 100))))
        ) cases(fixture, program)
    ) diagnostics;
    expected := jsonb_build_object(
        'oversized_version', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_VERSION_INVALID',
            'severity', 'ERROR', 'object_identity', 'm8.reference',
            'message', 'program name must be non-empty and version must be a positive integer',
            'hint', 'Use one stable name and increment immutable positive versions.',
            'details', '{}'::jsonb),
        'oversized_max_iterations', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_LIMIT_INVALID',
            'severity', 'ERROR', 'object_identity', 'm8.reference',
            'message', 'max_iterations must be 1..10000 and max_facts must be 1..10000000',
            'hint', 'Choose finite resource limits inside the supported boundary.',
            'details', '{}'::jsonb),
        'oversized_max_facts', jsonb_build_object(
            'contract_version', 3, 'code', 'PROGRAM_LIMIT_INVALID',
            'severity', 'ERROR', 'object_identity', 'm8.reference',
            'message', 'max_iterations must be 1..10000 and max_facts must be 1..10000000',
            'hint', 'Choose finite resource limits inside the supported boundary.',
            'details', '{}'::jsonb));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 oversized numeric diagnostics changed: %', actual;
    END IF;
END $$;

SELECT 'M8 exact positive-subset rejection diagnostics and zero-mutation checks passed' AS result;
