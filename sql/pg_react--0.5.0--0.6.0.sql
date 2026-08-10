-- M9 slice 6: grounded negative explanations and exact program repair.

ALTER TABLE pgreact_internal.derivation_program_components
    ADD COLUMN stratum integer NOT NULL DEFAULT 0 CHECK (stratum >= 0);

CREATE TABLE pgreact_internal.derivation_program_negative_inputs (
    program_version_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    input_order integer NOT NULL CHECK (input_order > 0),
    relation_oid oid NOT NULL,
    relation_name text NOT NULL,
    key_column name NOT NULL,
    relation_definition_digest bytea NOT NULL,
    relation_row_signature bytea NOT NULL,
    PRIMARY KEY (program_version_id, rule_version_id, input_order),
    UNIQUE (program_version_id, rule_version_id, relation_oid),
    FOREIGN KEY (program_version_id, rule_version_id)
        REFERENCES pgreact_internal.derivation_program_rules
);

CREATE TABLE pgreact_internal.negative_dependency_evidence (
    evidence_id uuid PRIMARY KEY,
    program_version_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    input_order integer NOT NULL CHECK (input_order > 0),
    support_id uuid NOT NULL
        REFERENCES pgreact_internal.derived_supports ON DELETE CASCADE,
    semantic_key bigint NOT NULL,
    relation_oid oid NOT NULL,
    relation_name text NOT NULL,
    source_stratum integer NOT NULL CHECK (source_stratum >= 0),
    target_stratum integer NOT NULL CHECK (target_stratum > source_stratum),
    lower_frontier bigint NOT NULL CHECK (lower_frontier > 0),
    active boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    invalidated_at timestamptz,
    FOREIGN KEY (program_version_id, rule_version_id, input_order)
        REFERENCES pgreact_internal.derivation_program_negative_inputs
        ON DELETE CASCADE
);

CREATE FUNCTION pgreact_internal.invalidate_negative_dependency_evidence()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    UPDATE pgreact_internal.negative_dependency_evidence
    SET active = false, invalidated_at = clock_timestamp()
    WHERE support_id = NEW.support_id AND active;
    RETURN NULL;
END
$$;

CREATE TRIGGER pgreact_invalidate_negative_dependency_evidence
AFTER UPDATE OF active ON pgreact_internal.derived_supports
FOR EACH ROW WHEN (OLD.active AND NOT NEW.active)
EXECUTE FUNCTION pgreact_internal.invalidate_negative_dependency_evidence();

ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    DROP CONSTRAINT derivation_program_repair_diagnostics_code_check;
ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    ADD CHECK (code IN (
        'MISSING_SUPPORT', 'EXTRA_SUPPORT', 'STALE_SUPPORT',
        'MISSING_FACT', 'EXTRA_FACT', 'STALE_FACT',
        'CIRCULAR_ONLY', 'WRONG_FRONTIER', 'MISSING_EVIDENCE',
        'EXTRA_EVIDENCE', 'STALE_EVIDENCE', 'WRONG_STRATUM'
    ));

CREATE FUNCTION pgreact_internal.relation_query_tree(target_relation oid)
RETURNS text
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE views(relid) AS (
        SELECT $1
        UNION
        SELECT dependency.refobjid
        FROM views parent
        JOIN pg_catalog.pg_rewrite rewrite ON rewrite.ev_class = parent.relid
        JOIN pg_catalog.pg_depend dependency
          ON dependency.classid = 'pg_rewrite'::regclass
         AND dependency.objid = rewrite.oid
         AND dependency.refclassid = 'pg_class'::regclass
        JOIN pg_catalog.pg_class relation ON relation.oid = dependency.refobjid
        WHERE relation.relkind IN ('v', 'm')
    )
    SELECT string_agg(rewrite.ev_action::text, E'\n' ORDER BY views.relid)
    FROM views
    JOIN pg_catalog.pg_rewrite rewrite
      ON rewrite.ev_class = views.relid AND rewrite.rulename = '_RETURN'
$$;

ALTER FUNCTION pgreact.validate_derivation_program(jsonb)
    RENAME TO validate_derivation_program_m8;
ALTER FUNCTION pgreact.validate_derivation_program_m8(jsonb)
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
    negative_item record;
    diagnostic record;
    source_oid oid;
    negative_oid oid;
    source_tree text;
    seen_negative_oids oid[];
    base_definition jsonb;
    current_program record;
    has_negative_field boolean;
