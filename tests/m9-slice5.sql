\set ON_ERROR_STOP on
\o /dev/null
SET client_min_messages = error;

CREATE SCHEMA m9_slice5;

CREATE TABLE m9_slice5.manifests (
    version integer PRIMARY KEY,
    definition jsonb NOT NULL,
    mappings jsonb NOT NULL
);

INSERT INTO m9_slice5.manifests
SELECT 1, definition, mappings FROM m9_slice4.manifest;

INSERT INTO m9_slice5.manifests
WITH base AS (
    SELECT definition, mappings, definition -> 'programs' -> 0 AS program
    FROM m9_slice4.manifest
), rules AS (
    SELECT ordinal, CASE rule ->> 'name'
        WHEN 'm9.eligible_to_alert' THEN
            (rule - 'inputs') || jsonb_build_object(
                'definition', 'm9.seed_source',
                'version', 2,
                'inputs', '[]'::jsonb,
                'negative_inputs', jsonb_build_array(jsonb_build_object(
                    'relation', 'm9.eligible', 'key', 'id')))
        ELSE rule END AS rule
    FROM base
    CROSS JOIN LATERAL jsonb_array_elements(program -> 'rules')
        WITH ORDINALITY items(rule, ordinal)
    WHERE rule ->> 'name' <> 'm9.reachable_to_candidate'
), program AS (
    SELECT jsonb_set(
        jsonb_set(base.program, '{version}', '2'::jsonb),
        '{rules}', jsonb_agg(rules.rule ORDER BY rules.ordinal)) AS definition
    FROM base, rules
    GROUP BY base.program
)
SELECT 2,
       jsonb_set(
           jsonb_set(base.definition, '{version}', to_jsonb('2'::text)),
           '{programs}', jsonb_build_array(program.definition)),
       base.mappings
FROM base, program;

INSERT INTO m9_slice5.manifests
WITH base AS (
    SELECT definition, mappings, definition -> 'programs' -> 0 AS program
    FROM m9_slice4.manifest
), rules AS (
    SELECT ordinal, CASE rule ->> 'name'
        WHEN 'm9.reachable_to_candidate' THEN
            jsonb_set(rule, '{version}', '2'::jsonb)
        WHEN 'm9.eligible_to_alert' THEN
            jsonb_set(rule, '{version}', '3'::jsonb)
        ELSE rule END AS rule
    FROM base
    CROSS JOIN LATERAL jsonb_array_elements(program -> 'rules')
        WITH ORDINALITY items(rule, ordinal)
), program AS (
    SELECT jsonb_set(
        jsonb_set(base.program, '{version}', '3'::jsonb),
        '{rules}', jsonb_agg(rules.rule ORDER BY rules.ordinal)) AS definition
    FROM base, rules
    GROUP BY base.program
)
SELECT 3,
       jsonb_set(
           jsonb_set(base.definition, '{version}', to_jsonb('3'::text)),
           '{programs}', jsonb_build_array(program.definition)),
       base.mappings
FROM base, program;

