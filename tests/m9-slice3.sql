\set ON_ERROR_STOP on

CREATE SCHEMA m9_slice3;
CREATE TYPE m9_slice3.fact_row AS (id bigint);
CREATE TABLE m9_slice3.candidate (id bigint PRIMARY KEY);
CREATE TABLE m9_slice3.blocked (id bigint);
CREATE VIEW m9_slice3.candidate_source AS
SELECT id FROM m9_slice3.candidate;
CREATE VIEW m9_slice3.blocked_source AS
SELECT id FROM m9_slice3.blocked WHERE id IS NOT NULL;

SELECT pgreact.create_derived_relation(
    'm9_slice3.z_denied', 'm9_slice3.fact_row'::regtype, ARRAY['id']);
SELECT pgreact.create_derived_relation(
    'm9_slice3.a_eligible', 'm9_slice3.fact_row'::regtype, ARRAY['id']);

CREATE VIEW m9_slice3.observe_eligible AS
SELECT id FROM m9_slice3.a_eligible;
SELECT pgreact.create_rule(
    name => 'm9.observe_eligible',
    definition => 'm9_slice3.observe_eligible'::regclass,
    key_columns => ARRAY['id'],
    kind => 'CONSTRAINT'
) AS observer_rule_version_id \gset
SELECT set_config(
    'm9.slice3_observer', :'observer_rule_version_id', false);

INSERT INTO m9_slice3.candidate VALUES (7), (8);
INSERT INTO m9_slice3.blocked VALUES (NULL), (8);

CREATE TABLE m9_slice3.manifest AS
SELECT jsonb_build_object(
    'format_version', 1,
    'pack', 'm9-slice3-pack',
    'version', '1',
    'owner', 'owner',
    'rules', jsonb_build_array(jsonb_build_object(
        'name', 'm9.slice3.base',
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
        'name', 'm9.slice3',
        'version', 1,
        'max_iterations', 8,
        'max_facts', 32,
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'm9.blocked_to_denied',
                'definition', 'm9.blocked_source',
                'key', 'id',
                'target', 'm9.denied',
                'version', 1,
                'inputs', '[]'::jsonb),
            jsonb_build_object(
                'name', 'm9.reachable_unblocked',
                'definition', 'm9.candidate_source',
                'key', 'id',
                'target', 'm9.eligible',
                'version', 1,
                'inputs', '[]'::jsonb,
                'negative_inputs', jsonb_build_array(jsonb_build_object(
                    'relation', 'm9.denied', 'key', 'id')))
        )
    )),
    'remove_programs', '[]'::jsonb
) AS definition,
jsonb_build_object(
    'roles', jsonb_build_object('owner', current_user),
    'objects', jsonb_build_object(
        'm9.candidate_source', 'm9_slice3.candidate_source',
        'm9.blocked_source', 'm9_slice3.blocked_source',
        'm9.denied', 'm9_slice3.z_denied',
        'm9.eligible', 'm9_slice3.a_eligible')
) AS mappings;

SELECT min(plan_digest) AS plan_digest
FROM pgreact.preview_pack(
    (SELECT definition FROM m9_slice3.manifest),
    (SELECT mappings FROM m9_slice3.manifest)) \gset
SELECT pgreact.deploy_pack(
    (SELECT definition FROM m9_slice3.manifest), :'plan_digest',
    (SELECT mappings FROM m9_slice3.manifest));

SELECT program_version_id
FROM pgreact.derivation_programs
WHERE program_name = 'm9.slice3' AND state = 'ACTIVE' \gset
SELECT set_config('m9.slice3_program', :'program_version_id', false);

SELECT pgreact.refresh_rule(current_setting('m9.slice3_observer')::uuid);

CREATE FUNCTION m9_slice3.normalized_state()
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
SELECT jsonb_build_object(
    'program_frontier', (
        SELECT frontier
        FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m9.slice3_program')::uuid),
    'strata', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'stratum', stratum,
            'component_order', component_order,
            'rules', to_jsonb(rule_names),
            'targets', to_jsonb(target_relations),
            'frontier', frontier,
            'iterations', iterations,
            'fact_count', fact_count,
            'support_count', support_count)
            ORDER BY stratum, component_order)
        FROM pgreact.derivation_strata
        WHERE program_version_id = current_setting('m9.slice3_program')::uuid
    ), '[]'::jsonb),
    'facts', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation_name,
            'key', semantic_key,
            'fact', fact,
            'support_count', support_count)
            ORDER BY relation_name, semantic_key)
        FROM pgreact.derived_facts
        WHERE relation_name IN (
            'm9_slice3.a_eligible', 'm9_slice3.z_denied')
    ), '[]'::jsonb),
    'supports', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'relation', relation.relation_name,
            'rule', rule.rule_name,
            'key', support.semantic_key,
            'fact', support.fact,
            'source_binding', support.source_binding,
            'activation_generation', support.activation_generation,
            'activation_revision', support.activation_revision,
            'support_frontier', support.support_frontier,
            'grounded', support.grounded,
            'active', support.active)
            ORDER BY rule.rule_name, support.semantic_key)
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = current_setting('m9.slice3_program')::uuid
         AND rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derived_relation_versions relation_version
          USING (relation_version_id)
        JOIN pgreact_internal.derived_relations relation USING (relation_id)
        WHERE support.active
    ), '[]'::jsonb),
    'events', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'key', (COALESCE(new_bindings, old_bindings) ->> 'id')::bigint,
            'event', event_kind,
            'generation', generation)
            ORDER BY (COALESCE(new_bindings, old_bindings) ->> 'id')::bigint,
                     generation, event_kind)
        FROM pgreact_internal.lifecycle_events
        WHERE rule_version_id = current_setting('m9.slice3_observer')::uuid
    ), '[]'::jsonb)
)
$$;

