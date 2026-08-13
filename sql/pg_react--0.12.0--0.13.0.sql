-- M16 richer stratified aggregation. The declaration remains one aggregate
-- dependency per rule and adds one typed column expression.

ALTER TABLE pgreact_internal.derivation_program_aggregate_inputs
    ALTER COLUMN threshold DROP NOT NULL,
    ADD COLUMN aggregate_function text NOT NULL DEFAULT 'COUNT_STAR'
        CHECK (aggregate_function IN ('COUNT_STAR', 'COUNT', 'SUM', 'MIN', 'MAX')),
    ADD COLUMN value_expression name,
    ADD COLUMN expression_attnum smallint,
    ADD COLUMN input_type oid,
    ADD COLUMN input_type_name text,
    ADD COLUMN result_type oid NOT NULL DEFAULT 'bigint'::regtype,
    ADD COLUMN result_type_name text NOT NULL DEFAULT 'bigint',
    ADD COLUMN expression_collation oid NOT NULL DEFAULT 0,
    ADD COLUMN expression_collation_name text,
    ADD COLUMN public_relation_name text,
    ADD COLUMN typed_threshold text;

UPDATE pgreact_internal.derivation_program_aggregate_inputs
SET typed_threshold = threshold::text;

ALTER TABLE pgreact_internal.derivation_program_aggregate_inputs
    ALTER COLUMN typed_threshold SET NOT NULL;

ALTER TABLE pgreact_internal.aggregate_dependency_evidence
    ALTER COLUMN exact_count DROP NOT NULL,
    ALTER COLUMN threshold DROP NOT NULL,
    ADD COLUMN aggregate_function text NOT NULL DEFAULT 'COUNT_STAR'
        CHECK (aggregate_function IN ('COUNT_STAR', 'COUNT', 'SUM', 'MIN', 'MAX')),
    ADD COLUMN value_expression name,
    ADD COLUMN input_type oid,
    ADD COLUMN input_type_name text,
    ADD COLUMN result_type oid NOT NULL DEFAULT 'bigint'::regtype,
    ADD COLUMN result_type_name text NOT NULL DEFAULT 'bigint',
    ADD COLUMN expression_collation oid NOT NULL DEFAULT 0,
    ADD COLUMN expression_collation_name text,
    ADD COLUMN exact_value text,
    ADD COLUMN typed_threshold text,
    ADD COLUMN truth_result boolean,
    ADD COLUMN public_group_key jsonb,
    ADD COLUMN canonical_group_key bytea;

UPDATE pgreact_internal.aggregate_dependency_evidence
SET exact_value = exact_count::text,
    typed_threshold = threshold::text,
    truth_result = CASE comparison
        WHEN '=' THEN exact_count = threshold
        WHEN '<' THEN exact_count < threshold
        WHEN '<=' THEN exact_count <= threshold
        WHEN '>' THEN exact_count > threshold
        WHEN '>=' THEN exact_count >= threshold
    END;

ALTER TABLE pgreact_internal.aggregate_dependency_evidence
    ALTER COLUMN typed_threshold SET NOT NULL;

ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    DROP CONSTRAINT derivation_program_repair_diagnostics_code_check;
ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    ADD CHECK (code IN (
        'MISSING_SUPPORT', 'EXTRA_SUPPORT', 'STALE_SUPPORT',
        'MISSING_FACT', 'EXTRA_FACT', 'STALE_FACT',
        'CIRCULAR_ONLY', 'WRONG_FRONTIER', 'MISSING_EVIDENCE',
        'EXTRA_EVIDENCE', 'STALE_EVIDENCE', 'WRONG_STRATUM',
        'MISSING_AGGREGATE_EVIDENCE', 'EXTRA_AGGREGATE_EVIDENCE',
        'STALE_AGGREGATE_EVIDENCE', 'WRONG_COUNT', 'WRONG_AGGREGATE'
    ));

CREATE FUNCTION pgreact_internal.aggregate_result_type(
    aggregate_function text,
    input_type oid
)
RETURNS oid
LANGUAGE SQL
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE
        WHEN $1 IN ('COUNT_STAR', 'COUNT') THEN 'bigint'::regtype::oid
        WHEN $1 = 'SUM' AND $2 IN ('smallint'::regtype, 'integer'::regtype)
            THEN 'bigint'::regtype::oid
        WHEN $1 = 'SUM' AND $2 IN ('bigint'::regtype, 'numeric'::regtype)
            THEN 'numeric'::regtype::oid
        WHEN $1 = 'SUM' AND $2 = 'real'::regtype THEN 'real'::regtype::oid
        WHEN $1 = 'SUM' AND $2 = 'double precision'::regtype
            THEN 'double precision'::regtype::oid
        WHEN $1 IN ('MIN', 'MAX') AND $2 IN (
            'smallint'::regtype, 'integer'::regtype, 'bigint'::regtype,
            'numeric'::regtype, 'real'::regtype, 'double precision'::regtype,
            'text'::regtype, 'date'::regtype, 'timestamp'::regtype,
            'timestamp with time zone'::regtype, 'uuid'::regtype)
            THEN $2
        ELSE NULL
    END
$$;

ALTER FUNCTION pgreact.validate_derivation_program(jsonb)
    RENAME TO validate_derivation_program_m15;
ALTER FUNCTION pgreact.validate_derivation_program_m15(jsonb)
    SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact.validate_derivation_program(definition jsonb)