CREATE FUNCTION m9_slice5.state()
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
WITH active AS (
    SELECT program_version_id
    FROM pgreact.derivation_programs
    WHERE program_name = 'm9.slice4' AND state = 'ACTIVE'
)
SELECT jsonb_build_object(
    'packs', COALESCE((
        SELECT jsonb_agg(version || ':' || status ORDER BY deployed_at)
        FROM pgreact.pack_history('m9-slice4-pack')
    ), '[]'::jsonb),
    'programs', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'version', program_version,
            'state', state,
            'frontier', frontier) ORDER BY program_version)
        FROM pgreact.derivation_programs
        WHERE program_name = 'm9.slice4'
    ), '[]'::jsonb),
    'graph', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name,
            'polarity', polarity,
            'source', source_relation,
            'target', target_relation,
            'source_stratum', source_stratum,
            'target_stratum', target_stratum)
            ORDER BY target_stratum, rule_name, polarity, input_order,
                     source_relation)
        FROM pgreact.derivation_dependency_graph
        WHERE program_version_id = (SELECT program_version_id FROM active)
    ), '[]'::jsonb),
    'strata', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'stratum', stratum,
            'order', component_order,
            'cyclic', cyclic,
            'rules', to_jsonb(rule_names),
            'targets', to_jsonb(target_relations),
            'frontier', frontier,
            'iterations', iterations,
            'facts', fact_count,
            'supports', support_count)
            ORDER BY component_order)
        FROM pgreact.derivation_strata
        WHERE program_version_id = (SELECT program_version_id FROM active)
    ), '[]'::jsonb),
    'facts', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation_name,
            'key', semantic_key,
            'fact', fact,
            'supports', support_count)
            ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts
        WHERE relation_name LIKE 'm9_slice4.%'
    ), '[]'::jsonb),
    'supports', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation.relation_name,
            'rule', rule.rule_name,
            'key', support.semantic_key,
            'frontier', support.support_frontier,
            'grounded', support.grounded,
            'active', support.active)
            ORDER BY rule.rule_name, support.semantic_key)
        FROM active
        JOIN pgreact_internal.derivation_program_rules rule USING (program_version_id)
        JOIN pgreact_internal.derived_supports support
          ON support.rule_version_id = rule.rule_version_id AND support.active
        JOIN pgreact_internal.derived_relation_versions relation_version
          USING (relation_version_id)
        JOIN pgreact_internal.derived_relations relation USING (relation_id)
    ), '[]'::jsonb),
    'orphaned_supports', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation.relation_name,
            'key', support.semantic_key,
            'fact', support.fact) ORDER BY relation.relation_name,
                     support.semantic_key)
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derived_relation_versions relation_version
          USING (relation_version_id)
        JOIN pgreact_internal.derived_relations relation USING (relation_id)
        WHERE support.active
          AND relation.relation_name LIKE 'm9_slice4.%'
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.derivation_program_rules rule
              JOIN pgreact_internal.derivation_program_versions program
                USING (program_version_id)
              WHERE rule.rule_version_id = support.rule_version_id
                AND program.state = 'ACTIVE')
    ), '[]'::jsonb),
    'negative_inputs', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name,
            'relation', input.relation_name,
            'key', input.key_column,
            'definition_current', input.relation_definition_digest =
                pgreact_internal.source_closure_digest(input.relation_oid),
            'row_current', input.relation_row_signature =
                pgreact_internal.source_row_signature(input.relation_oid))
            ORDER BY rule.rule_name, input.input_order)
        FROM active
        JOIN pgreact_internal.derivation_program_rules rule USING (program_version_id)
        JOIN pgreact_internal.derivation_program_negative_inputs input
          USING (program_version_id, rule_version_id)
    ), '[]'::jsonb)
)
$$;

