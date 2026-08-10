\set ON_ERROR_STOP on
\ir /tmp/m8-setup.sql

CREATE FUNCTION m8_ref.normalized_state()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_build_object(
    'program', (SELECT jsonb_build_object(
        'name', program_name || '@' || program_version,
        'state', state, 'frontier', frontier,
        'max_iterations', max_iterations, 'max_facts', max_facts)
        FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m8.program')::uuid),
    'components', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'relations', format('[%s]', (SELECT string_agg(
            upper(regexp_replace(regexp_replace(name, '^.*\.', ''), '@.*$', '')),
            ',' ORDER BY name)
            FROM unnest(c.target_relations) AS name)),
        'frontier', c.frontier) ORDER BY c.component_order)
        FROM pgreact.derivation_components c
        WHERE c.program_version_id = current_setting('m8.program')::uuid), '[]'::jsonb),
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

CREATE FUNCTION m8_ref.expected_state(
    expected_frontier bigint, expected_a_supports integer,
    has_facts boolean, expected_events jsonb
) RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $$
SELECT jsonb_build_object(
    'program', jsonb_build_object(
        'name', 'm8.reference@1', 'state', 'ACTIVE',
        'frontier', expected_frontier, 'max_iterations', 16, 'max_facts', 64),
    'components', jsonb_build_array(
        jsonb_build_object('relations', '[A]', 'frontier', expected_frontier),
        jsonb_build_object('relations', '[B]', 'frontier', expected_frontier),
        jsonb_build_object('relations', '[C,D]', 'frontier', expected_frontier)),
    'facts', CASE WHEN has_facts THEN jsonb_build_array('A(7)', 'B(7)', 'C(7)', 'D(7)')
                  ELSE '[]'::jsonb END,
    'support_counts', CASE WHEN has_facts THEN jsonb_build_array(
        format('A(7)=%s', expected_a_supports), 'B(7)=1', 'C(7)=3', 'D(7)=1')
        ELSE '[]'::jsonb END,
    'events', expected_events
)
$$;

CREATE FUNCTION m8_ref.expected_explanation(expected_frontier bigint, include_left boolean)
RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $$
WITH a AS (
    SELECT jsonb_build_object(
        'relation', 'm8_ref.a@1', 'fact', jsonb_build_object('id', 7),
        'supports', (CASE WHEN include_left THEN jsonb_build_array(jsonb_build_object(
            'rule', 'm8.left_to_a@1', 'source_binding', jsonb_build_object('id', 7),
            'inputs', '[]'::jsonb)) ELSE '[]'::jsonb END) ||
            jsonb_build_array(jsonb_build_object(
                'rule', 'm8.right_to_a@1', 'source_binding', jsonb_build_object('id', 7),
                'inputs', '[]'::jsonb))) AS value
), b AS (
    SELECT jsonb_build_object(
        'relation', 'm8_ref.b@1', 'fact', jsonb_build_object('id', 7),
        'supports', jsonb_build_array(jsonb_build_object(
            'rule', 'm8.a_to_b@1', 'source_binding', jsonb_build_object('id', 7),
            'inputs', jsonb_build_array(value)))) AS value FROM a
), d AS (
    SELECT jsonb_build_object(
        'relation', 'm8_ref.d@1', 'fact', jsonb_build_object('id', 7),
        'supports', jsonb_build_array(jsonb_build_object(
            'rule', 'm8.c_to_d@1', 'source_binding', jsonb_build_object('id', 7),
            'inputs', jsonb_build_array(jsonb_build_object(
                'cycle', true, 'relation', 'm8_ref.c@1', 'semantic_key', 7))))) AS value
), proof AS (
    SELECT jsonb_build_object(
        'relation', 'm8_ref.c@1', 'fact', jsonb_build_object('id', 7),
        'supports', jsonb_build_array(
            jsonb_build_object(
                'rule', 'm8.a_to_c@1', 'source_binding', jsonb_build_object('id', 7),
                'inputs', jsonb_build_array(a.value)),
            jsonb_build_object(
                'rule', 'm8.b_to_c@1', 'source_binding', jsonb_build_object('id', 7),
                'inputs', jsonb_build_array(b.value)),
            jsonb_build_object(
                'rule', 'm8.d_to_c@1', 'source_binding', jsonb_build_object('id', 7),
                'inputs', jsonb_build_array(d.value)))) AS value
    FROM a, b, d
)
SELECT jsonb_build_object(
    'program', 'm8.reference@1', 'frontier', expected_frontier,
    'relation', 'm8_ref.c@1', 'fact', jsonb_build_object('id', 7), 'proof', value)
