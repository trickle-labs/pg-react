\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
\ir /tmp/m9-slice4.sql

CREATE TABLE m9_slice4.recovery_control AS
SELECT current_setting('m9.slice4_program')::uuid AS program_version_id,
       current_setting('m9.slice4_observer')::uuid AS observer_version_id,
       (SELECT rule_version_id FROM pgreact.rules
        WHERE rule_name = 'm9.slice4.base' AND state = 'ACTIVE') AS base_version_id,
       (SELECT relation_version_id FROM pgreact.derived_relations
        WHERE relation_name = 'm9_slice4.e_alert' AND state = 'ACTIVE')
           AS alert_relation_version_id;

CREATE VIEW m9_slice4.recovery_state AS
SELECT jsonb_build_object(
    'state', m9_slice4.normalized_state(),
    'negative_inputs', COALESCE((
        SELECT jsonb_agg(to_jsonb(input)
                         ORDER BY program_version_id, rule_version_id, input_order)
        FROM pgreact_internal.derivation_program_negative_inputs input
    ), '[]'::jsonb),
    'evidence', COALESCE((
        SELECT jsonb_agg(to_jsonb(evidence) ORDER BY evidence_id)
        FROM pgreact.negative_dependency_evidence evidence
    ), '[]'::jsonb),
    'explanation', pgreact.explain_recursive_fact(
        control.program_version_id, control.alert_relation_version_id, 7)
) AS state
FROM m9_slice4.recovery_control control;

CREATE TABLE m9_slice4.recovery_snapshot AS
SELECT state FROM m9_slice4.recovery_state;

SELECT 'M9 physical-recovery stratified-state setup passed' AS result;