CREATE FUNCTION m9_slice5.expected_v2()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $$
SELECT jsonb_build_object(
    'packs', jsonb_build_array('1:SUPERSEDED', '2:ACTIVE'),
    'programs', jsonb_build_array(
        jsonb_build_object('version', 1, 'state', 'REMOVED', 'frontier', 7),
        jsonb_build_object('version', 2, 'state', 'ACTIVE', 'frontier', 1)),
    'graph', jsonb_build_array(
        jsonb_build_object(
            'rule', 'm9.candidate_to_reachable', 'polarity', 'POSITIVE',
            'source', 'm9_slice4.b_candidate',
            'target', 'm9_slice4.c_reachable',
            'source_stratum', 0, 'target_stratum', 0),
        jsonb_build_object(
            'rule', 'm9.reachable_unblocked', 'polarity', 'NEGATIVE',
            'source', 'm9_slice4.a_denied',
            'target', 'm9_slice4.d_eligible',
            'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object(
            'rule', 'm9.reachable_unblocked', 'polarity', 'POSITIVE',
            'source', 'm9_slice4.c_reachable',
            'target', 'm9_slice4.d_eligible',
            'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object(
            'rule', 'm9.eligible_to_alert', 'polarity', 'NEGATIVE',
            'source', 'm9_slice4.d_eligible',
            'target', 'm9_slice4.e_alert',
            'source_stratum', 1, 'target_stratum', 2)),
    'strata', jsonb_build_array(
        jsonb_build_object(
            'stratum', 0, 'order', 1, 'cyclic', false,
            'rules', jsonb_build_array('m9.blocked_to_denied'),
            'targets', jsonb_build_array('m9_slice4.a_denied'),
            'frontier', 1, 'iterations', 1, 'facts', 0, 'supports', 0),
        jsonb_build_object(
            'stratum', 0, 'order', 2, 'cyclic', false,
            'rules', jsonb_build_array('m9.seed_to_candidate'),
            'targets', jsonb_build_array('m9_slice4.b_candidate'),
            'frontier', 1, 'iterations', 2, 'facts', 1, 'supports', 1),
        jsonb_build_object(
            'stratum', 0, 'order', 3, 'cyclic', false,
            'rules', jsonb_build_array('m9.candidate_to_reachable'),
            'targets', jsonb_build_array('m9_slice4.c_reachable'),
            'frontier', 1, 'iterations', 2, 'facts', 1, 'supports', 1),
        jsonb_build_object(
            'stratum', 1, 'order', 4, 'cyclic', false,
            'rules', jsonb_build_array('m9.reachable_unblocked'),
            'targets', jsonb_build_array('m9_slice4.d_eligible'),
            'frontier', 1, 'iterations', 2, 'facts', 1, 'supports', 1),
        jsonb_build_object(
            'stratum', 2, 'order', 5, 'cyclic', false,
            'rules', jsonb_build_array('m9.eligible_to_alert'),
            'targets', jsonb_build_array('m9_slice4.e_alert'),
            'frontier', 1, 'iterations', 1, 'facts', 0, 'supports', 0)),
    'facts', jsonb_build_array(
        jsonb_build_object(
            'relation', 'm9_slice4.b_candidate', 'key', 7,
            'fact', jsonb_build_object('id', 7), 'supports', 1),
        jsonb_build_object(
            'relation', 'm9_slice4.c_reachable', 'key', 7,
            'fact', jsonb_build_object('id', 7), 'supports', 1),
        jsonb_build_object(
            'relation', 'm9_slice4.d_eligible', 'key', 7,
            'fact', jsonb_build_object('id', 7), 'supports', 1)),
    'supports', jsonb_build_array(
        jsonb_build_object(
            'relation', 'm9_slice4.c_reachable',
            'rule', 'm9.candidate_to_reachable', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true),
        jsonb_build_object(
            'relation', 'm9_slice4.d_eligible',
            'rule', 'm9.reachable_unblocked', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true),
        jsonb_build_object(
            'relation', 'm9_slice4.b_candidate',
            'rule', 'm9.seed_to_candidate', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true)),
    'orphaned_supports', '[]'::jsonb,
    'negative_inputs', jsonb_build_array(
        jsonb_build_object(
            'rule', 'm9.eligible_to_alert',
            'relation', 'm9_slice4.d_eligible', 'key', 'id',
            'definition_current', true, 'row_current', true),
        jsonb_build_object(
            'rule', 'm9.reachable_unblocked',
            'relation', 'm9_slice4.a_denied', 'key', 'id',
            'definition_current', true, 'row_current', true))
)
$$;