BEGIN
    has_negative_field := EXISTS (
        SELECT 1
        FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END) rule(value)
        WHERE rule.value ? 'negative_inputs'
    );

    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END)
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        source_oid := pg_catalog.to_regclass(rule_item.value ->> 'definition');
        IF source_oid IS NOT NULL THEN
            source_tree := pgreact_internal.relation_query_tree(source_oid);
            IF source_tree ~ E'\\{BOOLEXPR[[:space:]]+:boolop[[:space:]]+not[[:space:]]'
               OR source_tree ~ E':jointype[[:space:]]+[1-5][[:space:]]'
               OR source_tree ~ E':setOperations[[:space:]]+\\{SETOPERATIONSTMT[[:space:]]+:op[[:space:]]+3[[:space:]]' THEN
                RETURN QUERY SELECT 3, 'PROGRAM_ABSENCE_UNSUPPORTED', 'ERROR',
                    COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                    'absence must be declared with negative_inputs',
                    'Remove NOT EXISTS, outer joins, and EXCEPT from the source SQL.',
                    jsonb_build_object('source', rule_item.value ->> 'definition');
                RETURN;
            END IF;
        END IF;
    END LOOP;

    IF NOT has_negative_field THEN
        RETURN QUERY
        SELECT * FROM pgreact_internal.validate_derivation_program_m8(definition);
        RETURN;
    END IF;

    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END)
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        IF rule_item.value ? 'negative_inputs'
           AND pg_catalog.jsonb_typeof(rule_item.value -> 'negative_inputs')
               IS DISTINCT FROM 'array' THEN
            RETURN QUERY SELECT 3, 'PROGRAM_RULE_INVALID', 'ERROR',
                COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                'negative_inputs must be an array',
                'Use an array of objects containing exactly relation and key.',
                '{}'::jsonb;
            RETURN;
        END IF;
        seen_negative_oids := ARRAY[]::oid[];
        FOR negative_item IN
            SELECT value, ordinal
            FROM jsonb_array_elements(COALESCE(
                rule_item.value -> 'negative_inputs', '[]'::jsonb))
            WITH ORDINALITY inputs(value, ordinal)
        LOOP
            IF pg_catalog.jsonb_typeof(negative_item.value) IS DISTINCT FROM 'object'
               OR NOT negative_item.value ?& ARRAY['relation', 'key']
               OR (SELECT count(*) FROM jsonb_object_keys(negative_item.value)) <> 2 THEN
                RETURN QUERY SELECT 3, 'PROGRAM_RULE_INVALID', 'ERROR',
                    COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                    'negative inputs require exactly relation and key',
                    'Remove unsupported negative predicates and expressions.',
                    jsonb_build_object('input', negative_item.ordinal);
                RETURN;
            END IF;
            negative_oid := pg_catalog.to_regclass(
                negative_item.value ->> 'relation');
            IF negative_oid IS NULL OR NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_class
                WHERE oid = negative_oid AND relkind IN ('r', 'p', 'v', 'm')
            ) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_UNRESOLVED', 'ERROR',
                    negative_item.value ->> 'relation',
                    'negative input does not resolve to a table or view',
                    'Map relation to one existing authoritative or derived relation.',
                    jsonb_build_object('rule', rule_item.value ->> 'name');
                RETURN;
            END IF;
            IF negative_oid = ANY (seen_negative_oids) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_DUPLICATE', 'ERROR',
                    rule_item.value ->> 'name',
                    'the same relation cannot be checked twice by one rule',
                    'Declare each negative relation once.',
                    jsonb_build_object('relation', negative_item.value ->> 'relation');
                RETURN;
            END IF;
            seen_negative_oids := array_append(seen_negative_oids, negative_oid);
            IF NOT EXISTS (
                SELECT 1
                FROM pg_catalog.pg_attribute attribute
                WHERE attribute.attrelid = negative_oid
                  AND attribute.attname = (negative_item.value ->> 'key')::name
                  AND attribute.atttypid = 'bigint'::regtype
                  AND attribute.attnum > 0 AND NOT attribute.attisdropped
            ) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_KEY_INVALID', 'ERROR',
                    rule_item.value ->> 'name',
                    'negative input key must be one bigint column',
                    'Project one bigint key with the rule output-key name.',
                    jsonb_build_object('relation', negative_item.value ->> 'relation',
                                       'key', negative_item.value ->> 'key');
                RETURN;
            END IF;
            IF negative_item.value ->> 'key'
               IS DISTINCT FROM rule_item.value ->> 'key' THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_UNBOUND', 'ERROR',
                    rule_item.value ->> 'name',
                    'negative input key must equal the non-null output key',
                    'Bind absence to the rule output key.',
                    jsonb_build_object('negative_key', negative_item.value ->> 'key',
                                       'output_key', rule_item.value ->> 'key');
                RETURN;
            END IF;
            source_tree := pgreact_internal.relation_query_tree(negative_oid);
            IF source_tree ~ E':hasAggs[[:space:]]+true'
               OR source_tree ~ E':aggfnoid[[:space:]]+[1-9]' THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_AGGREGATE', 'ERROR',
                    rule_item.value ->> 'name',
                    'aggregate negative inputs are outside M9',
                    'Check one non-aggregate keyed relation.',
                    jsonb_build_object('relation', negative_item.value ->> 'relation');
                RETURN;
            END IF;
        END LOOP;
    END LOOP;

    IF EXISTS (
        WITH RECURSIVE edges(source_relation, target_relation, polarity, rule_name) AS (
            SELECT input.value ->> 'relation', rule.value ->> 'target',
                   'POSITIVE'::text, rule.value ->> 'name'
            FROM jsonb_array_elements(definition -> 'rules') rule(value)
            CROSS JOIN LATERAL jsonb_array_elements(rule.value -> 'inputs') input(value)
            UNION ALL
            SELECT input.value ->> 'relation', rule.value ->> 'target',
                   'NEGATIVE', rule.value ->> 'name'
            FROM jsonb_array_elements(definition -> 'rules') rule(value)
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
                rule.value -> 'negative_inputs', '[]'::jsonb)) input(value)
        ), reach(source_relation, target_relation) AS (
            SELECT source_relation, target_relation FROM edges
            UNION
            SELECT reach.source_relation, edges.target_relation
            FROM reach JOIN edges
              ON edges.source_relation = reach.target_relation
        )
        SELECT 1
        FROM edges negative_edge
        WHERE negative_edge.polarity = 'NEGATIVE'
          AND EXISTS (
              SELECT 1 FROM reach
              WHERE reach.source_relation = negative_edge.target_relation
                AND reach.target_relation = negative_edge.source_relation
          )
    ) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_CYCLE', 'ERROR',
            definition ->> 'name',
            'derivation program contains a cycle through negation',
            'Make every negative dependency point to a lower stratum.',
            '{}'::jsonb;
        RETURN;
    END IF;

    base_definition := jsonb_set(definition, '{rules}', COALESCE((
        SELECT jsonb_agg(value - 'negative_inputs' ORDER BY ordinal)
        FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY rules(value, ordinal)
    ), '[]'::jsonb), true);
    IF definition ->> 'version' ~ '^[1-9][0-9]*$'
       AND COALESCE(pg_catalog.pg_input_is_valid(
           definition ->> 'version', 'integer'), false) THEN
        SELECT version, definition INTO current_program
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = definition ->> 'name'
          AND version.state = 'ACTIVE';
        IF FOUND AND ((definition ->> 'version')::integer < current_program.version
           OR ((definition ->> 'version')::integer = current_program.version
               AND definition IS DISTINCT FROM current_program.definition)) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_VERSION_EXISTS', 'ERROR',
                definition ->> 'name',
                'an immutable active program version already exists',
                'Keep the exact definition or increment the program version.',
                jsonb_build_object('active_version', current_program.version);
            RETURN;
        ELSIF FOUND AND (definition ->> 'version')::integer = current_program.version THEN
            base_definition := jsonb_set(base_definition, '{version}',
                to_jsonb((current_program.version + 1)::text));
        END IF;
    END IF;

    FOR diagnostic IN
        SELECT *
        FROM pgreact_internal.validate_derivation_program_m8(base_definition)
        WHERE code <> 'OK'
    LOOP
        RETURN QUERY SELECT diagnostic.contract_version, diagnostic.code,
            diagnostic.severity, diagnostic.object_identity,
            diagnostic.message, diagnostic.hint, diagnostic.details;
        RETURN;
    END LOOP;
    RETURN QUERY SELECT 3, 'OK', 'INFO', definition ->> 'name',
        'stratified derivation program is valid',
        'Preview and deploy the containing pack.',
        jsonb_build_object('version', (definition ->> 'version')::integer,
                           'rules', jsonb_array_length(definition -> 'rules'));
END
$$;

CREATE FUNCTION pgreact_internal.derivation_program_strata(definition jsonb)
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
        FROM components
        CROSS JOIN LATERAL unnest(target_names) relation_name
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
    ),
    component_edges(source_component, target_component, weight) AS (
        SELECT source_member.component_id, target_member.component_id, raw_edges.weight
        FROM raw_edges
        LEFT JOIN membership source_member
          ON source_member.relation_name = raw_edges.source_relation
        JOIN membership target_member
          ON target_member.relation_name = raw_edges.target_relation
        WHERE source_member.component_id IS DISTINCT FROM target_member.component_id
    ),
    seeds(component_id, stratum) AS (
        SELECT components.component_id, 0 FROM components
        UNION
        SELECT target_component, weight
        FROM component_edges WHERE source_component IS NULL
    ),
    paths(component_id, stratum) AS (
        SELECT component_id, stratum FROM seeds
        UNION
        SELECT edge.target_component, paths.stratum + edge.weight
        FROM paths
        JOIN component_edges edge ON edge.source_component = paths.component_id
    )
    SELECT components.component_id, max(paths.stratum)::integer
    FROM components JOIN paths USING (component_id)
    GROUP BY components.component_id
$$;

CREATE FUNCTION pgreact_internal.derivation_program_graph(definition jsonb)
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
        FROM components
        CROSS JOIN LATERAL unnest(target_names) relation_name
    ),
    strata AS (
        SELECT * FROM pgreact_internal.derivation_program_strata($1)
    ),
    edges AS (
        SELECT rule.value ->> 'name' AS rule_name,
               input.ordinal::integer AS input_order,
               'POSITIVE'::text AS polarity,
               input.value ->> 'relation' AS source_relation,
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
    )
    SELECT pgreact_internal.activation_uuid(sha256(convert_to(
               ($1 ->> 'name') || '@' || ($1 ->> 'version') || ':' ||
               edges.rule_name || ':' || edges.polarity || ':' ||
               edges.input_order || ':' || edges.source_relation || ':' ||
               edges.target_relation, 'UTF8'))),
           edges.rule_name, edges.input_order, edges.polarity,
           edges.source_relation, edges.target_relation,
           source_member.component_id, target_member.component_id,
           COALESCE(source_stratum.stratum, 0), target_stratum.stratum
    FROM edges
    LEFT JOIN membership source_member
      ON source_member.relation_name = edges.source_relation
    JOIN membership target_member
      ON target_member.relation_name = edges.target_relation
    LEFT JOIN strata source_stratum
      ON source_stratum.component_id = source_member.component_id
    JOIN strata target_stratum
      ON target_stratum.component_id = target_member.component_id
    ORDER BY target_stratum.stratum, edges.rule_name, edges.polarity,
             edges.input_order, edges.source_relation
