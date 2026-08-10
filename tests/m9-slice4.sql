\set ON_ERROR_STOP on
\if :{?reverse_schedule}
\else
  \set reverse_schedule false
\endif
\o /dev/null

SET client_min_messages = error;

CREATE SCHEMA m9_slice4;
CREATE TYPE m9_slice4.fact_row AS (id bigint);
CREATE TABLE m9_slice4.seed (id bigint PRIMARY KEY);
CREATE TABLE m9_slice4.blocked (id bigint);
CREATE VIEW m9_slice4.seed_source AS
SELECT id FROM m9_slice4.seed;
CREATE VIEW m9_slice4.blocked_source AS
SELECT id FROM m9_slice4.blocked WHERE id IS NOT NULL;

SELECT pgreact.create_derived_relation(
    'm9_slice4.a_denied', 'm9_slice4.fact_row'::regtype, ARRAY['id']);
SELECT pgreact.create_derived_relation(
    'm9_slice4.b_candidate', 'm9_slice4.fact_row'::regtype, ARRAY['id']);
SELECT pgreact.create_derived_relation(
    'm9_slice4.c_reachable', 'm9_slice4.fact_row'::regtype, ARRAY['id']);
SELECT pgreact.create_derived_relation(
    'm9_slice4.d_eligible', 'm9_slice4.fact_row'::regtype, ARRAY['id']);
SELECT pgreact.create_derived_relation(
    'm9_slice4.e_alert', 'm9_slice4.fact_row'::regtype, ARRAY['id']);

CREATE VIEW m9_slice4.candidate_to_reachable AS
SELECT id FROM m9_slice4.b_candidate;
CREATE VIEW m9_slice4.reachable_to_candidate AS
SELECT id FROM m9_slice4.c_reachable;
CREATE VIEW m9_slice4.reachable_unblocked AS
SELECT id FROM m9_slice4.c_reachable;
CREATE VIEW m9_slice4.eligible_to_alert AS
SELECT id FROM m9_slice4.d_eligible;
CREATE VIEW m9_slice4.observe_alert AS
SELECT id FROM m9_slice4.e_alert;

SELECT pgreact.create_rule(
    name => 'm9.observe_alert',
    definition => 'm9_slice4.observe_alert'::regclass,
    key_columns => ARRAY['id'],
    kind => 'CONSTRAINT'
) AS observer_rule_version_id \gset
SELECT set_config('m9.slice4_observer', :'observer_rule_version_id', false);

INSERT INTO m9_slice4.seed VALUES (7);
INSERT INTO m9_slice4.blocked VALUES (NULL);