CREATE FUNCTION m9_slice5.expected_v3()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $$
SELECT jsonb_build_object(
    'packs', jsonb_build_array(
        '1:SUPERSEDED', '2:SUPERSEDED', '3:ACTIVE'),
    'programs', jsonb_build_array(
        jsonb_build_object('version', 1, 'state', 'REMOVED', 'frontier', 7),
        jsonb_build_object('version', 2, 'state', 'REMOVED', 'frontier', 1),
        jsonb_build_object('version', 3, 'state', 'ACTIVE', 'frontier', 1)),
    'graph', jsonb_build_array(
        jsonb_build_object(
            'rule', 'm9.candidate_to_reachable', 'polarity', 'POSITIVE',
            'source', 'm9_slice4.b_candidate',
            'target', 'm9_slice4.c_reachable',
            'source_stratum', 0, 'target_stratum', 0),
        jsonb_build_object(
            'rule', 'm9.reachable_to_candidate', 'polarity', 'POSITIVE',
            'source', 'm9_slice4.c_reachable',
            'target', 'm9_slice4.b_candidate',
            'source_stratum', 0, 'target_stratum', 0),
        jsonb_build_object(
            'rule', 'm9.eligible_to_alert', 'polarity', 'POSITIVE',
            'source', 'm9_slice4.d_eligible',
            'target', 'm9_slice4.e_alert',
            'source_stratum', 1, 'target_stratum', 1),
        jsonb_build_object(
            'rule', 'm9.reachable_unblocked', 'polarity', 'NEGATIVE',
            'source', 'm9_slice4.a_denied',
            'target', 'm9_slice4.d_eligible',
            'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object(
            'rule', 'm9.reachable_unblocked', 'polarity', 'POSITIVE',
            'source', 'm9_slice4.c_reachable',
            'target', 'm9_slice4.d_eligible',
            'source_stratum', 0, 'target_stratum', 1)),
    'strata', jsonb_build_array(
        jsonb_build_object(
            'stratum', 0, 'order', 1, 'cyclic', false,
            'rules', jsonb_build_array('m9.blocked_to_denied'),
            'targets', jsonb_build_array('m9_slice4.a_denied'),
            'frontier', 1, 'iterations', 1, 'facts', 0, 'supports', 0),
        jsonb_build_object(
            'stratum', 0, 'order', 2, 'cyclic', true,
            'rules', jsonb_build_array(
                'm9.candidate_to_reachable',
                'm9.reachable_to_candidate',
                'm9.seed_to_candidate'),
            'targets', jsonb_build_array(
                'm9_slice4.b_candidate', 'm9_slice4.c_reachable'),
            'frontier', 1, 'iterations', 2, 'facts', 2, 'supports', 3),
        jsonb_build_object(
            'stratum', 1, 'order', 3, 'cyclic', false,
            'rules', jsonb_build_array('m9.reachable_unblocked'),
            'targets', jsonb_build_array('m9_slice4.d_eligible'),
            'frontier', 1, 'iterations', 2, 'facts', 1, 'supports', 1),
        jsonb_build_object(
            'stratum', 1, 'order', 4, 'cyclic', false,
            'rules', jsonb_build_array('m9.eligible_to_alert'),
            'targets', jsonb_build_array('m9_slice4.e_alert'),
            'frontier', 1, 'iterations', 2, 'facts', 1, 'supports', 1)),
    'facts', jsonb_build_array(
        jsonb_build_object(
            'relation', 'm9_slice4.b_candidate', 'key', 7,
            'fact', jsonb_build_object('id', 7), 'supports', 2),
        jsonb_build_object(
            'relation', 'm9_slice4.c_reachable', 'key', 7,
            'fact', jsonb_build_object('id', 7), 'supports', 1),
        jsonb_build_object(
            'relation', 'm9_slice4.d_eligible', 'key', 7,
            'fact', jsonb_build_object('id', 7), 'supports', 1),
        jsonb_build_object(
            'relation', 'm9_slice4.e_alert', 'key', 7,
            'fact', jsonb_build_object('id', 7), 'supports', 1)),
    'supports', jsonb_build_array(
        jsonb_build_object(
            'relation', 'm9_slice4.c_reachable',
            'rule', 'm9.candidate_to_reachable', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true),
        jsonb_build_object(
            'relation', 'm9_slice4.e_alert',
            'rule', 'm9.eligible_to_alert', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true),
        jsonb_build_object(
            'relation', 'm9_slice4.b_candidate',
            'rule', 'm9.reachable_to_candidate', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true),
        jsonb_build_object(
            'relation', 'm9_slice4.d_eligible',
            'rule', 'm9.reachable_unblocked', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true),
        jsonb_build_object(
            'relation', 'm9_slice4.b_candidate',
            'rule', 'm9.seed_to_candidate', 'key', 7,
            'frontier', 1, 'grounded', true, 'active', true)),
    'orphaned_supports', '[]'::jsonb,
    'negative_inputs', jsonb_build_array(jsonb_build_object(
        'rule', 'm9.reachable_unblocked',
        'relation', 'm9_slice4.a_denied', 'key', 'id',
        'definition_current', true, 'row_current', true))
)
$$;