FROM proof
$$;

CREATE FUNCTION m8_ref.normalized_explanation(value jsonb)
RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $$
SELECT $1
    #- '{proof,supports,0,logical_support_id}'
    #- '{proof,supports,0,negative_checks}'
    #- '{proof,supports,1,logical_support_id}'
    #- '{proof,supports,1,negative_checks}'
    #- '{proof,supports,2,logical_support_id}'
    #- '{proof,supports,2,negative_checks}'
    #- '{proof,supports,0,inputs,0,supports,0,logical_support_id}'
    #- '{proof,supports,0,inputs,0,supports,0,negative_checks}'
    #- '{proof,supports,0,inputs,0,supports,1,logical_support_id}'
    #- '{proof,supports,0,inputs,0,supports,1,negative_checks}'
    #- '{proof,supports,1,inputs,0,supports,0,logical_support_id}'
    #- '{proof,supports,1,inputs,0,supports,0,negative_checks}'
    #- '{proof,supports,1,inputs,0,supports,0,inputs,0,supports,0,logical_support_id}'
    #- '{proof,supports,1,inputs,0,supports,0,inputs,0,supports,0,negative_checks}'
    #- '{proof,supports,1,inputs,0,supports,0,inputs,0,supports,1,logical_support_id}'
    #- '{proof,supports,1,inputs,0,supports,0,inputs,0,supports,1,negative_checks}'
    #- '{proof,supports,2,inputs,0,supports,0,logical_support_id}'
    #- '{proof,supports,2,inputs,0,supports,0,negative_checks}'
$$;

SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
DO $$
DECLARE actual jsonb;
BEGIN
    actual := m8_ref.normalized_state();
    IF actual IS DISTINCT FROM m8_ref.expected_state(1, 2, true,
        jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'generation', 1))) THEN
        RAISE EXCEPTION 'V1 frontier 1 changed: %', actual;
    END IF;
    actual := m8_ref.normalized_explanation(pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7));
    IF actual IS DISTINCT FROM m8_ref.expected_explanation(1, true) THEN
        RAISE EXCEPTION 'V1 frontier 1 explanation changed: %', actual;
    END IF;
END $$;

DELETE FROM m8_ref.left_seed WHERE id = 7;
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 2 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
DO $$
DECLARE actual jsonb;
BEGIN
    actual := m8_ref.normalized_state();
    IF actual IS DISTINCT FROM m8_ref.expected_state(2, 1, true,
        jsonb_build_array(jsonb_build_object('event', 'ACTIVATE', 'generation', 1))) THEN
        RAISE EXCEPTION 'V1 frontier 2 changed: %', actual;
    END IF;
    actual := m8_ref.normalized_explanation(pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7));
    IF actual IS DISTINCT FROM m8_ref.expected_explanation(2, false) THEN
        RAISE EXCEPTION 'V1 frontier 2 explanation changed: %', actual;
    END IF;
END $$;