CREATE TABLE m9_slice4.manifest AS
WITH rules(ordinal, definition) AS (
    VALUES
    (1, jsonb_build_object(
        'name', 'm9.blocked_to_denied',
        'definition', 'm9.blocked_source',
        'key', 'id', 'target', 'm9.denied', 'version', 1,
        'inputs', '[]'::jsonb)),
    (2, jsonb_build_object(
        'name', 'm9.seed_to_candidate',
        'definition', 'm9.seed_source',
        'key', 'id', 'target', 'm9.candidate', 'version', 1,
        'inputs', '[]'::jsonb)),
    (3, jsonb_build_object(
        'name', 'm9.candidate_to_reachable',
        'definition', 'm9.candidate_to_reachable',
        'key', 'id', 'target', 'm9.reachable', 'version', 1,
        'inputs', jsonb_build_array(jsonb_build_object(
            'relation', 'm9.candidate', 'key', 'id')))),
    (4, jsonb_build_object(
        'name', 'm9.reachable_to_candidate',
        'definition', 'm9.reachable_to_candidate',
        'key', 'id', 'target', 'm9.candidate', 'version', 1,
        'inputs', jsonb_build_array(jsonb_build_object(
            'relation', 'm9.reachable', 'key', 'id')))),
    (5, jsonb_build_object(
        'name', 'm9.reachable_unblocked',
        'definition', 'm9.reachable_unblocked',
        'key', 'id', 'target', 'm9.eligible', 'version', 1,
        'inputs', jsonb_build_array(jsonb_build_object(
            'relation', 'm9.reachable', 'key', 'id')),
        'negative_inputs', jsonb_build_array(jsonb_build_object(
            'relation', 'm9.denied', 'key', 'id')))),
    (6, jsonb_build_object(
        'name', 'm9.eligible_to_alert',
        'definition', 'm9.eligible_to_alert',
        'key', 'id', 'target', 'm9.alert', 'version', 1,
        'inputs', jsonb_build_array(jsonb_build_object(
            'relation', 'm9.eligible', 'key', 'id'))))
), program AS (
    SELECT jsonb_build_object(
        'name', 'm9.slice4', 'version', 1,
        'max_iterations', 8, 'max_facts', 4,
        'rules', jsonb_agg(definition ORDER BY CASE
            WHEN :'reverse_schedule'::boolean THEN -ordinal ELSE ordinal END)
    ) AS definition
    FROM rules
)
SELECT jsonb_build_object(
    'format_version', 1,
    'pack', 'm9-slice4-pack',
    'version', '1',
    'owner', 'owner',
    'rules', jsonb_build_array(jsonb_build_object(
        'name', 'm9.slice4.base',
        'definition', 'm9.seed_source',
        'key', 'id',
        'kind', 'CONSTRAINT',
        'depends_on', '[]'::jsonb)),
    'remove', '[]'::jsonb,
    'derived_relations', '[]'::jsonb,
    'derivations', '[]'::jsonb,
    'remove_derivations', '[]'::jsonb,
    'remove_derived_relations', '[]'::jsonb,
    'programs', jsonb_build_array(program.definition),
    'remove_programs', '[]'::jsonb
) AS definition,
jsonb_build_object(
    'roles', jsonb_build_object('owner', current_user),
    'objects', jsonb_build_object(
        'm9.seed_source', 'm9_slice4.seed_source',
        'm9.blocked_source', 'm9_slice4.blocked_source',
        'm9.candidate_to_reachable', 'm9_slice4.candidate_to_reachable',
        'm9.reachable_to_candidate', 'm9_slice4.reachable_to_candidate',
        'm9.reachable_unblocked', 'm9_slice4.reachable_unblocked',
        'm9.eligible_to_alert', 'm9_slice4.eligible_to_alert',
        'm9.denied', 'm9_slice4.a_denied',
        'm9.candidate', 'm9_slice4.b_candidate',
        'm9.reachable', 'm9_slice4.c_reachable',
        'm9.eligible', 'm9_slice4.d_eligible',
        'm9.alert', 'm9_slice4.e_alert')
) AS mappings
FROM program;

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m9_slice4.manifest),
    (SELECT mappings FROM m9_slice4.manifest)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m9_slice4.manifest), :'plan_digest',
    (SELECT mappings FROM m9_slice4.manifest));

SELECT program_version_id
FROM pgreact.derivation_programs
WHERE program_name = 'm9.slice4' AND state = 'ACTIVE' \gset
SELECT set_config('m9.slice4_program', :'program_version_id', false);
SELECT set_config(
    'm9.slice4_reverse_schedule', :'reverse_schedule', false);
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);