CREATE TEMP TABLE v1_state AS SELECT m9_slice5.state() AS state;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(diagnostic) ORDER BY code, object_identity)
    INTO actual
    FROM pgreact.validate_pack(
        (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
        (SELECT mappings FROM m9_slice5.manifests WHERE version = 2)) diagnostic;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 3,
        'code', 'OK',
        'severity', 'INFO',
        'object_identity', 'm9-slice4-pack',
        'message', 'M8 pack and derivation programs are valid',
        'hint', 'Preview and deploy with the exact plan digest.',
        'details', jsonb_build_object('programs', 1, 'remove_programs', 0))) THEN
        RAISE EXCEPTION 'M9 slice 5 validation changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
DECLARE expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'action', action,
        'name', rule_name,
        'dependencies', dependencies,
        'generated', jsonb_build_object(
            'object_kind', generated_object_changes -> 'object_kind',
            'components', generated_object_changes -> 'components',
            'graph', (
                SELECT jsonb_agg(value - 'id' - 'input_order')
                FROM jsonb_array_elements(
                    generated_object_changes -> 'dependency_graph')),
            'strata', (
                SELECT jsonb_agg(value - 'component_id')
                FROM jsonb_array_elements(
                    generated_object_changes -> 'strata'))),
        'risks', lifecycle_risks,
        'details', details - 'prior_program_version_id')
    INTO actual
    FROM pgreact.preview_pack(
        (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
        (SELECT mappings FROM m9_slice5.manifests WHERE version = 2))
    WHERE rule_name = 'm9.slice4';
    expected := jsonb_build_object(
        'action', 'REPLACE',
        'name', 'm9.slice4',
        'dependencies', jsonb_build_array(
            'm9.blocked_to_denied',
            'm9.seed_to_candidate',
            'm9.candidate_to_reachable',
            'm9.reachable_unblocked',
            'm9.eligible_to_alert'),
        'generated', jsonb_build_object(
            'object_kind', 'DERIVATION_PROGRAM',
            'components', 5,
            'graph', m9_slice5.expected_v2() -> 'graph',
            'strata', jsonb_build_array(
                jsonb_build_object(
                    'stratum', 0,
                    'rules', jsonb_build_array('m9.blocked_to_denied'),
                    'targets', jsonb_build_array('m9_slice4.a_denied')),
                jsonb_build_object(
                    'stratum', 0,
                    'rules', jsonb_build_array('m9.seed_to_candidate'),
                    'targets', jsonb_build_array('m9_slice4.b_candidate')),
                jsonb_build_object(
                    'stratum', 0,
                    'rules', jsonb_build_array('m9.candidate_to_reachable'),
                    'targets', jsonb_build_array('m9_slice4.c_reachable')),
                jsonb_build_object(
                    'stratum', 1,
                    'rules', jsonb_build_array('m9.reachable_unblocked'),
                    'targets', jsonb_build_array('m9_slice4.d_eligible')),
                jsonb_build_object(
                    'stratum', 2,
                    'rules', jsonb_build_array('m9.eligible_to_alert'),
                    'targets', jsonb_build_array('m9_slice4.e_alert')))),
        'risks', jsonb_build_array(
            'the complete program is rebuilt and commits at one frontier'),
        'details', jsonb_build_object(
            'prior_version', 1,
            'next_version', 2,
            'max_iterations', 8,
            'max_facts', 4));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 slice 5 replacement preview changed: %', actual;
    END IF;
END
$$;

CREATE TEMP TABLE stale_preview AS
SELECT min(plan_digest) AS digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
    (SELECT mappings FROM m9_slice5.manifests WHERE version = 2));

