\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET statement_timeout = '5min';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm16_author') THEN CREATE ROLE m16_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm16_operator') THEN CREATE ROLE m16_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm16_worker') THEN CREATE ROLE m16_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm16_reader') THEN CREATE ROLE m16_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm16_advanced') THEN CREATE ROLE m16_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm16_author', 'm16_operator', 'm16_worker', 'm16_reader', 'm16_advanced');

DO $$
DECLARE actual jsonb;
BEGIN
    actual := jsonb_build_object(
        'signature', to_regprocedure('pgreact_api.reconcile_program(text)')::text,
        'operator', has_function_privilege(
            'm16_operator', 'pgreact_api.reconcile_program(text)', 'EXECUTE'),
        'author', has_function_privilege(
            'm16_author', 'pgreact_api.reconcile_program(text)', 'EXECUTE'),
        'reader', has_function_privilege(
            'm16_reader', 'pgreact_api.reconcile_program(text)', 'EXECUTE'));
    IF actual IS DISTINCT FROM jsonb_build_object(
        'signature', 'pgreact_api.reconcile_program(text)',
        'operator', true, 'author', false, 'reader', false) THEN
        RAISE EXCEPTION 'M16 reconciliation API inventory or grants changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'function', function_name, 'input', input_type::regtype::text,
        'result', pgreact_internal.aggregate_result_type(
            function_name, input_type)::regtype::text)
        ORDER BY function_name, input_type::regtype::text)
    INTO actual
    FROM (VALUES
        ('COUNT', 'boolean'::regtype::oid), ('COUNT', 'bigint'::regtype::oid),
        ('COUNT', 'date'::regtype::oid), ('COUNT', 'double precision'::regtype::oid),
        ('COUNT', 'integer'::regtype::oid), ('COUNT', 'numeric'::regtype::oid),
        ('COUNT', 'real'::regtype::oid), ('COUNT', 'smallint'::regtype::oid),
        ('COUNT', 'text'::regtype::oid), ('COUNT', 'timestamp'::regtype::oid),
        ('COUNT', 'timestamp with time zone'::regtype::oid), ('COUNT', 'uuid'::regtype::oid),
        ('MAX', 'bigint'::regtype::oid), ('MAX', 'date'::regtype::oid),
        ('MAX', 'double precision'::regtype::oid), ('MAX', 'integer'::regtype::oid),
        ('MAX', 'numeric'::regtype::oid), ('MAX', 'real'::regtype::oid),
        ('MAX', 'smallint'::regtype::oid), ('MAX', 'text'::regtype::oid),
        ('MAX', 'timestamp'::regtype::oid), ('MAX', 'timestamp with time zone'::regtype::oid),
        ('MAX', 'uuid'::regtype::oid),
        ('MIN', 'bigint'::regtype::oid), ('MIN', 'date'::regtype::oid),
        ('MIN', 'double precision'::regtype::oid), ('MIN', 'integer'::regtype::oid),
        ('MIN', 'numeric'::regtype::oid), ('MIN', 'real'::regtype::oid),
        ('MIN', 'smallint'::regtype::oid), ('MIN', 'text'::regtype::oid),
        ('MIN', 'timestamp'::regtype::oid), ('MIN', 'timestamp with time zone'::regtype::oid),
        ('MIN', 'uuid'::regtype::oid),
        ('SUM', 'bigint'::regtype::oid), ('SUM', 'double precision'::regtype::oid),
        ('SUM', 'integer'::regtype::oid), ('SUM', 'numeric'::regtype::oid),
        ('SUM', 'real'::regtype::oid), ('SUM', 'smallint'::regtype::oid)
    ) matrix(function_name, input_type);
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('function','COUNT','input','bigint','result','bigint'),
        jsonb_build_object('function','COUNT','input','boolean','result','bigint'),
        jsonb_build_object('function','COUNT','input','date','result','bigint'),
        jsonb_build_object('function','COUNT','input','double precision','result','bigint'),
        jsonb_build_object('function','COUNT','input','integer','result','bigint'),
        jsonb_build_object('function','COUNT','input','numeric','result','bigint'),
        jsonb_build_object('function','COUNT','input','real','result','bigint'),
        jsonb_build_object('function','COUNT','input','smallint','result','bigint'),
        jsonb_build_object('function','COUNT','input','text','result','bigint'),
        jsonb_build_object('function','COUNT','input','timestamp without time zone','result','bigint'),
        jsonb_build_object('function','COUNT','input','timestamp with time zone','result','bigint'),
        jsonb_build_object('function','COUNT','input','uuid','result','bigint'),
        jsonb_build_object('function','MAX','input','bigint','result','bigint'),
        jsonb_build_object('function','MAX','input','date','result','date'),
        jsonb_build_object('function','MAX','input','double precision','result','double precision'),
        jsonb_build_object('function','MAX','input','integer','result','integer'),
        jsonb_build_object('function','MAX','input','numeric','result','numeric'),
        jsonb_build_object('function','MAX','input','real','result','real'),
        jsonb_build_object('function','MAX','input','smallint','result','smallint'),
        jsonb_build_object('function','MAX','input','text','result','text'),
        jsonb_build_object('function','MAX','input','timestamp without time zone','result','timestamp without time zone'),
        jsonb_build_object('function','MAX','input','timestamp with time zone','result','timestamp with time zone'),
        jsonb_build_object('function','MAX','input','uuid','result','uuid'),
        jsonb_build_object('function','MIN','input','bigint','result','bigint'),
        jsonb_build_object('function','MIN','input','date','result','date'),
        jsonb_build_object('function','MIN','input','double precision','result','double precision'),
        jsonb_build_object('function','MIN','input','integer','result','integer'),
        jsonb_build_object('function','MIN','input','numeric','result','numeric'),
        jsonb_build_object('function','MIN','input','real','result','real'),
        jsonb_build_object('function','MIN','input','smallint','result','smallint'),
        jsonb_build_object('function','MIN','input','text','result','text'),
        jsonb_build_object('function','MIN','input','timestamp without time zone','result','timestamp without time zone'),
        jsonb_build_object('function','MIN','input','timestamp with time zone','result','timestamp with time zone'),
        jsonb_build_object('function','MIN','input','uuid','result','uuid'),
        jsonb_build_object('function','SUM','input','bigint','result','numeric'),
        jsonb_build_object('function','SUM','input','double precision','result','double precision'),
        jsonb_build_object('function','SUM','input','integer','result','bigint'),
        jsonb_build_object('function','SUM','input','numeric','result','numeric'),
        jsonb_build_object('function','SUM','input','real','result','real'),
        jsonb_build_object('function','SUM','input','smallint','result','bigint')) THEN
        RAISE EXCEPTION 'M16 aggregate type matrix changed: %', actual;
    END IF;