CREATE FUNCTION m9_slice4.normalized_state()
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
SELECT jsonb_build_object(
    'program', (
        SELECT jsonb_build_object(
            'frontier', frontier,
            'max_iterations', max_iterations,
            'max_facts', max_facts)
        FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m9.slice4_program')::uuid),
    'graph', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'rule', rule_name,
            'input_order', input_order,
            'polarity', polarity,
            'source', source_relation,
            'target', target_relation,
            'source_stratum', source_stratum,
            'target_stratum', target_stratum)
            ORDER BY target_stratum, rule_name, polarity, input_order, source_relation)
        FROM pgreact.derivation_dependency_graph
        WHERE program_version_id = current_setting('m9.slice4_program')::uuid
    ), '[]'::jsonb),
    'strata', COALESCE((
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
        WHERE program_version_id = current_setting('m9.slice4_program')::uuid
    ), '[]'::jsonb),
    'facts', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation_name,
            'key', semantic_key,
            'fact', fact,
            'support_count', support_count)
            ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts
        WHERE relation_name LIKE 'm9_slice4.%'
    ), '[]'::jsonb),
    'supports', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation.relation_name,
            'rule', rule.rule_name,
            'key', support.semantic_key,
            'fact', support.fact,
            'source_binding', support.source_binding,
            'support_frontier', support.support_frontier,
            'grounded', support.grounded,
            'active', support.active)
            ORDER BY rule.rule_name, support.semantic_key)
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = current_setting('m9.slice4_program')::uuid
         AND rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derived_relation_versions relation_version
          USING (relation_version_id)
        JOIN pgreact_internal.derived_relations relation USING (relation_id)
        WHERE support.active
    ), '[]'::jsonb),
    'support_inputs', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name,
            'key', support.semantic_key,
            'input_order', input.input_order,
            'input_relation', relation.relation_name,
            'input_key', input.semantic_key)
            ORDER BY rule.rule_name, support.semantic_key, input.input_order)
        FROM pgreact_internal.derived_support_inputs input
        JOIN pgreact_internal.derived_supports support USING (support_id)
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = current_setting('m9.slice4_program')::uuid
         AND rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derived_relation_versions relation_version
          ON relation_version.relation_version_id = input.relation_version_id
        JOIN pgreact_internal.derived_relations relation USING (relation_id)
        WHERE support.active
    ), '[]'::jsonb),
    'events', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'event', event_kind,
            'generation', generation,
            'key', (COALESCE(new_bindings, old_bindings) ->> 'id')::bigint)
            ORDER BY generation, event_kind)
        FROM pgreact_internal.lifecycle_events
        WHERE rule_version_id = current_setting('m9.slice4_observer')::uuid
    ), '[]'::jsonb),
    'sources', jsonb_build_object(
        'seed', COALESCE((
            SELECT jsonb_agg(id ORDER BY id) FROM m9_slice4.seed), '[]'::jsonb),
        'blocked', COALESCE((
            SELECT jsonb_agg(id ORDER BY id NULLS FIRST) FROM m9_slice4.blocked),
            '[]'::jsonb))
)
$$;

