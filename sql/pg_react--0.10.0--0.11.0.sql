CREATE TABLE pgreact_internal.advanced_readers (
    role_oid oid PRIMARY KEY
);

CREATE FUNCTION pgreact_api.infer_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rule_item record;
    inferred_inputs jsonb;
    source_oid oid;
    result jsonb := definition;
BEGIN
    IF jsonb_typeof(definition) IS DISTINCT FROM 'object'
       OR jsonb_typeof(definition -> 'rules') IS DISTINCT FROM 'array' THEN
        RETURN definition;
    END IF;
    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'rules')
             WITH ORDINALITY rules(value, ordinal)
        ORDER BY ordinal
    LOOP
        IF rule_item.value ? 'inputs' THEN
            RAISE EXCEPTION 'M14_EXPLICIT_INPUTS: inputs are inferred from the definition view'
                USING HINT = 'Remove inputs and reference each positive derived relation from the PostgreSQL view.';
        END IF;
        source_oid := to_regclass(rule_item.value ->> 'definition');
        IF source_oid IS NULL THEN
            CONTINUE;
        END IF;
        WITH RECURSIVE dependencies(relation_oid) AS (
            SELECT source_oid
            UNION
            SELECT dependency.refobjid
            FROM dependencies parent
            JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relation_oid
            JOIN pg_depend dependency
              ON dependency.classid = 'pg_rewrite'::regclass
             AND dependency.objid = rewrite.oid
             AND dependency.refclassid = 'pg_class'::regclass
             AND dependency.refobjsubid = 0
             AND dependency.deptype = 'n'
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'relation', relation.relation_name,
                'key', version.key_column) ORDER BY relation.relation_name), '[]'::jsonb)
          INTO inferred_inputs
          FROM dependencies dependency
          JOIN pgreact_internal.derived_relation_versions version
            ON version.public_view_oid = dependency.relation_oid
           AND version.state = 'ACTIVE'
          JOIN pgreact_internal.derived_relations relation USING (relation_id);
        result := jsonb_set(result,
            ARRAY['rules', (rule_item.ordinal - 1)::text, 'inputs'], inferred_inputs, true);
    END LOOP;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_api.validate_program(definition jsonb)
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
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rule_item record;
    inferred jsonb;
BEGIN
    IF jsonb_typeof(definition) = 'object'
       AND jsonb_typeof(definition -> 'rules') = 'array' THEN
        FOR rule_item IN
            SELECT value, ordinal FROM jsonb_array_elements(definition -> 'rules')
                 WITH ORDINALITY rules(value, ordinal)
        LOOP
            IF rule_item.value ? 'inputs' THEN
                RETURN QUERY SELECT 4, 'M14_EXPLICIT_INPUTS', 'ERROR',
                    COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                    'positive derived dependencies are inferred from the definition view',
                    'Remove inputs and reference each positive derived relation from the PostgreSQL view.',
                    '{}'::jsonb;
                RETURN;
            END IF;
        END LOOP;
    END IF;
    inferred := pgreact_api.infer_program(definition);
    RETURN QUERY
    SELECT 4, diagnostic.code, diagnostic.severity, diagnostic.object_identity,
           diagnostic.message, diagnostic.hint,
           diagnostic.details || jsonb_build_object('inferred_definition', inferred)
    FROM pgreact.validate_derivation_program(inferred) diagnostic;
END
$$;

CREATE FUNCTION pgreact_api.declare_derived_relation(
    relation_name text,
    row_type regtype,
    semantic_key name,
    relation_version integer DEFAULT 1
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact.create_derived_relation($1, $2, ARRAY[$3], $4)
$$;

CREATE FUNCTION pgreact_api.m14_pack(definition jsonb)
RETURNS jsonb
LANGUAGE SQL
STABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'format_version', 1,
        'pack', $1 ->> 'name',
        'version', $1 ->> 'version',
        'owner', session_user,
        'rules', '[]'::jsonb,
        'remove', '[]'::jsonb,
        'derived_relations', '[]'::jsonb,
        'derivations', '[]'::jsonb,
        'remove_derivations', '[]'::jsonb,
        'remove_derived_relations', '[]'::jsonb,
        'programs', jsonb_build_array(pgreact_api.infer_program($1)),
        'remove_programs', '[]'::jsonb)
$$;

CREATE FUNCTION pgreact_api.preview_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    inferred jsonb := pgreact_api.infer_program(definition);
    diagnostic record;
    plan text;
BEGIN
    SELECT * INTO diagnostic FROM pgreact_api.validate_program(definition)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M14_PROGRAM_INVALID: % for %', diagnostic.code, diagnostic.object_identity
            USING HINT = diagnostic.hint;
    END IF;
    plan := encode(sha256(convert_to(inferred::text || ':' || session_user, 'UTF8')), 'hex');
    RETURN jsonb_build_object(
        'contract_version', 4,
        'program', inferred,
        'plan_digest', plan);
END
$$;

