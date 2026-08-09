\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
\ir /tmp/m7.sql

CREATE TABLE clinical.recovery_control AS
SELECT current_setting('m7.relation')::uuid AS relation_version_id;

CREATE VIEW clinical.recovery_state AS
SELECT jsonb_build_object(
    'public_rows', (SELECT jsonb_agg(to_jsonb(f) ORDER BY patient_id)
                    FROM clinical.patient_fever f),
    'relations', (SELECT jsonb_agg(to_jsonb(r) ORDER BY relation_id)
                  FROM pgreact_internal.derived_relations r),
    'relation_versions', (SELECT jsonb_agg(to_jsonb(v) ORDER BY relation_version_id)
                          FROM pgreact_internal.derived_relation_versions v),
    'derivations', (SELECT jsonb_agg(to_jsonb(d) ORDER BY rule_version_id)
                    FROM pgreact_internal.derivation_rule_versions d),
    'supports', (SELECT jsonb_agg(to_jsonb(s) ORDER BY support_id)
                 FROM pgreact_internal.derived_supports s),
    'facts', (SELECT jsonb_agg(to_jsonb(f) ORDER BY fact_id)
              FROM pgreact_internal.derived_facts f),
    'frontiers', (SELECT jsonb_agg(to_jsonb(f) ORDER BY relation_version_id)
                  FROM pgreact_internal.derived_frontiers f),
    'diagnostics', (SELECT jsonb_agg(to_jsonb(d) ORDER BY reconciliation_id, diagnostic_order)
                    FROM pgreact_internal.derived_repair_diagnostics d),
    'explanation', pgreact.explain_fact(
        (SELECT relation_version_id FROM clinical.recovery_control), 42)
) AS state;

CREATE TABLE clinical.recovery_snapshot AS
SELECT state FROM clinical.recovery_state;

SELECT 'M7 physical-recovery derived-state setup passed' AS result;