RETURNS TABLE(
    contract_version integer,
    code text,
    severity text,
    object_identity text,
    message text,
    hint text,
    details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rule_item record;
    aggregate_item jsonb;
    source_oid oid;
    identity_oid oid;
    source_identity text;
    expression_attribute record;
    function_name text;
    resolved_result_type oid;
    base_definition jsonb;
    diagnostic record;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END) rule(value)
        WHERE rule.value ? 'aggregate_input'
          AND (rule.value -> 'aggregate_input') ? 'function'
    ) THEN
        RETURN QUERY SELECT *
        FROM pgreact_internal.validate_derivation_program_m15(definition);
        RETURN;
    END IF;

    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END)
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        IF NOT rule_item.value ? 'aggregate_input' THEN CONTINUE; END IF;
        aggregate_item := rule_item.value -> 'aggregate_input';
        IF NOT aggregate_item ? 'function' THEN CONTINUE; END IF;
        IF jsonb_typeof(aggregate_item) IS DISTINCT FROM 'object'
           OR NOT aggregate_item ?& ARRAY[
               'relation', 'key', 'function', 'expression', 'comparison', 'threshold']
           OR (SELECT count(*) FROM jsonb_object_keys(aggregate_item)) NOT IN (6, 7)
           OR ((SELECT count(*) FROM jsonb_object_keys(aggregate_item)) = 7
               AND NOT aggregate_item ? 'public_relation') THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_INVALID', 'ERROR',
                COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                'typed aggregate_input requires exactly relation, key, function, expression, comparison, and threshold',
                'Declare one COUNT, SUM, MIN, or MAX over one named input column.',
                '{}'::jsonb;
            RETURN;
        END IF;
        function_name := aggregate_item ->> 'function';
        IF function_name NOT IN ('COUNT', 'SUM', 'MIN', 'MAX') THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_FUNCTION_UNSUPPORTED', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate function is outside the M16 allow-list',
                'Use COUNT, SUM, MIN, or MAX; COUNT(*) keeps the inherited four-field declaration.',
                jsonb_build_object('function', function_name);
            RETURN;
        END IF;
        IF jsonb_typeof(aggregate_item -> 'expression') IS DISTINCT FROM 'string'
           OR aggregate_item ->> 'expression' = '' THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_EXPRESSION_UNSUPPORTED', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate value expression must be one immutable named column',
                'Project casts or immutable calculations into the input view, then name that output column.',
                jsonb_build_object('expression', aggregate_item -> 'expression');
            RETURN;
        END IF;
        source_identity := COALESCE(
            aggregate_item ->> 'public_relation', aggregate_item ->> 'relation');
        IF strpos(source_identity, '.') = 0 THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_IDENTITY_AMBIGUOUS', 'ERROR',
                rule_item.value ->> 'name',
                'typed aggregate input relation must be schema-qualified',
                'Use a schema-qualified relation so search_path cannot retarget the dependency.',
                jsonb_build_object('relation', source_identity);
            RETURN;
        END IF;
        identity_oid := to_regclass(source_identity);
        source_oid := to_regclass(aggregate_item ->> 'relation');
        IF source_oid IS NULL OR identity_oid IS NULL THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_UNRESOLVED', 'ERROR',
                source_identity,
                'aggregate input does not resolve to a finite table or view',
                'Name one authoritative or active lower-stratum relation.',
                jsonb_build_object('rule', rule_item.value ->> 'name');
            RETURN;
        END IF;
        IF EXISTS (
            WITH RECURSIVE relations(relid) AS (
                SELECT identity_oid
                UNION
                SELECT dependency.refobjid
                FROM relations parent
                JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relid
                JOIN pg_depend dependency
                  ON dependency.classid = 'pg_rewrite'::regclass
                 AND dependency.objid = rewrite.oid
                 AND dependency.refclassid = 'pg_class'::regclass
                JOIN pg_class relation ON relation.oid = dependency.refobjid
                WHERE relation.relkind IN ('r', 'p', 'v', 'm')
            )
            SELECT 1 FROM relations
            JOIN pg_class relation ON relation.oid = relations.relid
            WHERE relation.relrowsecurity
        ) THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_RLS_UNSUPPORTED', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate input closure contains a row-security relation',
                'Use an unprotected authoritative projection owned by the program author.',
                jsonb_build_object('relation', source_identity);
            RETURN;
        END IF;
        IF EXISTS (
            WITH RECURSIVE relations(relid) AS (
                SELECT identity_oid
                UNION
                SELECT dependency.refobjid
                FROM relations parent
                JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relid
                JOIN pg_depend dependency
                  ON dependency.classid = 'pg_rewrite'::regclass
                 AND dependency.objid = rewrite.oid
                 AND dependency.refclassid = 'pg_class'::regclass
                JOIN pg_class relation ON relation.oid = dependency.refobjid
                WHERE relation.relkind IN ('v', 'm')
            ), trees AS (
                SELECT pgreact_internal.relation_query_tree(relid) AS tree
                FROM relations
            ), procedure_ids(oid) AS (
                SELECT match[1]::oid
                FROM trees
                CROSS JOIN LATERAL regexp_matches(tree, E':funcid ([0-9]+)', 'g') match
            ), operator_ids(oid) AS (
                SELECT match[1]::oid
                FROM trees
                CROSS JOIN LATERAL regexp_matches(tree, E':opno ([0-9]+)', 'g') match
            )
            SELECT 1 FROM trees
            WHERE tree ~ E'\\{SQLVALUEFUNCTION'
               OR tree ~ E':has(Aggs|WindowFuncs|TargetSRFs|SubLinks) true'
            UNION ALL
            SELECT 1
            FROM procedure_ids
            JOIN pg_proc procedure USING (oid)
            JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
            WHERE (procedure.provolatile <> 'i' OR procedure.proretset
               OR namespace.nspname <> 'pg_catalog')
              AND NOT (
                  procedure.oid =
                      'pg_catalog.jsonb_populate_record(anyelement,jsonb)'::regprocedure
                  AND EXISTS (
                      SELECT 1
                      FROM pgreact_internal.keyed_derived_relations derived
                      JOIN pgreact_internal.derived_relation_versions version
                        USING (relation_version_id)
                      WHERE derived.public_name = source_identity
                        AND version.state = 'ACTIVE'))
            UNION ALL
            SELECT 1
            FROM operator_ids
            JOIN pg_operator operator USING (oid)
            JOIN pg_namespace namespace ON namespace.oid = operator.oprnamespace
            JOIN pg_proc procedure ON procedure.oid = operator.oprcode
            WHERE procedure.provolatile <> 'i' OR procedure.proretset
               OR namespace.nspname <> 'pg_catalog'
        ) THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_VOLATILE', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate input closure must use only immutable PostgreSQL expressions',
                'Project values through immutable pg_catalog functions and operators only.',
                jsonb_build_object('relation', source_identity);
            RETURN;
        END IF;
        SELECT attribute.attnum, attribute.atttypid, attribute.attcollation,
               collation_row.collname, collation_row.collisdeterministic,
               database_row.datcollate
        INTO expression_attribute
        FROM pg_attribute attribute
        LEFT JOIN pg_collation collation_row ON collation_row.oid = attribute.attcollation
        CROSS JOIN pg_database database_row
        WHERE attribute.attrelid = source_oid
          AND attribute.attname = (aggregate_item ->> 'expression')::name
          AND attribute.attnum > 0 AND NOT attribute.attisdropped
          AND database_row.datname = current_database();
        IF NOT FOUND THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_EXPRESSION_UNRESOLVED', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate value expression column does not exist',
                'Project one supported typed column from the aggregate input relation.',
                jsonb_build_object('relation', source_identity,
                                   'expression', aggregate_item ->> 'expression');
            RETURN;
        END IF;
        resolved_result_type := pgreact_internal.aggregate_result_type(
            function_name, expression_attribute.atttypid);
        IF resolved_result_type IS NULL THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_TYPE_UNSUPPORTED', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate input type is outside the M16 allow-list',
                'Use COUNT on a built-in scalar, SUM on a supported numeric, or MIN/MAX on a supported ordered type.',
                jsonb_build_object('function', function_name,
                                   'input_type', expression_attribute.atttypid::regtype::text);
            RETURN;
        END IF;
        IF function_name = 'COUNT'
           AND expression_attribute.atttypid NOT IN (
               'boolean'::regtype, 'smallint'::regtype, 'integer'::regtype,
               'bigint'::regtype, 'numeric'::regtype, 'real'::regtype,
               'double precision'::regtype, 'text'::regtype, 'date'::regtype,
               'timestamp'::regtype, 'timestamp with time zone'::regtype,
               'uuid'::regtype) THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_TYPE_UNSUPPORTED', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate input type is outside the M16 allow-list',
                'Project one supported built-in scalar column.',
                jsonb_build_object('function', function_name,
                                   'input_type', expression_attribute.atttypid::regtype::text);
            RETURN;
        END IF;
        IF expression_attribute.atttypid = 'text'::regtype
           AND (NOT expression_attribute.collisdeterministic
                OR (expression_attribute.collname <> 'C'
                    AND NOT (expression_attribute.collname = 'default'
                             AND expression_attribute.datcollate IN ('C', 'C.UTF-8', 'C.utf8')))) THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_COLLATION_UNSUPPORTED', 'ERROR',
                rule_item.value ->> 'name',
                'text aggregation requires deterministic C collation',
                'Project the value column with COLLATE "C".',
                jsonb_build_object('collation', expression_attribute.collname);
            RETURN;
        END IF;
        IF NOT has_table_privilege(session_user, identity_oid, 'SELECT')
           OR NOT has_column_privilege(
               session_user, identity_oid, aggregate_item ->> 'expression', 'SELECT') THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_UNAUTHORIZED', 'ERROR',
                rule_item.value ->> 'name',
                'program owner cannot read the aggregate input expression',
                'Grant SELECT on the relation and value column before validation.',
                jsonb_build_object('relation', source_identity,
                                   'expression', aggregate_item ->> 'expression');
            RETURN;
        END IF;
        IF aggregate_item ->> 'comparison' NOT IN ('=', '<', '<=', '>', '>=')
           OR jsonb_typeof(aggregate_item -> 'threshold') NOT IN ('number', 'string')
           OR NOT COALESCE(pg_input_is_valid(
               aggregate_item ->> 'threshold', resolved_result_type::regtype::text), false) THEN
            RETURN QUERY SELECT 5, 'PROGRAM_AGGREGATE_THRESHOLD_INVALID', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate threshold cannot be cast to the exact result type with a supported comparison',
                'Use =, <, <=, >, or >= and a PostgreSQL literal for the published result type.',
                jsonb_build_object('comparison', aggregate_item ->> 'comparison',
                                   'threshold', aggregate_item -> 'threshold',
                                   'result_type', resolved_result_type::regtype::text);
            RETURN;
        END IF;
    END LOOP;

    base_definition := jsonb_set(definition, '{rules}', COALESCE((
        SELECT jsonb_agg(CASE
            WHEN value ? 'aggregate_input' AND (value -> 'aggregate_input') ? 'function'
            THEN jsonb_set(value, '{aggregate_input}',
                jsonb_build_object(
                    'relation', value #>> '{aggregate_input,relation}',
                    'key', value #>> '{aggregate_input,key}',
                    'comparison', value #>> '{aggregate_input,comparison}',
                    'threshold', 0))
            ELSE value END ORDER BY ordinal)
        FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY rules(value, ordinal)
    ), '[]'::jsonb), true);
    FOR diagnostic IN
        SELECT *
        FROM pgreact_internal.validate_derivation_program_m15(base_definition) legacy
        WHERE legacy.code <> 'OK'
    LOOP
        RETURN QUERY SELECT 5, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint,
            diagnostic.details;
        RETURN;
    END LOOP;
    RETURN QUERY SELECT 5, 'OK', 'INFO', definition ->> 'name',
        'typed stratified aggregate derivation program is valid',
        'Preview and deploy the program.',
        jsonb_build_object('version', (definition ->> 'version')::integer,
                           'rules', jsonb_array_length(definition -> 'rules'));
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.normalize_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    normalized jsonb := pgreact_api.infer_program(definition);
    rule_item record;
    dependency record;
    derived pgreact_internal.keyed_derived_relations%ROWTYPE;
    dependency_derived pgreact_internal.keyed_derived_relations%ROWTYPE;
    wrapper regclass;
    source regclass;