END
$$;

CREATE SCHEMA m16 AUTHORIZATION m16_author;
CREATE TYPE m16.fact_row AS (id bigint);
CREATE TYPE m16.lower_row AS (id bigint, units integer);
CREATE TABLE m16.groups (id bigint PRIMARY KEY);
CREATE TABLE m16.items (
    item_id bigint PRIMARY KEY,
    id bigint NOT NULL,
    units integer,
    amount numeric,
    label text COLLATE "C",
    occurred_on date,
    overflow_value real
);
CREATE TABLE m16.lower_seed (id bigint PRIMARY KEY, units integer);
CREATE TABLE m16.rls_items (id bigint, units integer);
CREATE TABLE m16.private_items (id bigint, units integer);
ALTER TABLE m16.rls_items ENABLE ROW LEVEL SECURITY;
CREATE COLLATION m16.non_c (provider = icu, locale = 'en-US');
CREATE FUNCTION m16.identity_units(value integer)
RETURNS integer LANGUAGE SQL IMMUTABLE AS 'SELECT value';
CREATE VIEW m16.group_source AS SELECT id FROM m16.groups;
CREATE VIEW m16.item_source AS SELECT id, units, amount, label, occurred_on, overflow_value FROM m16.items;
CREATE VIEW m16.lower_source AS SELECT id, units FROM m16.lower_seed;
CREATE VIEW m16.volatile_items AS
SELECT id, random()::integer AS units FROM m16.items;
CREATE VIEW m16.current_items AS
SELECT id, extract(year FROM CURRENT_DATE)::integer AS units FROM m16.items;
CREATE VIEW m16.srf_items AS
SELECT id, generate_series(1, COALESCE(units, 0)) AS units FROM m16.items;
CREATE VIEW m16.udf_items AS
SELECT id, m16.identity_units(units) AS units FROM m16.items;
CREATE VIEW m16.collated_items AS
SELECT id, label COLLATE m16.non_c AS label FROM m16.items;
ALTER TYPE m16.fact_row OWNER TO m16_author;
ALTER TYPE m16.lower_row OWNER TO m16_author;
ALTER TABLE m16.groups OWNER TO m16_author;
ALTER TABLE m16.items OWNER TO m16_author;
ALTER TABLE m16.lower_seed OWNER TO m16_author;
ALTER TABLE m16.rls_items OWNER TO m16_author;
ALTER VIEW m16.group_source OWNER TO m16_author;
ALTER VIEW m16.item_source OWNER TO m16_author;
ALTER VIEW m16.lower_source OWNER TO m16_author;
ALTER VIEW m16.volatile_items OWNER TO m16_author;
ALTER VIEW m16.current_items OWNER TO m16_author;
ALTER VIEW m16.srf_items OWNER TO m16_author;
ALTER VIEW m16.udf_items OWNER TO m16_author;
ALTER VIEW m16.collated_items OWNER TO m16_author;
ALTER FUNCTION m16.identity_units(integer) OWNER TO m16_author;

