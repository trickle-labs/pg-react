-- M10 stratified aggregation.  A program rule may declare one keyed
-- COUNT(*) threshold over an authoritative or completed lower stratum.

CREATE TABLE pgreact_internal.derivation_program_aggregate_inputs (
    program_version_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    relation_oid oid NOT NULL,
    relation_name text NOT NULL,
    key_column name NOT NULL,
    comparison text NOT NULL CHECK (comparison IN ('=', '<', '<=', '>', '>=')),
    threshold bigint NOT NULL CHECK (threshold >= 0),
    relation_definition_digest bytea NOT NULL,
    relation_row_signature bytea NOT NULL,
    PRIMARY KEY (program_version_id, rule_version_id),
    FOREIGN KEY (program_version_id, rule_version_id)
        REFERENCES pgreact_internal.derivation_program_rules
);

CREATE TABLE pgreact_internal.aggregate_dependency_evidence (
    evidence_id uuid PRIMARY KEY,
    program_version_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    activation_id uuid NOT NULL,
    support_id uuid REFERENCES pgreact_internal.derived_supports ON DELETE SET NULL,
    semantic_key bigint NOT NULL,
    relation_oid oid NOT NULL,
    relation_name text NOT NULL,
    exact_count bigint NOT NULL CHECK (exact_count >= 0),
    comparison text NOT NULL CHECK (comparison IN ('=', '<', '<=', '>', '>=')),
    threshold bigint NOT NULL CHECK (threshold >= 0),
    source_stratum integer NOT NULL CHECK (source_stratum >= 0),
    target_stratum integer NOT NULL CHECK (target_stratum > source_stratum),
    lower_frontier bigint NOT NULL CHECK (lower_frontier > 0),
    active boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    invalidated_at timestamptz,
    UNIQUE (program_version_id, rule_version_id, semantic_key),
    FOREIGN KEY (program_version_id, rule_version_id)
        REFERENCES pgreact_internal.derivation_program_aggregate_inputs
        ON DELETE CASCADE
);

CREATE INDEX aggregate_dependency_evidence_active_support
    ON pgreact_internal.aggregate_dependency_evidence (support_id)
    WHERE active;

CREATE FUNCTION pgreact_internal.invalidate_aggregate_dependency_evidence()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    UPDATE pgreact_internal.aggregate_dependency_evidence
    SET active = false, support_id = NULL, invalidated_at = clock_timestamp()
    WHERE activation_id = NEW.activation_id AND active;
    RETURN NULL;
END
$$;

CREATE TRIGGER pgreact_invalidate_aggregate_dependency_evidence
AFTER UPDATE OF active ON pgreact_internal.activation_state
FOR EACH ROW WHEN (OLD.active AND NOT NEW.active)
EXECUTE FUNCTION pgreact_internal.invalidate_aggregate_dependency_evidence();

ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    DROP CONSTRAINT derivation_program_repair_diagnostics_code_check;
ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    ADD CHECK (code IN (
        'MISSING_SUPPORT', 'EXTRA_SUPPORT', 'STALE_SUPPORT',
        'MISSING_FACT', 'EXTRA_FACT', 'STALE_FACT',
        'CIRCULAR_ONLY', 'WRONG_FRONTIER', 'MISSING_EVIDENCE',
        'EXTRA_EVIDENCE', 'STALE_EVIDENCE', 'WRONG_STRATUM',
        'MISSING_AGGREGATE_EVIDENCE', 'EXTRA_AGGREGATE_EVIDENCE',
        'STALE_AGGREGATE_EVIDENCE', 'WRONG_COUNT'
    ));

ALTER FUNCTION pgreact.validate_derivation_program(jsonb)
    RENAME TO validate_derivation_program_m9;
ALTER FUNCTION pgreact.validate_derivation_program_m9(jsonb)
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
#variable_conflict use_variable
DECLARE
    rule_item record;
    aggregate_item jsonb;
    diagnostic record;
    aggregate_oid oid;
    source_oid oid;
    source_tree text;
    aggregate_tree text;
    aggregate_key_attno smallint;
    current_program record;
    base_definition jsonb;
    has_aggregate boolean;
    aggregate_graph record;