BEGIN
    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'rules')
             WITH ORDINALITY rules(value, ordinal)
        ORDER BY ordinal
    LOOP
        SELECT * INTO derived
        FROM pgreact_internal.keyed_derived_relations
        WHERE public_name = rule_item.value ->> 'target';
        IF NOT FOUND THEN CONTINUE; END IF;
        source := to_regclass(rule_item.value ->> 'definition');
        IF source IS NULL THEN
            RAISE EXCEPTION 'M15_DERIVATION_SOURCE: definition view % does not exist',
                rule_item.value ->> 'definition';
        END IF;
        SELECT * INTO dependency_derived
        FROM pgreact_internal.keyed_derived_relations
        WHERE public_name = rule_item.value ->> 'definition';
        IF FOUND THEN
            wrapper := dependency_derived.internal_name::regclass;
        ELSE
            wrapper := pgreact_internal.create_key_wrapper(source, derived.key_columns);
        END IF;
        normalized := jsonb_set(normalized,
            ARRAY['rules', (rule_item.ordinal - 1)::text, 'definition'],
            to_jsonb(wrapper::text));
        normalized := jsonb_set(normalized,
            ARRAY['rules', (rule_item.ordinal - 1)::text, 'key'],
            to_jsonb('__pgreact_key'::text));
        normalized := jsonb_set(normalized,
            ARRAY['rules', (rule_item.ordinal - 1)::text, 'target'],
            to_jsonb(derived.internal_name));
        FOR dependency IN
            SELECT dependency_kind, dependency_value, dependency_ordinal
            FROM (
                SELECT 'inputs'::text, value, ordinal
                FROM jsonb_array_elements(COALESCE(normalized #> ARRAY[
                    'rules', (rule_item.ordinal - 1)::text, 'inputs'], '[]'::jsonb))
                     WITH ORDINALITY input(value, ordinal)
                UNION ALL
                SELECT 'negative_inputs'::text, value, ordinal
                FROM jsonb_array_elements(COALESCE(rule_item.value -> 'negative_inputs', '[]'::jsonb))
                     WITH ORDINALITY negative_input(value, ordinal)
            ) dependencies(dependency_kind, dependency_value, dependency_ordinal)
        LOOP
            source := to_regclass(dependency.dependency_value ->> 'relation');
            IF source IS NULL THEN
                RAISE EXCEPTION 'M15_DERIVATION_INPUT: relation % does not exist',
                    dependency.dependency_value ->> 'relation';
            END IF;
            SELECT * INTO dependency_derived
            FROM pgreact_internal.keyed_derived_relations
            WHERE public_name = dependency.dependency_value ->> 'relation';
            IF FOUND THEN
                wrapper := dependency_derived.internal_name::regclass;
            ELSE
                wrapper := pgreact_internal.create_key_wrapper(source, derived.key_columns);
            END IF;
            normalized := jsonb_set(normalized, ARRAY[
                'rules', (rule_item.ordinal - 1)::text, dependency.dependency_kind,
                (dependency.dependency_ordinal - 1)::text, 'relation'], to_jsonb(wrapper::text));
            normalized := jsonb_set(normalized, ARRAY[
                'rules', (rule_item.ordinal - 1)::text, dependency.dependency_kind,
                (dependency.dependency_ordinal - 1)::text, 'key'], to_jsonb('__pgreact_key'::text));
        END LOOP;
        IF rule_item.value -> 'aggregate_input' IS NOT NULL THEN
            source := to_regclass(rule_item.value #>> '{aggregate_input,relation}');
            IF source IS NULL THEN
                RAISE EXCEPTION 'M15_DERIVATION_INPUT: relation % does not exist',
                    rule_item.value #>> '{aggregate_input,relation}';
            END IF;
            SELECT * INTO dependency_derived
            FROM pgreact_internal.keyed_derived_relations
            WHERE public_name = rule_item.value #>> '{aggregate_input,relation}';
            IF FOUND THEN
                wrapper := dependency_derived.internal_name::regclass;
            ELSE
                wrapper := pgreact_internal.create_key_wrapper(source, derived.key_columns);
            END IF;
            IF (rule_item.value -> 'aggregate_input') ? 'function' THEN
                normalized := jsonb_set(normalized,
                    ARRAY['rules', (rule_item.ordinal - 1)::text,
                          'aggregate_input', 'public_relation'],
                    to_jsonb(rule_item.value #>> '{aggregate_input,relation}'));
            END IF;
            normalized := jsonb_set(normalized,
                ARRAY['rules', (rule_item.ordinal - 1)::text, 'aggregate_input', 'relation'],
                to_jsonb(wrapper::text));
            normalized := jsonb_set(normalized,
                ARRAY['rules', (rule_item.ordinal - 1)::text, 'aggregate_input', 'key'],
                to_jsonb('__pgreact_key'::text));
        END IF;
    END LOOP;
    RETURN normalized;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.validate_program(definition jsonb)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE normalized jsonb; diagnostic record;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(definition -> 'rules') rule
        JOIN pgreact_internal.keyed_derived_relations relation_spec
          ON relation_spec.public_name = rule ->> 'target') THEN
        RETURN QUERY SELECT * FROM pgreact_internal.validate_program_m14(definition);
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(definition -> 'rules') rule
        WHERE (rule -> 'aggregate_input') ? 'function') THEN
        SELECT * INTO diagnostic
        FROM pgreact.validate_derivation_program(definition) result
        WHERE result.severity = 'ERROR'
          AND result.code IN (
              'PROGRAM_AGGREGATE_INVALID',
              'PROGRAM_AGGREGATE_FUNCTION_UNSUPPORTED',
              'PROGRAM_AGGREGATE_EXPRESSION_UNSUPPORTED',
              'PROGRAM_AGGREGATE_IDENTITY_AMBIGUOUS',
              'PROGRAM_AGGREGATE_UNRESOLVED',
              'PROGRAM_AGGREGATE_RLS_UNSUPPORTED',
              'PROGRAM_AGGREGATE_VOLATILE',
              'PROGRAM_AGGREGATE_EXPRESSION_UNRESOLVED',
              'PROGRAM_AGGREGATE_TYPE_UNSUPPORTED',
              'PROGRAM_AGGREGATE_COLLATION_UNSUPPORTED',
              'PROGRAM_AGGREGATE_UNAUTHORIZED',
              'PROGRAM_AGGREGATE_THRESHOLD_INVALID')
        ORDER BY result.code, result.object_identity LIMIT 1;
        IF FOUND THEN
            RETURN QUERY SELECT 5, diagnostic.code, diagnostic.severity,
                diagnostic.object_identity, diagnostic.message, diagnostic.hint,
                diagnostic.details;
            RETURN;
        END IF;
    END IF;
    normalized := pgreact_internal.normalize_program(definition);
    RETURN QUERY
    SELECT 5, result.code, result.severity, result.object_identity,
           result.message, result.hint,
           result.details || jsonb_build_object('normalized_definition', normalized)
    FROM pgreact.validate_derivation_program(normalized) result;
END
$$;

CREATE FUNCTION pgreact_internal.program_plan_digest(normalized jsonb)
RETURNS text
LANGUAGE SQL
STABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH relations(relation_name) AS (
        SELECT rule ->> 'definition'
        FROM jsonb_array_elements($1 -> 'rules') rule
        UNION
        SELECT input ->> 'relation'
        FROM jsonb_array_elements($1 -> 'rules') rule
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(rule -> 'inputs', '[]'::jsonb)) input
        UNION
        SELECT input ->> 'relation'
        FROM jsonb_array_elements($1 -> 'rules') rule
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(rule -> 'negative_inputs', '[]'::jsonb)) input
        UNION
        SELECT rule #>> '{aggregate_input,relation}'
        FROM jsonb_array_elements($1 -> 'rules') rule
        WHERE rule ? 'aggregate_input'
    ), fingerprints AS (
        SELECT relation_name,
               encode(pgreact_internal.source_closure_digest(to_regclass(relation_name)), 'hex')
                   AS definition_digest,
               encode(pgreact_internal.source_row_signature(to_regclass(relation_name)), 'hex')
                   AS row_signature
        FROM relations
    )
    SELECT encode(sha256(convert_to(
        $1::text || ':' || session_user || ':' || COALESCE(string_agg(
            relation_name || ':' || definition_digest || ':' || row_signature,
            E'\n' ORDER BY relation_name), ''), 'UTF8')), 'hex')
    FROM fingerprints
$$;