CREATE FUNCTION pgreact_api.deploy_program(definition jsonb, expected_plan_digest text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    inferred jsonb := pgreact_api.infer_program(definition);
    actual_plan_digest text;
BEGIN
    actual_plan_digest := encode(sha256(convert_to(inferred::text || ':' || session_user, 'UTF8')), 'hex');
    IF expected_plan_digest IS NOT NULL AND expected_plan_digest <> actual_plan_digest THEN
        RAISE EXCEPTION 'M14_PROGRAM_PREVIEW_STALE'
            USING HINT = 'Preview the program again after DDL or deployment changes.';
    END IF;
    RETURN pgreact_internal.deploy_derivation_program(inferred, NULL);
END
$$;

CREATE FUNCTION pgreact_api.remove_program(program_name text, program_version integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    definition jsonb := jsonb_build_object(
        'format_version', 1, 'pack', program_name, 'version', program_version::text,
        'owner', session_user, 'rules', '[]'::jsonb, 'remove', '[]'::jsonb,
        'derived_relations', '[]'::jsonb, 'derivations', '[]'::jsonb,
        'remove_derivations', '[]'::jsonb, 'remove_derived_relations', '[]'::jsonb,
        'programs', '[]'::jsonb,
        'remove_programs', jsonb_build_array(jsonb_build_object('name', program_name)));
    plan text;
BEGIN
    SELECT min(plan_digest) INTO plan FROM pgreact.preview_pack(definition);
    PERFORM pgreact.deploy_pack(definition, plan);
END
$$;

CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH diagnostics AS (
        SELECT diagnostic
        FROM jsonb_array_elements(pgreact_api.health() -> 'diagnostics') diagnostic
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M14_EXTENSION_VERSION', 'severity', 'ERROR',
            'object_identity', 'pg_react',
            'message', 'pg_react extension version is not 0.11.0',
            'hint', 'Install the matching extension files and run ALTER EXTENSION pg_react UPDATE.')
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                          WHERE extname = 'pg_react' AND extversion = '0.11.0')
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M14_TRICKLE_VERSION', 'severity', 'ERROR',
            'object_identity', 'pg_trickle',
            'message', 'pg_trickle extension version is not 0.81.0',
            'hint', 'Install the supported pg_trickle 0.81.0 extension.')
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                          WHERE extname = 'pg_trickle' AND extversion = '0.81.0')
        UNION ALL
        SELECT jsonb_build_object(
            'code', 'M14_ROLE_CONFIGURATION', 'severity', 'WARNING',
            'object_identity', 'pgreact_api',
            'message', 'application facade roles are not configured',
            'hint', 'The extension owner must call pgreact_api.configure_roles with the M14 advanced reader.')
        WHERE (SELECT count(*) FROM pgreact_internal.application_roles) <> 4
    ), ordered AS (
        SELECT diagnostic
        FROM diagnostics
        ORDER BY CASE diagnostic ->> 'severity'
                     WHEN 'ERROR' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
                 diagnostic ->> 'code', diagnostic ->> 'object_identity'
    )
    SELECT jsonb_build_object(
        'contract_version', 4,
        'status', CASE WHEN EXISTS (SELECT 1 FROM ordered
                                    WHERE diagnostic ->> 'severity' = 'ERROR')
                       THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE((SELECT jsonb_agg(diagnostic) FROM ordered), '[]'::jsonb))
$$;

CREATE FUNCTION pgreact_api.explain(target text, semantic_key bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    relation_row record;
    program_id uuid;
    evidence jsonb;
BEGIN
    SELECT version.relation_version_id, relation.relation_name INTO relation_row
    FROM pgreact_internal.derived_relations relation
    JOIN pgreact_internal.derived_relation_versions version USING (relation_id)
    WHERE relation.relation_name = target AND version.state = 'ACTIVE';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'M14_FACT_NOT_FOUND: %', target;
    END IF;
    SELECT component.program_version_id INTO program_id
    FROM pgreact_internal.derivation_program_components component
    JOIN pgreact_internal.derivation_program_versions program
      ON program.program_version_id = component.program_version_id AND program.state = 'ACTIVE'
    WHERE relation_row.relation_version_id = ANY (component.target_relations)
    ORDER BY component.component_order LIMIT 1;
    IF program_id IS NULL THEN
        SELECT jsonb_build_object(
            'relation', fact.relation_name || '@' || fact.relation_version,
            'fact', fact.fact,
            'active_supports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'rule', support.rule_name || '@' || support.rule_version,
                'activation_generation', support.activation_generation,
                'source_binding', support.source_binding)
                ORDER BY support.rule_name, support.rule_version, support.activation_generation,
                         support.activation_revision)
                FROM pgreact.support_history support
                WHERE support.relation_version_id = relation_row.relation_version_id
                  AND support.semantic_key = semantic_key AND support.active), '[]'::jsonb))
          INTO evidence
          FROM pgreact.derived_facts fact
         WHERE fact.relation_version_id = relation_row.relation_version_id
           AND fact.semantic_key = semantic_key;
    ELSE
        evidence := pgreact_internal.recursive_fact_proof(
            program_id, relation_row.relation_version_id, semantic_key, ARRAY[]::uuid[]);
    END IF;
    RETURN jsonb_build_object(
        'contract_version', 4,
        'target', jsonb_build_object('kind', 'fact', 'name', target, 'key', semantic_key),
        'evidence', evidence);