CREATE FUNCTION m9_slice4.expected_state(
    expected_frontier bigint,
    seeded boolean,
    blocked boolean,
    expected_events jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
SELECT jsonb_build_object(
    'program', jsonb_build_object(
        'frontier', expected_frontier,
        'max_iterations', 8,
        'max_facts', 4),
    'graph', jsonb_build_array(
        jsonb_build_object(
            'rule', 'm9.candidate_to_reachable', 'input_order', 1,
            'polarity', 'POSITIVE',
            'source', 'm9_slice4.b_candidate',
            'target', 'm9_slice4.c_reachable',
            'source_stratum', 0, 'target_stratum', 0),
        jsonb_build_object(
            'rule', 'm9.reachable_to_candidate', 'input_order', 1,
            'polarity', 'POSITIVE',
            'source', 'm9_slice4.c_reachable',
            'target', 'm9_slice4.b_candidate',
            'source_stratum', 0, 'target_stratum', 0),
        jsonb_build_object(
            'rule', 'm9.eligible_to_alert', 'input_order', 1,
            'polarity', 'POSITIVE',
            'source', 'm9_slice4.d_eligible',
            'target', 'm9_slice4.e_alert',
            'source_stratum', 1, 'target_stratum', 1),
        jsonb_build_object(
            'rule', 'm9.reachable_unblocked', 'input_order', 1,
            'polarity', 'NEGATIVE',
            'source', 'm9_slice4.a_denied',
            'target', 'm9_slice4.d_eligible',
            'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object(
            'rule', 'm9.reachable_unblocked', 'input_order', 1,
            'polarity', 'POSITIVE',
            'source', 'm9_slice4.c_reachable',
            'target', 'm9_slice4.d_eligible',
            'source_stratum', 0, 'target_stratum', 1)),
    'strata', jsonb_build_array(
        jsonb_build_object(
            'stratum', 0, 'component_order', 1, 'cyclic', false,
            'rules', jsonb_build_array('m9.blocked_to_denied'),
            'targets', jsonb_build_array('m9_slice4.a_denied'),
            'frontier', expected_frontier,
            'iterations', CASE WHEN seeded AND blocked THEN 2 ELSE 1 END,
            'fact_count', CASE WHEN seeded AND blocked THEN 1 ELSE 0 END,
            'support_count', CASE WHEN seeded AND blocked THEN 1 ELSE 0 END),
        jsonb_build_object(
            'stratum', 0, 'component_order', 2, 'cyclic', true,
            'rules', jsonb_build_array(
                'm9.candidate_to_reachable',
                'm9.reachable_to_candidate',
                'm9.seed_to_candidate'),
            'targets', jsonb_build_array(
                'm9_slice4.b_candidate', 'm9_slice4.c_reachable'),
            'frontier', expected_frontier,
            'iterations', CASE WHEN NOT seeded THEN 1
                WHEN current_setting('m9.slice4_reverse_schedule')::boolean
                THEN 4 ELSE 2 END,
            'fact_count', CASE WHEN seeded THEN 2 ELSE 0 END,
            'support_count', CASE WHEN seeded THEN 3 ELSE 0 END),
        jsonb_build_object(
            'stratum', 1, 'component_order', 3, 'cyclic', false,
            'rules', jsonb_build_array('m9.reachable_unblocked'),
            'targets', jsonb_build_array('m9_slice4.d_eligible'),
            'frontier', expected_frontier,
            'iterations', CASE WHEN seeded AND NOT blocked THEN 2 ELSE 1 END,
            'fact_count', CASE WHEN seeded AND NOT blocked THEN 1 ELSE 0 END,
            'support_count', CASE WHEN seeded AND NOT blocked THEN 1 ELSE 0 END),
        jsonb_build_object(
            'stratum', 1, 'component_order', 4, 'cyclic', false,
            'rules', jsonb_build_array('m9.eligible_to_alert'),
            'targets', jsonb_build_array('m9_slice4.e_alert'),
            'frontier', expected_frontier,
            'iterations', CASE WHEN seeded AND NOT blocked THEN 2 ELSE 1 END,
            'fact_count', CASE WHEN seeded AND NOT blocked THEN 1 ELSE 0 END,
            'support_count', CASE WHEN seeded AND NOT blocked THEN 1 ELSE 0 END)),
    'facts', CASE
        WHEN NOT seeded THEN '[]'::jsonb
        WHEN blocked THEN jsonb_build_array(
            jsonb_build_object(
                'relation', 'm9_slice4.a_denied', 'key', 7,
                'fact', jsonb_build_object('id', 7), 'support_count', 1),
            jsonb_build_object(
                'relation', 'm9_slice4.b_candidate', 'key', 7,
                'fact', jsonb_build_object('id', 7), 'support_count', 2),
            jsonb_build_object(
                'relation', 'm9_slice4.c_reachable', 'key', 7,
                'fact', jsonb_build_object('id', 7), 'support_count', 1))
        ELSE jsonb_build_array(
            jsonb_build_object(
                'relation', 'm9_slice4.b_candidate', 'key', 7,
                'fact', jsonb_build_object('id', 7), 'support_count', 2),
            jsonb_build_object(
                'relation', 'm9_slice4.c_reachable', 'key', 7,
                'fact', jsonb_build_object('id', 7), 'support_count', 1),
            jsonb_build_object(
                'relation', 'm9_slice4.d_eligible', 'key', 7,
                'fact', jsonb_build_object('id', 7), 'support_count', 1),
            jsonb_build_object(
                'relation', 'm9_slice4.e_alert', 'key', 7,
                'fact', jsonb_build_object('id', 7), 'support_count', 1))
        END,
    'supports', CASE WHEN NOT seeded THEN '[]'::jsonb ELSE
        CASE WHEN blocked THEN jsonb_build_array(jsonb_build_object(
            'relation', 'm9_slice4.a_denied',
            'rule', 'm9.blocked_to_denied', 'key', 7,
            'fact', jsonb_build_object('id', 7),
            'source_binding', jsonb_build_object('id', 7),
            'support_frontier', expected_frontier,
            'grounded', true, 'active', true)) ELSE '[]'::jsonb END ||
        jsonb_build_array(
            jsonb_build_object(
                'relation', 'm9_slice4.c_reachable',
                'rule', 'm9.candidate_to_reachable', 'key', 7,
                'fact', jsonb_build_object('id', 7),
                'source_binding', jsonb_build_object('id', 7),
                'support_frontier', expected_frontier,
                'grounded', true, 'active', true)) ||
        CASE WHEN NOT blocked THEN jsonb_build_array(
            jsonb_build_object(
                'relation', 'm9_slice4.e_alert',
                'rule', 'm9.eligible_to_alert', 'key', 7,
                'fact', jsonb_build_object('id', 7),
                'source_binding', jsonb_build_object('id', 7),
                'support_frontier', expected_frontier,
                'grounded', true, 'active', true)) ELSE '[]'::jsonb END ||
        jsonb_build_array(
            jsonb_build_object(
                'relation', 'm9_slice4.b_candidate',
                'rule', 'm9.reachable_to_candidate', 'key', 7,
                'fact', jsonb_build_object('id', 7),
                'source_binding', jsonb_build_object('id', 7),
                'support_frontier', expected_frontier,
                'grounded', true, 'active', true)) ||
        CASE WHEN NOT blocked THEN jsonb_build_array(
            jsonb_build_object(
                'relation', 'm9_slice4.d_eligible',
                'rule', 'm9.reachable_unblocked', 'key', 7,
                'fact', jsonb_build_object('id', 7),
                'source_binding', jsonb_build_object('id', 7),
                'support_frontier', expected_frontier,
                'grounded', true, 'active', true)) ELSE '[]'::jsonb END ||
        jsonb_build_array(jsonb_build_object(
            'relation', 'm9_slice4.b_candidate',
            'rule', 'm9.seed_to_candidate', 'key', 7,
            'fact', jsonb_build_object('id', 7),
            'source_binding', jsonb_build_object('id', 7),
            'support_frontier', expected_frontier,
            'grounded', true, 'active', true)) END,
    'support_inputs', CASE WHEN NOT seeded THEN '[]'::jsonb ELSE
        jsonb_build_array(jsonb_build_object(
            'rule', 'm9.candidate_to_reachable', 'key', 7,
            'input_order', 1,
            'input_relation', 'm9_slice4.b_candidate', 'input_key', 7)) ||
        CASE WHEN NOT blocked THEN jsonb_build_array(
            jsonb_build_object(
                'rule', 'm9.eligible_to_alert', 'key', 7,
                'input_order', 1,
                'input_relation', 'm9_slice4.d_eligible', 'input_key', 7))
            ELSE '[]'::jsonb END ||
        jsonb_build_array(jsonb_build_object(
            'rule', 'm9.reachable_to_candidate', 'key', 7,
            'input_order', 1,
            'input_relation', 'm9_slice4.c_reachable', 'input_key', 7)) ||
        CASE WHEN NOT blocked THEN jsonb_build_array(
            jsonb_build_object(
                'rule', 'm9.reachable_unblocked', 'key', 7,
                'input_order', 1,
                'input_relation', 'm9_slice4.c_reachable', 'input_key', 7))
            ELSE '[]'::jsonb END END,
    'events', expected_events,
    'sources', jsonb_build_object(
        'seed', CASE WHEN seeded THEN jsonb_build_array(7) ELSE '[]'::jsonb END,
        'blocked', CASE WHEN blocked THEN jsonb_build_array(NULL, 7)
                        ELSE jsonb_build_array(NULL) END)
)
$$;

CREATE FUNCTION m9_slice4.assert_state(stage text, expected jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE actual jsonb := m9_slice4.normalized_state();
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 slice 4 % state changed: %', stage, actual;
    END IF;
END
$$;

SELECT m9_slice4.assert_state(
    'frontier 1',
    m9_slice4.expected_state(1, true, false,
        jsonb_build_array(jsonb_build_object(
            'event', 'ACTIVATE', 'generation', 1, 'key', 7))));

CREATE TEMP TABLE m9_slice4_frontier_1 AS
SELECT m9_slice4.normalized_state() AS state;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 1 AS noop \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :noop
\else
  SELECT 1 / 0;
\endif
DO $$
BEGIN
    IF m9_slice4.normalized_state() IS DISTINCT FROM
       (SELECT state FROM m9_slice4_frontier_1) THEN
        RAISE EXCEPTION 'M9 slice 4 repeated refresh changed frontier 1';
    END IF;
END
$$;

INSERT INTO m9_slice4.blocked VALUES (7);
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 2 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice4.assert_state(
    'frontier 2 blocked',
    m9_slice4.expected_state(2, true, true,
        jsonb_build_array(
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 1, 'key', 7))));

DELETE FROM m9_slice4.blocked WHERE id = 7;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 3 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice4.assert_state(
    'frontier 3 restored',
    m9_slice4.expected_state(3, true, false,
        jsonb_build_array(
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 2, 'key', 7))));

