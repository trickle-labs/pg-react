\set ON_ERROR_STOP on

CREATE SCHEMA m9_slice2;
CREATE TYPE m9_slice2.fact_row AS (id bigint);
CREATE TABLE m9_slice2.candidate (id bigint PRIMARY KEY);
CREATE TABLE m9_slice2.blocked (id bigint);
CREATE TABLE m9_slice2.blocked_text (id text);
CREATE TABLE m9_slice2.blocked_alt (other_id bigint);
CREATE VIEW m9_slice2.candidate_source AS
SELECT id FROM m9_slice2.candidate;
CREATE VIEW m9_slice2.candidate_not_exists AS
SELECT candidate.id
FROM m9_slice2.candidate
WHERE NOT EXISTS (
    SELECT 1 FROM m9_slice2.blocked WHERE blocked.id = candidate.id
);
CREATE VIEW m9_slice2.candidate_outer_join AS
SELECT candidate.id
FROM m9_slice2.candidate
LEFT JOIN m9_slice2.blocked USING (id)
WHERE blocked.id IS NULL;
CREATE VIEW m9_slice2.candidate_except AS
SELECT id FROM m9_slice2.candidate
EXCEPT
SELECT id FROM m9_slice2.blocked;
CREATE VIEW m9_slice2.blocked_aggregate AS
SELECT id, count(*) AS copies
FROM m9_slice2.blocked
GROUP BY id;

SELECT pgreact.create_derived_relation(
    'm9_slice2.eligible', 'm9_slice2.fact_row'::regtype, ARRAY['id']);
SELECT pgreact.create_derived_relation(
    'm9_slice2.cycle_a', 'm9_slice2.fact_row'::regtype, ARRAY['id']);
SELECT pgreact.create_derived_relation(
    'm9_slice2.cycle_b', 'm9_slice2.fact_row'::regtype, ARRAY['id']);

CREATE VIEW m9_slice2.cycle_a_source AS
SELECT id FROM m9_slice2.candidate;
CREATE VIEW m9_slice2.cycle_b_source AS
SELECT id FROM m9_slice2.cycle_a;

CREATE FUNCTION m9_slice2.program(
    source_name text,
    negative_inputs jsonb,
    output_key text DEFAULT 'id'
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT jsonb_build_object(
        'name', 'm9.slice2.validation',
        'version', 1,
        'max_iterations', 8,
        'max_facts', 32,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm9.validation',
            'definition', source_name,
            'key', output_key,
            'target', 'm9_slice2.eligible',
            'version', 1,
            'inputs', '[]'::jsonb,
            'negative_inputs', negative_inputs
        ))
    )
$$;

DO $$
DECLARE
    actual jsonb;
    expected jsonb := jsonb_build_array(
        jsonb_build_object(
            'fixture', 'negative_aggregate',
            'code', 'PROGRAM_NEGATIVE_AGGREGATE',
            'object', 'm9.validation',
            'message', 'aggregate negative inputs are outside M9'),
        jsonb_build_object(
            'fixture', 'negative_duplicate',
            'code', 'PROGRAM_NEGATIVE_DUPLICATE',
            'object', 'm9.validation',
            'message', 'the same relation cannot be checked twice by one rule'),
        jsonb_build_object(
            'fixture', 'negative_except',
            'code', 'PROGRAM_ABSENCE_UNSUPPORTED',
            'object', 'm9.validation',
            'message', 'absence must be declared with negative_inputs'),
        jsonb_build_object(
            'fixture', 'negative_not_exists',
            'code', 'PROGRAM_ABSENCE_UNSUPPORTED',
            'object', 'm9.validation',
            'message', 'absence must be declared with negative_inputs'),
        jsonb_build_object(
            'fixture', 'negative_outer_join',
            'code', 'PROGRAM_ABSENCE_UNSUPPORTED',
            'object', 'm9.validation',
            'message', 'absence must be declared with negative_inputs'),
        jsonb_build_object(
            'fixture', 'negative_unbound',
            'code', 'PROGRAM_NEGATIVE_UNBOUND',
            'object', 'm9.validation',
            'message', 'negative input key must equal the non-null output key'),
        jsonb_build_object(
            'fixture', 'negative_unresolved',
            'code', 'PROGRAM_NEGATIVE_UNRESOLVED',
            'object', 'm9_slice2.missing',
            'message', 'negative input does not resolve to a table or view'),
        jsonb_build_object(
            'fixture', 'negative_wrong_type',
            'code', 'PROGRAM_NEGATIVE_KEY_INVALID',
            'object', 'm9.validation',
            'message', 'negative input key must be one bigint column')
    );
