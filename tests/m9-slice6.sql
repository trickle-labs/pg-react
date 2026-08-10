\set ON_ERROR_STOP on

CREATE SCHEMA m9_slice6;

SELECT program_version_id
FROM pgreact.derivation_programs
WHERE program_name = 'm9.slice4' AND state = 'ACTIVE' \gset
SELECT set_config('m9.slice6_program', :'program_version_id', false);

CREATE FUNCTION m9_slice6.expected_evidence_id(frontier_program uuid)
RETURNS uuid
LANGUAGE SQL
STABLE
AS $$
SELECT pgreact_internal.activation_uuid(sha256(convert_to(
           frontier_program::text || ':' || rule.rule_version_id::text || ':1:7',
           'UTF8')))
FROM pgreact_internal.derivation_program_rules rule
WHERE rule.program_version_id = frontier_program
  AND rule.rule_name = 'm9.reachable_unblocked'
$$;

CREATE FUNCTION m9_slice6.expected_explanation(
    evidence_id uuid,
    expected_frontier bigint
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $$
WITH candidate AS (
    SELECT jsonb_build_object(
        'relation', 'm9_slice4.b_candidate@1',
        'fact', jsonb_build_object('id', 7),
        'supports', jsonb_build_array(
            jsonb_build_object(
                'rule', 'm9.reachable_to_candidate@1',
                'source_binding', jsonb_build_object('id', 7),
                'inputs', jsonb_build_array(jsonb_build_object(
                    'cycle', true,
                    'relation', 'm9_slice4.c_reachable@1',
                    'semantic_key', 7)),
                'negative_checks', '[]'::jsonb),
            jsonb_build_object(
                'rule', 'm9.seed_to_candidate@1',
                'source_binding', jsonb_build_object('id', 7),
                'inputs', '[]'::jsonb,
                'negative_checks', '[]'::jsonb))) AS value
), reachable AS (
    SELECT jsonb_build_object(
        'relation', 'm9_slice4.c_reachable@1',
        'fact', jsonb_build_object('id', 7),
        'supports', jsonb_build_array(jsonb_build_object(
            'rule', 'm9.candidate_to_reachable@1',
            'source_binding', jsonb_build_object('id', 7),
            'inputs', jsonb_build_array(candidate.value),
            'negative_checks', '[]'::jsonb))) AS value
    FROM candidate
), eligible AS (
    SELECT jsonb_build_object(
        'relation', 'm9_slice4.d_eligible@1',
        'fact', jsonb_build_object('id', 7),
        'supports', jsonb_build_array(jsonb_build_object(
            'rule', 'm9.reachable_unblocked@1',
            'source_binding', jsonb_build_object('id', 7),
            'inputs', jsonb_build_array(reachable.value),
            'negative_checks', jsonb_build_array(jsonb_build_object(
                'evidence_id', evidence_id,
                'relation', 'm9_slice4.a_denied',
                'semantic_key', 7,
                'source_stratum', 0,
                'lower_frontier', expected_frontier))))) AS value
    FROM reachable
), alert AS (
    SELECT jsonb_build_object(
        'relation', 'm9_slice4.e_alert@1',
        'fact', jsonb_build_object('id', 7),
        'supports', jsonb_build_array(jsonb_build_object(
            'rule', 'm9.eligible_to_alert@1',
            'source_binding', jsonb_build_object('id', 7),
            'inputs', jsonb_build_array(eligible.value),
            'negative_checks', '[]'::jsonb))) AS value
    FROM eligible
)
SELECT jsonb_build_object(
    'program', 'm9.slice4@1',
    'frontier', expected_frontier,
    'relation', 'm9_slice4.e_alert@1',
    'fact', jsonb_build_object('id', 7),
    'proof', alert.value)
FROM alert
$$;

CREATE FUNCTION m9_slice6.current_state()
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
SELECT jsonb_build_object(
    'strata', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'stratum', stratum,
            'component_order', component_order,
            'frontier', frontier)
            ORDER BY component_order)
        FROM pgreact.derivation_strata
        WHERE program_version_id = current_setting('m9.slice6_program')::uuid
    ), '[]'::jsonb),
    'facts', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation_name,
            'semantic_key', semantic_key,
            'fact', fact,
            'support_count', support_count)
            ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts
        WHERE relation_name LIKE 'm9_slice4.%'
    ), '[]'::jsonb),
    'supports', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name,
            'semantic_key', support.semantic_key,
            'fact', support.fact,
            'source_binding', support.source_binding,
            'support_frontier', support.support_frontier,
            'grounded', support.grounded)
            ORDER BY rule.rule_name, support.semantic_key)
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = current_setting('m9.slice6_program')::uuid
         AND rule.rule_version_id = support.rule_version_id
        WHERE support.active
    ), '[]'::jsonb),
    'evidence', COALESCE((
        SELECT jsonb_agg(
            to_jsonb(evidence) - 'program_version_id' - 'rule_version_id' - 'support_id'
            ORDER BY evidence_id)
        FROM pgreact.negative_dependency_evidence evidence
        WHERE program_version_id = current_setting('m9.slice6_program')::uuid
    ), '[]'::jsonb),
    'explanation', pgreact.explain_recursive_fact(
        current_setting('m9.slice6_program')::uuid,
        (SELECT relation_version_id
         FROM pgreact.derived_relations
         WHERE relation_name = 'm9_slice4.e_alert' AND state = 'ACTIVE'),
        7)
)
$$;