CREATE OR REPLACE FUNCTION pgreact_api.preview_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    normalized jsonb;
    inferred jsonb;
    diagnostic record;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(definition -> 'rules') rule
        JOIN pgreact_internal.keyed_derived_relations relation_spec
          ON relation_spec.public_name = rule ->> 'target') THEN
        RETURN pgreact_internal.preview_program_m14(definition);
    END IF;
    SELECT * INTO diagnostic FROM pgreact_api.validate_program(definition)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M16_PROGRAM_INVALID: % for %', diagnostic.code, diagnostic.object_identity
            USING HINT = diagnostic.hint;
    END IF;
    normalized := pgreact_internal.normalize_program(definition);
    inferred := pgreact_api.infer_program(definition);
    RETURN jsonb_build_object(
        'contract_version', 5, 'program', inferred,
        'plan_digest', pgreact_internal.program_plan_digest(normalized));
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.deploy_program(
    definition jsonb,
    expected_plan_digest text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    normalized jsonb;
    actual_plan_digest text;
    deployed uuid;
    rule_item record;
    derived pgreact_internal.keyed_derived_relations%ROWTYPE;
    version_id uuid;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(definition -> 'rules') rule
        JOIN pgreact_internal.keyed_derived_relations relation_spec
          ON relation_spec.public_name = rule ->> 'target') THEN
        RETURN pgreact_internal.deploy_program_m14(definition, expected_plan_digest);
    END IF;
    SELECT * INTO rule_item FROM pgreact_api.validate_program(definition)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M16_PROGRAM_INVALID: % for %', rule_item.code, rule_item.object_identity
            USING HINT = rule_item.hint;
    END IF;
    normalized := pgreact_internal.normalize_program(definition);
    actual_plan_digest := pgreact_internal.program_plan_digest(normalized);
    IF expected_plan_digest IS NOT NULL AND expected_plan_digest <> actual_plan_digest THEN
        RAISE EXCEPTION 'M16_PROGRAM_PREVIEW_STALE'
            USING HINT = 'Preview the program again after DDL or deployment changes.';
    END IF;
    deployed := pgreact_internal.deploy_derivation_program(normalized, NULL);
    FOR rule_item IN
        SELECT original.value, normalized_rule.value AS normalized_value
        FROM jsonb_array_elements(definition -> 'rules') WITH ORDINALITY original(value, ordinal)
        JOIN jsonb_array_elements(normalized -> 'rules') WITH ORDINALITY normalized_rule(value, ordinal)
          USING (ordinal)
    LOOP
        SELECT * INTO derived
        FROM pgreact_internal.keyed_derived_relations
        WHERE public_name = rule_item.value ->> 'target';
        IF NOT FOUND THEN CONTINUE; END IF;
        SELECT version.rule_version_id INTO STRICT version_id
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name = rule_item.value ->> 'name' AND version.state = 'ACTIVE';
        INSERT INTO pgreact_internal.keyed_rule_versions VALUES (
            version_id, to_regclass(rule_item.value ->> 'definition'),
            to_regclass(rule_item.normalized_value ->> 'definition'),
            derived.key_columns, derived.key_types, derived.key_collations)
        ON CONFLICT (rule_version_id) DO UPDATE
        SET public_condition = EXCLUDED.public_condition,
            wrapper_condition = EXCLUDED.wrapper_condition,
            key_columns = EXCLUDED.key_columns,
            key_types = EXCLUDED.key_types,
            key_collations = EXCLUDED.key_collations;
    END LOOP;
    RETURN deployed;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.derivation_component_fingerprint(
    target_program uuid,
    target_component uuid
)
RETURNS bytea
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sha256(convert_to(
        COALESCE((
            SELECT string_agg(format('%s@%s:%s@%s:%s:%s:%s:%s',
                                     rule.rule_name, rule_version.version,
                                     relation.relation_name, relation_version.version,
                                     support.semantic_key, support.fact::text,
                                     support.source_binding::text,
                                     COALESCE((
                                         SELECT string_agg(format('%s@%s:%s',
                                             input_relation.relation_name, input_version.version,
                                             input.semantic_key), ',' ORDER BY input.input_order)
                                         FROM pgreact_internal.derived_support_inputs input
                                         JOIN pgreact_internal.derived_relation_versions input_version
                                           ON input_version.relation_version_id = input.relation_version_id
                                         JOIN pgreact_internal.derived_relations input_relation USING (relation_id)
                                         WHERE input.support_id = support.support_id
                                     ), '')),
                E'\n' ORDER BY rule.rule_name, rule_version.version, relation.relation_name,
                relation_version.version, support.semantic_key, support.fact::text,
                support.source_binding::text)
            FROM pgreact_internal.derived_supports support
            JOIN pgreact_internal.derivation_program_rules member
              ON member.program_version_id = $1 AND member.component_id = $2
             AND member.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.derivation_rule_versions rule_version
              ON rule_version.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.rules rule ON rule.rule_id = rule_version.rule_id
            JOIN pgreact_internal.derived_relation_versions relation_version
              ON relation_version.relation_version_id = support.relation_version_id
            JOIN pgreact_internal.derived_relations relation USING (relation_id)
            WHERE support.active
        ), '') || E'\n--facts--\n' || COALESCE((
            SELECT string_agg(format('%s@%s:%s:%s', relation.relation_name,
                relation_version.version, fact.semantic_key, fact.fact::text), E'\n'
                ORDER BY relation.relation_name, relation_version.version, fact.semantic_key)
            FROM pgreact_internal.derived_facts fact
            JOIN pgreact_internal.derivation_program_components component
              ON component.program_version_id = $1 AND component.component_id = $2
             AND fact.relation_version_id = ANY (component.target_relations)
            JOIN pgreact_internal.derived_relation_versions relation_version
              ON relation_version.relation_version_id = fact.relation_version_id
            JOIN pgreact_internal.derived_relations relation USING (relation_id)
        ), '') || E'\n--aggregates--\n' || COALESCE((
            SELECT string_agg(CASE WHEN evidence.aggregate_function = 'COUNT_STAR'
                THEN format('%s:%s:%s:%s:%s:%s', evidence.rule_version_id,
                    evidence.semantic_key, evidence.exact_count, evidence.comparison,
                    evidence.threshold, evidence.active)
                ELSE format('%s:%s:%s:%s:%s:%s:%s:%s:%s:%s',
                    evidence.rule_version_id, evidence.semantic_key,
                    encode(evidence.canonical_group_key, 'hex'),
                    evidence.aggregate_function, evidence.value_expression,
                    evidence.result_type_name, evidence.exact_value,
                    evidence.comparison, evidence.typed_threshold, evidence.truth_result)
                END, E'\n'
                ORDER BY evidence.rule_version_id, evidence.semantic_key)
            FROM pgreact_internal.aggregate_dependency_evidence evidence
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = $1 AND rule.component_id = $2
             AND rule.rule_version_id = evidence.rule_version_id
        ), ''), 'UTF8'))
$$;