INSERT INTO m16.groups VALUES (1), (2);
INSERT INTO m16.items VALUES
    (1, 1, 2, 4.25, 'z', '2026-01-01', NULL),
    (2, 1, NULL, 6.25, 'b', NULL, NULL),
    (3, 1, 5, NULL, NULL, '2026-03-01', NULL);
INSERT INTO m16.lower_seed VALUES (1, 9);

SET SESSION AUTHORIZATION m16_author;
SELECT pgreact_api.declare_derived_relation(
    'm16.count_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm16.sum_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm16.min_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm16.max_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm16.overflow_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm16.lower', 'm16.lower_row'::regtype, ARRAY['id']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm16.lower_count_alert', 'm16.fact_row'::regtype, ARRAY['id']::name[]);

DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm16.aggregates', 'version', 1, 'max_iterations', 8, 'max_facts', 32,
        'rules', jsonb_build_array(
            jsonb_build_object(
                'name', 'm16.lower', 'definition', 'm16.lower_source',
                'key', 'id', 'target', 'm16.lower', 'version', 1),
            jsonb_build_object(
                'name', 'm16.lower_count', 'definition', 'm16.group_source',
                'key', 'id', 'target', 'm16.lower_count_alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm16.lower', 'key', 'id', 'function', 'COUNT',
                    'expression', 'units', 'comparison', '>=', 'threshold', 1)),
            jsonb_build_object(
                'name', 'm16.count', 'definition', 'm16.group_source',
                'key', 'id', 'target', 'm16.count_alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm16.item_source', 'key', 'id', 'function', 'COUNT',
                    'expression', 'units', 'comparison', '>=', 'threshold', 2)),
            jsonb_build_object(
                'name', 'm16.sum', 'definition', 'm16.group_source',
                'key', 'id', 'target', 'm16.sum_alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm16.item_source', 'key', 'id', 'function', 'SUM',
                    'expression', 'amount', 'comparison', '>=', 'threshold', 10.50)),
            jsonb_build_object(
                'name', 'm16.min', 'definition', 'm16.group_source',
                'key', 'id', 'target', 'm16.min_alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm16.item_source', 'key', 'id', 'function', 'MIN',
                    'expression', 'label', 'comparison', '<', 'threshold', 'm')),
            jsonb_build_object(
                'name', 'm16.max', 'definition', 'm16.group_source',
                'key', 'id', 'target', 'm16.max_alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm16.item_source', 'key', 'id', 'function', 'MAX',
                    'expression', 'occurred_on', 'comparison', '>=', 'threshold', '2026-02-01')),
            jsonb_build_object(
                'name', 'm16.overflow', 'definition', 'm16.group_source',
                'key', 'id', 'target', 'm16.overflow_alert', 'version', 1,
                'aggregate_input', jsonb_build_object(
                    'relation', 'm16.item_source', 'key', 'id', 'function', 'SUM',
                    'expression', 'overflow_value', 'comparison', '>', 'threshold', 0))));
    preview jsonb;
    deployed uuid;
BEGIN
    preview := pgreact_api.preview_program(definition);
    IF preview ->> 'contract_version' <> '5'
       OR preview ->> 'plan_digest' !~ '^[0-9a-f]{64}$'
       OR preview -> 'program' IS DISTINCT FROM jsonb_set(definition, '{rules}', (
            SELECT jsonb_agg(value || jsonb_build_object('inputs', '[]'::jsonb) ORDER BY ordinal)
            FROM jsonb_array_elements(definition -> 'rules')
                 WITH ORDINALITY rule(value, ordinal))) THEN
        RAISE EXCEPTION 'M16 preview output changed: %', preview;
    END IF;
    deployed := pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
    PERFORM set_config('m16.program', deployed::text, false);
    PERFORM set_config('m16.definition', definition::text, false);
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m16_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;

