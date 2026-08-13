\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;

CREATE SCHEMA m16_recovery;
CREATE TYPE m16_recovery.fact_row AS (id bigint);
CREATE TABLE m16_recovery.groups (id bigint PRIMARY KEY);
CREATE TABLE m16_recovery.items (
    item_id bigint PRIMARY KEY, id bigint NOT NULL, amount numeric);
CREATE VIEW m16_recovery.group_source AS SELECT id FROM m16_recovery.groups;
CREATE VIEW m16_recovery.item_source AS SELECT id, amount FROM m16_recovery.items;
INSERT INTO m16_recovery.groups VALUES (1), (2);
INSERT INTO m16_recovery.items VALUES (1, 1, 4.25), (2, 1, 6.25);
SELECT pgreact_api.declare_derived_relation(
    'm16_recovery.alert', 'm16_recovery.fact_row'::regtype, ARRAY['id']::name[]);
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm16.recovery', 'version', 1, 'max_iterations', 4, 'max_facts', 4,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm16.recovery.sum', 'definition', 'm16_recovery.group_source',
            'key', 'id', 'target', 'm16_recovery.alert', 'version', 1,
            'aggregate_input', jsonb_build_object(
                'relation', 'm16_recovery.item_source', 'key', 'id', 'function', 'SUM',
                'expression', 'amount', 'comparison', '>=', 'threshold', 10.50))));
    preview jsonb;
BEGIN
    preview := pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
END
$$;
SELECT pgreact_api.run();
CREATE TABLE m16_recovery.control AS
SELECT
    (SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name, public_group_key)
     FROM pgreact.aggregate_dependency_evidence evidence
     WHERE program_name = 'm16.recovery') AS evidence,
    pgreact_api.explain('m16_recovery.alert', '1'::jsonb) AS true_explanation,
    pgreact_api.explain('m16_recovery.alert', '2'::jsonb) AS false_explanation;
CHECKPOINT;
SELECT 'M16 typed aggregate recovery setup passed';