BEGIN
    WITH fixtures(name, definition) AS (
        VALUES
        ('negative_aggregate', m9_slice2.program(
            'm9_slice2.candidate_source',
            '[{"relation":"m9_slice2.blocked_aggregate","key":"id"}]')),
        ('negative_duplicate', m9_slice2.program(
            'm9_slice2.candidate_source',
            '[{"relation":"m9_slice2.blocked","key":"id"},
              {"relation":"m9_slice2.blocked","key":"id"}]')),
        ('negative_except', m9_slice2.program(
            'm9_slice2.candidate_except', '[]')),
        ('negative_not_exists', m9_slice2.program(
            'm9_slice2.candidate_not_exists', '[]')),
        ('negative_outer_join', m9_slice2.program(
            'm9_slice2.candidate_outer_join', '[]')),
        ('negative_unbound', m9_slice2.program(
            'm9_slice2.candidate_source',
            '[{"relation":"m9_slice2.blocked_alt","key":"other_id"}]')),
        ('negative_unresolved', m9_slice2.program(
            'm9_slice2.candidate_source',
            '[{"relation":"m9_slice2.missing","key":"id"}]')),
        ('negative_wrong_type', m9_slice2.program(
            'm9_slice2.candidate_source',
            '[{"relation":"m9_slice2.blocked_text","key":"id"}]'))
    )
    SELECT jsonb_agg(jsonb_build_object(
        'fixture', fixtures.name,
        'code', diagnostic.code,
        'object', diagnostic.object_identity,
        'message', diagnostic.message) ORDER BY fixtures.name)
    INTO actual
    FROM fixtures
    CROSS JOIN LATERAL pgreact.validate_derivation_program(
        fixtures.definition) diagnostic
    WHERE diagnostic.severity = 'ERROR';
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 rejection diagnostics changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm9.slice2.negative_cycle',
        'version', 1,
        'max_iterations', 8,
        'max_facts', 32,
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'm9.cycle_a',
                'definition', 'm9_slice2.cycle_a_source',
                'key', 'id',
                'target', 'm9_slice2.cycle_a',
                'version', 1,
                'inputs', '[]'::jsonb,
                'negative_inputs', jsonb_build_array(jsonb_build_object(
                    'relation', 'm9_slice2.cycle_b', 'key', 'id'))),
            jsonb_build_object(
                'name', 'm9.cycle_b',
                'definition', 'm9_slice2.cycle_b_source',
                'key', 'id',
                'target', 'm9_slice2.cycle_b',
                'version', 1,
                'inputs', jsonb_build_array(jsonb_build_object(
                    'relation', 'm9_slice2.cycle_a', 'key', 'id')),
                'negative_inputs', '[]'::jsonb)
        )
    );
    actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'code', code, 'object', object_identity, 'message', message))
    INTO actual
    FROM pgreact.validate_derivation_program(definition)
    WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'code', 'PROGRAM_NEGATIVE_CYCLE',
        'object', 'm9.slice2.negative_cycle',
        'message', 'derivation program contains a cycle through negation')) THEN
        RAISE EXCEPTION 'M9 negative-cycle diagnostic changed: %', actual;
    END IF;
END
$$;