$$;

CREATE FUNCTION pgreact_internal.set_derivation_component_stratum()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    SELECT assigned.stratum, assigned.component_order
    INTO STRICT NEW.stratum, NEW.component_order
    FROM pgreact_internal.derivation_program_versions version
    CROSS JOIN LATERAL (
        SELECT strata.component_id, strata.stratum,
               row_number() OVER (
                   ORDER BY strata.stratum, component.component_order
               )::integer AS component_order
        FROM pgreact_internal.derivation_program_components(
            version.definition) component
        JOIN pgreact_internal.derivation_program_strata(
            version.definition) strata USING (component_id)
    ) assigned
    WHERE version.program_version_id = NEW.program_version_id
      AND assigned.component_id = NEW.component_id;
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_set_derivation_component_stratum
BEFORE INSERT ON pgreact_internal.derivation_program_components
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.set_derivation_component_stratum();

CREATE FUNCTION pgreact_internal.attach_derivation_negative_inputs()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    negative_item record;
BEGIN
    FOR negative_item IN
        SELECT input.value, input.ordinal
        FROM pgreact_internal.derivation_program_versions version
        CROSS JOIN LATERAL jsonb_array_elements(version.definition -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
            rule.value -> 'negative_inputs', '[]'::jsonb))
            WITH ORDINALITY input(value, ordinal)
        WHERE version.program_version_id = NEW.program_version_id
          AND rule.value ->> 'name' = NEW.rule_name
    LOOP
        INSERT INTO pgreact_internal.derivation_program_negative_inputs (
            program_version_id, rule_version_id, input_order,
            relation_oid, relation_name, key_column,
            relation_definition_digest, relation_row_signature
        ) VALUES (
            NEW.program_version_id, NEW.rule_version_id, negative_item.ordinal,
            pg_catalog.to_regclass(negative_item.value ->> 'relation'),
            negative_item.value ->> 'relation',
            (negative_item.value ->> 'key')::name,
            pgreact_internal.source_closure_digest(
                pg_catalog.to_regclass(negative_item.value ->> 'relation')),
            pgreact_internal.source_row_signature(
                pg_catalog.to_regclass(negative_item.value ->> 'relation'))
        );
    END LOOP;
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_attach_derivation_negative_inputs
AFTER INSERT ON pgreact_internal.derivation_program_rules
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.attach_derivation_negative_inputs();

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
            (rule_item - 'definition' - 'target' - 'inputs' - 'negative_inputs') ||
            jsonb_build_object(
                'definition', pgreact_internal.pack_mapping(
                    $2, 'objects', rule_item ->> 'definition'),
                'target', pgreact_internal.pack_mapping(
                    $2, 'objects', rule_item ->> 'target'),
                'inputs', COALESCE((
                    SELECT jsonb_agg(
                        (input_item - 'relation') || jsonb_build_object(
                            'relation', pgreact_internal.pack_mapping(
                                $2, 'objects', input_item ->> 'relation'))
                        ORDER BY input_ordinal
                    )
                    FROM jsonb_array_elements(rule_item -> 'inputs')
                    WITH ORDINALITY inputs(input_item, input_ordinal)
                ), '[]'::jsonb)
            ) || CASE WHEN rule_item ? 'negative_inputs' THEN
                jsonb_build_object('negative_inputs', COALESCE((
                    SELECT jsonb_agg(
                        (input_item - 'relation') || jsonb_build_object(
                            'relation', pgreact_internal.pack_mapping(
                                $2, 'objects', input_item ->> 'relation'))
                        ORDER BY input_ordinal
                    )
                    FROM jsonb_array_elements(rule_item -> 'negative_inputs')
                    WITH ORDINALITY inputs(input_item, input_ordinal)
                ), '[]'::jsonb))
            ELSE '{}'::jsonb END
            ORDER BY rule_ordinal
        )
        FROM jsonb_array_elements($1 -> 'rules')
        WITH ORDINALITY rules(rule_item, rule_ordinal)
    ), '[]'::jsonb), true)
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.m8_pack_plan_digest(
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
    material text;
    item record;
    negative_item record;
    program_state text;
    source_state text;
    negative_state text;
    mapped_program jsonb;
BEGIN
    SELECT plan_digest INTO base_digest
    FROM pgreact_internal.preview_pack(
        pgreact_internal.m8_pack_definition(definition), mappings)
    ORDER BY action_order LIMIT 1;
    material := definition::text || E'\n' || mappings::text ||
        E'\nbase:' || COALESCE(base_digest, '<empty>') ||
        E'\nowner:' || session_user;
    FOR item IN
        SELECT program, program_ordinal, rule, rule_ordinal
        FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb))
             WITH ORDINALITY programs(program, program_ordinal)
        LEFT JOIN LATERAL jsonb_array_elements(program -> 'rules')
             WITH ORDINALITY rules(rule, rule_ordinal) ON true
        ORDER BY program_ordinal, rule_ordinal
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            item.program, mappings);
        SELECT concat_ws(':', version.program_version_id, version.version,
                         version.state, version.frontier,
                         encode(version.definition_digest, 'hex'))
        INTO program_state
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = item.program ->> 'name'
          AND version.state = 'ACTIVE';
        IF item.rule IS NOT NULL THEN
            SELECT concat_ws(':', relation.oid,
                encode(pgreact_internal.source_closure_digest(relation.oid), 'hex'),
                pgreact_internal.source_row_signature(relation.oid))
            INTO source_state
            FROM pg_catalog.pg_class relation
            WHERE relation.oid = pg_catalog.to_regclass(
                mapped_program -> 'rules' ->
                    (item.rule_ordinal - 1)::integer ->> 'definition');
        ELSE
            source_state := '<no-rule>';
        END IF;
        material := material || format(E'\nprogram:%s:%s:%s:rule:%s:%s:%s',
            item.program_ordinal, item.program ->> 'name',
            COALESCE(program_state, '<add>'), item.rule_ordinal,
            COALESCE(item.rule ->> 'name', '<none>'),
            COALESCE(source_state, '<missing>'));
        FOR negative_item IN
            SELECT input.value, input.ordinal
            FROM jsonb_array_elements(COALESCE(
                mapped_program -> 'rules' ->
                    (item.rule_ordinal - 1)::integer -> 'negative_inputs',
                '[]'::jsonb)) WITH ORDINALITY input(value, ordinal)
        LOOP
            SELECT concat_ws(':', relation.oid,
                encode(pgreact_internal.source_closure_digest(relation.oid), 'hex'),
                pgreact_internal.source_row_signature(relation.oid))
            INTO negative_state
            FROM pg_catalog.pg_class relation
            WHERE relation.oid = pg_catalog.to_regclass(
                negative_item.value ->> 'relation');
            material := material || format(E'\nnegative:%s:%s:%s',
                negative_item.ordinal,
                negative_item.value ->> 'relation',
                COALESCE(negative_state, '<missing>'));
        END LOOP;
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
$$;