DELETE FROM m8_ref.right_seed WHERE id = 7;
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 3 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
DO $$
DECLARE actual jsonb;
BEGIN
    actual := m8_ref.normalized_state();
    IF actual IS DISTINCT FROM m8_ref.expected_state(3, 0, false,
        jsonb_build_array(
            jsonb_build_object('event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('event', 'DEACTIVATE', 'generation', 1))) THEN
        RAISE EXCEPTION 'V1 frontier 3 changed: %', actual;
    END IF;
    IF pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7) IS NOT NULL THEN
        RAISE EXCEPTION 'ungrounded cycle remained explainable';
    END IF;
END $$;

CREATE TEMP TABLE frontier_3 AS SELECT m8_ref.normalized_state() AS state;
INSERT INTO m8_ref.right_seed VALUES (7);
DO $$
DECLARE result bigint;
BEGIN
    PERFORM set_config('pgreact.test_fail_program_phase', 'after_iteration', true);
    result := pgreact.refresh_derivation_program(current_setting('m8.program')::uuid);
    IF result IS NOT NULL THEN
        RAISE EXCEPTION 'injected program refresh unexpectedly returned %', result;
    END IF;
END $$;
DO $$
DECLARE actual jsonb; failed_runs jsonb;
BEGIN
    actual := m8_ref.normalized_state();
    IF actual IS DISTINCT FROM (SELECT state FROM frontier_3) THEN
        RAISE EXCEPTION 'failed convergence exposed partial state: %', actual;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations, 'fact_count', fact_count,
        'support_count', support_count, 'status', status,
        'error_sqlstate', error_sqlstate, 'error_message', error_message,
        'error_detail', error_detail, 'error_hint', error_hint,
        'requested_by', requested_by) ORDER BY run_id)
    INTO failed_runs
    FROM pgreact_internal.derivation_program_runs
    WHERE program_version_id = current_setting('m8.program')::uuid
      AND status = 'FAILED';
    IF failed_runs IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'prior_frontier', 3, 'committed_frontier', 3,
        'iterations', 0, 'fact_count', NULL, 'support_count', NULL,
        'status', 'FAILED', 'error_sqlstate', 'P0001',
        'error_message', 'injected derivation-program failure after after_iteration phase',
        'error_detail', NULL, 'error_hint', NULL,
        'requested_by', current_user)) THEN
        RAISE EXCEPTION 'injected refresh FAILED run changed: %', failed_runs;
    END IF;
END $$;

SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 4 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
DO $$
DECLARE actual jsonb;
BEGIN
    actual := m8_ref.normalized_state();
    IF actual IS DISTINCT FROM m8_ref.expected_state(4, 1, true,
        jsonb_build_array(
            jsonb_build_object('event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object('event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object('event', 'ACTIVATE', 'generation', 2))) THEN
        RAISE EXCEPTION 'V1 frontier 4 changed: %', actual;
    END IF;
    actual := m8_ref.normalized_explanation(pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7));
    IF actual IS DISTINCT FROM m8_ref.expected_explanation(4, false) THEN
        RAISE EXCEPTION 'V1 frontier 4 explanation changed: %', actual;
    END IF;
END $$;

CREATE TEMP TABLE frontier_4 AS SELECT m8_ref.normalized_state() AS state;
CREATE FUNCTION m8_ref.logical_support_identities()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT COALESCE(jsonb_object_agg(
    format('%s(%s)', r.rule_name, s.semantic_key), s.logical_support_id
    ORDER BY r.rule_name, s.semantic_key), '{}'::jsonb)
FROM pgreact_internal.derived_supports s
JOIN pgreact_internal.derivation_program_rules r
  ON r.program_version_id = current_setting('m8.program')::uuid
 AND r.rule_version_id = s.rule_version_id
WHERE s.active
$$;
CREATE TEMP TABLE frontier_4_support_identities AS
SELECT m8_ref.logical_support_identities() AS identities;
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 4 AS noop \gset
SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
\if :noop
\else
  SELECT 1 / 0;
\endif
DO $$
BEGIN
    IF m8_ref.normalized_state() IS DISTINCT FROM (SELECT state FROM frontier_4) THEN
        RAISE EXCEPTION 'no-op refresh changed V1 frontier 4';
    END IF;
    IF m8_ref.logical_support_identities() IS DISTINCT FROM
       (SELECT identities FROM frontier_4_support_identities) THEN
        RAISE EXCEPTION 'no-op refresh changed logical support identities: %',
            m8_ref.logical_support_identities();
    END IF;
END $$;