DO $$
DECLARE
    target_program uuid := current_setting('m9.slice6_program')::uuid;
    expected_id uuid := m9_slice6.expected_evidence_id(target_program);
    actual jsonb;
    expected jsonb;
BEGIN
    actual := pgreact.explain_recursive_fact(
        target_program,
        (SELECT relation_version_id
         FROM pgreact.derived_relations
         WHERE relation_name = 'm9_slice4.e_alert' AND state = 'ACTIVE'),
        7);
    expected := m9_slice6.expected_explanation(expected_id, 7);
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 slice 6 frontier 7 explanation changed: %', actual;
    END IF;

    SELECT to_jsonb(evidence) INTO STRICT actual
    FROM pgreact.negative_dependency_evidence evidence
    WHERE evidence.program_version_id = target_program;
    SELECT jsonb_build_object(
        'evidence_id', expected_id,
        'program_version_id', target_program,
        'program_name', 'm9.slice4',
        'program_version', 1,
        'rule_version_id', rule.rule_version_id,
        'rule_name', 'm9.reachable_unblocked',
        'input_order', 1,
        'support_id', support.support_id,
        'semantic_key', 7,
        'checked_relation', 'm9_slice4.a_denied',
        'source_stratum', 0,
        'target_stratum', 1,
        'lower_frontier', 7)
    INTO STRICT expected
    FROM pgreact_internal.derivation_program_rules rule
    JOIN pgreact_internal.derived_supports support
      ON support.rule_version_id = rule.rule_version_id AND support.active
    WHERE rule.program_version_id = target_program
      AND rule.rule_name = 'm9.reachable_unblocked';
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 slice 6 public evidence changed: %', actual;
    END IF;
END
$$;

INSERT INTO m9_slice4.blocked VALUES (7);
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice6_program')::uuid) = 8 AS frontier_ok \gset
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif

DO $$
DECLARE
    target_program uuid := current_setting('m9.slice6_program')::uuid;
    actual jsonb;
BEGIN
    IF pgreact.explain_recursive_fact(
        target_program,
        (SELECT relation_version_id
         FROM pgreact.derived_relations
         WHERE relation_name = 'm9_slice4.e_alert' AND state = 'ACTIVE'),
        7) IS NOT NULL THEN
        RAISE EXCEPTION 'M9 slice 6 blocked fact remained explainable';
    END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(evidence)), '[]'::jsonb)
    INTO actual
    FROM pgreact.negative_dependency_evidence evidence
    WHERE evidence.program_version_id = target_program;
    IF actual IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'M9 slice 6 blocked evidence remained public: %', actual;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'evidence_id', evidence_id,
        'active', active,
        'lower_frontier', lower_frontier,
        'invalidated', invalidated_at IS NOT NULL))
    INTO STRICT actual
    FROM pgreact_internal.negative_dependency_evidence
    WHERE program_version_id = target_program;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'evidence_id', m9_slice6.expected_evidence_id(target_program),
        'active', false,
        'lower_frontier', 7,
        'invalidated', true)) THEN
        RAISE EXCEPTION 'M9 slice 6 evidence invalidation changed: %', actual;
    END IF;
END
$$;

SELECT pgreact.reconcile_derivation_program(
    current_setting('m9.slice6_program')::uuid) = 0 AS blocked_reconcile_noop \gset
\if :blocked_reconcile_noop
\else
  SELECT 1 / 0;
\endif

DELETE FROM m9_slice4.blocked WHERE id = 7;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice6_program')::uuid) = 9 AS frontier_ok \gset
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif

DO $$
DECLARE
    target_program uuid := current_setting('m9.slice6_program')::uuid;
    actual jsonb;
BEGIN
    actual := pgreact.explain_recursive_fact(
        target_program,
        (SELECT relation_version_id
         FROM pgreact.derived_relations
         WHERE relation_name = 'm9_slice4.e_alert' AND state = 'ACTIVE'),
        7);
    IF actual IS DISTINCT FROM m9_slice6.expected_explanation(
        m9_slice6.expected_evidence_id(target_program), 9) THEN
        RAISE EXCEPTION 'M9 slice 6 restored explanation changed: %', actual;
    END IF;
END
$$;

CREATE TEMP TABLE m9_slice6_clean AS
SELECT m9_slice6.current_state() AS state;

UPDATE pgreact_internal.negative_dependency_evidence
SET active = false, invalidated_at = clock_timestamp()
WHERE evidence_id = m9_slice6.expected_evidence_id(
    current_setting('m9.slice6_program')::uuid);