CREATE OR REPLACE FUNCTION pgreact.preview_pack(
    definition jsonb,
    mappings jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
    plan_digest text,
    action_order integer,
    action text,
    rule_name text,
    dependencies text[],
    generated_object_changes jsonb,
    lifecycle_risks jsonb,
    details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    diagnostic record;
    preview_row record;
    program_item record;
    current_program record;
    digest text;
    ordinal integer := 0;
    dependency_names text[];
    mapped_program jsonb;
    has_negative boolean;
BEGIN
    IF NOT (definition ? 'programs' OR definition ? 'remove_programs') THEN
        SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
        WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'pg-react pack validation % for %: %',
                diagnostic.code, diagnostic.object_identity, diagnostic.message
                USING HINT = diagnostic.hint;
        END IF;
        RETURN QUERY SELECT * FROM pgreact_internal.preview_pack(definition, mappings);
        RETURN;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    digest := pgreact_internal.m8_pack_plan_digest(definition, mappings);
    FOR preview_row IN
        SELECT * FROM pgreact_internal.preview_pack(
            pgreact_internal.m8_pack_definition(definition), mappings)
        ORDER BY action_order
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := preview_row.action;
        rule_name := preview_row.rule_name;
        dependencies := preview_row.dependencies;
        generated_object_changes := preview_row.generated_object_changes;
        lifecycle_risks := preview_row.lifecycle_risks;
        details := preview_row.details;
        RETURN NEXT;
    END LOOP;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(
            definition -> 'programs', '[]'::jsonb)) value
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            program_item.value, mappings);
        SELECT version.program_version_id, version.version INTO current_program
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = program_item.value ->> 'name'
          AND version.state = 'ACTIVE';
        SELECT array_agg(value ->> 'name' ORDER BY rule_ordinal)::text[]
        INTO dependency_names
        FROM jsonb_array_elements(program_item.value -> 'rules')
        WITH ORDINALITY rules(value, rule_ordinal);
        SELECT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(mapped_program -> 'rules') rule(value)
            WHERE jsonb_array_length(COALESCE(
                rule.value -> 'negative_inputs', '[]'::jsonb)) > 0
        ) INTO has_negative;
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_program.program_version_id IS NULL THEN 'ADD'
                       WHEN current_program.version =
                            (program_item.value ->> 'version')::integer THEN 'KEEP'
                       ELSE 'REPLACE' END;
        rule_name := program_item.value ->> 'name';
        dependencies := COALESCE(dependency_names, ARRAY[]::text[]);
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION_PROGRAM',
            'components', (SELECT count(*)
                           FROM pgreact_internal.derivation_program_components(
                               mapped_program))) || CASE WHEN has_negative THEN
            jsonb_build_object(
                'dependency_graph', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'id', dependency_id,
                        'rule', graph.rule_name,
                        'input_order', graph.input_order,
                        'polarity', polarity,
                        'source', source_relation,
                        'target', target_relation,
                        'source_stratum', source_stratum,
                        'target_stratum', target_stratum)
                        ORDER BY target_stratum, graph.rule_name, polarity,
                                 graph.input_order, source_relation)
                    FROM pgreact_internal.derivation_program_graph(
                        mapped_program) graph
                ), '[]'::jsonb),
                'strata', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'component_id', component.component_id,
                        'stratum', assigned.stratum,
                        'rules', component.rule_names,
                        'targets', component.target_names)
                        ORDER BY assigned.stratum, component.component_order)
                    FROM pgreact_internal.derivation_program_components(
                        mapped_program) component
                    JOIN pgreact_internal.derivation_program_strata(
                        mapped_program) assigned USING (component_id)
                ), '[]'::jsonb)
            ) ELSE '{}'::jsonb END;
        lifecycle_risks := jsonb_build_array(
            'the complete program is rebuilt and commits at one frontier');
        details := jsonb_build_object(
            'prior_program_version_id', current_program.program_version_id,
            'prior_version', current_program.version,
            'next_version', (program_item.value ->> 'version')::integer,
            'max_iterations', (program_item.value ->> 'max_iterations')::integer,
            'max_facts', (program_item.value ->> 'max_facts')::bigint);
        RETURN NEXT;
    END LOOP;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(
            definition -> 'remove_programs', '[]'::jsonb)) value
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := 'REMOVE';
        rule_name := program_item.value ->> 'name';
        dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION_PROGRAM');
        lifecycle_risks := jsonb_build_array(
            'all member supports and facts retract atomically');
        details := '{}'::jsonb;
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.derivation_negative_blocked(
    target_program uuid,
    target_rule_version uuid,
    target_key bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    negative_input record;
    blocked boolean;
BEGIN
    FOR negative_input IN
        SELECT *
        FROM pgreact_internal.derivation_program_negative_inputs
        WHERE program_version_id = target_program
          AND rule_version_id = target_rule_version
        ORDER BY input_order
    LOOP
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %s WHERE %I = $1)',
            negative_input.relation_oid::regclass,
            negative_input.key_column)
        INTO blocked USING target_key;
        IF blocked THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
END
$$;

ALTER FUNCTION pgreact_internal.maintain_derived_support(uuid, uuid)
    RENAME TO maintain_derived_support_m8;

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
    activation_key bigint;
    negative_input record;
    old_support record;
    current_support record;
    frontier_value bigint;
BEGIN
    SELECT rule.*, version.definition
    INTO program_rule
    FROM pgreact_internal.derivation_program_rules rule
    JOIN pgreact_internal.derivation_program_versions version
      USING (program_version_id)
    WHERE rule.rule_version_id = target_rule_version
      AND version.state = 'ACTIVE'
    ORDER BY version.created_at DESC
    LIMIT 1;
    IF NOT FOUND THEN
        PERFORM pgreact_internal.maintain_derived_support_m8(
            target_rule_version, target_activation);
        RETURN;
    END IF;
    SELECT semantic_key INTO activation_key
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = target_rule_version
      AND activation_id = target_activation AND active;
    IF FOUND AND pgreact_internal.derivation_negative_blocked(
        program_rule.program_version_id, target_rule_version, activation_key) THEN
        SELECT support_id, relation_version_id, semantic_key
        INTO old_support
        FROM pgreact_internal.derived_supports
        WHERE rule_version_id = target_rule_version
          AND activation_id = target_activation AND active;
        IF FOUND THEN
            frontier_value := pgreact_internal.advance_derived_frontier(
                old_support.relation_version_id);
            UPDATE pgreact_internal.derived_supports
            SET active = false, grounded = false,
                last_frontier = frontier_value,
                invalidated_at = clock_timestamp()
            WHERE support_id = old_support.support_id;
            PERFORM pgreact_internal.recompute_derived_fact(
                old_support.relation_version_id,
                old_support.semantic_key, frontier_value);
        END IF;
        RETURN;
    END IF;
    PERFORM pgreact_internal.maintain_derived_support_m8(
        target_rule_version, target_activation);
    SELECT support_id, semantic_key, support_frontier
    INTO current_support
    FROM pgreact_internal.derived_supports
    WHERE rule_version_id = target_rule_version
      AND activation_id = target_activation AND active;
    IF NOT FOUND THEN RETURN; END IF;
    FOR negative_input IN
        SELECT input.*, graph.source_stratum, graph.target_stratum
        FROM pgreact_internal.derivation_program_negative_inputs input
        CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
            program_rule.definition) graph
        WHERE input.program_version_id = program_rule.program_version_id
          AND input.rule_version_id = target_rule_version
          AND graph.rule_name = program_rule.rule_name
          AND graph.polarity = 'NEGATIVE'
          AND graph.input_order = input.input_order
        ORDER BY input.input_order
    LOOP
        INSERT INTO pgreact_internal.negative_dependency_evidence (
            evidence_id, program_version_id, rule_version_id, input_order,
            support_id, semantic_key, relation_oid, relation_name,
            source_stratum, target_stratum, lower_frontier, active
        ) VALUES (
            pgreact_internal.activation_uuid(sha256(convert_to(
                program_rule.program_version_id::text || ':' ||
                target_rule_version::text || ':' ||
                negative_input.input_order || ':' ||
                current_support.semantic_key, 'UTF8'))),
            program_rule.program_version_id, target_rule_version,
            negative_input.input_order, current_support.support_id,
            current_support.semantic_key, negative_input.relation_oid,
            negative_input.relation_name, negative_input.source_stratum,
            negative_input.target_stratum, current_support.support_frontier, true
        )
        ON CONFLICT (evidence_id) DO UPDATE SET
            support_id = EXCLUDED.support_id,
            semantic_key = EXCLUDED.semantic_key,
            relation_oid = EXCLUDED.relation_oid,
            relation_name = EXCLUDED.relation_name,
            source_stratum = EXCLUDED.source_stratum,
            target_stratum = EXCLUDED.target_stratum,
            lower_frontier = EXCLUDED.lower_frontier,
            active = true,
            invalidated_at = NULL;
    END LOOP;
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
#variable_conflict use_variable
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    component_row record;
    rule_row record;
    activation_row record;
    relation_id uuid;
    run_id bigint := existing_run_id;
    component_iterations integer;
    total_iterations integer := 0;
    previous_fingerprint bytea;
    current_fingerprint bytea;
    before_fingerprint bytea;
    after_fingerprint bytea;
    facts bigint;
    supports bigint;
    relation_frontier bigint;
    component_converged boolean;
    source_drift record;
    locked_relation oid;