BEGIN
    has_aggregate := EXISTS (
        SELECT 1
        FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END) rule(value)
        WHERE rule.value ? 'aggregate_input'
    );
    IF NOT has_aggregate THEN
        RETURN QUERY SELECT *
        FROM pgreact_internal.validate_derivation_program_m9(definition);
        RETURN;
    END IF;

    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END)
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        IF NOT rule_item.value ? 'aggregate_input' THEN
            CONTINUE;
        END IF;
        aggregate_item := rule_item.value -> 'aggregate_input';
        IF jsonb_typeof(aggregate_item) IS DISTINCT FROM 'object'
           OR NOT aggregate_item ?& ARRAY['relation', 'key', 'comparison', 'threshold']
           OR (SELECT count(*) FROM jsonb_object_keys(aggregate_item)) <> 4 THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_INVALID', 'ERROR',
                COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                'aggregate_input requires exactly relation, key, comparison, and threshold',
                'Declare one grouped COUNT(*) threshold without expression, DISTINCT, or FILTER.',
                '{}'::jsonb;
            RETURN;
        END IF;
        IF aggregate_item ->> 'comparison' NOT IN ('=', '<', '<=', '>', '>=')
           OR aggregate_item ->> 'threshold' !~ '^[0-9]+$'
           OR NOT COALESCE(pg_input_is_valid(
               aggregate_item ->> 'threshold', 'bigint'), false)
           OR (aggregate_item ->> 'threshold')::bigint < 0 THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_THRESHOLD_INVALID', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate threshold must be one immutable non-negative bigint with =, <, <=, >, or >=',
                'Use a JSON integer threshold and one supported comparison.',
                jsonb_build_object('comparison', aggregate_item ->> 'comparison',
                                   'threshold', aggregate_item -> 'threshold');
            RETURN;
        END IF;
        IF aggregate_item ->> 'key' IS DISTINCT FROM rule_item.value ->> 'key' THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_UNBOUND', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate group key must equal the derived fact semantic key',
                'Bind aggregate_input.key to the rule output key.',
                jsonb_build_object('aggregate_key', aggregate_item ->> 'key',
                                   'output_key', rule_item.value ->> 'key');
            RETURN;
        END IF;
        aggregate_oid := to_regclass(aggregate_item ->> 'relation');
        IF aggregate_oid IS NULL OR NOT EXISTS (
            SELECT 1 FROM pg_class
            WHERE oid = aggregate_oid AND relkind IN ('r', 'p', 'v', 'm')
        ) THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_UNRESOLVED', 'ERROR',
                aggregate_item ->> 'relation',
                'aggregate input does not resolve to a finite table or view',
                'Map relation to one authoritative or active lower-stratum derived relation.',
                jsonb_build_object('rule', rule_item.value ->> 'name');
            RETURN;
        END IF;
        SELECT attnum INTO aggregate_key_attno
        FROM pg_attribute
        WHERE attrelid = aggregate_oid
          AND attname = (aggregate_item ->> 'key')::name
          AND atttypid = 'bigint'::regtype
          AND attnum > 0 AND NOT attisdropped;
        IF aggregate_key_attno IS NULL THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_KEY_INVALID', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate input key must be one bigint column',
                'Project the non-null grouped key with the output-key name.',
                jsonb_build_object('relation', aggregate_item ->> 'relation',
                                   'key', aggregate_item ->> 'key');
            RETURN;
        END IF;
        source_oid := to_regclass(rule_item.value ->> 'definition');
        IF source_oid IS NOT NULL AND NOT pgreact_internal.view_key_is_direct(
            source_oid,
            (SELECT attnum FROM pg_attribute
             WHERE attrelid = source_oid
               AND attname = (rule_item.value ->> 'key')::name
               AND attnum > 0 AND NOT attisdropped)) THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_UNBOUND', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate group key must be positively bound by the source row',
                'Project the source key unchanged; do not synthesize a group key.',
                jsonb_build_object('key', rule_item.value ->> 'key');
            RETURN;
        END IF;
        aggregate_tree := pgreact_internal.relation_query_tree(aggregate_oid);
        IF aggregate_tree ~ E':hasAggs[[:space:]]+true'
           OR aggregate_tree ~ E':aggfnoid[[:space:]]+[1-9]'
           OR aggregate_tree ~ E':has(WindowFuncs|DistinctOn|Recursive|GroupRTE)[[:space:]]+true'
           OR aggregate_tree ~ E':(groupClause|groupingSets|havingQual|distinctClause|windowClause)[[:space:]]+[({]' THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_UNSUPPORTED', 'ERROR',
                rule_item.value ->> 'name',
                'aggregate_input must name raw rows; M10 computes the only COUNT(*) itself',
                'Remove nested aggregates, DISTINCT, FILTER, windows, and grouping from the input relation.',
                jsonb_build_object('relation', aggregate_item ->> 'relation');
            RETURN;
        END IF;
    END LOOP;

    IF EXISTS (
        WITH RECURSIVE edges(source_relation, target_relation, polarity) AS (
            SELECT input.value ->> 'relation', rule.value ->> 'target', 'POSITIVE'::text
            FROM jsonb_array_elements(definition -> 'rules') rule(value)
            CROSS JOIN LATERAL jsonb_array_elements(rule.value -> 'inputs') input(value)
            UNION ALL
            SELECT input.value ->> 'relation', rule.value ->> 'target', 'NEGATIVE'
            FROM jsonb_array_elements(definition -> 'rules') rule(value)
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
                rule.value -> 'negative_inputs', '[]'::jsonb)) input(value)
            UNION ALL
            SELECT rule.value -> 'aggregate_input' ->> 'relation',
                   rule.value ->> 'target', 'AGGREGATE'
            FROM jsonb_array_elements(definition -> 'rules') rule(value)
            WHERE rule.value ? 'aggregate_input'
        ), reach(source_relation, target_relation) AS (
            SELECT source_relation, target_relation FROM edges
            UNION
            SELECT reach.source_relation, edges.target_relation
            FROM reach JOIN edges ON edges.source_relation = reach.target_relation
        )
        SELECT 1
        FROM edges edge
        WHERE edge.polarity IN ('NEGATIVE', 'AGGREGATE')
          AND EXISTS (
              SELECT 1 FROM reach
              WHERE reach.source_relation = edge.target_relation
                AND reach.target_relation = edge.source_relation
          )
    ) THEN
        RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_CYCLE', 'ERROR',
            definition ->> 'name',
            'derivation program contains a cycle through negation or aggregation',
            'Make every aggregate and negative dependency point strictly downward.',
            '{}'::jsonb;
        RETURN;
    END IF;

    base_definition := jsonb_set(definition, '{rules}', COALESCE((
        SELECT jsonb_agg(value - 'aggregate_input' ORDER BY ordinal)
        FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY rules(value, ordinal)
    ), '[]'::jsonb), true);
    IF definition ->> 'version' ~ '^[1-9][0-9]*$'
       AND COALESCE(pg_input_is_valid(definition ->> 'version', 'integer'), false) THEN
        SELECT version, definition INTO current_program
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = definition ->> 'name'
          AND version.state = 'ACTIVE';
        IF FOUND AND current_program.definition IS NOT DISTINCT FROM definition THEN
            base_definition := jsonb_set(base_definition, '{version}',
                to_jsonb((current_program.version + 1)::text));
        END IF;
    END IF;
    FOR diagnostic IN
        SELECT * FROM pgreact_internal.validate_derivation_program_m9(base_definition)
        WHERE code <> 'OK'
    LOOP
        RETURN QUERY SELECT diagnostic.contract_version, diagnostic.code,
            diagnostic.severity, diagnostic.object_identity,
            diagnostic.message, diagnostic.hint, diagnostic.details;
        RETURN;
    END LOOP;
    FOR aggregate_graph IN
        SELECT * FROM pgreact_internal.derivation_program_graph(definition)
        WHERE polarity = 'AGGREGATE'
        ORDER BY rule_name, input_order
    LOOP
        IF aggregate_graph.source_component_id IS NOT NULL
           AND aggregate_graph.source_stratum >= aggregate_graph.target_stratum THEN
            RETURN QUERY SELECT 4, 'PROGRAM_AGGREGATE_STRATUM', 'ERROR',
                aggregate_graph.rule_name,
                'aggregate input must be in a strictly lower completed stratum',
                'Move the counted relation below the aggregate target.',
                jsonb_build_object('source_stratum', aggregate_graph.source_stratum,
                                   'target_stratum', aggregate_graph.target_stratum);
            RETURN;
        END IF;
    END LOOP;
    RETURN QUERY SELECT 4, 'OK', 'INFO', definition ->> 'name',
        'stratified aggregate derivation program is valid',
        'Preview and deploy the containing pack.',
        jsonb_build_object('version', (definition ->> 'version')::integer,
                           'rules', jsonb_array_length(definition -> 'rules'));
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.derivation_program_strata(definition jsonb)
RETURNS TABLE(component_id uuid, stratum integer)
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE
    components AS (
        SELECT * FROM pgreact_internal.derivation_program_components($1)
    ),
    membership AS (
        SELECT component_id, relation_name
        FROM components CROSS JOIN LATERAL unnest(target_names) relation_name
    ),
    raw_edges(source_relation, target_relation, weight) AS (
        SELECT input.value ->> 'relation', rule.value ->> 'target', 0
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(rule.value -> 'inputs') input(value)
        UNION ALL
        SELECT input.value ->> 'relation', rule.value ->> 'target', 1
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
            rule.value -> 'negative_inputs', '[]'::jsonb)) input(value)
        UNION ALL
        SELECT rule.value -> 'aggregate_input' ->> 'relation',
               rule.value ->> 'target', 1
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        WHERE rule.value ? 'aggregate_input'
    ),
    component_edges(source_component, target_component, weight) AS (
        SELECT source_member.component_id, target_member.component_id, raw_edges.weight
        FROM raw_edges
        LEFT JOIN membership source_member ON source_member.relation_name = raw_edges.source_relation
        JOIN membership target_member ON target_member.relation_name = raw_edges.target_relation
        WHERE source_member.component_id IS DISTINCT FROM target_member.component_id
    ),
    seeds(component_id, stratum) AS (
        SELECT components.component_id, 0 FROM components
        UNION
        SELECT target_component, weight FROM component_edges WHERE source_component IS NULL
    ),
    paths(component_id, stratum) AS (
        SELECT component_id, stratum FROM seeds
        UNION
        SELECT edge.target_component, paths.stratum + edge.weight
        FROM paths JOIN component_edges edge ON edge.source_component = paths.component_id
    )
    SELECT components.component_id, max(paths.stratum)::integer
    FROM components JOIN paths USING (component_id)
    GROUP BY components.component_id
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.derivation_program_graph(definition jsonb)
RETURNS TABLE(
    dependency_id uuid,
    rule_name text,
    input_order integer,
    polarity text,
    source_relation text,
    target_relation text,
    source_component_id uuid,
    target_component_id uuid,
    source_stratum integer,
    target_stratum integer
)
LANGUAGE SQL
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH components AS (
        SELECT * FROM pgreact_internal.derivation_program_components($1)
    ),
    membership AS (
        SELECT component_id, relation_name
        FROM components CROSS JOIN LATERAL unnest(target_names) relation_name
    ),
    strata AS (
        SELECT * FROM pgreact_internal.derivation_program_strata($1)
    ),
    edges AS (
        SELECT rule.value ->> 'name' AS rule_name, input.ordinal::integer AS input_order,
               'POSITIVE'::text AS polarity, input.value ->> 'relation' AS source_relation,
               rule.value ->> 'target' AS target_relation
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(rule.value -> 'inputs')
            WITH ORDINALITY input(value, ordinal)
        UNION ALL
        SELECT rule.value ->> 'name', input.ordinal::integer, 'NEGATIVE',
               input.value ->> 'relation', rule.value ->> 'target'
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
            rule.value -> 'negative_inputs', '[]'::jsonb))
            WITH ORDINALITY input(value, ordinal)
        UNION ALL
        SELECT rule.value ->> 'name', 1, 'AGGREGATE',
               rule.value -> 'aggregate_input' ->> 'relation', rule.value ->> 'target'
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        WHERE rule.value ? 'aggregate_input'
    )
    SELECT pgreact_internal.activation_uuid(sha256(convert_to(
               ($1 ->> 'name') || '@' || ($1 ->> 'version') || ':' ||
               edges.rule_name || ':' || edges.polarity || ':' || edges.input_order || ':' ||
               edges.source_relation || ':' || edges.target_relation, 'UTF8'))),
           edges.rule_name, edges.input_order, edges.polarity,
           edges.source_relation, edges.target_relation,
           source_member.component_id, target_member.component_id,
           COALESCE(source_stratum.stratum, 0), target_stratum.stratum
    FROM edges
    LEFT JOIN membership source_member ON source_member.relation_name = edges.source_relation
    JOIN membership target_member ON target_member.relation_name = edges.target_relation
    LEFT JOIN strata source_stratum ON source_stratum.component_id = source_member.component_id
    JOIN strata target_stratum ON target_stratum.component_id = target_member.component_id
    ORDER BY target_stratum.stratum, edges.rule_name, edges.polarity,
             edges.input_order, edges.source_relation
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.m8_program_definition(
    program jsonb,
    mappings jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_set($1, '{rules}', COALESCE((
        SELECT jsonb_agg(
            (rule_item - 'definition' - 'target' - 'inputs' - 'negative_inputs' - 'aggregate_input') ||
            jsonb_build_object(
                'definition', pgreact_internal.pack_mapping($2, 'objects', rule_item ->> 'definition'),
                'target', pgreact_internal.pack_mapping($2, 'objects', rule_item ->> 'target'),
                'inputs', COALESCE((
                    SELECT jsonb_agg((input_item - 'relation') || jsonb_build_object(
                        'relation', pgreact_internal.pack_mapping($2, 'objects', input_item ->> 'relation'))
                        ORDER BY input_ordinal)
                    FROM jsonb_array_elements(rule_item -> 'inputs')
                    WITH ORDINALITY inputs(input_item, input_ordinal)
                ), '[]'::jsonb)
            ) || CASE WHEN rule_item ? 'negative_inputs' THEN jsonb_build_object(
                'negative_inputs', COALESCE((
                    SELECT jsonb_agg((input_item - 'relation') || jsonb_build_object(
                        'relation', pgreact_internal.pack_mapping($2, 'objects', input_item ->> 'relation'))
                        ORDER BY input_ordinal)
                    FROM jsonb_array_elements(rule_item -> 'negative_inputs')
                    WITH ORDINALITY inputs(input_item, input_ordinal)
                ), '[]'::jsonb)) ELSE '{}'::jsonb END ||
            CASE WHEN rule_item ? 'aggregate_input' THEN jsonb_build_object(
                'aggregate_input', ((rule_item -> 'aggregate_input') - 'relation') || jsonb_build_object(
                    'relation', pgreact_internal.pack_mapping($2, 'objects',
                        rule_item -> 'aggregate_input' ->> 'relation')))
            ELSE '{}'::jsonb END
            ORDER BY rule_ordinal
        )
        FROM jsonb_array_elements($1 -> 'rules')
        WITH ORDINALITY rules(rule_item, rule_ordinal)
    ), '[]'::jsonb), true)
$$;

ALTER FUNCTION pgreact_internal.m8_pack_plan_digest(jsonb, jsonb)
    RENAME TO m9_pack_plan_digest;

CREATE FUNCTION pgreact_internal.m8_pack_plan_digest(
    definition jsonb,
    mappings jsonb
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    base_digest text;
    item record;
    mapped_program jsonb;
    aggregate_state text;
BEGIN
    base_digest := pgreact_internal.m9_pack_plan_digest(definition, mappings);
    FOR item IN
        SELECT program, program_ordinal, rule, rule_ordinal
        FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb))
             WITH ORDINALITY programs(program, program_ordinal)
        LEFT JOIN LATERAL jsonb_array_elements(program -> 'rules')
             WITH ORDINALITY rules(rule, rule_ordinal) ON true
        WHERE rule ? 'aggregate_input'
        ORDER BY program_ordinal, rule_ordinal
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(item.program, mappings);
        SELECT concat_ws(':', relation.oid,
                         encode(pgreact_internal.source_closure_digest(relation.oid), 'hex'),
                         pgreact_internal.source_row_signature(relation.oid))
        INTO aggregate_state
        FROM pg_class relation
        WHERE relation.oid = to_regclass(
            mapped_program -> 'rules' -> (item.rule_ordinal - 1)::integer ->
                'aggregate_input' ->> 'relation');
        base_digest := base_digest || format(E'\naggregate:%s:%s:%s',
            item.program_ordinal, item.rule_ordinal,
            COALESCE(aggregate_state, '<missing>'));
    END LOOP;
    RETURN encode(sha256(convert_to(base_digest, 'UTF8')), 'hex');