CREATE FUNCTION m9_slice3.expected_state(
    expected_frontier bigint,
    denied_key bigint,
    eligible_key bigint,
    denied_generation bigint,
    expected_events jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $$
SELECT jsonb_build_object(
    'program_frontier', expected_frontier,
    'strata', jsonb_build_array(
        jsonb_build_object(
            'stratum', 0,
            'component_order', 1,
            'rules', jsonb_build_array('m9.blocked_to_denied'),
            'targets', jsonb_build_array('m9_slice3.z_denied'),
            'frontier', expected_frontier,
            'iterations', 2,
            'fact_count', 1,
            'support_count', 1),
        jsonb_build_object(
            'stratum', 1,
            'component_order', 2,
            'rules', jsonb_build_array('m9.reachable_unblocked'),
            'targets', jsonb_build_array('m9_slice3.a_eligible'),
            'frontier', expected_frontier,
            'iterations', 2,
            'fact_count', 1,
            'support_count', 1)),
    'facts', jsonb_build_array(
        jsonb_build_object(
            'relation', 'm9_slice3.a_eligible',
            'key', eligible_key,
            'fact', jsonb_build_object('id', eligible_key),
            'support_count', 1),
        jsonb_build_object(
            'relation', 'm9_slice3.z_denied',
            'key', denied_key,
            'fact', jsonb_build_object('id', denied_key),
            'support_count', 1)),
    'supports', jsonb_build_array(
        jsonb_build_object(
            'relation', 'm9_slice3.z_denied',
            'rule', 'm9.blocked_to_denied',
            'key', denied_key,
            'fact', jsonb_build_object('id', denied_key),
            'source_binding', jsonb_build_object('id', denied_key),
            'activation_generation', denied_generation,
            'activation_revision', 0,
            'support_frontier', expected_frontier,
            'grounded', true,
            'active', true),
        jsonb_build_object(
            'relation', 'm9_slice3.a_eligible',
            'rule', 'm9.reachable_unblocked',
            'key', eligible_key,
            'fact', jsonb_build_object('id', eligible_key),
            'source_binding', jsonb_build_object('id', eligible_key),
            'activation_generation', 1,
            'activation_revision', 0,
            'support_frontier', expected_frontier,
            'grounded', true,
            'active', true)),
    'events', expected_events
)
$$;

CREATE FUNCTION m9_slice3.assert_state(stage text, expected jsonb)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE actual jsonb := m9_slice3.normalized_state();
BEGIN
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 slice 3 % state changed: %', stage, actual;
    END IF;
END
$$;

CREATE FUNCTION m9_slice3.semantic_state()
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
WITH state AS (SELECT m9_slice3.normalized_state() AS value)
SELECT jsonb_build_object(
    'strata', (
        SELECT jsonb_agg(item - 'frontier' ORDER BY ordinal)
        FROM state,
             jsonb_array_elements(value -> 'strata')
                 WITH ORDINALITY items(item, ordinal)),
    'facts', value -> 'facts',
    'supports', (
        SELECT jsonb_agg(
            item - 'activation_generation' - 'support_frontier'
            ORDER BY ordinal)
        FROM jsonb_array_elements(value -> 'supports')
            WITH ORDINALITY items(item, ordinal))
)
FROM state
$$;

SELECT m9_slice3.assert_state(
    'frontier 1',
    m9_slice3.expected_state(
        1, 8, 7, 1,
        jsonb_build_array(jsonb_build_object(
            'key', 7, 'event', 'ACTIVATE', 'generation', 1))));

BEGIN;
INSERT INTO m9_slice3.blocked VALUES (7);
DELETE FROM m9_slice3.blocked WHERE id = 8;
COMMIT;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice3_program')::uuid) = 2 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice3_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice3.assert_state(
    'frontier 2 insert-then-delete',
    m9_slice3.expected_state(
        2, 7, 8, 1,
        jsonb_build_array(
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 7, 'event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 8, 'event', 'ACTIVATE', 'generation', 1))));
CREATE TEMP TABLE m9_slice3_order_a AS
SELECT m9_slice3.semantic_state() AS state;
CREATE TEMP TABLE m9_slice3_frontier_2 AS
SELECT m9_slice3.normalized_state() AS state;

SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice3_program')::uuid) = 2 AS noop \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice3_observer')::uuid);
\if :noop
\else
  SELECT 1 / 0;
\endif
DO $$
BEGIN
    IF m9_slice3.normalized_state() IS DISTINCT FROM
       (SELECT state FROM m9_slice3_frontier_2) THEN
        RAISE EXCEPTION 'M9 repeated refresh changed frontier 2';
    END IF;
END
$$;

BEGIN;
INSERT INTO m9_slice3.blocked VALUES (8);
DELETE FROM m9_slice3.blocked WHERE id = 7;
COMMIT;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice3_program')::uuid) = 3 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice3_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice3.assert_state(
    'frontier 3 restored',
    m9_slice3.expected_state(
        3, 8, 7, 2,
        jsonb_build_array(
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 7, 'event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 2),
            jsonb_build_object(
                'key', 8, 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 8, 'event', 'DEACTIVATE', 'generation', 1))));