CREATE FUNCTION m16.evidence_state()
RETURNS jsonb
LANGUAGE SQL
STABLE
AS $$
    SELECT jsonb_agg(jsonb_build_object(
        'rule', evidence.rule_name,
        'key', evidence.public_group_key,
        'relation', evidence.counted_relation,
        'function', evidence.aggregate_function,
        'expression', evidence.value_expression,
        'input_type', evidence.input_type::text,
        'result_type', evidence.result_type::text,
        'value', evidence.exact_value,
        'comparison', evidence.comparison,
        'threshold', evidence.typed_threshold,
        'truth', evidence.truth_result,
        'source_stratum', evidence.source_stratum,
        'target_stratum', evidence.target_stratum)
        ORDER BY evidence.rule_name, evidence.public_group_key)
    FROM pgreact.aggregate_dependency_evidence evidence
    WHERE evidence.program_version_id = current_setting('m16.program')::uuid
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := m16.evidence_state();
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('rule', 'm16.count', 'key', 1, 'relation', 'm16.item_source',
            'function', 'COUNT', 'expression', 'units', 'input_type', 'integer',
            'result_type', 'bigint', 'value', '2', 'comparison', '>=', 'threshold', '2',
            'truth', true, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.count', 'key', 2, 'relation', 'm16.item_source',
            'function', 'COUNT', 'expression', 'units', 'input_type', 'integer',
            'result_type', 'bigint', 'value', '0', 'comparison', '>=', 'threshold', '2',
            'truth', false, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.lower_count', 'key', 1, 'relation', 'm16.lower',
            'function', 'COUNT', 'expression', 'units', 'input_type', 'integer',
            'result_type', 'bigint', 'value', '1', 'comparison', '>=', 'threshold', '1',
            'truth', true, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.lower_count', 'key', 2, 'relation', 'm16.lower',
            'function', 'COUNT', 'expression', 'units', 'input_type', 'integer',
            'result_type', 'bigint', 'value', '0', 'comparison', '>=', 'threshold', '1',
            'truth', false, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.max', 'key', 1, 'relation', 'm16.item_source',
            'function', 'MAX', 'expression', 'occurred_on', 'input_type', 'date',
            'result_type', 'date', 'value', '2026-03-01', 'comparison', '>=',
            'threshold', '2026-02-01', 'truth', true, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.max', 'key', 2, 'relation', 'm16.item_source',
            'function', 'MAX', 'expression', 'occurred_on', 'input_type', 'date',
            'result_type', 'date', 'value', NULL, 'comparison', '>=',
            'threshold', '2026-02-01', 'truth', NULL, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.min', 'key', 1, 'relation', 'm16.item_source',
            'function', 'MIN', 'expression', 'label', 'input_type', 'text',
            'result_type', 'text', 'value', 'b', 'comparison', '<', 'threshold', 'm',
            'truth', true, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.min', 'key', 2, 'relation', 'm16.item_source',
            'function', 'MIN', 'expression', 'label', 'input_type', 'text',
            'result_type', 'text', 'value', NULL, 'comparison', '<', 'threshold', 'm',
            'truth', NULL, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.overflow', 'key', 1, 'relation', 'm16.item_source',
            'function', 'SUM', 'expression', 'overflow_value', 'input_type', 'real',
            'result_type', 'real', 'value', NULL, 'comparison', '>', 'threshold', '0',
            'truth', NULL, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.overflow', 'key', 2, 'relation', 'm16.item_source',
            'function', 'SUM', 'expression', 'overflow_value', 'input_type', 'real',
            'result_type', 'real', 'value', NULL, 'comparison', '>', 'threshold', '0',
            'truth', NULL, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.sum', 'key', 1, 'relation', 'm16.item_source',
            'function', 'SUM', 'expression', 'amount', 'input_type', 'numeric',
            'result_type', 'numeric', 'value', '10.50', 'comparison', '>=', 'threshold', '10.50',
            'truth', true, 'source_stratum', 0, 'target_stratum', 1),
        jsonb_build_object('rule', 'm16.sum', 'key', 2, 'relation', 'm16.item_source',
            'function', 'SUM', 'expression', 'amount', 'input_type', 'numeric',
            'result_type', 'numeric', 'value', NULL, 'comparison', '>=', 'threshold', '10.50',
            'truth', NULL, 'source_stratum', 0, 'target_stratum', 1)) THEN
        RAISE EXCEPTION 'M16 exact aggregate evidence changed: %', actual;
    END IF;
    IF (SELECT jsonb_agg(relation_name ORDER BY relation_name)
        FROM pgreact.derived_facts WHERE relation_name LIKE 'pgreact_runtime.m15_relation_%')
       IS NULL THEN
        RAISE EXCEPTION 'M16 expected typed derived facts were not created';
    END IF;