BEGIN
    SELECT * INTO STRICT program_row
    FROM pgreact_internal.derivation_program_versions
    WHERE program_version_id = target_program AND state = 'ACTIVE';
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    FOR locked_relation IN
        SELECT relation_oid
        FROM (
            SELECT rule.source_view_oid AS relation_oid
            FROM pgreact_internal.derivation_program_rules rule
            WHERE rule.program_version_id = target_program
            UNION
            SELECT input.relation_oid
            FROM pgreact_internal.derivation_program_negative_inputs input
            WHERE input.program_version_id = target_program
            UNION
            SELECT version.public_view_oid
            FROM pgreact_internal.derivation_program_components component
            CROSS JOIN LATERAL unnest(component.target_relations) target(relation_version_id)
            JOIN pgreact_internal.derived_relation_versions version
              USING (relation_version_id)
            WHERE component.program_version_id = target_program
        ) relations
        ORDER BY relation_oid
    LOOP
        EXECUTE format(
            'LOCK TABLE %s IN ACCESS SHARE MODE', locked_relation::regclass);
    END LOOP;
    SELECT r.rule_name,
           encode(r.source_definition_digest, 'hex') AS expected_digest,
           encode(pgreact_internal.source_closure_digest(r.source_view_oid), 'hex')
             AS current_digest
    INTO source_drift
    FROM pgreact_internal.derivation_program_rules r
    WHERE r.program_version_id = target_program
      AND r.source_definition_digest IS DISTINCT FROM
          pgreact_internal.source_closure_digest(r.source_view_oid)
    ORDER BY r.rule_order, r.rule_name
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'derivation program source drift for %',
            source_drift.rule_name
            USING HINT = 'Replace the complete derivation program through its rule pack.',
                  DETAIL = format('expected %s, current %s',
                                  source_drift.expected_digest,
                                  source_drift.current_digest);
    END IF;
    SELECT rule.rule_name, input.relation_name,
           encode(input.relation_definition_digest, 'hex') AS expected_digest,
           encode(pgreact_internal.source_closure_digest(input.relation_oid), 'hex')
             AS current_digest,
           encode(input.relation_row_signature, 'hex') AS expected_signature,
           encode(pgreact_internal.source_row_signature(input.relation_oid), 'hex')
             AS current_signature
    INTO source_drift
    FROM pgreact_internal.derivation_program_negative_inputs input
    JOIN pgreact_internal.derivation_program_rules rule
      USING (program_version_id, rule_version_id)
    WHERE input.program_version_id = target_program
      AND (input.relation_definition_digest IS DISTINCT FROM
               pgreact_internal.source_closure_digest(input.relation_oid)
           OR input.relation_row_signature IS DISTINCT FROM
               pgreact_internal.source_row_signature(input.relation_oid))
    ORDER BY rule.rule_order, rule.rule_name, input.input_order
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'derivation program negative-input drift for %',
            source_drift.rule_name
            USING HINT = 'Replace the complete derivation program through its rule pack.',
                  DETAIL = format(
                      'relation %s; expected definition %s, current %s; expected row signature %s, current %s',
                      source_drift.relation_name,
                      source_drift.expected_digest,
                      source_drift.current_digest,
                      source_drift.expected_signature,
                      source_drift.current_signature);
    END IF;
    PERFORM pg_catalog.set_config(
        'pgreact.program_support_frontier',
        CASE WHEN preserve_frontier THEN program_row.frontier
             ELSE program_row.frontier + 1 END::text,
        true);
    IF run_id IS NULL THEN
        INSERT INTO pgreact_internal.derivation_program_runs (
            program_version_id, started_at, prior_frontier, status, requested_by
        ) VALUES (
            target_program, clock_timestamp(), program_row.frontier,
            'RUNNING', session_user
        ) RETURNING pgreact_internal.derivation_program_runs.run_id INTO run_id;
    END IF;

    SELECT sha256(convert_to(COALESCE(string_agg(
        encode(pgreact_internal.derivation_component_fingerprint(
            target_program, c.component_id), 'hex'), '' ORDER BY c.component_order), ''), 'UTF8'))
    INTO before_fingerprint
    FROM pgreact_internal.derivation_program_components c
    WHERE c.program_version_id = target_program;

    IF NOT preserve_frontier THEN
      FOR rule_row IN
        SELECT r.rule_version_id
        FROM pgreact_internal.derivation_program_components c
        JOIN pgreact_internal.derivation_program_rules r
          USING (program_version_id, component_id)
        WHERE c.program_version_id = target_program
        ORDER BY c.component_order, r.rule_order, r.rule_name
    LOOP
        IF NOT pgreact_internal.derivation_rule_source_current(
            rule_row.rule_version_id) THEN
            PERFORM pgreact_internal.refresh_rule(rule_row.rule_version_id);
            SET CONSTRAINTS ALL IMMEDIATE;
            SET CONSTRAINTS ALL DEFERRED;
        END IF;
        FOR activation_row IN
            SELECT activation_id
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = rule_row.rule_version_id AND active
            ORDER BY activation_id
        LOOP
            PERFORM pgreact_internal.maintain_derived_support(
                rule_row.rule_version_id, activation_row.activation_id);
        END LOOP;
      END LOOP;
      SELECT sha256(convert_to(COALESCE(string_agg(
        encode(pgreact_internal.derivation_component_fingerprint(
            target_program, c.component_id), 'hex'), '' ORDER BY c.component_order), ''), 'UTF8'))
      INTO after_fingerprint
      FROM pgreact_internal.derivation_program_components c
      WHERE c.program_version_id = target_program;
      IF NOT force_rebuild AND before_fingerprint = after_fingerprint THEN
        UPDATE pgreact_internal.derivation_program_runs SET
            completed_at = clock_timestamp(),
            committed_frontier = program_row.frontier,
            iterations = 0,
            fact_count = (
                SELECT count(*)
                FROM pgreact_internal.derived_facts f
                JOIN pgreact_internal.derivation_program_components c
                  ON c.program_version_id = target_program
                 AND f.relation_version_id = ANY (c.target_relations)
            ),
            support_count = (
                SELECT count(*)
                FROM pgreact_internal.derived_supports s
                JOIN pgreact_internal.derivation_program_rules r
                  ON r.program_version_id = target_program
                 AND r.rule_version_id = s.rule_version_id
                WHERE s.active
            ),
            status = 'NOOP'
        WHERE pgreact_internal.derivation_program_runs.run_id = run_id;
          RETURN program_row.frontier;
      END IF;
    END IF;

    IF preserve_frontier THEN
        UPDATE pgreact_internal.derived_frontiers f
        SET transaction_id = pg_catalog.pg_current_xact_id()
        FROM pgreact_internal.derivation_program_components c
        WHERE c.program_version_id = target_program
          AND f.relation_version_id = ANY (c.target_relations);
    END IF;

    FOR relation_id IN
        SELECT DISTINCT unnest(c.target_relations)
        FROM pgreact_internal.derivation_program_components c
        WHERE c.program_version_id = target_program
        ORDER BY 1
    LOOP
        relation_frontier := pgreact_internal.advance_derived_frontier(relation_id);
        UPDATE pgreact_internal.derived_supports s SET
            active = false,
            grounded = false,
            last_frontier = relation_frontier,
            invalidated_at = clock_timestamp()
        FROM pgreact_internal.derivation_program_rules r
        WHERE r.program_version_id = target_program
          AND r.rule_version_id = s.rule_version_id
          AND s.relation_version_id = relation_id
          AND s.active;
        DELETE FROM pgreact_internal.derived_facts f
        WHERE f.relation_version_id = relation_id;
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_program('after_empty');

    FOR component_row IN
        SELECT * FROM pgreact_internal.derivation_program_components
        WHERE program_version_id = target_program
        ORDER BY component_order
    LOOP
        component_converged := false;
        component_iterations := 0;
        previous_fingerprint := pgreact_internal.derivation_component_fingerprint(
            target_program, component_row.component_id);
        FOR iteration_number IN 1..program_row.max_iterations LOOP
            component_iterations := iteration_number;
            total_iterations := total_iterations + 1;
            FOR rule_row IN
                SELECT * FROM pgreact_internal.derivation_program_rules
                WHERE program_version_id = target_program
                  AND component_id = component_row.component_id
                ORDER BY rule_order, rule_name
            LOOP
                IF NOT pgreact_internal.derivation_rule_source_current(
                    rule_row.rule_version_id) THEN
                    PERFORM pgreact_internal.refresh_rule(
                        rule_row.rule_version_id);
                    SET CONSTRAINTS ALL IMMEDIATE;
                    SET CONSTRAINTS ALL DEFERRED;
                END IF;
                FOR activation_row IN
                    SELECT activation_id
                    FROM pgreact_internal.activation_state
                    WHERE rule_version_id = rule_row.rule_version_id AND active
                    ORDER BY activation_id
                LOOP
                    PERFORM pgreact_internal.maintain_derived_support(
                        rule_row.rule_version_id, activation_row.activation_id);
                END LOOP;
            END LOOP;
            current_fingerprint := pgreact_internal.derivation_component_fingerprint(
                target_program, component_row.component_id);
            SELECT count(*) INTO facts
            FROM pgreact_internal.derived_facts
            WHERE relation_version_id = ANY (component_row.target_relations);
            SELECT count(*) INTO supports
            FROM pgreact_internal.derived_supports s
            JOIN pgreact_internal.derivation_program_rules r
              ON r.program_version_id = target_program
             AND r.component_id = component_row.component_id
             AND r.rule_version_id = s.rule_version_id
            WHERE s.active;
            INSERT INTO pgreact_internal.derivation_program_iterations (
                run_id, program_version_id, component_id, iteration,
                fact_count, support_count, fingerprint, completed_at
            ) VALUES (
                run_id, target_program, component_row.component_id,
                iteration_number, facts, supports,
                current_fingerprint, clock_timestamp()
            );
            IF (
                SELECT count(*) FROM pgreact_internal.derived_facts f
                JOIN pgreact_internal.derivation_program_components c
                  ON c.program_version_id = target_program
                 AND f.relation_version_id = ANY (c.target_relations)
            ) > program_row.max_facts THEN
                RAISE EXCEPTION 'derivation program % exceeded max_facts %',
                    target_program, program_row.max_facts;
            END IF;
            PERFORM pgreact_internal.maybe_fail_program('after_iteration');
            IF current_fingerprint = previous_fingerprint THEN
                component_converged := true;
                EXIT;
            END IF;
            previous_fingerprint := current_fingerprint;
        END LOOP;
        IF NOT component_converged THEN
            RAISE EXCEPTION 'derivation program % component % did not converge within % iterations',
                target_program, component_row.component_id,
                program_row.max_iterations;
        END IF;
        INSERT INTO pgreact_internal.derivation_program_component_frontiers (
            program_version_id, component_id, frontier, iterations,
            fact_count, support_count, fingerprint, committed_at
        ) VALUES (
            target_program, component_row.component_id,
            CASE WHEN preserve_frontier THEN program_row.frontier
                 ELSE program_row.frontier + 1 END,
            component_iterations,
            facts, supports, current_fingerprint, clock_timestamp()
        )
        ON CONFLICT (program_version_id, component_id) DO UPDATE SET
            frontier = EXCLUDED.frontier,
            iterations = EXCLUDED.iterations,
            fact_count = EXCLUDED.fact_count,
            support_count = EXCLUDED.support_count,
            fingerprint = EXCLUDED.fingerprint,
            committed_at = EXCLUDED.committed_at;
    END LOOP;

    IF NOT preserve_frontier THEN
        UPDATE pgreact_internal.derivation_program_versions
        SET frontier = frontier + 1
        WHERE program_version_id = target_program
        RETURNING frontier INTO program_row.frontier;
    END IF;
    SELECT count(*) INTO facts
    FROM pgreact_internal.derived_facts f
    JOIN pgreact_internal.derivation_program_components c
      ON c.program_version_id = target_program
     AND f.relation_version_id = ANY (c.target_relations);
    SELECT count(*) INTO supports
    FROM pgreact_internal.derived_supports s
    JOIN pgreact_internal.derivation_program_rules r
      ON r.program_version_id = target_program
     AND r.rule_version_id = s.rule_version_id
    WHERE s.active;
    UPDATE pgreact_internal.derivation_program_runs SET
        completed_at = clock_timestamp(),
        committed_frontier = program_row.frontier,
        iterations = total_iterations,
        fact_count = facts,
        support_count = supports,
        status = 'COMPLETED'
    WHERE pgreact_internal.derivation_program_runs.run_id = run_id;
    PERFORM pgreact_internal.maybe_fail_program('before_commit');
    RETURN program_row.frontier;