CREATE OR REPLACE VIEW m9_slice4.blocked_source AS
SELECT id FROM m9_slice4.blocked WHERE id IS NOT NULL AND id <> -1;

DO $$
DECLARE current_digest text;
DECLARE failure_detail text;
DECLARE failure_hint text;
BEGIN
    SELECT min(plan_digest) INTO current_digest
    FROM pgreact.preview_pack(
        (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
        (SELECT mappings FROM m9_slice5.manifests WHERE version = 2));
    BEGIN
        PERFORM pgreact.deploy_pack(
            (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
            (SELECT digest FROM stale_preview),
            (SELECT mappings FROM m9_slice5.manifests WHERE version = 2));
        RAISE EXCEPTION 'stale M9 slice 5 preview unexpectedly deployed';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'rule-pack preview is stale' THEN RAISE; END IF;
        GET STACKED DIAGNOSTICS
            failure_detail = PG_EXCEPTION_DETAIL,
            failure_hint = PG_EXCEPTION_HINT;
        IF failure_detail IS DISTINCT FROM format(
               'expected %s, current %s',
               (SELECT digest FROM stale_preview), current_digest)
           OR failure_hint IS DISTINCT FROM
               'Run pgreact.preview_pack again after concurrent DDL, support, or deployment changes.' THEN
            RAISE EXCEPTION 'M9 slice 5 stale diagnostic changed: %, %',
                failure_detail, failure_hint;
        END IF;
    END;
    IF m9_slice5.state() IS DISTINCT FROM (SELECT state FROM v1_state) THEN
        RAISE EXCEPTION 'M9 slice 5 stale preview changed V1: %',
            m9_slice5.state();
    END IF;
END
$$;

CREATE OR REPLACE VIEW m9_slice4.blocked_source AS
SELECT id FROM m9_slice4.blocked WHERE id IS NOT NULL;

CREATE TEMP TABLE v2_preview AS
SELECT min(plan_digest) AS digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
    (SELECT mappings FROM m9_slice5.manifests WHERE version = 2));

DO $$
BEGIN
    BEGIN
        PERFORM set_config('pgreact.test_fail_pack_phase', 'programs', true);
        PERFORM pgreact.deploy_pack(
            (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
            (SELECT digest FROM v2_preview),
            (SELECT mappings FROM m9_slice5.manifests WHERE version = 2));
        RAISE EXCEPTION 'injected M9 slice 5 deployment unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'injected rule-pack failure after programs phase' THEN
            RAISE;
        END IF;
    END;
    IF m9_slice5.state() IS DISTINCT FROM (SELECT state FROM v1_state) THEN
        RAISE EXCEPTION 'M9 slice 5 injected deployment changed V1: %',
            m9_slice5.state();
    END IF;
END
$$;

SELECT pgreact.deploy_pack(
    (SELECT definition FROM m9_slice5.manifests WHERE version = 2),
    (SELECT digest FROM v2_preview),
    (SELECT mappings FROM m9_slice5.manifests WHERE version = 2));

DO $$
BEGIN
    IF m9_slice5.state() IS DISTINCT FROM m9_slice5.expected_v2() THEN
        RAISE EXCEPTION 'M9 slice 5 split/stratum insertion state changed: %',
            m9_slice5.state();
    END IF;
END
$$;

ALTER VIEW m9_slice4.a_denied RENAME TO a_denied_drifted;

CREATE TEMP TABLE drift_state AS SELECT m9_slice5.state() AS state;
CREATE TEMP TABLE drift_expected AS
SELECT format(
    'relation %s; expected definition %s, current %s; expected row signature %s, current %s',
    input.relation_name,
    encode(input.relation_definition_digest, 'hex'),
    encode(pgreact_internal.source_closure_digest(input.relation_oid), 'hex'),
    encode(input.relation_row_signature, 'hex'),
    encode(pgreact_internal.source_row_signature(input.relation_oid), 'hex')) AS detail
FROM pgreact_internal.derivation_program_negative_inputs input
JOIN pgreact_internal.derivation_program_rules rule
  USING (program_version_id, rule_version_id)
JOIN pgreact_internal.derivation_program_versions program
  USING (program_version_id)
WHERE program.state = 'ACTIVE'
  AND rule.rule_name = 'm9.reachable_unblocked';

SELECT pgreact.refresh_derivation_program(program_version_id) IS NULL AS failed
FROM pgreact.derivation_programs
WHERE program_name = 'm9.slice4' AND state = 'ACTIVE' \gset
\if :failed
\else
  SELECT 1 / 0;
\endif

DO $$
DECLARE failure jsonb;
BEGIN
    IF m9_slice5.state() IS DISTINCT FROM (SELECT state FROM drift_state) THEN
        RAISE EXCEPTION 'M9 slice 5 negative drift changed V2: %',
            m9_slice5.state();
    END IF;
    SELECT jsonb_build_object(
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations,
        'fact_count', fact_count,
        'support_count', support_count,
        'status', status,
        'sqlstate', error_sqlstate,
        'message', error_message,
        'detail', error_detail,
        'hint', error_hint,
        'requested_by', requested_by)
    INTO failure
    FROM pgreact.derivation_program_runs
    WHERE program_version_id = (
        SELECT program_version_id FROM pgreact.derivation_programs
        WHERE program_name = 'm9.slice4' AND state = 'ACTIVE')
      AND status = 'FAILED'
    ORDER BY run_id DESC LIMIT 1;
    IF failure IS DISTINCT FROM jsonb_build_object(
        'prior_frontier', 1,
        'committed_frontier', 1,
        'iterations', 0,
        'fact_count', NULL,
        'support_count', NULL,
        'status', 'FAILED',
        'sqlstate', 'P0001',
        'message', 'derivation program negative-input drift for m9.reachable_unblocked',
        'detail', (SELECT detail FROM drift_expected),
        'hint', 'Replace the complete derivation program through its rule pack.',
        'requested_by', current_user) THEN
        RAISE EXCEPTION 'M9 slice 5 negative drift failure changed: %', failure;
    END IF;
END
$$;

ALTER VIEW m9_slice4.a_denied_drifted RENAME TO a_denied;

SELECT pgreact.refresh_derivation_program(program_version_id) = 1 AS noop
FROM pgreact.derivation_programs
WHERE program_name = 'm9.slice4' AND state = 'ACTIVE' \gset
\if :noop
\else
  SELECT 1 / 0;
\endif

CREATE TEMP TABLE v3_preview AS
SELECT min(plan_digest) AS digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m9_slice5.manifests WHERE version = 3),
    (SELECT mappings FROM m9_slice5.manifests WHERE version = 3));