END
$$;

CREATE FUNCTION pgreact_internal.attach_derivation_aggregate_input()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    aggregate_item jsonb;
BEGIN
    SELECT rule.value -> 'aggregate_input' INTO aggregate_item
    FROM pgreact_internal.derivation_program_versions version
    CROSS JOIN LATERAL jsonb_array_elements(version.definition -> 'rules') rule(value)
    WHERE version.program_version_id = NEW.program_version_id
      AND rule.value ->> 'name' = NEW.rule_name;
    IF aggregate_item IS NULL THEN RETURN NEW; END IF;
    INSERT INTO pgreact_internal.derivation_program_aggregate_inputs (
        program_version_id, rule_version_id, relation_oid, relation_name, key_column,
        comparison, threshold, relation_definition_digest, relation_row_signature
    ) VALUES (
        NEW.program_version_id, NEW.rule_version_id,
        to_regclass(aggregate_item ->> 'relation'), aggregate_item ->> 'relation',
        (aggregate_item ->> 'key')::name, aggregate_item ->> 'comparison',
        (aggregate_item ->> 'threshold')::bigint,
        pgreact_internal.source_closure_digest(to_regclass(aggregate_item ->> 'relation')),
        pgreact_internal.source_row_signature(to_regclass(aggregate_item ->> 'relation'))
    );
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_attach_derivation_aggregate_input
AFTER INSERT ON pgreact_internal.derivation_program_rules
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.attach_derivation_aggregate_input();