END
$$;

ALTER FUNCTION pgreact.reconcile_derivation_program(uuid)
    RENAME TO reconcile_derivation_program_m8;
ALTER FUNCTION pgreact.reconcile_derivation_program_m8(uuid)
    SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact.reconcile_derivation_program(target_program uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    target_reconciliation_id bigint;
    diagnostic_order integer;
    repair_count bigint;
    defect record;
    defects jsonb := '[]'::jsonb;
BEGIN
    program_row := pgreact_internal.assert_program_owner(target_program);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);

    FOR defect IN
        SELECT component.component_id, component.stratum AS actual,
               expected.stratum AS expected
        FROM pgreact_internal.derivation_program_components component
        JOIN LATERAL pgreact_internal.derivation_program_strata(
            program_row.definition) expected
          ON expected.component_id = component.component_id
        WHERE component.program_version_id = target_program
          AND component.stratum IS DISTINCT FROM expected.stratum
        ORDER BY component.component_order
    LOOP
        defects := defects || jsonb_build_array(jsonb_build_object(
            'code', 'WRONG_STRATUM',
            'object_identity', defect.component_id,
            'details', jsonb_build_object(
                'object_kind', 'COMPONENT',
                'expected', defect.expected,
                'actual', defect.actual)));
    END LOOP;
    UPDATE pgreact_internal.derivation_program_components component
    SET stratum = expected.stratum
    FROM pgreact_internal.derivation_program_strata(
        program_row.definition) expected
    WHERE component.program_version_id = target_program
      AND component.component_id = expected.component_id
      AND component.stratum IS DISTINCT FROM expected.stratum;

    FOR defect IN
        SELECT support.support_id, support.rule_version_id,
               support.semantic_key
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = target_program
         AND rule.rule_version_id = support.rule_version_id
        WHERE support.active
          AND EXISTS (
              SELECT 1
              FROM pgreact_internal.derivation_program_negative_inputs input
              WHERE input.program_version_id = target_program
                AND input.rule_version_id = support.rule_version_id)
        ORDER BY support.support_id
    LOOP
        IF pgreact_internal.derivation_negative_blocked(
            target_program, defect.rule_version_id, defect.semantic_key) THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'EXTRA_SUPPORT',
                'object_identity', defect.support_id,
                'details', jsonb_build_object(
                    'rule_version_id', defect.rule_version_id,
                    'semantic_key', defect.semantic_key,
                    'reason', 'negative input is present')));
        END IF;
    END LOOP;

    FOR defect IN
        WITH expected AS (
            SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                       target_program::text || ':' || support.rule_version_id::text || ':' ||
                       input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id,
                   support.support_id, support.rule_version_id,
                   input.input_order, support.semantic_key,
                   input.relation_oid, input.relation_name,
                   graph.source_stratum, graph.target_stratum,
                   support.support_frontier AS lower_frontier
            FROM pgreact_internal.derived_supports support
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = target_program
             AND rule.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.derivation_program_negative_inputs input
              ON input.program_version_id = target_program
             AND input.rule_version_id = support.rule_version_id
            CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
                program_row.definition) graph
            WHERE support.active
              AND graph.rule_name = rule.rule_name
              AND graph.polarity = 'NEGATIVE'
              AND graph.input_order = input.input_order
        )
        SELECT expected.*
        FROM expected
        LEFT JOIN pgreact_internal.negative_dependency_evidence evidence
          ON evidence.evidence_id = expected.evidence_id AND evidence.active
        WHERE evidence.evidence_id IS NULL
        ORDER BY expected.evidence_id
    LOOP
        defects := defects || jsonb_build_array(jsonb_build_object(
            'code', 'MISSING_EVIDENCE',
            'object_identity', defect.evidence_id,
            'details', jsonb_build_object(
                'rule_version_id', defect.rule_version_id,
                'input_order', defect.input_order,
                'semantic_key', defect.semantic_key)));
    END LOOP;

    FOR defect IN
        WITH expected AS (
            SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                       target_program::text || ':' || support.rule_version_id::text || ':' ||
                       input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id
            FROM pgreact_internal.derived_supports support
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = target_program
             AND rule.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.derivation_program_negative_inputs input
              ON input.program_version_id = target_program
             AND input.rule_version_id = support.rule_version_id
            WHERE support.active
        )
        SELECT evidence.evidence_id
        FROM pgreact_internal.negative_dependency_evidence evidence
        WHERE evidence.program_version_id = target_program AND evidence.active
          AND NOT EXISTS (
              SELECT 1 FROM expected
              WHERE expected.evidence_id = evidence.evidence_id)
        ORDER BY evidence.evidence_id
    LOOP
        defects := defects || jsonb_build_array(jsonb_build_object(
            'code', 'EXTRA_EVIDENCE',
            'object_identity', defect.evidence_id,
            'details', '{}'::jsonb));
    END LOOP;

    FOR defect IN
        WITH expected AS (
            SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                       target_program::text || ':' || support.rule_version_id::text || ':' ||
                       input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id,
                   support.support_id, support.rule_version_id,
                   input.input_order, support.semantic_key,
                   input.relation_oid, input.relation_name,
                   graph.source_stratum, graph.target_stratum,
                   support.support_frontier AS lower_frontier
            FROM pgreact_internal.derived_supports support
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = target_program
             AND rule.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.derivation_program_negative_inputs input
              ON input.program_version_id = target_program
             AND input.rule_version_id = support.rule_version_id
            CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
                program_row.definition) graph
            WHERE support.active
              AND graph.rule_name = rule.rule_name
              AND graph.polarity = 'NEGATIVE'
              AND graph.input_order = input.input_order
        )
        SELECT evidence.*, expected.evidence_id AS expected_evidence_id,
               expected.support_id AS expected_support_id,
               expected.relation_oid AS expected_relation_oid,
               expected.relation_name AS expected_relation_name,
               expected.source_stratum AS expected_source_stratum,
               expected.target_stratum AS expected_target_stratum,
               expected.lower_frontier AS expected_lower_frontier
        FROM pgreact_internal.negative_dependency_evidence evidence
        JOIN expected
          ON expected.rule_version_id = evidence.rule_version_id
         AND expected.input_order = evidence.input_order
         AND expected.semantic_key = evidence.semantic_key
        WHERE evidence.program_version_id = target_program AND evidence.active
        ORDER BY evidence.evidence_id
    LOOP
        IF defect.evidence_id IS DISTINCT FROM defect.expected_evidence_id
           OR defect.support_id IS DISTINCT FROM defect.expected_support_id
           OR defect.relation_oid IS DISTINCT FROM defect.expected_relation_oid
           OR defect.relation_name IS DISTINCT FROM defect.expected_relation_name THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'STALE_EVIDENCE',
                'object_identity', defect.evidence_id,
                'details', jsonb_build_object(
                    'expected_evidence_id', defect.expected_evidence_id,
                    'expected_support_id', defect.expected_support_id,
                    'expected_relation', defect.expected_relation_name)));
        END IF;
        IF defect.source_stratum IS DISTINCT FROM defect.expected_source_stratum
           OR defect.target_stratum IS DISTINCT FROM defect.expected_target_stratum THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'WRONG_STRATUM',
                'object_identity', defect.evidence_id,
                'details', jsonb_build_object(
                    'object_kind', 'EVIDENCE',
                    'expected_source', defect.expected_source_stratum,
                    'actual_source', defect.source_stratum,
                    'expected_target', defect.expected_target_stratum,
                    'actual_target', defect.target_stratum)));
        END IF;
        IF defect.lower_frontier IS DISTINCT FROM defect.expected_lower_frontier THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'WRONG_FRONTIER',
                'object_identity', defect.evidence_id,
                'details', jsonb_build_object(
                    'object_kind', 'EVIDENCE',
                    'expected', defect.expected_lower_frontier,
                    'actual', defect.lower_frontier)));
        END IF;
    END LOOP;

    PERFORM pgreact_internal.reconcile_derivation_program_m8(target_program);
    SELECT max(reconciliation.reconciliation_id)
    INTO STRICT target_reconciliation_id
    FROM pgreact_internal.derivation_program_reconciliations reconciliation
    WHERE reconciliation.program_version_id = target_program;

    FOR defect IN
        SELECT diagnostic.diagnostic_order, activation.semantic_key,
               (diagnostic.details ->> 'rule_version_id')::uuid AS rule_version_id
        FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
        JOIN pgreact_internal.activation_state activation
          ON activation.rule_version_id =
                 (diagnostic.details ->> 'rule_version_id')::uuid
         AND activation.activation_id =
                 (diagnostic.details ->> 'activation_id')::uuid
        WHERE diagnostic.reconciliation_id = target_reconciliation_id
          AND diagnostic.code = 'MISSING_SUPPORT'
        ORDER BY diagnostic.diagnostic_order
    LOOP
        IF pgreact_internal.derivation_negative_blocked(
            target_program, defect.rule_version_id, defect.semantic_key) THEN
            DELETE FROM pgreact_internal.derivation_program_repair_diagnostics
            WHERE pgreact_internal.derivation_program_repair_diagnostics.reconciliation_id =
                      target_reconciliation_id
              AND pgreact_internal.derivation_program_repair_diagnostics.diagnostic_order =
                      defect.diagnostic_order;
        END IF;
    END LOOP;

    WITH expected AS (
        SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                   target_program::text || ':' || support.rule_version_id::text || ':' ||
                   input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = target_program
         AND rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derivation_program_negative_inputs input
          ON input.program_version_id = target_program
         AND input.rule_version_id = support.rule_version_id
        WHERE support.active
    )
    DELETE FROM pgreact_internal.negative_dependency_evidence evidence
    WHERE evidence.program_version_id = target_program AND evidence.active
      AND NOT EXISTS (
          SELECT 1 FROM expected
          WHERE expected.evidence_id = evidence.evidence_id);

    SELECT COALESCE(max(diagnostic.diagnostic_order), 0)
    INTO diagnostic_order
    FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
    WHERE diagnostic.reconciliation_id = target_reconciliation_id;
    FOR defect IN
        SELECT item.value
        FROM jsonb_array_elements(defects) WITH ORDINALITY item(value, ordinal)
        ORDER BY item.ordinal
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            target_reconciliation_id, diagnostic_order,
            defect.value ->> 'code', defect.value ->> 'object_identity',
            defect.value -> 'details');
    END LOOP;
    SELECT count(*) INTO repair_count
    FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
    WHERE diagnostic.reconciliation_id = target_reconciliation_id;
    UPDATE pgreact_internal.derivation_program_reconciliations
    SET repairs = repair_count
    WHERE pgreact_internal.derivation_program_reconciliations.reconciliation_id =
          target_reconciliation_id;
    RETURN repair_count;
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
    input_node jsonb;
    relation_identity text;