END
$$;

CREATE FUNCTION pgreact_api.explain(target text, activation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = target AND version.state = 'ACTIVE';
    IF version_id IS NULL THEN RAISE EXCEPTION 'M14_RULE_NOT_FOUND: %', target; END IF;
    RETURN jsonb_build_object(
        'contract_version', 4,
        'target', jsonb_build_object('kind', 'match', 'rule', target, 'match_id', activation_id),
        'evidence', pgreact.explain_activation(version_id, activation_id));
END
$$;

CREATE FUNCTION pgreact_api.explain(target text, identifier bigint, job_target boolean)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT job_target OR target <> 'job' THEN
        RAISE EXCEPTION 'M14_EXPLAIN_TARGET: use explain(''job'', job_id, true) for a durable job';
    END IF;
    RETURN jsonb_build_object(
        'contract_version', 4,
        'target', jsonb_build_object('kind', 'job', 'job_id', identifier),
        'evidence', pgreact.explain_episode(identifier));
END
$$;

CREATE FUNCTION pgreact_api.explain(program_name text, include_graph boolean)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 4,
        'target', jsonb_build_object('kind', 'program', 'name', p.program_name,
                                     'version', p.program_version),
        'evidence', jsonb_build_object(
            'definition', version.definition,
            'components', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'component_id', component.component_id,
                'order', component.component_order,
                'cyclic', component.cyclic,
                'rules', component.rule_names,
                'targets', component.target_relations)
                ORDER BY component.component_order)
                FROM pgreact_internal.derivation_program_components component
                WHERE component.program_version_id = p.program_version_id), '[]'::jsonb),
            'graph', COALESCE((SELECT jsonb_agg(to_jsonb(graph)
                ORDER BY graph.target_stratum, graph.rule_name, graph.polarity, graph.input_order)
                FROM pgreact_internal.derivation_program_graph(version.definition) graph), '[]'::jsonb)))
    FROM pgreact.derivation_programs p
    JOIN pgreact_internal.derivation_program_versions version USING (program_version_id)
    WHERE p.program_name = $1 AND p.state = 'ACTIVE' AND $2
$$;

CREATE FUNCTION pgreact_api.explain_advanced(target_program uuid)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 4,
        'program', to_jsonb(program),
        'components', COALESCE((SELECT jsonb_agg(to_jsonb(component)
            ORDER BY component.component_order)
            FROM pgreact_internal.derivation_program_components component
            WHERE component.program_version_id = program.program_version_id), '[]'::jsonb),
        'rules', COALESCE((SELECT jsonb_agg(to_jsonb(rule) ORDER BY rule.rule_order)
            FROM pgreact_internal.derivation_program_rules rule
            WHERE rule.program_version_id = program.program_version_id), '[]'::jsonb))
    FROM pgreact.derivation_programs program
    WHERE program.program_version_id = $1
$$;

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
DECLARE previous name;
BEGIN
    PERFORM pgreact_api.configure_roles(author_role, operator_role, worker_role, reader_role);
    SELECT role_oid::regrole::text INTO previous FROM pgreact_internal.advanced_readers;
    IF previous IS NOT NULL THEN
        EXECUTE format('REVOKE ALL ON FUNCTION pgreact_api.explain_advanced(uuid) FROM %I', previous);
        EXECUTE format('REVOKE USAGE ON SCHEMA pgreact_api FROM %I', previous);
    END IF;
    DELETE FROM pgreact_internal.advanced_readers;
    INSERT INTO pgreact_internal.advanced_readers VALUES (advanced_reader_role);
    EXECUTE format('GRANT USAGE ON SCHEMA pgreact_api TO %I', advanced_reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.explain_advanced(uuid) TO %I', advanced_reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.validate_program(jsonb), '
        'pgreact_api.preview_program(jsonb), pgreact_api.declare_derived_relation(text,regtype,name,integer), '
        'pgreact_api.deploy_program(jsonb,text), pgreact_api.remove_program(text,integer) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.doctor(), '
        'pgreact_api.explain(text,bigint), pgreact_api.explain(text,uuid), '
        'pgreact_api.explain(text,bigint,boolean), pgreact_api.explain(text,boolean) TO %I', operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.doctor(), '
        'pgreact_api.explain(text,bigint), pgreact_api.explain(text,uuid), '
        'pgreact_api.explain(text,bigint,boolean), pgreact_api.explain(text,boolean) TO %I', reader_role::text);
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M14 PostgreSQL-native diagnosis, explanation, and inferred derivation programs';