ALTER FUNCTION pgreact_internal.maintain_derived_support(uuid, uuid)
    RENAME TO maintain_derived_support_m9;

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
    exact_count bigint;
    holds boolean;
    current_support uuid;
    old_support record;
    frontier_value bigint;
    lower_frontier bigint;
    graph_row record;
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
    SELECT semantic_key INTO activation_key
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
    EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1',
        aggregate_input.relation_oid::regclass, aggregate_input.key_column)
    INTO exact_count USING activation_key;
    holds := CASE aggregate_input.comparison
        WHEN '=' THEN exact_count = aggregate_input.threshold
        WHEN '<' THEN exact_count < aggregate_input.threshold
        WHEN '<=' THEN exact_count <= aggregate_input.threshold
        WHEN '>' THEN exact_count > aggregate_input.threshold
        WHEN '>=' THEN exact_count >= aggregate_input.threshold
    END;
    SELECT graph.* INTO graph_row
    FROM pgreact_internal.derivation_program_graph(program_rule.definition) graph
    WHERE graph.rule_name = program_rule.rule_name AND graph.polarity = 'AGGREGATE';
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
        source_stratum, target_stratum, lower_frontier, active
    ) VALUES (
        pgreact_internal.activation_uuid(sha256(convert_to(
            program_rule.program_version_id::text || ':' || target_rule_version::text || ':' ||
            activation_key, 'UTF8'))),
        program_rule.program_version_id, target_rule_version, target_activation, current_support,
        activation_key, aggregate_input.relation_oid, aggregate_input.relation_name,
        exact_count, aggregate_input.comparison, aggregate_input.threshold,
        graph_row.source_stratum, graph_row.target_stratum, lower_frontier, true
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
            WHEN pgreact_internal.aggregate_dependency_evidence.exact_count
                     IS DISTINCT FROM EXCLUDED.exact_count
              OR pgreact_internal.aggregate_dependency_evidence.comparison
                     IS DISTINCT FROM EXCLUDED.comparison
              OR pgreact_internal.aggregate_dependency_evidence.threshold
                     IS DISTINCT FROM EXCLUDED.threshold
            THEN EXCLUDED.lower_frontier
            ELSE pgreact_internal.aggregate_dependency_evidence.lower_frontier
        END,
        active = true,
        invalidated_at = NULL;
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
            SELECT string_agg(format('%s:%s:%s:%s:%s:%s', evidence.rule_version_id,
                evidence.semantic_key, evidence.exact_count, evidence.comparison,
                evidence.threshold, evidence.active), E'\n'
                ORDER BY evidence.rule_version_id, evidence.semantic_key)
            FROM pgreact_internal.aggregate_dependency_evidence evidence
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = $1 AND rule.component_id = $2
             AND rule.rule_version_id = evidence.rule_version_id
        ), ''), 'UTF8'))