END
$$;

CREATE TEMP TABLE m16_stable_support AS
SELECT evidence.evidence_id, evidence.support_id
FROM pgreact_internal.aggregate_dependency_evidence evidence
JOIN pgreact_internal.derivation_program_rules rule
  USING (program_version_id, rule_version_id)
WHERE evidence.program_version_id = current_setting('m16.program')::uuid
  AND rule.rule_name = 'm16.sum' AND evidence.truth_result;

UPDATE m16.items SET amount = 7.25 WHERE item_id = 2;
SET SESSION AUTHORIZATION m16_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF (SELECT jsonb_build_object(
            'value', evidence.exact_value, 'truth', evidence.truth_result,
            'same_evidence', evidence.evidence_id = stable.evidence_id,
            'same_support', evidence.support_id = stable.support_id)
        FROM pgreact_internal.aggregate_dependency_evidence evidence
        JOIN pgreact_internal.derivation_program_rules rule
          USING (program_version_id, rule_version_id)
        CROSS JOIN m16_stable_support stable
        WHERE evidence.program_version_id = current_setting('m16.program')::uuid
          AND rule.rule_name = 'm16.sum' AND evidence.truth_result)
       IS DISTINCT FROM jsonb_build_object(
            'value', '11.50', 'truth', true,
            'same_evidence', true, 'same_support', true) THEN
        RAISE EXCEPTION 'M16 non-crossing value update changed support identity';
    END IF;
END
$$;

UPDATE m16.items SET units = NULL WHERE item_id = 1;
DELETE FROM m16.items WHERE item_id = 2;
SET SESSION AUTHORIZATION m16_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_object_agg(rule.rule_name, jsonb_build_object(
               'value', evidence.exact_value, 'truth', evidence.truth_result,
               'support', evidence.support_id IS NOT NULL) ORDER BY rule.rule_name)
    INTO actual
    FROM pgreact_internal.aggregate_dependency_evidence evidence
    JOIN pgreact_internal.derivation_program_rules rule
      USING (program_version_id, rule_version_id)
    WHERE evidence.program_version_id = current_setting('m16.program')::uuid
      AND evidence.semantic_key = (
          SELECT semantic_key FROM pgreact_internal.semantic_key_identities identity
          JOIN pgreact_internal.derivation_program_rules count_rule
            ON count_rule.rule_version_id = identity.rule_version_id
          WHERE count_rule.program_version_id = current_setting('m16.program')::uuid
            AND count_rule.rule_name = 'm16.count' AND identity.public_key = '1'::jsonb)
      AND rule.rule_name IN ('m16.count', 'm16.sum', 'm16.min');
    IF actual IS DISTINCT FROM jsonb_build_object(
        'm16.count', jsonb_build_object('value', '1', 'truth', false, 'support', false),
        'm16.min', jsonb_build_object('value', 'z', 'truth', false, 'support', false),
        'm16.sum', jsonb_build_object('value', '4.25', 'truth', false, 'support', false)) THEN
        RAISE EXCEPTION 'M16 deletion/null retraction changed: %', actual;
    END IF;
END
$$;