DELETE FROM m9_slice4.seed WHERE id = 7;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 4 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice4.assert_state(
    'frontier 4 ungrounded cycle',
    m9_slice4.expected_state(4, false, false,
        jsonb_build_array(
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 2, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 2, 'key', 7))));

INSERT INTO m9_slice4.seed VALUES (7);
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 5 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice4.assert_state(
    'frontier 5 regrounded',
    m9_slice4.expected_state(5, true, false,
        jsonb_build_array(
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 2, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 2, 'key', 7),
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 3, 'key', 7))));

INSERT INTO m9_slice4.blocked VALUES (7);
CREATE TEMP TABLE m9_slice4_before_injected_failure AS
SELECT m9_slice4.normalized_state() AS state;
DO $$
DECLARE result bigint;
BEGIN
    PERFORM set_config(
        'pgreact.test_fail_program_phase', 'after_iteration', true);
    result := pgreact.refresh_derivation_program(
        current_setting('m9.slice4_program')::uuid);
    IF result IS NOT NULL THEN
        RAISE EXCEPTION 'M9 slice 4 injected refresh returned %', result;
    END IF;
END
$$;
DO $$
DECLARE failed_run jsonb;
BEGIN
    IF m9_slice4.normalized_state() IS DISTINCT FROM
       (SELECT state FROM m9_slice4_before_injected_failure) THEN
        RAISE EXCEPTION 'M9 slice 4 failure exposed partial strata: %',
            m9_slice4.normalized_state();
    END IF;
    SELECT jsonb_build_object(
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations,
        'fact_count', fact_count,
        'support_count', support_count,
        'status', status,
        'error_sqlstate', error_sqlstate,
        'error_message', error_message,
        'error_detail', error_detail,
        'error_hint', error_hint,
        'requested_by', requested_by)
    INTO failed_run
    FROM pgreact.derivation_program_runs
    WHERE program_version_id = current_setting('m9.slice4_program')::uuid
      AND status = 'FAILED'
    ORDER BY run_id DESC LIMIT 1;
    IF failed_run IS DISTINCT FROM jsonb_build_object(
        'prior_frontier', 5,
        'committed_frontier', 5,
        'iterations', 0,
        'fact_count', NULL,
        'support_count', NULL,
        'status', 'FAILED',
        'error_sqlstate', 'P0001',
        'error_message',
            'injected derivation-program failure after after_iteration phase',
        'error_detail', NULL,
        'error_hint', NULL,
        'requested_by', current_user) THEN
        RAISE EXCEPTION 'M9 slice 4 injected FAILED run changed: %', failed_run;
    END IF;