BEGIN
    SELECT f.fact_id, f.fact, relation.relation_name, version.version
    INTO fact_row
    FROM pgreact_internal.derived_facts f
    JOIN pgreact_internal.derived_relation_versions version
      USING (relation_version_id)
    JOIN pgreact_internal.derived_relations relation USING (relation_id)
    WHERE f.relation_version_id = target_relation
      AND f.semantic_key = target_key;
    IF NOT FOUND THEN RETURN NULL; END IF;
    relation_identity := fact_row.relation_name || '@' || fact_row.version;
    IF fact_row.fact_id = ANY (path) THEN
        RETURN jsonb_build_object(
            'cycle', true,
            'relation', relation_identity,
            'semantic_key', target_key
        );
    END IF;
    FOR support_row IN
        SELECT support.support_id, support.logical_support_id,
               support.source_binding, rule.rule_name, derivation.version
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules program_rule
          ON program_rule.program_version_id = target_program
         AND program_rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derivation_rule_versions derivation
          ON derivation.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.rules rule ON rule.rule_id = derivation.rule_id
        WHERE support.relation_version_id = target_relation
          AND support.semantic_key = target_key AND support.active
        ORDER BY rule.rule_name, derivation.version,
                 support.logical_support_id
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
                input_node := jsonb_build_object(
                    'cycle', true,
                    'relation', input_row.relation_name || '@' || input_row.version,
                    'semantic_key', input_row.semantic_key
                );
            ELSE
                input_node := pgreact_internal.recursive_fact_proof(
                    target_program, input_row.relation_version_id,
                    input_row.semantic_key, path || fact_row.fact_id);
            END IF;
            inputs := inputs || jsonb_build_array(input_node);
        END LOOP;
        negative_checks := '[]'::jsonb;
        FOR evidence_row IN
            SELECT *
            FROM pgreact_internal.negative_dependency_evidence
            WHERE support_id = support_row.support_id AND active
            ORDER BY input_order
        LOOP
            negative_checks := negative_checks || jsonb_build_array(
                jsonb_build_object(
                    'evidence_id', evidence_row.evidence_id,
                    'relation', evidence_row.relation_name,
                    'semantic_key', evidence_row.semantic_key,
                    'source_stratum', evidence_row.source_stratum,
                    'lower_frontier', evidence_row.lower_frontier
                ));
        END LOOP;
        supports := supports || jsonb_build_array(jsonb_build_object(
            'rule', support_row.rule_name || '@' || support_row.version,
            'source_binding', support_row.source_binding,
            'inputs', inputs,
            'negative_checks', negative_checks
        ));
    END LOOP;
    RETURN jsonb_build_object(
        'relation', relation_identity,
        'fact', fact_row.fact,
        'supports', supports
    );