INSERT INTO pgreact_internal.negative_dependency_evidence (
    evidence_id, program_version_id, rule_version_id, input_order,
    support_id, semantic_key, relation_oid, relation_name,
    source_stratum, target_stratum, lower_frontier, active
)
SELECT 'ffffffff-ffff-4fff-8fff-fffffffffff6'::uuid,
       program_version_id, rule_version_id, input_order,
       support_id, semantic_key, relation_oid, 'm9_slice4.stale_denied',
       source_stratum, 2, 99, true
FROM pgreact_internal.negative_dependency_evidence
WHERE evidence_id = m9_slice6.expected_evidence_id(
    current_setting('m9.slice6_program')::uuid);

UPDATE pgreact_internal.derivation_program_components component
SET stratum = 2
FROM pgreact_internal.derivation_program_rules rule
WHERE rule.program_version_id = current_setting('m9.slice6_program')::uuid
  AND rule.rule_name = 'm9.reachable_unblocked'
  AND component.program_version_id = rule.program_version_id
  AND component.component_id = rule.component_id;

DELETE FROM pgreact_internal.derived_supports support
USING pgreact_internal.derivation_program_rules rule
WHERE rule.program_version_id = current_setting('m9.slice6_program')::uuid
  AND rule.rule_name = 'm9.seed_to_candidate'
  AND support.rule_version_id = rule.rule_version_id AND support.active;
UPDATE pgreact_internal.derived_supports support
SET source_binding = jsonb_build_object('id', 8)
FROM pgreact_internal.derivation_program_rules rule
WHERE rule.program_version_id = current_setting('m9.slice6_program')::uuid
  AND rule.rule_name = 'm9.eligible_to_alert'
  AND support.rule_version_id = rule.rule_version_id AND support.active;
UPDATE pgreact_internal.derived_facts
SET support_count = 99
WHERE relation_version_id = (
    SELECT relation_version_id
    FROM pgreact.derived_relations
    WHERE relation_name = 'm9_slice4.e_alert' AND state = 'ACTIVE')
  AND semantic_key = 7;
INSERT INTO pgreact_internal.derived_facts (
    relation_version_id, fact_id, semantic_key, fact, support_count,
    first_frontier, last_frontier
)
SELECT relation_version_id,
       pgreact_internal.activation_uuid(pgreact_internal.activation_digest(
           relation_version_id, pgreact_internal.canonical_bigint_v1(99))),
       99, jsonb_build_object('id', 99), 1, 9, 9
FROM pgreact.derived_relations
WHERE relation_name = 'm9_slice4.b_candidate' AND state = 'ACTIVE';

SELECT pgreact.reconcile_derivation_program(
    current_setting('m9.slice6_program')::uuid) AS repairs \gset

DO $$
DECLARE
    actual_codes text[];
BEGIN
    IF m9_slice6.current_state() IS DISTINCT FROM
       (SELECT state FROM m9_slice6_clean) THEN
        RAISE EXCEPTION 'M9 slice 6 reconciliation changed clean state: %',
            m9_slice6.current_state();
    END IF;
    SELECT array_agg(code ORDER BY code, diagnostic_order)
    INTO actual_codes
    FROM pgreact.derivation_program_repair_diagnostics
    WHERE reconciliation_id = (
        SELECT max(reconciliation_id)
        FROM pgreact_internal.derivation_program_reconciliations
        WHERE program_version_id = current_setting('m9.slice6_program')::uuid);
    IF actual_codes IS DISTINCT FROM ARRAY[
        'CIRCULAR_ONLY', 'CIRCULAR_ONLY', 'CIRCULAR_ONLY', 'CIRCULAR_ONLY',
        'CIRCULAR_ONLY', 'EXTRA_EVIDENCE', 'EXTRA_FACT', 'MISSING_EVIDENCE',
        'MISSING_SUPPORT', 'STALE_EVIDENCE', 'STALE_FACT', 'STALE_FACT',
        'STALE_SUPPORT', 'WRONG_FRONTIER', 'WRONG_STRATUM', 'WRONG_STRATUM'
    ] THEN
        RAISE EXCEPTION 'M9 slice 6 repair diagnostics changed: %', actual_codes;
    END IF;
END
$$;

SELECT pgreact.reconcile_derivation_program(
    current_setting('m9.slice6_program')::uuid) = 0 AS second_repair_noop \gset
\if :second_repair_noop
\else
  SELECT 1 / 0;
\endif

DO $$
DECLARE diagnostics jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(to_jsonb(diagnostic) ORDER BY diagnostic_order),
                    '[]'::jsonb)
    INTO diagnostics
    FROM pgreact.derivation_program_repair_diagnostics diagnostic
    WHERE reconciliation_id = (
        SELECT max(reconciliation_id)
        FROM pgreact_internal.derivation_program_reconciliations
        WHERE program_version_id = current_setting('m9.slice6_program')::uuid);
    IF diagnostics IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'M9 slice 6 second repair recorded diagnostics: %',
            diagnostics;
    END IF;
END
$$;

SELECT 'M9 slice 6 explanation and repair gate passed' AS result;