CREATE TEMP TABLE m16_before_failure AS
SELECT frontier, m16.evidence_state() AS evidence
FROM pgreact.derivation_programs
WHERE program_version_id = current_setting('m16.program')::uuid;
UPDATE m16.items SET overflow_value = '3.4e38'::real WHERE item_id IN (1, 3);
DO $$
BEGIN
    BEGIN
        SET LOCAL ROLE m16_operator;
        PERFORM pgreact_api.run();
        RAISE EXCEPTION 'M16 expected real SUM overflow';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'M13_RUN_PROGRAM_FAILED: program m16.aggregates failed' THEN
            RAISE;
        END IF;
    END;
    IF (SELECT jsonb_build_object('frontier', frontier, 'evidence', m16.evidence_state())
        FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m16.program')::uuid)
       IS DISTINCT FROM (SELECT jsonb_build_object('frontier', frontier, 'evidence', evidence)
                         FROM m16_before_failure) THEN
        RAISE EXCEPTION 'M16 overflow exposed a partial aggregate frontier';
    END IF;
END
$$;
UPDATE m16.items SET overflow_value = NULL;

DO $$
DECLARE actual jsonb; repaired bigint;
BEGIN
    SET LOCAL ROLE m16_operator;
    repaired := pgreact_api.reconcile_program('m16.aggregates');
    IF repaired <> 0 THEN
        RAISE EXCEPTION 'M16 clean reconciliation changed: %', repaired;
    END IF;
    RESET ROLE;
    UPDATE pgreact_internal.aggregate_dependency_evidence evidence
    SET active = false, invalidated_at = clock_timestamp()
    FROM pgreact_internal.derivation_program_rules rule
    WHERE rule.program_version_id = evidence.program_version_id
      AND rule.rule_version_id = evidence.rule_version_id
      AND evidence.program_version_id = current_setting('m16.program')::uuid
      AND rule.rule_name = 'm16.sum' AND evidence.public_group_key = '1'::jsonb;
    UPDATE pgreact_internal.aggregate_dependency_evidence evidence
    SET exact_value = 'wrong', truth_result = true
    FROM pgreact_internal.derivation_program_rules rule
    WHERE rule.program_version_id = evidence.program_version_id
      AND rule.rule_version_id = evidence.rule_version_id
      AND evidence.program_version_id = current_setting('m16.program')::uuid
      AND rule.rule_name = 'm16.min' AND evidence.public_group_key = '1'::jsonb;
    UPDATE pgreact_internal.aggregate_dependency_evidence evidence
    SET lower_frontier = 99
    FROM pgreact_internal.derivation_program_rules rule
    WHERE rule.program_version_id = evidence.program_version_id
      AND rule.rule_version_id = evidence.rule_version_id
      AND evidence.program_version_id = current_setting('m16.program')::uuid
      AND rule.rule_name = 'm16.max' AND evidence.public_group_key = '1'::jsonb;
    SET LOCAL ROLE m16_operator;
    repaired := pgreact_api.reconcile_program('m16.aggregates');
    RESET ROLE;
    SELECT jsonb_build_object(
        'repairs', repaired,
        'diagnostics', (SELECT jsonb_agg(diagnostic.code ORDER BY diagnostic_order)
            FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
            WHERE diagnostic.reconciliation_id = (
                SELECT max(reconciliation_id)
                FROM pgreact_internal.derivation_program_reconciliations
                WHERE program_version_id = current_setting('m16.program')::uuid)),
        'evidence', jsonb_object_agg(rule.rule_name, jsonb_build_object(
            'value', evidence.exact_value, 'truth', evidence.truth_result,
            'active', evidence.active) ORDER BY rule.rule_name))
    INTO actual
    FROM pgreact_internal.aggregate_dependency_evidence evidence
    JOIN pgreact_internal.derivation_program_rules rule
      USING (program_version_id, rule_version_id)
    WHERE evidence.program_version_id = current_setting('m16.program')::uuid
      AND evidence.public_group_key = '1'::jsonb
      AND rule.rule_name IN ('m16.max', 'm16.min', 'm16.sum');
    IF actual IS DISTINCT FROM jsonb_build_object(
        'repairs', 3,
        'diagnostics', jsonb_build_array(
            'MISSING_EVIDENCE', 'WRONG_AGGREGATE', 'WRONG_FRONTIER'),
        'evidence', jsonb_build_object(
            'm16.max', jsonb_build_object(
                'value', '2026-03-01', 'truth', true, 'active', true),
            'm16.min', jsonb_build_object('value', 'z', 'truth', false, 'active', true),
            'm16.sum', jsonb_build_object('value', '4.25', 'truth', false, 'active', true))) THEN
        RAISE EXCEPTION 'M16 aggregate reconciliation changed: %', actual;
    END IF;
END
$$;

CREATE TEMP TABLE m16_validation_before AS
SELECT
    (SELECT count(*) FROM pgreact_internal.derivation_program_versions) AS programs,
    (SELECT count(*) FROM pgreact_internal.key_wrappers) AS wrappers;
SET SESSION AUTHORIZATION m16_author;
DO $$
DECLARE
    valid jsonb;
    candidate jsonb;
    actual jsonb;
BEGIN
    valid := current_setting('m16.definition')::jsonb;
    candidate := jsonb_set(valid, '{rules,2,aggregate_input,expression}', '"random()"');
    SELECT jsonb_build_object('contract_version', contract_version, 'code', code,
        'severity', severity, 'object_identity', object_identity,
        'message', message, 'hint', hint, 'details', details)
    INTO actual FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5, 'code', 'PROGRAM_AGGREGATE_EXPRESSION_UNRESOLVED',
        'severity', 'ERROR', 'object_identity', 'm16.count',
        'message', 'aggregate value expression column does not exist',
        'hint', 'Project one supported typed column from the aggregate input relation.',
        'details', jsonb_build_object(
            'relation', 'm16.item_source', 'expression', 'random()')) THEN
        RAISE EXCEPTION 'M16 expression diagnostic changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,4,aggregate_input,function}', '"SUM"');
    SELECT jsonb_build_object('contract_version', contract_version, 'code', code,
        'severity', severity, 'object_identity', object_identity,
        'message', message, 'hint', hint, 'details', details)
    INTO actual FROM pgreact_api.validate_program(candidate);
    IF actual ->> 'code' <> 'PROGRAM_AGGREGATE_TYPE_UNSUPPORTED'
       OR actual #>> '{details,input_type}' <> 'text'
       OR actual #>> '{details,function}' <> 'SUM' THEN
        RAISE EXCEPTION 'M16 unsupported-type diagnostic changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,2,aggregate_input,function}', '"AVG"');
    SELECT jsonb_build_object('code', code, 'details', details) INTO actual
    FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'code', 'PROGRAM_AGGREGATE_FUNCTION_UNSUPPORTED',
        'details', jsonb_build_object('function', 'AVG')) THEN
        RAISE EXCEPTION 'M16 unsupported-function diagnostic changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,3,aggregate_input,threshold}', '"invalid"');
    SELECT jsonb_build_object('code', code, 'details', details) INTO actual
    FROM pgreact_api.validate_program(candidate);
    IF actual ->> 'code' <> 'PROGRAM_AGGREGATE_THRESHOLD_INVALID'
       OR actual #>> '{details,result_type}' <> 'numeric' THEN
        RAISE EXCEPTION 'M16 typed-threshold diagnostic changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,2,aggregate_input,relation}', '"item_source"');
    SELECT jsonb_build_object('code', code, 'details', details) INTO actual
    FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'code', 'PROGRAM_AGGREGATE_IDENTITY_AMBIGUOUS',
        'details', jsonb_build_object('relation', 'item_source')) THEN
        RAISE EXCEPTION 'M16 schema-identity diagnostic changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,2,aggregate_input,relation}', '"m16.rls_items"');
    SELECT jsonb_build_object('code', code, 'details', details) INTO actual
    FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'code', 'PROGRAM_AGGREGATE_RLS_UNSUPPORTED',
        'details', jsonb_build_object('relation', 'm16.rls_items')) THEN
        RAISE EXCEPTION 'M16 RLS diagnostic changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,2,aggregate_input,relation}', '"m16.volatile_items"');
    SELECT jsonb_build_object('code', code, 'details', details) INTO actual
    FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'code', 'PROGRAM_AGGREGATE_VOLATILE',
        'details', jsonb_build_object('relation', 'm16.volatile_items')) THEN
        RAISE EXCEPTION 'M16 volatile-expression diagnostic changed: %', actual;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'relation', relation_name, 'code', diagnostic.code,
        'details', diagnostic.details) ORDER BY relation_name)
    INTO actual
    FROM (VALUES
        ('m16.current_items'), ('m16.srf_items'), ('m16.udf_items')
    ) input(relation_name)
    CROSS JOIN LATERAL pgreact_api.validate_program(jsonb_set(
        valid, '{rules,2,aggregate_input,relation}', to_jsonb(relation_name))) diagnostic
    WHERE diagnostic.severity = 'ERROR';
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('relation', 'm16.current_items',
            'code', 'PROGRAM_AGGREGATE_VOLATILE',
            'details', jsonb_build_object('relation', 'm16.current_items')),
        jsonb_build_object('relation', 'm16.srf_items',
            'code', 'PROGRAM_AGGREGATE_VOLATILE',
            'details', jsonb_build_object('relation', 'm16.srf_items')),
        jsonb_build_object('relation', 'm16.udf_items',
            'code', 'PROGRAM_AGGREGATE_VOLATILE',
            'details', jsonb_build_object('relation', 'm16.udf_items'))) THEN
        RAISE EXCEPTION 'M16 expression-closure diagnostics changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,4,aggregate_input,relation}', '"m16.collated_items"');
    SELECT jsonb_build_object('code', code, 'details', details) INTO actual
    FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'code', 'PROGRAM_AGGREGATE_COLLATION_UNSUPPORTED',
        'details', jsonb_build_object('collation', 'non_c')) THEN
        RAISE EXCEPTION 'M16 collation diagnostic changed: %', actual;
    END IF;
    candidate := jsonb_set(valid, '{rules,2,aggregate_input,relation}', '"m16.private_items"');
    SELECT jsonb_build_object('code', code, 'details', details) INTO actual
    FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'code', 'PROGRAM_AGGREGATE_UNAUTHORIZED',
        'details', jsonb_build_object(
            'relation', 'm16.private_items', 'expression', 'units')) THEN
        RAISE EXCEPTION 'M16 authorization diagnostic changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF (SELECT jsonb_build_object(
            'programs', (SELECT count(*) FROM pgreact_internal.derivation_program_versions),
            'wrappers', (SELECT count(*) FROM pgreact_internal.key_wrappers)))
       IS DISTINCT FROM (SELECT to_jsonb(before_row) FROM m16_validation_before before_row) THEN
        RAISE EXCEPTION 'M16 rejected public declarations mutated durable state';
    END IF;