CREATE OR REPLACE FUNCTION pgreact.reconcile_derivation_program(target_program uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    activation_row record;
    aggregate_evidence record;
    actual_value text;
    actual_truth boolean;
    actual_threshold text;
    expected_evidence_id uuid;
    expected_evidence_ids uuid[] := '{}'::uuid[];
    expected_metadata jsonb;
    actual_metadata jsonb;
    reconciliation_row_id bigint;
    next_diagnostic_order integer;
    aggregate_defects jsonb := '[]'::jsonb;
    aggregate_defect jsonb;
BEGIN
    PERFORM pgreact_internal.assert_program_owner(target_program);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM set_config('TimeZone', 'UTC', true);
    PERFORM set_config('DateStyle', 'ISO, YMD', true);
    PERFORM set_config('extra_float_digits', '3', true);
    FOR activation_row IN
        SELECT activation.rule_version_id, activation.activation_id,
               activation.semantic_key,
               activation.current_bindings -> '__pgreact_public_key' AS public_group_key,
               (activation.current_bindings ->> '__pgreact_canonical')::bytea
                   AS canonical_group_key,
               input.relation_oid, input.relation_name, input.key_column,
               input.comparison, input.typed_threshold,
               input.aggregate_function, input.value_expression,
               input.input_type, input.input_type_name,
               input.result_type, input.result_type_name,
               input.expression_collation, input.expression_collation_name,
               COALESCE(source_component.stratum, 0) AS source_stratum,
               target_component.stratum AS target_stratum,
               version.frontier,
               support.support_id
        FROM pgreact_internal.activation_state activation
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = target_program
         AND rule.rule_version_id = activation.rule_version_id
        JOIN pgreact_internal.derivation_program_aggregate_inputs input
          ON input.program_version_id = target_program
         AND input.rule_version_id = activation.rule_version_id
        JOIN pgreact_internal.derivation_program_versions version
          ON version.program_version_id = target_program
        JOIN pgreact_internal.derivation_program_components target_component
          ON target_component.program_version_id = target_program
         AND target_component.component_id = rule.component_id
        LEFT JOIN pgreact_internal.derived_relation_versions source_version
          ON source_version.public_view_oid = input.relation_oid
         AND source_version.state = 'ACTIVE'
        LEFT JOIN pgreact_internal.derivation_program_components source_component
          ON source_component.program_version_id = target_program
         AND source_version.relation_version_id = ANY (source_component.target_relations)
        LEFT JOIN pgreact_internal.derived_supports support
          ON support.rule_version_id = activation.rule_version_id
         AND support.activation_id = activation.activation_id AND support.active
        WHERE activation.active
        ORDER BY rule.rule_order, activation.activation_id
    LOOP
        IF activation_row.aggregate_function = 'COUNT_STAR' THEN
            EXECUTE format(
                'SELECT count(*)::text, count(*) OPERATOR(pg_catalog.%s) $2::bigint, '
                '$2::bigint::text FROM %s WHERE %I = $1', activation_row.comparison,
                activation_row.relation_oid::regclass, activation_row.key_column)
            INTO actual_value, actual_truth, actual_threshold
            USING activation_row.semantic_key, activation_row.typed_threshold;
        ELSIF activation_row.aggregate_function IN ('MIN', 'MAX')
              AND activation_row.input_type = 'uuid'::regtype THEN
            EXECUTE format(
                'SELECT aggregate_value::text, '
                'aggregate_value OPERATOR(pg_catalog.%s) $2::uuid, $2::uuid::text '
                'FROM (SELECT (SELECT %I FROM %s '
                'WHERE %I = $1 AND __pgreact_canonical = $3 AND %I IS NOT NULL '
                'ORDER BY %I %s LIMIT 1) AS aggregate_value) aggregate_result',
                activation_row.comparison, activation_row.value_expression,
                activation_row.relation_oid::regclass, activation_row.key_column,
                activation_row.value_expression, activation_row.value_expression,
                CASE activation_row.aggregate_function
                    WHEN 'MIN' THEN 'ASC' ELSE 'DESC' END)
            INTO actual_value, actual_truth, actual_threshold
            USING activation_row.semantic_key, activation_row.typed_threshold,
                  activation_row.canonical_group_key;
        ELSE
            EXECUTE format(
                'SELECT aggregate_value::text, '
                'aggregate_value OPERATOR(pg_catalog.%s) $2::%s, $2::%s::text '
                'FROM (SELECT pg_catalog.%s(%I) AS aggregate_value FROM %s '
                'WHERE %I = $1 AND __pgreact_canonical = $3) aggregate_result',
                activation_row.comparison, activation_row.result_type::regtype,
                activation_row.result_type::regtype, activation_row.aggregate_function,
                activation_row.value_expression, activation_row.relation_oid::regclass,
                activation_row.key_column)
            INTO actual_value, actual_truth, actual_threshold
            USING activation_row.semantic_key, activation_row.typed_threshold,
                  activation_row.canonical_group_key;
        END IF;
        expected_evidence_id := pgreact_internal.activation_uuid(sha256(convert_to(
            target_program::text || ':' || activation_row.rule_version_id::text || ':' ||
            CASE WHEN activation_row.aggregate_function = 'COUNT_STAR'
                 THEN activation_row.semantic_key::text
                 ELSE encode(activation_row.canonical_group_key, 'hex') END, 'UTF8')));
        expected_evidence_ids := expected_evidence_ids || expected_evidence_id;
        expected_metadata := jsonb_build_object(
            'support_id', activation_row.support_id,
            'semantic_key', activation_row.semantic_key,
            'relation_oid', activation_row.relation_oid,
            'relation_name', activation_row.relation_name,
            'exact_count', CASE WHEN activation_row.aggregate_function IN ('COUNT_STAR', 'COUNT')
                                THEN actual_value::bigint END,
            'comparison', activation_row.comparison,
            'threshold', CASE WHEN activation_row.aggregate_function = 'COUNT_STAR'
                              THEN actual_threshold::bigint END,
            'source_stratum', activation_row.source_stratum,
            'target_stratum', activation_row.target_stratum,
            'function', activation_row.aggregate_function,
            'expression', activation_row.value_expression,
            'input_type', activation_row.input_type,
            'input_type_name', activation_row.input_type_name,
            'result_type', activation_row.result_type,
            'result_type_name', activation_row.result_type_name,
            'collation', activation_row.expression_collation,
            'collation_name', activation_row.expression_collation_name,
            'value', actual_value, 'typed_threshold', actual_threshold,
            'truth', actual_truth,
            'public_group_key', activation_row.public_group_key,
            'canonical_group_key', encode(activation_row.canonical_group_key, 'hex'));
        SELECT * INTO aggregate_evidence
        FROM pgreact_internal.aggregate_dependency_evidence evidence
        WHERE evidence.evidence_id = expected_evidence_id AND evidence.active;
        IF NOT FOUND THEN
            aggregate_defects := aggregate_defects || jsonb_build_array(jsonb_build_object(
                'code', 'MISSING_EVIDENCE', 'evidence_id', expected_evidence_id,
                'expected', expected_metadata, 'actual', NULL));
            CONTINUE;
        END IF;
        actual_metadata := jsonb_build_object(
            'support_id', aggregate_evidence.support_id,
            'semantic_key', aggregate_evidence.semantic_key,
            'relation_oid', aggregate_evidence.relation_oid,
            'relation_name', aggregate_evidence.relation_name,
            'exact_count', aggregate_evidence.exact_count,
            'comparison', aggregate_evidence.comparison,
            'threshold', aggregate_evidence.threshold,
            'source_stratum', aggregate_evidence.source_stratum,
            'target_stratum', aggregate_evidence.target_stratum,
            'function', aggregate_evidence.aggregate_function,
            'expression', aggregate_evidence.value_expression,
            'input_type', aggregate_evidence.input_type,
            'input_type_name', aggregate_evidence.input_type_name,
            'result_type', aggregate_evidence.result_type,
            'result_type_name', aggregate_evidence.result_type_name,
            'collation', aggregate_evidence.expression_collation,
            'collation_name', aggregate_evidence.expression_collation_name,
            'value', aggregate_evidence.exact_value,
            'typed_threshold', aggregate_evidence.typed_threshold,
            'truth', aggregate_evidence.truth_result,
            'public_group_key', aggregate_evidence.public_group_key,
            'canonical_group_key', encode(aggregate_evidence.canonical_group_key, 'hex'));
        IF actual_metadata IS DISTINCT FROM expected_metadata THEN
            aggregate_defects := aggregate_defects || jsonb_build_array(jsonb_build_object(
                'code', CASE WHEN activation_row.aggregate_function = 'COUNT_STAR'
                             THEN 'WRONG_COUNT' ELSE 'WRONG_AGGREGATE' END,
                'evidence_id', expected_evidence_id,
                'expected', expected_metadata, 'actual', actual_metadata));
        END IF;
        IF aggregate_evidence.lower_frontier > activation_row.frontier THEN
            aggregate_defects := aggregate_defects || jsonb_build_array(jsonb_build_object(
                'code', 'WRONG_FRONTIER', 'evidence_id', expected_evidence_id,
                'expected', jsonb_build_object('maximum', activation_row.frontier),
                'actual', jsonb_build_object(
                    'lower_frontier', aggregate_evidence.lower_frontier)));
        END IF;
    END LOOP;
    FOR aggregate_evidence IN
        SELECT * FROM pgreact_internal.aggregate_dependency_evidence evidence
        WHERE evidence.program_version_id = target_program AND evidence.active
          AND evidence.evidence_id <> ALL (expected_evidence_ids)
        ORDER BY evidence.evidence_id
    LOOP
        aggregate_defects := aggregate_defects || jsonb_build_array(jsonb_build_object(
            'code', 'EXTRA_EVIDENCE', 'evidence_id', aggregate_evidence.evidence_id,
            'expected', NULL,
            'actual', jsonb_build_object('function', aggregate_evidence.aggregate_function,
                                         'value', aggregate_evidence.exact_value,
                                         'truth', aggregate_evidence.truth_result)));
    END LOOP;
    PERFORM pgreact_internal.reconcile_derivation_program_m9(target_program);
    IF jsonb_array_length(aggregate_defects) > 0 THEN
        UPDATE pgreact_internal.aggregate_dependency_evidence evidence
        SET active = false, support_id = NULL, invalidated_at = clock_timestamp()
        WHERE evidence.program_version_id = target_program AND evidence.active
          AND evidence.evidence_id <> ALL (expected_evidence_ids);
        PERFORM pgreact_internal.rebuild_derivation_program(
            target_program, true, true);
    END IF;
    SELECT max(reconciliation_id) INTO reconciliation_row_id
    FROM pgreact_internal.derivation_program_reconciliations
    WHERE program_version_id = target_program;
    SELECT COALESCE(max(diagnostic_order), 0) INTO next_diagnostic_order
    FROM pgreact_internal.derivation_program_repair_diagnostics
    WHERE reconciliation_id = reconciliation_row_id;
    DELETE FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
    USING pgreact_internal.activation_state activation,
          pgreact_internal.aggregate_dependency_evidence evidence
    WHERE diagnostic.reconciliation_id = reconciliation_row_id
      AND diagnostic.code = 'MISSING_SUPPORT'
      AND activation.rule_version_id = (diagnostic.details ->> 'rule_version_id')::uuid
      AND activation.activation_id = (diagnostic.details ->> 'activation_id')::uuid
      AND evidence.program_version_id = target_program
      AND evidence.rule_version_id = activation.rule_version_id
      AND evidence.semantic_key = activation.semantic_key
      AND evidence.active;
    FOR aggregate_defect IN
        SELECT value FROM jsonb_array_elements(aggregate_defects)
    LOOP
        next_diagnostic_order := next_diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_row_id, next_diagnostic_order,
            aggregate_defect ->> 'code',
            aggregate_defect ->> 'evidence_id', jsonb_build_object(
                'expected', aggregate_defect -> 'expected',
                'actual', aggregate_defect -> 'actual'));
    END LOOP;
    UPDATE pgreact_internal.derivation_program_reconciliations
    SET repairs = (SELECT count(*) FROM pgreact_internal.derivation_program_repair_diagnostics
                   WHERE reconciliation_id = reconciliation_row_id)
    WHERE reconciliation_id = reconciliation_row_id;
    RETURN (SELECT reconciliation.repairs
            FROM pgreact_internal.derivation_program_reconciliations reconciliation
            WHERE reconciliation.reconciliation_id = reconciliation_row_id);
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.attach_derivation_aggregate_input()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    aggregate_item jsonb;
    function_name text;
    expression_attnum smallint;
    expression_type oid;
    expression_collation oid;