BEGIN;
DELETE FROM m9_slice3.blocked WHERE id = 8;
INSERT INTO m9_slice3.blocked VALUES (7);
COMMIT;
SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice3_program')::uuid) = 4 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice3_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice3.assert_state(
    'frontier 4 delete-then-insert',
    m9_slice3.expected_state(
        4, 7, 8, 2,
        jsonb_build_array(
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 7, 'event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 2),
            jsonb_build_object(
                'key', 7, 'event', 'DEACTIVATE', 'generation', 2),
            jsonb_build_object(
                'key', 8, 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 8, 'event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 8, 'event', 'ACTIVATE', 'generation', 2))));
DO $$
BEGIN
    IF m9_slice3.semantic_state() IS DISTINCT FROM
       (SELECT state FROM m9_slice3_order_a) THEN
        RAISE EXCEPTION 'M9 equivalent delta order changed the semantic state: %',
            m9_slice3.semantic_state();
    END IF;
END
$$;

CREATE TEMP TABLE m9_slice3_frontier_4 AS
SELECT m9_slice3.normalized_state() AS state;
BEGIN;
INSERT INTO m9_slice3.blocked VALUES (8);
DELETE FROM m9_slice3.blocked WHERE id = 7;
COMMIT;
DO $$
DECLARE result bigint;
BEGIN
    PERFORM set_config(
        'pgreact.test_fail_program_phase', 'after_iteration', true);
    result := pgreact.refresh_derivation_program(
        current_setting('m9.slice3_program')::uuid);
    IF result IS NOT NULL THEN
        RAISE EXCEPTION 'M9 injected refresh unexpectedly returned %', result;
    END IF;
END
$$;
DO $$
DECLARE failed_run jsonb;
BEGIN
    IF m9_slice3.normalized_state() IS DISTINCT FROM
       (SELECT state FROM m9_slice3_frontier_4) THEN
        RAISE EXCEPTION 'M9 failed refresh exposed partial stratified state: %',
            m9_slice3.normalized_state();
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
    WHERE program_version_id = current_setting('m9.slice3_program')::uuid
      AND status = 'FAILED'
    ORDER BY run_id DESC LIMIT 1;
    IF failed_run IS DISTINCT FROM jsonb_build_object(
        'prior_frontier', 4,
        'committed_frontier', 4,
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
        RAISE EXCEPTION 'M9 failed run changed: %', failed_run;
    END IF;
END
$$;

SELECT pgreact.refresh_derivation_program(
    current_setting('m9.slice3_program')::uuid) = 5 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m9.slice3_observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif
SELECT m9_slice3.assert_state(
    'frontier 5 retry',
    m9_slice3.expected_state(
        5, 8, 7, 3,
        jsonb_build_array(
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 7, 'event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 2),
            jsonb_build_object(
                'key', 7, 'event', 'DEACTIVATE', 'generation', 2),
            jsonb_build_object(
                'key', 7, 'event', 'ACTIVATE', 'generation', 3),
            jsonb_build_object(
                'key', 8, 'event', 'ACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 8, 'event', 'DEACTIVATE', 'generation', 1),
            jsonb_build_object(
                'key', 8, 'event', 'ACTIVATE', 'generation', 2),
            jsonb_build_object(
                'key', 8, 'event', 'DEACTIVATE', 'generation', 2))));

SELECT 'M9 slice 3 deletion-sensitive truth gate passed' AS result;
