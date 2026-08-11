\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
\ir /tmp/m10-slice1.sql

INSERT INTO m10_slice1.items VALUES (4, 7);
SELECT pgreact.refresh_derivation_program(
    current_setting('m10.slice1_program')::uuid) = 6 AS crossed_after_recovery_setup \gset
\if :crossed_after_recovery_setup
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.refresh_rule(current_setting('m10.slice1_observer')::uuid);

CREATE TABLE m10_slice1.recovery_control AS
SELECT current_setting('m10.slice1_program')::uuid AS program_version_id,
       current_setting('m10.slice1_observer')::uuid AS observer_version_id,
       (SELECT rule_version_id FROM pgreact.rules
        WHERE rule_name = 'm10.slice1.base' AND state = 'ACTIVE') AS base_version_id,
       (SELECT relation_version_id FROM pgreact.derived_relations
        WHERE relation_name = 'm10_slice1.alert' AND state = 'ACTIVE')
           AS alert_relation_version_id;

CREATE VIEW m10_slice1.recovery_state AS
SELECT jsonb_build_object(
    'state', m10_slice1.state(),
    'evidence', COALESCE((
        SELECT jsonb_agg(to_jsonb(evidence) ORDER BY group_key)
        FROM pgreact.aggregate_dependency_evidence evidence
    ), '[]'::jsonb),
    'explanation', pgreact.explain_recursive_fact(
        control.program_version_id, control.alert_relation_version_id, 7)
) AS state
FROM m10_slice1.recovery_control control;

CREATE TABLE m10_slice1.recovery_snapshot AS
SELECT state FROM m10_slice1.recovery_state;

SELECT 'M10 physical-recovery aggregate-state setup passed' AS result;