CREATE FUNCTION m8_ref.normalized_recursive_state()
RETURNS jsonb LANGUAGE SQL STABLE AS $$
SELECT jsonb_build_object(
    'state', m8_ref.normalized_state(),
    'fact_frontiers', (SELECT jsonb_agg(jsonb_build_object(
        'relation', relation_name, 'semantic_key', semantic_key,
        'first_frontier', first_frontier, 'last_frontier', last_frontier)
        ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts
        WHERE relation_name IN ('m8_ref.a', 'm8_ref.b', 'm8_ref.c', 'm8_ref.d')),
    'active_supports', (SELECT jsonb_agg(jsonb_build_object(
        'rule', r.rule_name, 'logical_support_id', s.logical_support_id,
        'semantic_key', s.semantic_key, 'fact', s.fact,
        'source_binding', s.source_binding, 'grounded', s.grounded,
        'first_frontier', s.first_frontier, 'last_frontier', s.last_frontier,
        'support_frontier', s.support_frontier)
        ORDER BY r.rule_name, s.logical_support_id)
        FROM pgreact_internal.derived_supports s
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = current_setting('m8.program')::uuid
         AND r.rule_version_id = s.rule_version_id
        WHERE s.active),
    'input_edges', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'support_id', s.logical_support_id, 'order', i.input_order,
        'relation_version_id', i.relation_version_id,
        'semantic_key', i.semantic_key, 'fact_id', i.fact_id)
        ORDER BY s.logical_support_id, i.input_order)
        FROM pgreact_internal.derived_support_inputs i
        JOIN pgreact_internal.derived_supports s USING (support_id)
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = current_setting('m8.program')::uuid
         AND r.rule_version_id = s.rule_version_id
        WHERE s.active), '[]'::jsonb),
    'explanation', m8_ref.normalized_explanation(pgreact.explain_recursive_fact(
        current_setting('m8.program')::uuid,
        (SELECT relation_version_id FROM pgreact.derived_relations
         WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE'), 7))
)
$$;
CREATE TEMP TABLE clean_frontier_4 AS SELECT m8_ref.normalized_recursive_state() AS state;

DELETE FROM pgreact_internal.derived_supports s
USING pgreact_internal.derivation_program_rules r
WHERE r.program_version_id = current_setting('m8.program')::uuid
  AND r.rule_version_id = s.rule_version_id
  AND r.rule_name = 'm8.right_to_a' AND s.active;
INSERT INTO pgreact_internal.derived_supports (
    support_id, logical_support_id, relation_version_id, rule_version_id,
    activation_id, activation_generation, activation_revision, semantic_key,
    fact_id, fact, source_binding, active, first_frontier, last_frontier,
    created_at, invalidated_at, program_version_id, grounded, support_frontier
)
SELECT 'ffffffff-ffff-4fff-8fff-fffffffffff1'::uuid,
       'ffffffff-ffff-4fff-8fff-fffffffffff2'::uuid,
       s.relation_version_id, s.rule_version_id,
       'ffffffff-ffff-4fff-8fff-fffffffffff3'::uuid,
       s.activation_generation, s.activation_revision, s.semantic_key,
       s.fact_id, s.fact, s.source_binding, true, s.first_frontier, NULL,
       clock_timestamp(), NULL, s.program_version_id, false, s.support_frontier
FROM pgreact_internal.derived_supports s
JOIN pgreact_internal.derivation_program_rules r
  ON r.program_version_id = current_setting('m8.program')::uuid
 AND r.rule_version_id = s.rule_version_id
WHERE r.rule_name = 'm8.a_to_b' AND s.active;
INSERT INTO pgreact_internal.derived_support_inputs (
    support_id, input_order, relation_version_id, semantic_key, fact_id
)
SELECT 'ffffffff-ffff-4fff-8fff-fffffffffff1'::uuid,
       i.input_order, i.relation_version_id, i.semantic_key, i.fact_id
FROM pgreact_internal.derived_support_inputs i
JOIN pgreact_internal.derived_supports s USING (support_id)
JOIN pgreact_internal.derivation_program_rules r
  ON r.program_version_id = current_setting('m8.program')::uuid
 AND r.rule_version_id = s.rule_version_id
WHERE r.rule_name = 'm8.a_to_b' AND s.active
  AND s.support_id <> 'ffffffff-ffff-4fff-8fff-fffffffffff1'::uuid;
UPDATE pgreact_internal.derived_supports s
SET source_binding = jsonb_build_object('id', 8)
FROM pgreact_internal.derivation_program_rules r
WHERE r.program_version_id = current_setting('m8.program')::uuid
  AND r.rule_version_id = s.rule_version_id
  AND r.rule_name = 'm8.a_to_c' AND s.active;
UPDATE pgreact_internal.derived_supports s
SET support_frontier = 99
FROM pgreact_internal.derivation_program_rules r
WHERE r.program_version_id = current_setting('m8.program')::uuid
  AND r.rule_version_id = s.rule_version_id
  AND r.rule_name = 'm8.b_to_c' AND s.active;
UPDATE pgreact_internal.derived_facts
SET support_count = 99
WHERE relation_version_id = (
    SELECT relation_version_id FROM pgreact.derived_relations
    WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE') AND semantic_key = 7;
DELETE FROM pgreact_internal.derived_facts
WHERE relation_version_id = (
    SELECT relation_version_id FROM pgreact.derived_relations
    WHERE relation_name = 'm8_ref.d' AND state = 'ACTIVE') AND semantic_key = 7;
INSERT INTO pgreact_internal.derived_facts (
    relation_version_id, fact_id, semantic_key, fact, support_count,
    first_frontier, last_frontier
)
SELECT relation_version_id,
       pgreact_internal.activation_uuid(pgreact_internal.activation_digest(
           relation_version_id, pgreact_internal.canonical_bigint_v1(99))),
       99, jsonb_build_object('id', 99), 1, 4, 4
FROM pgreact.derived_relations
WHERE relation_name = 'm8_ref.a' AND state = 'ACTIVE';

SELECT pgreact.reconcile_derivation_program(current_setting('m8.program')::uuid) AS repairs \gset
DO $$
DECLARE actual jsonb; codes text[];
BEGIN
    IF m8_ref.normalized_recursive_state() IS DISTINCT FROM
       (SELECT state FROM clean_frontier_4) THEN
        RAISE EXCEPTION 'M8 reconciliation did not restore exact frontier 4: %',
            m8_ref.normalized_recursive_state();
    END IF;
    SELECT array_agg(code ORDER BY code, diagnostic_order) INTO codes
    FROM pgreact.derivation_program_repair_diagnostics
    WHERE reconciliation_id = (
        SELECT max(reconciliation_id)
        FROM pgreact.derivation_program_repair_diagnostics);
    IF codes IS DISTINCT FROM ARRAY[
        'CIRCULAR_ONLY', 'CIRCULAR_ONLY', 'CIRCULAR_ONLY', 'CIRCULAR_ONLY',
        'EXTRA_FACT', 'EXTRA_FACT', 'EXTRA_SUPPORT', 'MISSING_FACT',
        'MISSING_SUPPORT', 'STALE_FACT', 'STALE_FACT', 'STALE_SUPPORT',
        'WRONG_FRONTIER'
    ] THEN
        RAISE EXCEPTION 'M8 repair diagnostics changed: %', codes;
    END IF;
END $$;

SELECT pgreact.reconcile_derivation_program(current_setting('m8.program')::uuid) = 0
       AS second_reconcile_noop \gset
\if :second_reconcile_noop
\else
  SELECT 1 / 0;
\endif
DO $$
DECLARE diagnostics jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(d) ORDER BY diagnostic_order), '[]'::jsonb)
    INTO diagnostics
    FROM pgreact.derivation_program_repair_diagnostics d
    WHERE reconciliation_id = (
        SELECT max(reconciliation_id)
        FROM pgreact_internal.derivation_program_reconciliations);
    IF diagnostics IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'second M8 reconciliation recorded diagnostics: %', diagnostics;
    END IF;
END $$;

SELECT 'M8 exact recursive lifecycle, grounded cycle, rollback, downstream, and no-op checks passed' AS result;