BEGIN
    SELECT rule.value -> 'aggregate_input' INTO aggregate_item
    FROM pgreact_internal.derivation_program_versions version
    CROSS JOIN LATERAL jsonb_array_elements(version.definition -> 'rules') rule(value)
    WHERE version.program_version_id = NEW.program_version_id
      AND rule.value ->> 'name' = NEW.rule_name;
    IF aggregate_item IS NULL THEN RETURN NEW; END IF;
    function_name := COALESCE(aggregate_item ->> 'function', 'COUNT_STAR');
    IF function_name <> 'COUNT_STAR' THEN
        SELECT attnum, atttypid, attcollation
        INTO STRICT expression_attnum, expression_type, expression_collation
        FROM pg_attribute
        WHERE attrelid = to_regclass(aggregate_item ->> 'relation')
          AND attname = (aggregate_item ->> 'expression')::name
          AND attnum > 0 AND NOT attisdropped;
    END IF;
    INSERT INTO pgreact_internal.derivation_program_aggregate_inputs (
        program_version_id, rule_version_id, relation_oid, relation_name, key_column,
        comparison, threshold, relation_definition_digest, relation_row_signature,
        aggregate_function, value_expression, expression_attnum, input_type,
        input_type_name, result_type, result_type_name,
        expression_collation, expression_collation_name,
        public_relation_name, typed_threshold
    ) VALUES (
        NEW.program_version_id, NEW.rule_version_id,
        to_regclass(aggregate_item ->> 'relation'), aggregate_item ->> 'relation',
        (aggregate_item ->> 'key')::name, aggregate_item ->> 'comparison',
        CASE WHEN function_name = 'COUNT_STAR'
             THEN (aggregate_item ->> 'threshold')::bigint END,
        pgreact_internal.source_closure_digest(to_regclass(aggregate_item ->> 'relation')),
        pgreact_internal.source_row_signature(to_regclass(aggregate_item ->> 'relation')),
        function_name, (aggregate_item ->> 'expression')::name,
        expression_attnum, expression_type,
        CASE WHEN expression_type IS NULL THEN NULL ELSE expression_type::regtype::text END,
        pgreact_internal.aggregate_result_type(function_name, expression_type),
        pgreact_internal.aggregate_result_type(function_name, expression_type)::regtype::text,
        COALESCE(expression_collation, 0),
        CASE WHEN COALESCE(expression_collation, 0) = 0 THEN NULL
             ELSE expression_collation::regcollation::text END,
        aggregate_item ->> 'public_relation',
        aggregate_item ->> 'threshold'
    );
    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.rebuild_derivation_program(
    target_program uuid,
    force_rebuild boolean DEFAULT false,
    preserve_frontier boolean DEFAULT false,
    existing_run_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    input_row record;
    drift record;
BEGIN
    PERFORM pg_advisory_xact_lock(5788046901200000);
    FOR input_row IN
        SELECT * FROM pgreact_internal.derivation_program_aggregate_inputs
        WHERE program_version_id = target_program
        ORDER BY relation_oid
    LOOP
        EXECUTE format('LOCK TABLE %s IN ACCESS SHARE MODE', input_row.relation_oid::regclass);
    END LOOP;
    SELECT rule.rule_name, input.relation_name,
           encode(input.relation_definition_digest, 'hex') AS expected_digest,
           encode(pgreact_internal.source_closure_digest(input.relation_oid), 'hex') AS current_digest,
           encode(input.relation_row_signature, 'hex') AS expected_signature,
           encode(pgreact_internal.source_row_signature(input.relation_oid), 'hex') AS current_signature
    INTO drift
    FROM pgreact_internal.derivation_program_aggregate_inputs input
    JOIN pgreact_internal.derivation_program_rules rule
      USING (program_version_id, rule_version_id)
    LEFT JOIN pg_attribute expression_attribute
      ON expression_attribute.attrelid = input.relation_oid
     AND expression_attribute.attname = input.value_expression
     AND expression_attribute.attnum > 0 AND NOT expression_attribute.attisdropped
    WHERE input.program_version_id = target_program
      AND (input.relation_definition_digest IS DISTINCT FROM
               pgreact_internal.source_closure_digest(input.relation_oid)
           OR input.relation_row_signature IS DISTINCT FROM
               pgreact_internal.source_row_signature(input.relation_oid)
           OR (input.aggregate_function <> 'COUNT_STAR' AND (
               expression_attribute.attnum IS DISTINCT FROM input.expression_attnum
               OR expression_attribute.atttypid IS DISTINCT FROM input.input_type
               OR expression_attribute.attcollation IS DISTINCT FROM input.expression_collation
               OR pgreact_internal.aggregate_result_type(
                    input.aggregate_function, expression_attribute.atttypid)
                  IS DISTINCT FROM input.result_type)))
    ORDER BY rule.rule_order, rule.rule_name LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'derivation program aggregate-input drift for %', drift.rule_name
            USING HINT = 'Replace the complete derivation program through its public API.',
                  DETAIL = format(
                      'relation %s; expected definition %s, current %s; expected row signature %s, current %s',
                      drift.relation_name, drift.expected_digest, drift.current_digest,
                      drift.expected_signature, drift.current_signature);
    END IF;
    RETURN pgreact_internal.rebuild_derivation_program_m9(
        target_program, force_rebuild, preserve_frontier, existing_run_id);
END
$$;

ALTER FUNCTION pgreact_internal.maintain_derived_support(uuid, uuid)
    RENAME TO maintain_derived_support_m15;

CREATE FUNCTION pgreact_internal.maintain_derived_support(
    target_rule_version uuid,
    target_activation uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program_rule record;
    aggregate_input record;
    activation_key bigint;
    activation_public_key jsonb;
    activation_canonical_key bytea;
    current_value text;
    current_threshold text;
    holds boolean;
    current_support uuid;
    old_support record;
    frontier_value bigint;
    lower_frontier bigint;
    source_stratum_value integer;
    target_stratum_value integer;
BEGIN
    SELECT rule.*, version.definition, version.frontier AS program_frontier
    INTO program_rule
    FROM pgreact_internal.derivation_program_rules rule
    JOIN pgreact_internal.derivation_program_versions version USING (program_version_id)
    WHERE rule.rule_version_id = target_rule_version AND version.state = 'ACTIVE'
    ORDER BY version.created_at DESC LIMIT 1;
    SELECT input.* INTO aggregate_input
    FROM pgreact_internal.derivation_program_aggregate_inputs input
    WHERE input.rule_version_id = target_rule_version
      AND input.program_version_id = program_rule.program_version_id;
    IF NOT FOUND THEN
        PERFORM pgreact_internal.maintain_derived_support_m9(
            target_rule_version, target_activation);
        RETURN;
    END IF;
    SELECT semantic_key,
           current_bindings -> '__pgreact_public_key',
           (current_bindings ->> '__pgreact_canonical')::bytea
    INTO activation_key, activation_public_key, activation_canonical_key
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = target_rule_version
      AND activation_id = target_activation AND active;
    IF NOT FOUND THEN
        UPDATE pgreact_internal.aggregate_dependency_evidence
        SET active = false, support_id = NULL, invalidated_at = clock_timestamp()
        WHERE activation_id = target_activation AND active;
        PERFORM pgreact_internal.maintain_derived_support_m9(
            target_rule_version, target_activation);
        RETURN;
    END IF;
    PERFORM set_config('TimeZone', 'UTC', true);
    PERFORM set_config('DateStyle', 'ISO, YMD', true);
    PERFORM set_config('extra_float_digits', '3', true);
    IF aggregate_input.aggregate_function = 'COUNT_STAR' THEN
        EXECUTE format(
            'SELECT count(*)::text, count(*) OPERATOR(pg_catalog.%s) $2::bigint, '
            '$2::bigint::text FROM %s WHERE %I = $1',
            aggregate_input.comparison, aggregate_input.relation_oid::regclass,
            aggregate_input.key_column)
        INTO current_value, holds, current_threshold
        USING activation_key, aggregate_input.typed_threshold;
    ELSIF aggregate_input.aggregate_function IN ('MIN', 'MAX')
          AND aggregate_input.input_type = 'uuid'::regtype THEN
        IF activation_canonical_key IS NULL OR activation_public_key IS NULL THEN
            RAISE EXCEPTION 'M16_AGGREGATE_KEY_IDENTITY: typed aggregate activation lacks canonical identity';
        END IF;
        EXECUTE format(
            'SELECT aggregate_value::text, '
            'aggregate_value OPERATOR(pg_catalog.%s) $2::uuid, $2::uuid::text '
            'FROM (SELECT (SELECT %I FROM %s '
            'WHERE %I = $1 AND __pgreact_canonical = $3 AND %I IS NOT NULL '
            'ORDER BY %I %s LIMIT 1) AS aggregate_value) aggregate_result',
            aggregate_input.comparison, aggregate_input.value_expression,
            aggregate_input.relation_oid::regclass, aggregate_input.key_column,
            aggregate_input.value_expression, aggregate_input.value_expression,
            CASE aggregate_input.aggregate_function
                WHEN 'MIN' THEN 'ASC' ELSE 'DESC' END)
        INTO current_value, holds, current_threshold
        USING activation_key, aggregate_input.typed_threshold, activation_canonical_key;
    ELSE
        IF activation_canonical_key IS NULL OR activation_public_key IS NULL THEN
            RAISE EXCEPTION 'M16_AGGREGATE_KEY_IDENTITY: typed aggregate activation lacks canonical identity';
        END IF;
        EXECUTE format(
            'SELECT aggregate_value::text, '
            'aggregate_value OPERATOR(pg_catalog.%s) $2::%s, $2::%s::text '
            'FROM (SELECT pg_catalog.%s(%I) AS aggregate_value '
            'FROM %s WHERE %I = $1 AND __pgreact_canonical = $3) aggregate_result',
            aggregate_input.comparison, aggregate_input.result_type::regtype,
            aggregate_input.result_type::regtype,
            aggregate_input.aggregate_function, aggregate_input.value_expression,
            aggregate_input.relation_oid::regclass, aggregate_input.key_column)
        INTO current_value, holds, current_threshold
        USING activation_key, aggregate_input.typed_threshold, activation_canonical_key;
    END IF;
    SELECT COALESCE(source_component.stratum, 0), target_component.stratum
    INTO STRICT source_stratum_value, target_stratum_value
    FROM pgreact_internal.derivation_program_components target_component
    LEFT JOIN pgreact_internal.derived_relation_versions source_version
      ON source_version.public_view_oid = aggregate_input.relation_oid
     AND source_version.state = 'ACTIVE'
    LEFT JOIN pgreact_internal.derivation_program_components source_component
      ON source_component.program_version_id = program_rule.program_version_id
     AND source_version.relation_version_id = ANY (source_component.target_relations)
    WHERE target_component.program_version_id = program_rule.program_version_id
      AND target_component.component_id = program_rule.component_id;
    SELECT component_frontier.frontier INTO lower_frontier
    FROM pgreact_internal.derivation_program_components component
    JOIN pgreact_internal.derivation_program_component_frontiers component_frontier
      USING (program_version_id, component_id)
    JOIN pgreact_internal.derived_relation_versions relation_version
      ON relation_version.relation_version_id = ANY (component.target_relations)
    WHERE component.program_version_id = program_rule.program_version_id
      AND relation_version.public_view_oid = aggregate_input.relation_oid;
    lower_frontier := COALESCE(lower_frontier,
        NULLIF(current_setting('pgreact.program_support_frontier', true), '')::bigint,
        program_rule.program_frontier + 1);
    IF holds THEN
        PERFORM pgreact_internal.maintain_derived_support_m9(
            target_rule_version, target_activation);
    ELSE
        SELECT support_id, relation_version_id, semantic_key INTO old_support
        FROM pgreact_internal.derived_supports
        WHERE rule_version_id = target_rule_version
          AND activation_id = target_activation AND active;
        IF FOUND THEN
            frontier_value := pgreact_internal.advance_derived_frontier(
                old_support.relation_version_id);
            UPDATE pgreact_internal.derived_supports
            SET active = false, grounded = false, last_frontier = frontier_value,
                invalidated_at = clock_timestamp()
            WHERE support_id = old_support.support_id;
            PERFORM pgreact_internal.recompute_derived_fact(
                old_support.relation_version_id, old_support.semantic_key, frontier_value);
        END IF;
    END IF;
    SELECT support_id INTO current_support
    FROM pgreact_internal.derived_supports
    WHERE rule_version_id = target_rule_version
      AND activation_id = target_activation AND active;
    INSERT INTO pgreact_internal.aggregate_dependency_evidence (
        evidence_id, program_version_id, rule_version_id, activation_id, support_id,
        semantic_key, relation_oid, relation_name, exact_count, comparison, threshold,
        source_stratum, target_stratum, lower_frontier, active,
        aggregate_function, value_expression, input_type, result_type,
        input_type_name, result_type_name, expression_collation,
        expression_collation_name, exact_value, typed_threshold, truth_result,
        public_group_key, canonical_group_key
    ) VALUES (
        pgreact_internal.activation_uuid(sha256(convert_to(
            program_rule.program_version_id::text || ':' || target_rule_version::text || ':' ||
            CASE WHEN aggregate_input.aggregate_function = 'COUNT_STAR'
                 THEN activation_key::text
                 ELSE encode(activation_canonical_key, 'hex') END, 'UTF8'))),
        program_rule.program_version_id, target_rule_version, target_activation, current_support,
        activation_key, aggregate_input.relation_oid, aggregate_input.relation_name,
        CASE WHEN aggregate_input.aggregate_function IN ('COUNT_STAR', 'COUNT')
             THEN current_value::bigint END,
        aggregate_input.comparison,
        CASE WHEN aggregate_input.aggregate_function = 'COUNT_STAR'
             THEN aggregate_input.typed_threshold::bigint END,
        source_stratum_value, target_stratum_value, lower_frontier, true,
        aggregate_input.aggregate_function, aggregate_input.value_expression,
        aggregate_input.input_type, aggregate_input.result_type,
        aggregate_input.input_type_name, aggregate_input.result_type_name,
        aggregate_input.expression_collation,
        aggregate_input.expression_collation_name, current_value,
        current_threshold, holds, activation_public_key, activation_canonical_key
    ) ON CONFLICT (evidence_id) DO UPDATE SET
        activation_id = EXCLUDED.activation_id,
        support_id = EXCLUDED.support_id,
        semantic_key = EXCLUDED.semantic_key,
        relation_oid = EXCLUDED.relation_oid,
        relation_name = EXCLUDED.relation_name,
        exact_count = EXCLUDED.exact_count,
        comparison = EXCLUDED.comparison,
        threshold = EXCLUDED.threshold,
        source_stratum = EXCLUDED.source_stratum,
        target_stratum = EXCLUDED.target_stratum,
        lower_frontier = CASE
            WHEN pgreact_internal.aggregate_dependency_evidence.exact_value
                     IS DISTINCT FROM EXCLUDED.exact_value
              OR pgreact_internal.aggregate_dependency_evidence.comparison
                     IS DISTINCT FROM EXCLUDED.comparison
              OR pgreact_internal.aggregate_dependency_evidence.typed_threshold
                     IS DISTINCT FROM EXCLUDED.typed_threshold
            THEN EXCLUDED.lower_frontier
            ELSE pgreact_internal.aggregate_dependency_evidence.lower_frontier
        END,
        active = true,
        invalidated_at = NULL,
        aggregate_function = EXCLUDED.aggregate_function,
        value_expression = EXCLUDED.value_expression,
        input_type = EXCLUDED.input_type,
        input_type_name = EXCLUDED.input_type_name,
        result_type = EXCLUDED.result_type,
        result_type_name = EXCLUDED.result_type_name,
        expression_collation = EXCLUDED.expression_collation,
        expression_collation_name = EXCLUDED.expression_collation_name,
        exact_value = EXCLUDED.exact_value,
        typed_threshold = EXCLUDED.typed_threshold,
        truth_result = EXCLUDED.truth_result,
        public_group_key = EXCLUDED.public_group_key,
        canonical_group_key = EXCLUDED.canonical_group_key;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.recursive_fact_proof(
    target_program uuid,
    target_relation uuid,
    target_key bigint,
    path uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    fact_row record;
    support_row record;
    input_row record;
    evidence_row record;
    supports jsonb := '[]'::jsonb;
    inputs jsonb;
    negative_checks jsonb;
    aggregate_conditions jsonb;
    support_node jsonb;
    input_node jsonb;
    relation_identity text;
BEGIN
    SELECT fact.fact_id, fact.fact, relation.relation_name, version.version
    INTO fact_row
    FROM pgreact_internal.derived_facts fact
    JOIN pgreact_internal.derived_relation_versions version USING (relation_version_id)
    JOIN pgreact_internal.derived_relations relation USING (relation_id)
    WHERE fact.relation_version_id = target_relation AND fact.semantic_key = target_key;
    IF NOT FOUND THEN RETURN NULL; END IF;
    relation_identity := fact_row.relation_name || '@' || fact_row.version;
    IF fact_row.fact_id = ANY (path) THEN
        RETURN jsonb_build_object('cycle', true, 'relation', relation_identity,
                                  'semantic_key', target_key);
    END IF;
    FOR support_row IN
        SELECT support.support_id, support.logical_support_id, support.source_binding,
               rule.rule_name, derivation.version
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules program_rule
          ON program_rule.program_version_id = target_program
         AND program_rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derivation_rule_versions derivation
          ON derivation.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.rules rule ON rule.rule_id = derivation.rule_id
        WHERE support.relation_version_id = target_relation
          AND support.semantic_key = target_key AND support.active
        ORDER BY rule.rule_name, derivation.version, support.logical_support_id
    LOOP
        inputs := '[]'::jsonb;
        FOR input_row IN
            SELECT input.*, relation.relation_name, version.version
            FROM pgreact_internal.derived_support_inputs input
            JOIN pgreact_internal.derived_relation_versions version
              ON version.relation_version_id = input.relation_version_id
            JOIN pgreact_internal.derived_relations relation USING (relation_id)
            WHERE input.support_id = support_row.support_id
            ORDER BY input.input_order
        LOOP
            IF input_row.fact_id = ANY (path || fact_row.fact_id) THEN
                input_node := jsonb_build_object('cycle', true,
                    'relation', input_row.relation_name || '@' || input_row.version,
                    'semantic_key', input_row.semantic_key);
            ELSE
                input_node := pgreact_internal.recursive_fact_proof(
                    target_program, input_row.relation_version_id,
                    input_row.semantic_key, path || fact_row.fact_id);
            END IF;
            inputs := inputs || jsonb_build_array(input_node);
        END LOOP;
        negative_checks := '[]'::jsonb;
        FOR evidence_row IN
            SELECT * FROM pgreact_internal.negative_dependency_evidence
            WHERE support_id = support_row.support_id AND active ORDER BY input_order
        LOOP
            negative_checks := negative_checks || jsonb_build_array(jsonb_build_object(
                'evidence_id', evidence_row.evidence_id,
                'relation', evidence_row.relation_name,
                'semantic_key', evidence_row.semantic_key,
                'source_stratum', evidence_row.source_stratum,
                'lower_frontier', evidence_row.lower_frontier));
        END LOOP;
        aggregate_conditions := '[]'::jsonb;
        FOR evidence_row IN
            SELECT evidence.*,
                   COALESCE(input.public_relation_name, evidence.relation_name)
                       AS public_relation_name
            FROM pgreact_internal.aggregate_dependency_evidence evidence
            JOIN pgreact_internal.derivation_program_aggregate_inputs input
              USING (program_version_id, rule_version_id)
            WHERE evidence.support_id = support_row.support_id AND evidence.active
            ORDER BY evidence.evidence_id
        LOOP
            aggregate_conditions := aggregate_conditions || jsonb_build_array(CASE
                WHEN evidence_row.aggregate_function = 'COUNT_STAR' THEN
                    jsonb_build_object(
                        'evidence_id', evidence_row.evidence_id,
                        'relation', evidence_row.public_relation_name,
                        'group_key', evidence_row.semantic_key,
                        'count', evidence_row.exact_count,
                        'comparison', evidence_row.comparison,
                        'threshold', evidence_row.threshold,
                        'source_stratum', evidence_row.source_stratum,
                        'lower_frontier', evidence_row.lower_frontier)
                ELSE jsonb_build_object(
                    'evidence_id', evidence_row.evidence_id,
                    'relation', evidence_row.public_relation_name,
                    'group_key', evidence_row.public_group_key,
                    'function', evidence_row.aggregate_function,
                    'expression', evidence_row.value_expression,
                    'input_type', evidence_row.input_type_name,
                    'result_type', evidence_row.result_type_name,
                    'value', evidence_row.exact_value,
                    'comparison', evidence_row.comparison,
                    'threshold', evidence_row.typed_threshold,
                    'truth', evidence_row.truth_result,
                    'source_stratum', evidence_row.source_stratum,
                    'lower_frontier', evidence_row.lower_frontier)
                END);
        END LOOP;
        support_node := jsonb_build_object(
            'rule', support_row.rule_name || '@' || support_row.version,
            'source_binding', support_row.source_binding,
            'inputs', inputs,
            'negative_checks', negative_checks);
        IF aggregate_conditions <> '[]'::jsonb THEN
            support_node := support_node || jsonb_build_object(
                'aggregate_conditions', aggregate_conditions);
        END IF;
        supports := supports || jsonb_build_array(support_node);
    END LOOP;
    RETURN jsonb_build_object('relation', relation_identity,
                              'fact', fact_row.fact, 'supports', supports);
END
$$;

CREATE OR REPLACE VIEW pgreact.aggregate_dependency_evidence AS
SELECT evidence.evidence_id, evidence.program_version_id, program.program_name,
       version.version AS program_version, evidence.rule_version_id, rule.rule_name,
       evidence.semantic_key AS group_key,
       COALESCE(input.public_relation_name,
                wrapper.public_condition::regclass::text,
                evidence.relation_name) AS counted_relation,
       evidence.exact_count, evidence.comparison, evidence.threshold,
       evidence.source_stratum, evidence.target_stratum, evidence.lower_frontier,
       evidence.aggregate_function, evidence.value_expression,
       CASE WHEN evidence.input_type IS NULL THEN NULL
            ELSE evidence.input_type::regtype END AS input_type,
       evidence.result_type::regtype AS result_type,
       evidence.exact_value, evidence.typed_threshold, evidence.truth_result,
       CASE WHEN evidence.expression_collation = 0 THEN NULL
            ELSE evidence.expression_collation::regcollation END AS expression_collation,
       evidence.public_group_key, evidence.input_type_name,
       evidence.result_type_name, evidence.expression_collation_name
FROM pgreact_internal.aggregate_dependency_evidence evidence
JOIN pgreact_internal.derivation_program_versions version USING (program_version_id)
JOIN pgreact_internal.derivation_programs program USING (program_id)
JOIN pgreact_internal.derivation_program_rules rule
  USING (program_version_id, rule_version_id)
JOIN pgreact_internal.derivation_program_aggregate_inputs input
  USING (program_version_id, rule_version_id)
LEFT JOIN pgreact_internal.key_wrappers wrapper
  ON wrapper.wrapper_condition = evidence.relation_oid
WHERE version.state = 'ACTIVE' AND evidence.active;

CREATE OR REPLACE FUNCTION pgreact_api.explain(target text, semantic_key jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    activation uuid;
    derived pgreact_internal.keyed_derived_relations%ROWTYPE;
    surrogate bigint;
    result jsonb;
    aggregate_summary jsonb;
BEGIN
    SELECT * INTO derived
    FROM pgreact_internal.keyed_derived_relations
    WHERE public_name = target;
    IF FOUND THEN
        EXECUTE format(
            'SELECT __pgreact_key FROM %s WHERE __pgreact_public_key = $1',
            derived.internal_name)
        INTO surrogate USING semantic_key;
        IF surrogate IS NULL THEN
            SELECT jsonb_build_object(
                'program', program.program_name || '@' || version.version,
                'frontier', version.frontier,
                'aggregate_conditions', jsonb_agg(jsonb_build_object(
                    'relation', input.public_relation_name,
                    'group_key', evidence.public_group_key,
                    'function', evidence.aggregate_function,
                    'expression', evidence.value_expression,
                    'input_type', evidence.input_type_name,
                    'result_type', evidence.result_type_name,
                    'value', evidence.exact_value,
                    'comparison', evidence.comparison,
                    'threshold', evidence.typed_threshold,
                    'truth', evidence.truth_result,
                    'source_stratum', evidence.source_stratum,
                    'target_stratum', evidence.target_stratum,
                    'lower_frontier', evidence.lower_frontier)
                    ORDER BY rule.rule_name))
            INTO aggregate_summary
            FROM pgreact_internal.aggregate_dependency_evidence evidence
            JOIN pgreact_internal.derivation_program_aggregate_inputs input
              USING (program_version_id, rule_version_id)
            JOIN pgreact_internal.derivation_program_rules rule
              USING (program_version_id, rule_version_id)
            JOIN pgreact_internal.derivation_program_versions version
              USING (program_version_id)
            JOIN pgreact_internal.derivation_programs program USING (program_id)
            WHERE rule.target_relation_version_id = derived.relation_version_id
              AND evidence.public_group_key = $2
              AND evidence.active AND version.state = 'ACTIVE'
            GROUP BY program.program_name, version.version, version.frontier;
            RETURN jsonb_build_object(
                'contract_version', 5,
                'target', jsonb_build_object(
                    'kind', 'fact', 'name', target, 'key', semantic_key),
                'evidence', aggregate_summary);
        END IF;
        result := pgreact_api.explain(derived.internal_name, surrogate);
        result := jsonb_set(result, '{contract_version}', '5'::jsonb);
        result := jsonb_set(result, '{target}', jsonb_build_object(
            'kind', 'fact', 'name', target, 'key', semantic_key));
        IF result #> '{evidence,fact}' IS NOT NULL THEN
            result := jsonb_set(result, '{evidence,fact}',
                (result #> '{evidence,fact}')
                - ARRAY['__pgreact_canonical', '__pgreact_key', '__pgreact_public_key']);
        END IF;
        RETURN pgreact_internal.public_json(result);
    END IF;
    SELECT state.activation_id INTO activation
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.semantic_key_identities identity USING (rule_version_id)
    JOIN pgreact_internal.activation_state state
      ON state.rule_version_id = identity.rule_version_id
     AND state.semantic_key = identity.semantic_key
    WHERE rule.rule_name = target AND version.state = 'ACTIVE'
      AND identity.public_key = $2;
    IF activation IS NULL THEN
        RETURN jsonb_build_object(
            'contract_version', 5,
            'target', jsonb_build_object(
                'kind', 'match', 'rule', target, 'key', semantic_key),
            'evidence', NULL);
    END IF;
    RETURN pgreact_internal.public_json(jsonb_set(
        pgreact_api.explain(target, activation), '{contract_version}', '5'::jsonb)
        || jsonb_build_object(
            'target', jsonb_build_object(
                'kind', 'match', 'rule', target, 'key', semantic_key)));
END
$$;

CREATE FUNCTION pgreact_api.reconcile_program(program_name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE target_program uuid;
BEGIN
    SELECT version.program_version_id INTO STRICT target_program
    FROM pgreact_internal.derivation_programs program
    JOIN pgreact_internal.derivation_program_versions version USING (program_id)
    WHERE program.program_name = $1 AND version.state = 'ACTIVE';
    RETURN pgreact.reconcile_derivation_program(target_program);
EXCEPTION WHEN no_data_found THEN
    RAISE EXCEPTION 'M16_PROGRAM_NOT_ACTIVE: %', $1
        USING HINT = 'Name one active derivation program.';
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.remove_program(
    program_name text,
    program_version integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE target_program uuid;
BEGIN
    SELECT version.program_version_id INTO STRICT target_program
    FROM pgreact_internal.derivation_programs program
    JOIN pgreact_internal.derivation_program_versions version USING (program_id)
    WHERE program.program_name = $1 AND version.version = $2
      AND version.state = 'ACTIVE';
    PERFORM pgreact.remove_derivation_program(target_program);
EXCEPTION WHEN no_data_found THEN
    RAISE EXCEPTION 'M16_PROGRAM_NOT_ACTIVE: %@%', $1, $2
        USING HINT = 'Name the active program version.';
END
$$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
RENAME TO configure_roles_m15;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole,
    operator_role regrole,
    worker_role regrole,
    reader_role regrole,
    advanced_reader_role regrole
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.configure_roles_m15(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.reconcile_program(text) TO %I',
        operator_role::text);
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH diagnostics AS (
        SELECT diagnostic FROM jsonb_array_elements(pgreact_api.health() -> 'diagnostics') diagnostic
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M16_EXTENSION_VERSION', 'severity', 'ERROR', 'object_identity', 'pg_react',
            'message', 'pg_react extension version is not 0.13.0',
            'hint', 'Install matching files and run ALTER EXTENSION pg_react UPDATE.')
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.13.0')
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M15_TRICKLE_VERSION', 'severity', 'ERROR', 'object_identity', 'pg_trickle',
            'message', 'pg_trickle extension version is not 0.81.0',
            'hint', 'Install the supported pg_trickle 0.81.0 extension.')
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trickle' AND extversion = '0.81.0')
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M15_ROLE_CONFIGURATION', 'severity', 'WARNING', 'object_identity', 'pgreact_api',
            'message', 'application facade roles are not configured',
            'hint', 'The extension owner must call pgreact_api.configure_roles with five distinct roles.')
        WHERE (SELECT count(*) FROM pgreact_internal.application_roles) <> 4
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M15_MANAGED_CONFIGURATION', 'severity', 'ERROR', 'object_identity', current_database(),
            'message', 'this database is not configured for a managed worker',
            'hint', 'Preload pg_react, add this database to pg_react.databases, and restart PostgreSQL.')
        WHERE NOT current_database() = ANY (regexp_split_to_array(
            current_setting('pg_react.databases', true), '\\s*,\\s*'))
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M15_MANAGED_PROCESS', 'severity', 'ERROR', 'object_identity', current_database(),
            'message', CASE WHEN process.database_oid IS NULL THEN 'managed worker has not attached'
                            ELSE 'managed worker state is ' || process.state END,
            'hint', 'Inspect pgreact_api.managed_status(), PostgreSQL logs, preload settings, and worker role connectivity.')
        FROM (SELECT 1) singleton
        LEFT JOIN pgreact_internal.managed_processes process
          ON process.database_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
        WHERE process.database_oid IS NULL OR process.state <> 'ready'
           OR process.heartbeat_at < clock_timestamp() - interval '10 seconds'
    ), ordered AS (
        SELECT diagnostic FROM diagnostics
        ORDER BY CASE diagnostic ->> 'severity' WHEN 'ERROR' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
                 diagnostic ->> 'code', diagnostic ->> 'object_identity'
    )
    SELECT jsonb_build_object(
        'contract_version', 5,
        'status', CASE WHEN EXISTS (SELECT 1 FROM ordered WHERE diagnostic ->> 'severity' = 'ERROR')
                       THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE((SELECT jsonb_agg(diagnostic) FROM ordered), '[]'::jsonb))
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgreact_internal.derivation_program_graph(jsonb) TO PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

DO $$
DECLARE
    author_role regrole;
    operator_role regrole;
    worker_role regrole;
    reader_role regrole;
    advanced_reader_role regrole;
BEGIN
    SELECT role_oid::regrole INTO author_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid::regrole INTO operator_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid::regrole INTO worker_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'worker';
    SELECT role_oid::regrole INTO reader_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    SELECT role_oid::regrole INTO advanced_reader_role
    FROM pgreact_internal.advanced_readers;
    IF author_role IS NOT NULL AND operator_role IS NOT NULL
       AND worker_role IS NOT NULL AND reader_role IS NOT NULL
       AND advanced_reader_role IS NOT NULL THEN
        PERFORM pgreact_api.configure_roles(
            author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    END IF;
END
$$;

COMMENT ON EXTENSION pg_react IS
    'M16 typed COUNT, SUM, MIN, and MAX over stable lower strata';