END
$$;

SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 6 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
DELETE FROM m9_slice4.blocked WHERE id = 7;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 7 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice4.assert_state(
    'frontier 7 after retry',
    m9_slice4.expected_state(7, true, false,
        jsonb_build_array(
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 1, 'key', 7),
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 2, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 2, 'key', 7),
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 3, 'key', 7),
            jsonb_build_object(
                'event', 'DEACTIVATE', 'generation', 3, 'key', 7),
            jsonb_build_object(
                'event', 'ACTIVATE', 'generation', 4, 'key', 7))));

UPDATE pgreact_internal.derivation_program_versions
SET max_iterations = 1
WHERE program_version_id = current_setting('m9.slice4_program')::uuid;
INSERT INTO m9_slice4.blocked VALUES (7);
CREATE TEMP TABLE m9_slice4_before_resource_failure AS
SELECT m9_slice4.normalized_state() AS state;
DO $$
DECLARE result bigint;
BEGIN
    result := pgreact.refresh_derivation_program(
        current_setting('m9.slice4_program')::uuid);
    IF result IS NOT NULL THEN
        RAISE EXCEPTION 'M9 slice 4 resource-limited refresh returned %', result;
    END IF;
END
$$;
DO $$
DECLARE failed_run jsonb;
BEGIN
    IF m9_slice4.normalized_state() IS DISTINCT FROM
       (SELECT state FROM m9_slice4_before_resource_failure) THEN
        RAISE EXCEPTION 'M9 slice 4 resource failure changed prior state: %',
            m9_slice4.normalized_state();
    END IF;
    SELECT jsonb_build_object(
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations,
        'fact_count', fact_count,
        'support_count', support_count,
        'status', status,
        'error_sqlstate', error_sqlstate,
        'error_message', error_message,
        'error_detail', error_detail,
        'error_hint', error_hint,
        'requested_by', requested_by)
    INTO failed_run
    FROM pgreact.derivation_program_runs
    WHERE program_version_id = current_setting('m9.slice4_program')::uuid
      AND status = 'FAILED'
    ORDER BY run_id DESC LIMIT 1;
    IF failed_run IS DISTINCT FROM jsonb_build_object(
        'prior_frontier', 7,
        'committed_frontier', 7,
        'iterations', 0,
        'fact_count', NULL,
        'support_count', NULL,
        'status', 'FAILED',
        'error_sqlstate', 'P0001',
        'error_message', format(
            'derivation program %s component %s did not converge within 1 iterations',
            current_setting('m9.slice4_program'),
            (SELECT component_id
             FROM pgreact.derivation_strata
             WHERE program_version_id =
                       current_setting('m9.slice4_program')::uuid
               AND rule_names = ARRAY['m9.blocked_to_denied'])),
        'error_detail', NULL,
        'error_hint', NULL,
        'requested_by', current_user) THEN
        RAISE EXCEPTION 'M9 slice 4 resource FAILED run changed: %', failed_run;
    END IF;
END
$$;

DELETE FROM m9_slice4.blocked WHERE id = 7;
UPDATE pgreact_internal.derivation_program_versions
SET max_iterations = 8
WHERE program_version_id = current_setting('m9.slice4_program')::uuid;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice4_program')::uuid) = 7 AS noop \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice4_observer')::uuid);
\if :noop
\else
  SELECT 1 / 0;
\endif

\o
WITH state AS (
    SELECT m9_slice4.normalized_state() AS value
), strata AS (
    SELECT jsonb_agg(item - 'iterations' ORDER BY ordinal) AS value
    FROM state, jsonb_array_elements(value -> 'strata')
        WITH ORDINALITY items(item, ordinal)
)
SELECT jsonb_set(state.value, '{strata}', strata.value)::text
FROM state, strata;
SELECT 'M9 slice 4 stratified fixed-point gate passed' AS result;