END
$$;

DO $$
DECLARE explanation jsonb; false_explanation jsonb;
BEGIN
    explanation := pgreact_api.explain('m16.max_alert', '1'::jsonb);
    IF explanation #>> '{evidence,proof,supports,0,aggregate_conditions,0,function}' <> 'MAX'
       OR explanation #>> '{evidence,proof,supports,0,aggregate_conditions,0,expression}' <> 'occurred_on'
       OR explanation #>> '{evidence,proof,supports,0,aggregate_conditions,0,result_type}' <> 'date'
       OR explanation #>> '{evidence,proof,supports,0,aggregate_conditions,0,value}' <> '2026-03-01'
       OR explanation::text LIKE '%pgreact_runtime.%'
       OR explanation::text LIKE '%__pgreact_%' THEN
        RAISE EXCEPTION 'M16 unified aggregate explanation changed: %', explanation;
    END IF;
    false_explanation := pgreact_api.explain('m16.min_alert', '2'::jsonb);
    IF false_explanation #>> '{evidence,aggregate_conditions,0,function}' <> 'MIN'
       OR false_explanation #>> '{evidence,aggregate_conditions,0,group_key}' <> '2'
       OR false_explanation #> '{evidence,aggregate_conditions,0,value}' IS DISTINCT FROM 'null'::jsonb
       OR false_explanation #> '{evidence,aggregate_conditions,0,truth}' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'M16 false aggregate explanation changed: %', false_explanation;
    END IF;