END
$$;

CREATE VIEW pgreact.derivation_dependency_graph AS
SELECT version.program_version_id, program.program_name,
       version.version AS program_version,
       graph.dependency_id, graph.rule_name, graph.input_order,
       graph.polarity, graph.source_relation, graph.target_relation,
       graph.source_component_id, graph.target_component_id,
       graph.source_stratum, graph.target_stratum
FROM pgreact_internal.derivation_program_versions version
JOIN pgreact_internal.derivation_programs program USING (program_id)
CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
    version.definition) graph;

CREATE VIEW pgreact.derivation_strata AS
SELECT component.program_version_id, program.program_name,
       version.version AS program_version, component.component_id,
       component.stratum, component.component_order, component.cyclic,
       component.rule_names,
       ARRAY(
           SELECT relation.relation_name
           FROM unnest(component.target_relations)
                WITH ORDINALITY target(relation_version_id, ordinal)
           JOIN pgreact_internal.derived_relation_versions relation_version
             USING (relation_version_id)
           JOIN pgreact_internal.derived_relations relation USING (relation_id)
           ORDER BY target.ordinal
       ) AS target_relations,
       frontier.frontier, frontier.iterations, frontier.fact_count,
       frontier.support_count, frontier.committed_at
FROM pgreact_internal.derivation_program_components component
JOIN pgreact_internal.derivation_program_versions version USING (program_version_id)
JOIN pgreact_internal.derivation_programs program USING (program_id)
LEFT JOIN pgreact_internal.derivation_program_component_frontiers frontier
  USING (program_version_id, component_id);

CREATE VIEW pgreact.negative_dependency_evidence AS
SELECT evidence.evidence_id, evidence.program_version_id,
       program.program_name, version.version AS program_version,
       evidence.rule_version_id, rule.rule_name, evidence.input_order,
       evidence.support_id, evidence.semantic_key,
       evidence.relation_name AS checked_relation,
       evidence.source_stratum, evidence.target_stratum,
       evidence.lower_frontier
FROM pgreact_internal.negative_dependency_evidence evidence
JOIN pgreact_internal.derivation_program_versions version
  USING (program_version_id)
JOIN pgreact_internal.derivation_programs program USING (program_id)
JOIN pgreact_internal.derivation_program_rules rule
  USING (program_version_id, rule_version_id)
JOIN pgreact_internal.derived_supports support USING (support_id)
WHERE version.state = 'ACTIVE' AND evidence.active AND support.active;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    pgreact_internal.derivation_program_graph(jsonb) TO PUBLIC;
REVOKE ALL ON pgreact.derivation_dependency_graph,
    pgreact.derivation_strata,
    pgreact.negative_dependency_evidence FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M9 stratified negation composed with positive fixed points';
