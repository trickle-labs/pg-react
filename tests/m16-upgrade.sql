\set ON_ERROR_STOP on

CREATE SCHEMA m16_upgrade;
CREATE TYPE m16_upgrade.fact_row AS (id bigint);
CREATE TABLE m16_upgrade.groups (id bigint PRIMARY KEY);
CREATE TABLE m16_upgrade.items (item_id bigint PRIMARY KEY, id bigint NOT NULL);
CREATE VIEW m16_upgrade.group_source AS SELECT id FROM m16_upgrade.groups;
CREATE VIEW m16_upgrade.item_source AS SELECT id FROM m16_upgrade.items;
INSERT INTO m16_upgrade.groups VALUES (7);
INSERT INTO m16_upgrade.items VALUES (1, 7), (2, 7);
SELECT pgreact.create_derived_relation(
    'm16_upgrade.alert', 'm16_upgrade.fact_row'::regtype, ARRAY['id']);

CREATE TEMP TABLE m16_upgrade_definition AS SELECT jsonb_build_object(
    'name', 'm16.upgrade', 'version', 1, 'max_iterations', 4, 'max_facts', 4,
    'rules', jsonb_build_array(jsonb_build_object(
        'name', 'm16.upgrade.count', 'definition', 'm16_upgrade.group_source',
        'key', 'id', 'target', 'm16_upgrade.alert', 'version', 1, 'inputs', '[]'::jsonb,
        'aggregate_input', jsonb_build_object(
            'relation', 'm16_upgrade.item_source', 'key', 'id',
            'comparison', '>=', 'threshold', 2)))) AS definition;
SELECT pgreact_internal.deploy_derivation_program(definition, NULL) AS program_version_id
FROM m16_upgrade_definition \gset
SELECT pgreact.refresh_derivation_program(:'program_version_id');

CREATE TEMP TABLE m16_before_upgrade AS
SELECT
    (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') AS version,
    (SELECT jsonb_agg(to_jsonb(fact) ORDER BY relation_version_id, semantic_key)
     FROM pgreact_internal.derived_facts fact) AS facts,
    (SELECT jsonb_agg(to_jsonb(support) ORDER BY support_id)
     FROM pgreact_internal.derived_supports support) AS supports,
    (SELECT jsonb_agg(to_jsonb(evidence) ORDER BY evidence_id)
     FROM pgreact_internal.aggregate_dependency_evidence evidence) AS evidence;

ALTER EXTENSION pg_react UPDATE TO '0.13.0';

DO $$
DECLARE before_row m16_before_upgrade%ROWTYPE;
BEGIN
    SELECT * INTO STRICT before_row FROM m16_before_upgrade;
    IF before_row.version <> '0.12.0'
       OR (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.13.0'
       OR before_row.facts IS DISTINCT FROM (
            SELECT jsonb_agg(to_jsonb(fact) ORDER BY relation_version_id, semantic_key)
            FROM pgreact_internal.derived_facts fact)
       OR before_row.supports IS DISTINCT FROM (
            SELECT jsonb_agg(to_jsonb(support) ORDER BY support_id)
            FROM pgreact_internal.derived_supports support)
       OR (SELECT jsonb_agg(jsonb_build_object(
                'evidence_id', evidence_id, 'program_version_id', program_version_id,
                'rule_version_id', rule_version_id, 'activation_id', activation_id,
                'support_id', support_id, 'semantic_key', semantic_key,
                'relation_oid', relation_oid, 'relation_name', relation_name,
                'exact_count', exact_count, 'comparison', comparison, 'threshold', threshold,
                'source_stratum', source_stratum, 'target_stratum', target_stratum,
                'lower_frontier', lower_frontier, 'active', active,
                'created_at', created_at, 'invalidated_at', invalidated_at)
            ORDER BY evidence_id)
           FROM pgreact_internal.aggregate_dependency_evidence)
          IS DISTINCT FROM before_row.evidence
       OR EXISTS (
            SELECT 1 FROM pgreact_internal.derivation_program_aggregate_inputs
            WHERE aggregate_function <> 'COUNT_STAR'
               OR typed_threshold IS DISTINCT FROM threshold::text)
       OR EXISTS (
            SELECT 1 FROM pgreact_internal.aggregate_dependency_evidence
            WHERE aggregate_function <> 'COUNT_STAR'
               OR exact_value IS DISTINCT FROM exact_count::text
               OR typed_threshold IS DISTINCT FROM threshold::text) THEN
        RAISE EXCEPTION 'M16 populated upgrade did not preserve exact M10 aggregate state';
    END IF;
END
$$;

SELECT 'M16 populated 0.12.0 to 0.13.0 upgrade gate passed';