INSERT INTO m9_slice2.candidate VALUES (7), (8);
INSERT INTO m9_slice2.blocked VALUES (NULL), (8);

CREATE TABLE m9_slice2.manifest AS
SELECT jsonb_build_object(
    'format_version', 1,
    'pack', 'm9-slice2-pack',
    'version', '1',
    'owner', 'owner',
    'rules', jsonb_build_array(jsonb_build_object(
        'name', 'm9.slice2.base',
        'definition', 'm9.candidate_source',
        'key', 'id',
        'kind', 'CONSTRAINT',
        'depends_on', '[]'::jsonb)),
    'remove', '[]'::jsonb,
    'derived_relations', '[]'::jsonb,
    'derivations', '[]'::jsonb,
    'remove_derivations', '[]'::jsonb,
    'remove_derived_relations', '[]'::jsonb,
    'programs', jsonb_build_array(jsonb_build_object(
        'name', 'm9.slice2',
        'version', 1,
        'max_iterations', 8,
        'max_facts', 32,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm9.eligible',
            'definition', 'm9.candidate_source',
            'key', 'id',
            'target', 'm9.eligible',
            'version', 1,
            'inputs', '[]'::jsonb,
            'negative_inputs', jsonb_build_array(jsonb_build_object(
                'relation', 'm9.blocked', 'key', 'id'))
        ))
    )),
    'remove_programs', '[]'::jsonb
) AS definition,
jsonb_build_object(
    'roles', jsonb_build_object('owner', current_user),
    'objects', jsonb_build_object(
        'm9.candidate_source', 'm9_slice2.candidate_source',
        'm9.blocked', 'm9_slice2.blocked',
        'm9.eligible', 'm9_slice2.eligible')
) AS mappings;

CREATE TEMP TABLE m9_preview AS
SELECT plan_digest, generated_object_changes
FROM pgreact.preview_pack(
    (SELECT definition FROM m9_slice2.manifest),
    (SELECT mappings FROM m9_slice2.manifest))
WHERE rule_name = 'm9.slice2';

DO $$
DECLARE
    actual jsonb;
    expected jsonb := jsonb_build_object(
        'components', 1,
        'object_kind', 'DERIVATION_PROGRAM',
        'graph', jsonb_build_array(jsonb_build_object(
            'rule', 'm9.eligible',
            'input_order', 1,
            'polarity', 'NEGATIVE',
            'source', 'm9_slice2.blocked',
            'target', 'm9_slice2.eligible',
            'source_stratum', 0,
            'target_stratum', 1)),
        'strata', jsonb_build_array(jsonb_build_object(
            'stratum', 1,
            'rules', jsonb_build_array('m9.eligible'),
            'targets', jsonb_build_array('m9_slice2.eligible')))
    );
BEGIN
    SELECT jsonb_build_object(
        'components', generated_object_changes -> 'components',
        'object_kind', generated_object_changes -> 'object_kind',
        'graph', (SELECT jsonb_agg(value - 'id')
                  FROM jsonb_array_elements(
                      generated_object_changes -> 'dependency_graph')),
        'strata', (SELECT jsonb_agg(value - 'component_id')
                   FROM jsonb_array_elements(
                       generated_object_changes -> 'strata')))
    INTO actual
    FROM m9_preview;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 graph preview changed: %', actual;
    END IF;
END
$$;

SELECT pgreact.deploy_pack(
    (SELECT definition FROM m9_slice2.manifest),
    (SELECT plan_digest FROM m9_preview),
    (SELECT mappings FROM m9_slice2.manifest));