SELECT pgreact.deploy_pack(
    (SELECT definition FROM m9_slice5.manifests WHERE version = 3),
    (SELECT digest FROM v3_preview),
    (SELECT mappings FROM m9_slice5.manifests WHERE version = 3));

DO $$
BEGIN
    IF m9_slice5.state() IS DISTINCT FROM m9_slice5.expected_v3() THEN
        RAISE EXCEPTION 'M9 slice 5 merge/stratum deletion state changed: %',
            m9_slice5.state();
    END IF;
END
$$;

INSERT INTO m9_slice5.manifests
SELECT 4,
       jsonb_set(
           jsonb_set(definition, '{version}', to_jsonb('4'::text)),
           '{programs,0,version}', '4'::jsonb),
       mappings
FROM m9_slice5.manifests WHERE version = 3;

CREATE TABLE m9_slice5.concurrent_control AS
SELECT definition, mappings, (
    SELECT min(plan_digest)
    FROM pgreact.preview_pack(manifest.definition, manifest.mappings)
) AS plan_digest,
(
    SELECT program_version_id
    FROM pgreact.derivation_programs
    WHERE program_name = 'm9.slice4' AND state = 'ACTIVE'
) AS program_version_id
FROM m9_slice5.manifests manifest
WHERE version = 4;

\o
SELECT 'M9 slice 5 atomic stratified-program change gate passed' AS result;