$$;

ALTER FUNCTION pgreact_internal.rebuild_derivation_program(uuid, boolean, boolean, bigint)
    RENAME TO rebuild_derivation_program_m9;

CREATE FUNCTION pgreact_internal.rebuild_derivation_program(
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
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
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
    WHERE input.program_version_id = target_program
      AND (input.relation_definition_digest IS DISTINCT FROM
               pgreact_internal.source_closure_digest(input.relation_oid)
           OR input.relation_row_signature IS DISTINCT FROM
               pgreact_internal.source_row_signature(input.relation_oid))
    ORDER BY rule.rule_order, rule.rule_name LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'derivation program aggregate-input drift for %', drift.rule_name
            USING HINT = 'Replace the complete derivation program through its rule pack.',
                  DETAIL = format('relation %s; expected definition %s, current %s; expected row signature %s, current %s',
                      drift.relation_name, drift.expected_digest, drift.current_digest,
                      drift.expected_signature, drift.current_signature);
    END IF;
    RETURN pgreact_internal.rebuild_derivation_program_m9(
        target_program, force_rebuild, preserve_frontier, existing_run_id);
END
$$;

ALTER FUNCTION pgreact.reconcile_derivation_program(uuid)
    RENAME TO reconcile_derivation_program_m9;
ALTER FUNCTION pgreact.reconcile_derivation_program_m9(uuid)
    SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact.reconcile_derivation_program(target_program uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    aggregate_evidence record;
    actual_count bigint;
    reconciliation_row_id bigint;
    next_diagnostic_order integer;
    aggregate_defects jsonb := '[]'::jsonb;
    aggregate_defect jsonb;
BEGIN
    PERFORM pgreact_internal.assert_program_owner(target_program);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    FOR aggregate_evidence IN
        SELECT * FROM pgreact_internal.aggregate_dependency_evidence
        WHERE program_version_id = target_program AND active
        ORDER BY evidence_id
    LOOP
        EXECUTE format('SELECT count(*) FROM %s WHERE %I = $1',
            aggregate_evidence.relation_oid::regclass,
            (SELECT key_column FROM pgreact_internal.derivation_program_aggregate_inputs input
             WHERE input.program_version_id = aggregate_evidence.program_version_id
               AND input.rule_version_id = aggregate_evidence.rule_version_id))
        INTO actual_count USING aggregate_evidence.semantic_key;
        IF actual_count IS DISTINCT FROM aggregate_evidence.exact_count THEN
            aggregate_defects := aggregate_defects || jsonb_build_array(jsonb_build_object(
                'evidence_id', aggregate_evidence.evidence_id, 'expected', actual_count,
                'actual', aggregate_evidence.exact_count));
        END IF;
    END LOOP;
    PERFORM pgreact_internal.reconcile_derivation_program_m9(target_program);
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
            reconciliation_row_id, next_diagnostic_order, 'WRONG_COUNT',
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
            SELECT * FROM pgreact_internal.aggregate_dependency_evidence
            WHERE support_id = support_row.support_id AND active
            ORDER BY evidence_id
        LOOP
            aggregate_conditions := aggregate_conditions || jsonb_build_array(
                jsonb_build_object(
                    'evidence_id', evidence_row.evidence_id,
                    'relation', evidence_row.relation_name,
                    'group_key', evidence_row.semantic_key,
                    'count', evidence_row.exact_count,
                    'comparison', evidence_row.comparison,
                    'threshold', evidence_row.threshold,
                    'source_stratum', evidence_row.source_stratum,
                    'lower_frontier', evidence_row.lower_frontier));
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

CREATE VIEW pgreact.aggregate_dependency_evidence AS
SELECT evidence.evidence_id, evidence.program_version_id, program.program_name,
       version.version AS program_version, evidence.rule_version_id, rule.rule_name,
       evidence.semantic_key AS group_key, evidence.relation_name AS counted_relation,
       evidence.exact_count, evidence.comparison, evidence.threshold,
       evidence.source_stratum, evidence.target_stratum, evidence.lower_frontier
FROM pgreact_internal.aggregate_dependency_evidence evidence
JOIN pgreact_internal.derivation_program_versions version USING (program_version_id)
JOIN pgreact_internal.derivation_programs program USING (program_id)
JOIN pgreact_internal.derivation_program_rules rule
  USING (program_version_id, rule_version_id)
WHERE version.state = 'ACTIVE' AND evidence.active;

REVOKE ALL ON pgreact.aggregate_dependency_evidence FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgreact_internal.derivation_program_graph(jsonb) TO PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M10 stratified keyed COUNT(*) thresholds over stable lower strata';
