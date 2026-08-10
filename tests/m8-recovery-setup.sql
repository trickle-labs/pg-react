\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
\ir /tmp/m8-setup.sql

SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
DELETE FROM m8_ref.left_seed WHERE id = 7;
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 2 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
DELETE FROM m8_ref.right_seed WHERE id = 7;
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 3 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
INSERT INTO m8_ref.right_seed VALUES (7);
SELECT pgreact.refresh_derivation_program(current_setting('m8.program')::uuid) = 4 AS frontier_ok \gset
SELECT pgreact.refresh_rule(current_setting('m8.observer')::uuid);
\if :frontier_ok
\else
  SELECT 1 / 0;
\endif

CREATE TABLE m8_ref.recovery_control AS
SELECT current_setting('m8.program')::uuid AS program_version_id,
       current_setting('m8.observer')::uuid AS observer_version_id,
       (SELECT relation_version_id FROM pgreact.derived_relations
        WHERE relation_name = 'm8_ref.c' AND state = 'ACTIVE') AS c_relation_version_id;

CREATE VIEW m8_ref.recovery_state AS
SELECT jsonb_build_object(
    'programs', (SELECT jsonb_agg(to_jsonb(p) ORDER BY program_id)
                 FROM pgreact_internal.derivation_programs p),
    'program_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY program_version_id)
                         FROM pgreact_internal.derivation_program_versions v),
    'components', (SELECT jsonb_agg(to_jsonb(c) ORDER BY program_version_id, component_order)
                   FROM pgreact_internal.derivation_program_components c),
    'program_rules', (SELECT jsonb_agg(to_jsonb(r) ORDER BY program_version_id, rule_order)
                      FROM pgreact_internal.derivation_program_rules r),
    'program_inputs', (SELECT jsonb_agg(to_jsonb(i)
                       ORDER BY program_version_id, rule_version_id, input_order)
                       FROM pgreact_internal.derivation_program_inputs i),
    'component_frontiers', (SELECT jsonb_agg(to_jsonb(f)
                            ORDER BY program_version_id, component_id)
                            FROM pgreact_internal.derivation_program_component_frontiers f),
    'runs', (SELECT jsonb_agg(to_jsonb(r) ORDER BY run_id)
             FROM pgreact_internal.derivation_program_runs r
             WHERE status = 'COMPLETED'),
    'iterations', (SELECT jsonb_agg(to_jsonb(i) ORDER BY run_id, component_id, iteration)
                   FROM pgreact_internal.derivation_program_iterations i),
    'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_version_id, fact_id)
              FROM pgreact_internal.derived_facts f),
    'supports', (SELECT jsonb_agg(to_jsonb(s) ORDER BY support_id)
                 FROM pgreact_internal.derived_supports s),
    'support_inputs', (SELECT jsonb_agg(to_jsonb(i) ORDER BY support_id, input_order)
                       FROM pgreact_internal.derived_support_inputs i),
    'explanation', pgreact.explain_recursive_fact(
        (SELECT program_version_id FROM m8_ref.recovery_control),
        (SELECT c_relation_version_id FROM m8_ref.recovery_control), 7),
    'events', (SELECT jsonb_agg(to_jsonb(e) ORDER BY event_id)
               FROM pgreact_internal.lifecycle_events e
               WHERE rule_version_id = (SELECT observer_version_id FROM m8_ref.recovery_control))
) AS state;

CREATE TABLE m8_ref.recovery_snapshot AS SELECT state FROM m8_ref.recovery_state;

SELECT 'M8 physical-recovery recursive-state setup passed' AS result;