END
$$;

CREATE TEMP TABLE m16_before_drift AS
SELECT frontier, m16.evidence_state() AS evidence
FROM pgreact.derivation_programs
WHERE program_version_id = current_setting('m16.program')::uuid;
CREATE TEMP TABLE m16_stale_program_count AS
SELECT count(*) AS programs FROM pgreact_internal.derivation_program_versions;
SET SESSION AUTHORIZATION m16_author;
CREATE TEMP TABLE m16_stale_preview AS
SELECT pgreact_api.preview_program(current_setting('m16.definition')::jsonb) AS preview;
CREATE OR REPLACE VIEW m16.item_source AS
SELECT id, units, amount, label, occurred_on, overflow_value
FROM m16.items WHERE id > 0;
DO $$
BEGIN
    BEGIN
        PERFORM pgreact_api.deploy_program(
            current_setting('m16.definition')::jsonb,
            (SELECT preview ->> 'plan_digest' FROM m16_stale_preview));
        RAISE EXCEPTION 'M16 expected stale aggregate preview';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'M16_PROGRAM_PREVIEW_STALE' THEN RAISE; END IF;
    END;
END
$$;
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF (SELECT count(*) FROM pgreact_internal.derivation_program_versions)
       <> (SELECT programs FROM m16_stale_program_count) THEN
        RAISE EXCEPTION 'M16 stale preview mutated durable program state';
    END IF;
    BEGIN
        SET LOCAL ROLE m16_operator;
        PERFORM pgreact_api.run();
        RAISE EXCEPTION 'M16 expected aggregate input drift';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'M13_RUN_PROGRAM_FAILED: program m16.aggregates failed' THEN
            RAISE;
        END IF;
    END;
    IF (SELECT jsonb_build_object('frontier', frontier, 'evidence', m16.evidence_state())
        FROM pgreact.derivation_programs
        WHERE program_version_id = current_setting('m16.program')::uuid)
       IS DISTINCT FROM (SELECT jsonb_build_object('frontier', frontier, 'evidence', evidence)
                         FROM m16_before_drift) THEN
        RAISE EXCEPTION 'M16 drift failure exposed partial state';
    END IF;
END
$$;
CREATE OR REPLACE VIEW m16.item_source AS
SELECT id, units, amount, label, occurred_on, overflow_value FROM m16.items;

SELECT 'M16 typed aggregate semantics, evidence, diagnostics, and atomicity gate passed';