DO $$
DECLARE
    actual jsonb;
    expected jsonb := jsonb_build_object(
        'program_frontier', 1,
        'graph', jsonb_build_array(jsonb_build_object(
            'rule', 'm9.eligible',
            'input_order', 1,
            'polarity', 'NEGATIVE',
            'source', 'm9_slice2.blocked',
            'target', 'm9_slice2.eligible',
            'source_stratum', 0,
            'target_stratum', 1)),
        'strata', jsonb_build_array(jsonb_build_object(
            'stratum', 1,
            'component_order', 1,
            'cyclic', false,
            'rules', jsonb_build_array('m9.eligible'),
            'targets', jsonb_build_array('m9_slice2.eligible'),
            'frontier', 1,
            'iterations', 2,
            'fact_count', 1,
            'support_count', 1)),
        'facts', jsonb_build_array(jsonb_build_object(
            'relation', 'm9_slice2.eligible',
            'key', 7,
            'fact', jsonb_build_object('id', 7),
            'support_count', 1,
            'first_frontier', 1,
            'last_frontier', 1)),
        'supports', jsonb_build_array(jsonb_build_object(
            'relation', 'm9_slice2.eligible',
            'rule', 'm9.eligible',
            'key', 7,
            'fact', jsonb_build_object('id', 7),
            'active', true,
            'first_frontier', 1,
            'last_frontier', NULL))
    );
    preview_dependency uuid;
    preview_component uuid;
BEGIN
    SELECT (generated_object_changes -> 'dependency_graph' -> 0 ->> 'id')::uuid,
           (generated_object_changes -> 'strata' -> 0 ->> 'component_id')::uuid
    INTO preview_dependency, preview_component
    FROM m9_preview;
    IF preview_dependency IS DISTINCT FROM (
        SELECT dependency_id
        FROM pgreact.derivation_dependency_graph
        WHERE program_name = 'm9.slice2' AND polarity = 'NEGATIVE'
    ) OR preview_component IS DISTINCT FROM (
        SELECT component_id
        FROM pgreact.derivation_strata
        WHERE program_name = 'm9.slice2'
    ) THEN
        RAISE EXCEPTION 'M9 preview and deployed graph identities differ';
    END IF;

    SELECT jsonb_build_object(
        'program_frontier', (
            SELECT frontier FROM pgreact.derivation_programs
            WHERE program_name = 'm9.slice2' AND state = 'ACTIVE'),
        'graph', (
            SELECT jsonb_agg(jsonb_build_object(
                'rule', rule_name,
                'input_order', input_order,
                'polarity', polarity,
                'source', source_relation,
                'target', target_relation,
                'source_stratum', source_stratum,
                'target_stratum', target_stratum)
                ORDER BY target_stratum, rule_name, polarity, input_order)
            FROM pgreact.derivation_dependency_graph
            WHERE program_name = 'm9.slice2'),
        'strata', (
            SELECT jsonb_agg(jsonb_build_object(
                'stratum', stratum,
                'component_order', component_order,
                'cyclic', cyclic,
                'rules', to_jsonb(rule_names),
                'targets', to_jsonb(target_relations),
                'frontier', frontier,
                'iterations', iterations,
                'fact_count', fact_count,
                'support_count', support_count)
                ORDER BY stratum, component_order)
            FROM pgreact.derivation_strata
            WHERE program_name = 'm9.slice2'),
        'facts', (
            SELECT jsonb_agg(jsonb_build_object(
                'relation', relation_name,
                'key', semantic_key,
                'fact', fact,
                'support_count', support_count,
                'first_frontier', first_frontier,
                'last_frontier', last_frontier)
                ORDER BY relation_name, semantic_key)
            FROM pgreact.derived_facts
            WHERE relation_name = 'm9_slice2.eligible'),
        'supports', (
            SELECT jsonb_agg(jsonb_build_object(
                'relation', relation_name,
                'rule', rule_name,
                'key', semantic_key,
                'fact', fact,
                'active', active,
                'first_frontier', first_frontier,
                'last_frontier', last_frontier)
                ORDER BY relation_name, rule_name, semantic_key)
            FROM pgreact.support_history
            WHERE relation_name = 'm9_slice2.eligible' AND active)
    ) INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 deployed initial state changed: %', actual;
    END IF;
END
$$;

SELECT 'M9 slice 2 safe-negative deployment gate passed' AS result;
