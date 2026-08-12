-- M13 core PostgreSQL ergonomics.  The existing lifecycle, derivation,
-- deadline, and worker engines remain authoritative behind this facade.

CREATE TABLE pgreact_internal.application_roles (
    role_kind text PRIMARY KEY
        CHECK (role_kind IN ('author', 'operator', 'worker', 'reader')),
    role_oid oid NOT NULL UNIQUE,
    configured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    configured_by name NOT NULL DEFAULT session_user
);

CREATE OR REPLACE FUNCTION pgreact_internal.is_operator_admin()
RETURNS boolean
LANGUAGE SQL
STABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user)
        OR (to_regrole('pgreact_admin') IS NOT NULL
            AND pg_catalog.pg_has_role(session_user, 'pgreact_admin', 'member'))
        OR EXISTS (
            SELECT 1
            FROM pgreact_internal.application_roles application_role
            WHERE application_role.role_kind = 'operator'
              AND pg_catalog.pg_has_role(
                    session_user, application_role.role_oid, 'member'))
$$;

CREATE FUNCTION pgreact_internal.resolve_action(
    action_schema name,
    action_name name,
    condition regclass,
    event_kind text
)
RETURNS regprocedure
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    source_type oid;
    source_owner oid;
    action_namespace oid;
    candidate record;
    named_count integer := 0;
    compatible_count integer := 0;
    authorized_count integer := 0;
    selected oid;
    identities text[] := ARRAY[]::text[];
    compatible boolean;
BEGIN
    IF event_kind NOT IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE') THEN
        RAISE EXCEPTION 'M13_ACTION_EVENT: unsupported action event %', event_kind;
    END IF;
    SELECT class.reltype, class.relowner
      INTO STRICT source_type, source_owner
      FROM pg_catalog.pg_class class
     WHERE class.oid = condition;
    SELECT namespace.oid INTO action_namespace
      FROM pg_catalog.pg_namespace namespace
     WHERE namespace.nspname = action_schema;
    IF action_namespace IS NULL
       OR action_namespace = pg_catalog.pg_my_temp_schema()
       OR action_schema IN (
            'pg_catalog', 'information_schema', 'pgreact', 'pgreact_api',
            'pgreact_internal', 'pgreact_runtime') THEN
        RAISE EXCEPTION 'M13_ACTION_SCHEMA: action schema % is not supported',
            action_schema
            USING HINT = 'Name one persistent application schema explicitly.';
    END IF;

    FOR candidate IN
        SELECT procedure.*,
               procedure.oid::regprocedure::text AS identity
          FROM pg_catalog.pg_proc procedure
         WHERE procedure.pronamespace = action_namespace
           AND procedure.proname = action_name
         ORDER BY procedure.oid::regprocedure::text
    LOOP
        named_count := named_count + 1;
        identities := identities || candidate.identity;
        compatible := candidate.prokind = 'f'
            AND candidate.prorettype = 'void'::regtype
            AND NOT candidate.proretset
            AND candidate.provariadic = 0
            AND candidate.pronargdefaults = 0
            AND candidate.proargmodes IS NULL
            AND CASE event_kind
                WHEN 'CHANGE' THEN
                    (candidate.pronargs = 2
                     AND candidate.proargtypes[0] = source_type
                     AND candidate.proargtypes[1] = source_type)
                    OR
                    (candidate.pronargs = 3
                     AND candidate.proargtypes[0] = 'pgreact.activation_context'::regtype
                     AND candidate.proargtypes[1] = source_type
                     AND candidate.proargtypes[2] = source_type)
                ELSE
                    (candidate.pronargs = 1
                     AND candidate.proargtypes[0] = source_type)
                    OR
                    (candidate.pronargs = 2
                     AND candidate.proargtypes[0] = 'pgreact.activation_context'::regtype
                     AND candidate.proargtypes[1] = source_type)
                END;
        IF compatible THEN
            compatible_count := compatible_count + 1;
            IF candidate.proowner = source_owner
               AND pg_catalog.has_schema_privilege(
                    source_owner, action_namespace, 'USAGE')
               AND pg_catalog.has_function_privilege(
                    source_owner, candidate.oid, 'EXECUTE') THEN
                authorized_count := authorized_count + 1;
                selected := candidate.oid;
            END IF;
        END IF;
    END LOOP;

    IF named_count = 0 THEN
        RAISE EXCEPTION 'M13_ACTION_NOT_FOUND: no action named %.% exists',
            action_schema, action_name
            USING HINT = 'Create one exact typed action in the named schema.';
    ELSIF compatible_count = 0 THEN
        RAISE EXCEPTION 'M13_ACTION_SIGNATURE: %.% has no supported % signature',
            action_schema, action_name, event_kind
            USING DETAIL = array_to_string(identities, ', '),
                  HINT = CASE event_kind
                    WHEN 'CHANGE' THEN
                        'Use (condition_row, condition_row) or (pgreact.activation_context, condition_row, condition_row) RETURNS void without defaults or VARIADIC arguments.'
                    ELSE
                        'Use (condition_row) or (pgreact.activation_context, condition_row) RETURNS void without defaults or VARIADIC arguments.'
                    END;
    ELSIF authorized_count = 0 THEN
        RAISE EXCEPTION 'M13_ACTION_UNAUTHORIZED: no compatible %.% action is owned and executable by the condition owner',
            action_schema, action_name
            USING DETAIL = array_to_string(identities, ', '),
                  HINT = 'Create the action as the condition owner in an accessible application schema.';
    ELSIF authorized_count > 1 THEN
        RAISE EXCEPTION 'M13_ACTION_AMBIGUOUS: %.% resolves to % authorized actions',
            action_schema, action_name, authorized_count
            USING DETAIL = array_to_string(identities, ', '),
                  HINT = 'Keep exactly one supported signature for this action name and lifecycle event.';
    END IF;
    RETURN selected::regprocedure;
END
$$;

CREATE FUNCTION pgreact_internal.add_resolved_binding(
    target_version_id uuid,
    event_kind text,
    action regprocedure
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    procedure_row record;
    action_qualified text;
    dispatcher_name text;
    dispatcher_qualified text;
    dispatcher oid;
    has_context boolean;
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    SELECT * INTO STRICT version_row
      FROM pgreact_internal.rule_versions
     WHERE rule_version_id = target_version_id;
    SELECT procedure.*, format('%I.%I', namespace.nspname, procedure.proname) AS qualified
      INTO STRICT procedure_row
      FROM pg_catalog.pg_proc procedure
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = procedure.pronamespace
     WHERE procedure.oid = action;
    action_qualified := procedure_row.qualified;
    has_context := procedure_row.proargtypes[0]
        = 'pgreact.activation_context'::regtype;
    dispatcher_name := format(
        'dispatch_m13_%s_%s',
        replace(target_version_id::text, '-', ''), lower(event_kind));
    dispatcher_qualified := format('%I.%I', 'pgreact_runtime', dispatcher_name);

    IF event_kind = 'CHANGE' AND has_context THEN
        EXECUTE format(
            'CREATE FUNCTION %s(context pgreact.activation_context, old_bindings jsonb, new_bindings jsonb) '
            'RETURNS void LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp '
            'AS $f$ SELECT %s($1, jsonb_populate_record(NULL::%s, $2), jsonb_populate_record(NULL::%s, $3)) $f$',
            dispatcher_qualified, action_qualified,
            version_row.source_view_name, version_row.source_view_name);
    ELSIF event_kind = 'CHANGE' THEN
        EXECUTE format(
            'CREATE FUNCTION %s(context pgreact.activation_context, old_bindings jsonb, new_bindings jsonb) '
            'RETURNS void LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp '
            'AS $f$ SELECT %s(jsonb_populate_record(NULL::%s, $2), jsonb_populate_record(NULL::%s, $3)) $f$',
            dispatcher_qualified, action_qualified,
            version_row.source_view_name, version_row.source_view_name);
    ELSIF has_context THEN
        EXECUTE format(
            'CREATE FUNCTION %s(context pgreact.activation_context, old_bindings jsonb, new_bindings jsonb) '
            'RETURNS void LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp '
            'AS $f$ SELECT %s($1, jsonb_populate_record(NULL::%s, $%s)) $f$',
            dispatcher_qualified, action_qualified, version_row.source_view_name,
            CASE WHEN event_kind = 'ACTIVATE' THEN '3' ELSE '2' END);
    ELSE
        EXECUTE format(
            'CREATE FUNCTION %s(context pgreact.activation_context, old_bindings jsonb, new_bindings jsonb) '
            'RETURNS void LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp '
            'AS $f$ SELECT %s(jsonb_populate_record(NULL::%s, $%s)) $f$',
            dispatcher_qualified, action_qualified, version_row.source_view_name,
            CASE WHEN event_kind = 'ACTIVATE' THEN '3' ELSE '2' END);
    END IF;
    EXECUTE format(
        'ALTER FUNCTION %s(pgreact.activation_context,jsonb,jsonb) OWNER TO %I',
        dispatcher_qualified, session_user);
    EXECUTE format(
        'REVOKE ALL ON FUNCTION %s(pgreact.activation_context,jsonb,jsonb) FROM PUBLIC',
        dispatcher_qualified);
    dispatcher := to_regprocedure(
        dispatcher_qualified || '(pgreact.activation_context,jsonb,jsonb)');
    INSERT INTO pgreact_internal.consequence_bindings (
        rule_version_id, event_kind, consequence_kind,
        function_oid, function_digest, function_identity,
        dispatcher_oid, dispatcher_digest, dispatcher_identity,
        max_attempts, initial_backoff_seconds,
        backoff_multiplier, max_backoff_seconds
    ) VALUES (
        target_version_id, event_kind, 'DATABASE_TYPED',
        action, sha256(convert_to(pg_get_functiondef(action), 'UTF8')),
        action::regprocedure::text,
        dispatcher, sha256(convert_to(pg_get_functiondef(dispatcher), 'UTF8')),
        dispatcher::regprocedure::text,
        1, 1, 2, 60);
END
$$;

CREATE FUNCTION pgreact_internal.validate_resolved_rule(
    condition regclass,
    semantic_key name,
    action_schema name,
    on_activate name,
    on_deactivate name,
    on_change name,
    deadline_column name DEFAULT NULL
)
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
    diagnostic record;
    resolved regprocedure;
    resolved_actions jsonb := '{}'::jsonb;
    action_name name;
    action_event text;
    includes_context boolean;
BEGIN
    IF deadline_column IS NULL THEN
        SELECT * INTO diagnostic
          FROM pgreact.validate_rule(
                condition, ARRAY[semantic_key], NULL) base_diagnostic
         WHERE base_diagnostic.severity = 'ERROR'
         ORDER BY base_diagnostic.code LIMIT 1;
    ELSE
        SELECT * INTO diagnostic
          FROM pgreact_internal.validate_deadline_rule(
                condition, semantic_key, deadline_column, NULL) base_diagnostic
         WHERE base_diagnostic.severity = 'ERROR'
         ORDER BY base_diagnostic.code LIMIT 1;
    END IF;
    IF FOUND THEN
        RETURN QUERY SELECT 3, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message,
            diagnostic.hint, diagnostic.details;
        RETURN;
    END IF;
    IF action_schema IS NULL
       AND (on_activate IS NOT NULL OR on_deactivate IS NOT NULL
            OR on_change IS NOT NULL) THEN
        RETURN QUERY SELECT 3, 'M13_ACTION_SCHEMA', 'ERROR', condition::text,
            'actions require one explicit application schema',
            'Pass action_schema by name.', '{}'::jsonb;
        RETURN;
    END IF;

    FOR action_event, action_name IN
        SELECT * FROM (VALUES
            ('ACTIVATE'::text, on_activate),
            ('DEACTIVATE'::text, on_deactivate),
            ('CHANGE'::text, on_change)
        ) actions(event_kind, action_name)
        WHERE actions.action_name IS NOT NULL
    LOOP
        resolved := pgreact_internal.resolve_action(
            action_schema, action_name, condition, action_event);
        SELECT procedure.proargtypes[0]
                   = 'pgreact.activation_context'::regtype
          INTO STRICT includes_context
          FROM pg_catalog.pg_proc procedure
         WHERE procedure.oid = resolved;
        resolved_actions := resolved_actions || jsonb_build_object(
            lower(action_event), jsonb_build_object(
                'identity', resolved::text,
                'context', CASE WHEN includes_context
                    THEN 'included' ELSE 'omitted' END));
    END LOOP;
    RETURN QUERY SELECT 3, 'OK', 'INFO', condition::text,
        'rule has one schema-safe immutable action resolution',
        'Author the rule with the same named arguments.',
        jsonb_build_object(
            'semantic_key', semantic_key,
            'actions', resolved_actions,
            'deadline_column', deadline_column);
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 3,
        CASE WHEN SQLERRM LIKE 'M13_%:%'
            THEN split_part(SQLERRM, ':', 1)
            ELSE 'M13_ACTION_RESOLUTION' END,
        'ERROR', condition::text, SQLERRM,
        COALESCE(NULLIF(pg_catalog.current_setting(
            'pgreact.validation_hint', true), ''),
            'Correct the named action and retry.'),
        '{}'::jsonb;
END
$$;

CREATE FUNCTION pgreact_internal.author_resolved_rule(
    rule_name text,
    condition regclass,
    semantic_key name,
    action_schema name,
    on_activate name,
    on_deactivate name,
    on_change name,
    deadline_column name DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    version_id uuid;
    activate_action regprocedure;
    deactivate_action regprocedure;
    change_action regprocedure;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    SELECT * INTO diagnostic
      FROM pgreact_internal.validate_resolved_rule(
            condition, semantic_key, action_schema,
            on_activate, on_deactivate, on_change, deadline_column)
     WHERE severity = 'ERROR'
     ORDER BY code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    IF on_activate IS NOT NULL THEN
        activate_action := pgreact_internal.resolve_action(
            action_schema, on_activate, condition, 'ACTIVATE');
    END IF;
    IF on_deactivate IS NOT NULL THEN
        deactivate_action := pgreact_internal.resolve_action(
            action_schema, on_deactivate, condition, 'DEACTIVATE');
    END IF;
    IF on_change IS NOT NULL THEN
        change_action := pgreact_internal.resolve_action(
            action_schema, on_change, condition, 'CHANGE');
    END IF;
    IF deadline_column IS NULL THEN
        version_id := pgreact.create_rule(
            rule_name, condition, ARRAY[semantic_key], 'COMMAND',
            NULL, NULL, NULL, 'SEED_CURRENT');
    ELSE
        version_id := pgreact.create_deadline_rule(
            rule_name, condition, ARRAY[semantic_key], deadline_column,
            'COMMAND', NULL, NULL, NULL, 'SEED_CURRENT');
    END IF;
    IF activate_action IS NOT NULL THEN
        PERFORM pgreact_internal.add_resolved_binding(
            version_id, 'ACTIVATE', activate_action);
    END IF;
    IF deactivate_action IS NOT NULL THEN
        PERFORM pgreact_internal.add_resolved_binding(
            version_id, 'DEACTIVATE', deactivate_action);
    END IF;
    IF change_action IS NOT NULL THEN
        PERFORM pgreact_internal.add_resolved_binding(
            version_id, 'CHANGE', change_action);
    END IF;
    RETURN version_id;
END
$$;

CREATE FUNCTION pgreact_api.validate_rule(
    condition regclass,
    semantic_key name,
    action_schema name,
    on_activate name
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT * FROM pgreact_internal.validate_resolved_rule(
        $1, $2, $3, $4, NULL, NULL)
$$;

CREATE FUNCTION pgreact_api.validate_rule(
    condition regclass,
    semantic_key name,
    action_schema name,
    on_activate name,
    on_deactivate name,
    on_change name
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT * FROM pgreact_internal.validate_resolved_rule(
        $1, $2, $3, $4, $5, $6)
$$;

CREATE FUNCTION pgreact_api.author_rule(
    rule_name text,
    condition regclass,
    semantic_key name,
    action_schema name,
    on_activate name
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.author_resolved_rule(
        $1, $2, $3, $4, $5, NULL, NULL)
$$;

CREATE FUNCTION pgreact_api.author_rule(
    rule_name text,
    condition regclass,
    semantic_key name,
    action_schema name,
    on_activate name,
    on_deactivate name,
    on_change name
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF on_deactivate IS NULL AND on_change IS NULL THEN
        RAISE EXCEPTION 'M13_LIFECYCLE_ACTIONS: use the activation-only overload';
    END IF;
    RETURN pgreact_internal.author_resolved_rule(
        rule_name, condition, semantic_key, action_schema,
        on_activate, on_deactivate, on_change);
END
$$;

CREATE FUNCTION pgreact_api.validate_deadline_rule(
    condition regclass,
    semantic_key name,
    deadline_column name,
    action_schema name,
    on_activate name
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT * FROM pgreact_internal.validate_resolved_rule(
        $1, $2, $4, $5, NULL, NULL, $3)
$$;

CREATE FUNCTION pgreact_api.author_deadline_rule(
    rule_name text,
    condition regclass,
    semantic_key name,
    deadline_column name,
    action_schema name,
    on_activate name
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.author_resolved_rule(
        $1, $2, $3, $5, $6, NULL, NULL, $4)
$$;

CREATE FUNCTION pgreact_internal.active_program_order()
RETURNS TABLE(program_version_id uuid, program_name text)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE active AS (
        SELECT version.program_version_id, program.program_name
          FROM pgreact_internal.derivation_program_versions version
          JOIN pgreact_internal.derivation_programs program USING (program_id)
         WHERE version.state = 'ACTIVE'
    ), edges AS (
        SELECT DISTINCT producer.program_version_id AS source_program,
                        consumer.program_version_id AS target_program
          FROM pgreact_internal.derivation_program_inputs input
          JOIN active consumer
            ON consumer.program_version_id = input.program_version_id
          JOIN pgreact_internal.derivation_program_components component
            ON input.relation_version_id = ANY (component.target_relations)
          JOIN active producer
            ON producer.program_version_id = component.program_version_id
         WHERE producer.program_version_id <> consumer.program_version_id
    ), reach(source_program, target_program) AS (
        SELECT source_program, target_program FROM edges
        UNION
        SELECT reach.source_program, edges.target_program
          FROM reach
          JOIN edges ON edges.source_program = reach.target_program
    )
    SELECT active.program_version_id, active.program_name
      FROM active
      LEFT JOIN reach ON reach.target_program = active.program_version_id
     GROUP BY active.program_version_id, active.program_name
     ORDER BY count(DISTINCT reach.source_program), active.program_name
$$;

CREATE FUNCTION pgreact_api.run(
    sampled_time timestamptz DEFAULT clock_timestamp()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    run_refresh_id bigint := pg_catalog.pg_current_xact_id()::text::bigint;
    rule_row record;
    relation_row record;
    program_row record;
    program_frontier bigint;
    clock_result jsonb;
    rules jsonb := '[]'::jsonb;
    relations jsonb := '[]'::jsonb;
    programs jsonb := '[]'::jsonb;
    jobs_before bigint;
    jobs_after bigint;
    session_locks integer := 0;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M13_RUN_UNAUTHORIZED: only the configured operator may run coordination';
    END IF;
    IF sampled_time IS NULL OR NOT isfinite(sampled_time) THEN
        RAISE EXCEPTION 'M13_RUN_SAMPLE: sampled database time must be finite and non-null';
    END IF;
    IF pg_catalog.pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M13_RUN_STANDBY: coordination cannot run on a physical standby';
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT count(*) INTO jobs_before FROM pgreact_internal.agenda;
    BEGIN
        PERFORM pgreact.begin_deadline_refresh(run_refresh_id);
        session_locks := 1;
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.rule_barriers barrier
             WHERE barrier.refresh_id IS DISTINCT FROM run_refresh_id
        ) THEN
            RAISE EXCEPTION 'M13_RUN_BARRIER: a rule already has a recovery or maintenance barrier';
        END IF;

        FOR rule_row IN
            SELECT rule.rule_name, version.rule_version_id,
                   deadline.rule_version_id IS NOT NULL AS deadline
              FROM pgreact_internal.rule_versions version
              JOIN pgreact_internal.rules rule USING (rule_id)
              LEFT JOIN pgreact_internal.deadline_rules deadline
                USING (rule_version_id)
             WHERE version.state = 'ACTIVE'
               AND NOT EXISTS (
                    SELECT 1
                      FROM pgreact_internal.derivation_rule_versions derivation
                     WHERE derivation.rule_version_id = version.rule_version_id)
               AND NOT EXISTS (
                    SELECT 1
                      FROM pgreact_internal.source_derived_dependencies(
                            version.source_view_oid))
             ORDER BY rule.rule_name, version.created_at
        LOOP
            PERFORM pgreact.refresh_rule(rule_row.rule_version_id);
            SET CONSTRAINTS ALL IMMEDIATE;
            SET CONSTRAINTS ALL DEFERRED;
            rules := rules || jsonb_build_array(jsonb_build_object(
                'rule', rule_row.rule_name,
                'kind', CASE WHEN rule_row.deadline
                    THEN 'deadline' ELSE 'ordinary' END,
                'result', 'refreshed'));
        END LOOP;
        IF pg_catalog.current_setting('pgreact.test_fail_run_phase', true) = 'rules' THEN
            RAISE EXCEPTION 'injected M13 run failure after rules';
        END IF;

        FOR relation_row IN
            SELECT relation.relation_name, version.relation_version_id
              FROM pgreact_internal.derived_relation_versions version
              JOIN pgreact_internal.derived_relations relation USING (relation_id)
             WHERE version.state = 'ACTIVE'
               AND NOT EXISTS (
                    SELECT 1
                      FROM pgreact_internal.derivation_program_components component
                      JOIN pgreact_internal.derivation_program_versions program
                        USING (program_version_id)
                     WHERE program.state = 'ACTIVE'
                       AND version.relation_version_id = ANY (component.target_relations))
             ORDER BY relation.relation_name, version.version
        LOOP
            program_frontier := pgreact.refresh_derived_relation(
                relation_row.relation_version_id);
            relations := relations || jsonb_build_array(jsonb_build_object(
                'relation', relation_row.relation_name,
                'frontier', program_frontier));
        END LOOP;

        IF EXISTS (
            WITH RECURSIVE active AS (
                SELECT program_version_id
                  FROM pgreact_internal.derivation_program_versions
                 WHERE state = 'ACTIVE'
            ), edges AS (
                SELECT DISTINCT producer.program_version_id AS source_program,
                                consumer.program_version_id AS target_program
                  FROM pgreact_internal.derivation_program_inputs input
                  JOIN active consumer
                    ON consumer.program_version_id = input.program_version_id
                  JOIN pgreact_internal.derivation_program_components component
                    ON input.relation_version_id = ANY (component.target_relations)
                  JOIN active producer
                    ON producer.program_version_id = component.program_version_id
                 WHERE producer.program_version_id <> consumer.program_version_id
            ), reach(source_program, target_program) AS (
                SELECT source_program, target_program FROM edges
                UNION
                SELECT reach.source_program, edges.target_program
                  FROM reach JOIN edges
                    ON edges.source_program = reach.target_program
            )
            SELECT 1 FROM reach WHERE source_program = target_program
        ) THEN
            RAISE EXCEPTION 'M13_RUN_PROGRAM_CYCLE: active programs have a cross-program dependency cycle';
        END IF;
        FOR program_row IN
            SELECT * FROM pgreact_internal.active_program_order()
        LOOP
            program_frontier := pgreact.refresh_derivation_program(
                program_row.program_version_id);
            IF program_frontier IS NULL THEN
                RAISE EXCEPTION 'M13_RUN_PROGRAM_FAILED: program % failed',
                    program_row.program_name;
            END IF;
            programs := programs || jsonb_build_array(jsonb_build_object(
                'program', program_row.program_name,
                'frontier', program_frontier));
        END LOOP;

        FOR rule_row IN
            SELECT rule.rule_name, version.rule_version_id,
                   deadline.rule_version_id IS NOT NULL AS deadline
              FROM pgreact_internal.rule_versions version
              JOIN pgreact_internal.rules rule USING (rule_id)
              LEFT JOIN pgreact_internal.deadline_rules deadline
                USING (rule_version_id)
             WHERE version.state = 'ACTIVE'
               AND NOT EXISTS (
                    SELECT 1
                      FROM pgreact_internal.derivation_rule_versions derivation
                     WHERE derivation.rule_version_id = version.rule_version_id)
               AND EXISTS (
                    SELECT 1
                      FROM pgreact_internal.source_derived_dependencies(
                            version.source_view_oid))
             ORDER BY rule.rule_name, version.created_at
        LOOP
            PERFORM pgreact.refresh_rule(rule_row.rule_version_id);
            SET CONSTRAINTS ALL IMMEDIATE;
            SET CONSTRAINTS ALL DEFERRED;
            rules := rules || jsonb_build_array(jsonb_build_object(
                'rule', rule_row.rule_name,
                'kind', CASE WHEN rule_row.deadline
                    THEN 'deadline' ELSE 'ordinary' END,
                'result', 'refreshed'));
        END LOOP;
        IF pg_catalog.current_setting('pgreact.test_fail_run_phase', true) = 'programs' THEN
            RAISE EXCEPTION 'injected M13 run failure after programs';
        END IF;

        clock_result := pgreact.advance_deadline_clock(sampled_time);
        IF pg_catalog.current_setting('pgreact.test_fail_run_phase', true) = 'clock' THEN
            RAISE EXCEPTION 'injected M13 run failure after clock';
        END IF;
        PERFORM pgreact.finish_deadline_refresh();
        session_locks := 0;
        SELECT count(*) INTO jobs_after FROM pgreact_internal.agenda;
        RETURN jsonb_build_object(
            'contract_version', 3,
            'sampled_time', sampled_time,
            'rules', rules,
            'relations', relations,
            'programs', programs,
            'clock', clock_result,
            'jobs_created', jobs_after - jobs_before);
    EXCEPTION WHEN OTHERS THEN
        WHILE session_locks > 0 LOOP
            PERFORM pg_catalog.pg_advisory_unlock(5788046901200000);
            session_locks := session_locks - 1;
        END LOOP;
        RAISE;
    END;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.run_rule(name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
          FROM pgreact_internal.rules rule
          JOIN pgreact_internal.rule_versions version USING (rule_id)
         WHERE rule.rule_name = run_rule.name
           AND version.state <> 'REMOVED') THEN
        RAISE EXCEPTION 'M11_RULE_NOT_FOUND: %', name;
    END IF;
    IF EXISTS (
        SELECT 1
          FROM pgreact_internal.rules rule
          JOIN pgreact_internal.rule_versions version USING (rule_id)
         WHERE rule.rule_name = run_rule.name
           AND version.state <> 'ACTIVE'
           AND version.state <> 'REMOVED') THEN
        RAISE EXCEPTION 'M12_RULE_NOT_ACTIVE: %', name;
    END IF;
    PERFORM pgreact_api.run();
END
$$;

CREATE FUNCTION pgreact_api.status(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 3,
        'rules', COALESCE(jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name,
            'condition', rule.source_view_name,
            'key', rule.key_column,
            'state', lower(rule.state),
            'actions', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'action', lower(binding.event_kind),
                    'function', binding.function_identity)
                    ORDER BY binding.event_kind)
                  FROM pgreact_internal.consequence_bindings binding
                 WHERE binding.rule_version_id = rule.rule_version_id
            ), '[]'::jsonb)) ORDER BY rule.rule_name), '[]'::jsonb))
      FROM pgreact.rules rule
     WHERE $1 IS NULL OR rule.rule_name = $1
$$;

CREATE FUNCTION pgreact_api.matches(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 3,
        'matches', COALESCE(jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name,
            'key', match.semantic_key,
            'matched_at', match.first_seen_at,
            'observed_at', match.last_seen_at)
            ORDER BY rule.rule_name, match.semantic_key), '[]'::jsonb))
      FROM pgreact_internal.activation_state match
      JOIN pgreact_internal.rule_versions version USING (rule_version_id)
      JOIN pgreact_internal.rules rule USING (rule_id)
     WHERE match.active AND ($1 IS NULL OR rule.rule_name = $1)
$$;

CREATE FUNCTION pgreact_api.jobs(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 3,
        'jobs', COALESCE(jsonb_agg(jsonb_build_object(
            'job_id', job.episode_id,
            'rule', rule.rule_name,
            'action', lower(job.event_kind),
            'state', lower(job.state),
            'available_at', job.available_at,
            'claimed_at', job.claimed_at,
            'completed_at', job.completed_at,
            'idempotency_key', job.idempotency_key)
            ORDER BY job.episode_id), '[]'::jsonb))
      FROM pgreact_internal.agenda job
      JOIN pgreact_internal.rules rule USING (rule_id)
     WHERE $1 IS NULL OR rule.rule_name = $1
$$;

CREATE FUNCTION pgreact_api.attempts(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 3,
        'attempts', COALESCE(jsonb_agg(jsonb_build_object(
            'job_id', attempt.episode_id,
            'attempt', attempt.attempt_no,
            'worker', attempt.worker_id,
            'status', lower(attempt.status),
            'started_at', attempt.started_at,
            'finished_at', attempt.finished_at,
            'error_code', attempt.error_code,
            'error_message', attempt.error_message)
            ORDER BY attempt.episode_id, attempt.attempt_no), '[]'::jsonb))
      FROM pgreact_internal.executions attempt
      JOIN pgreact_internal.agenda job USING (episode_id)
      JOIN pgreact_internal.rules rule USING (rule_id)
     WHERE $1 IS NULL OR rule.rule_name = $1
$$;

CREATE FUNCTION pgreact_api.explain(name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rule_status jsonb := pgreact_api.status(name);
BEGIN
    IF jsonb_array_length(rule_status -> 'rules') = 0 THEN
        RAISE EXCEPTION 'M11_RULE_NOT_FOUND: %', name;
    END IF;
    RETURN jsonb_build_object(
        'contract_version', 3,
        'rule', rule_status #> '{rules,0}',
        'matches', pgreact_api.matches(name) -> 'matches',
        'jobs', pgreact_api.jobs(name) -> 'jobs',
        'attempts', pgreact_api.attempts(name) -> 'attempts');
END
$$;

CREATE FUNCTION pgreact_api.claim_batch(
    rule_version_id uuid,
    action text,
    worker_id text,
    max_jobs integer DEFAULT 32,
    lease_for interval DEFAULT interval '60 seconds'
)
RETURNS TABLE(batch_id uuid, item_order integer, job_id bigint, lease_token uuid)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT * FROM pgreact.claim_batch($1, upper($2), $3, $4, $5)
$$;

CREATE FUNCTION pgreact_api.worker_protocol_compatible(protocol integer)
RETURNS boolean
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$ SELECT pgreact.worker_protocol_compatible($1) $$;

CREATE FUNCTION pgreact_api.execute_batch(batch_id uuid, worker_id text)
RETURNS TABLE(job_id bigint, status text, error_code text, error_message text)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$ SELECT * FROM pgreact.execute_claimed_batch($1, $2) $$;

CREATE FUNCTION pgreact_api.batch_status(batch_id uuid)
RETURNS text
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT batch.state
      FROM pgreact_internal.execution_batches batch
     WHERE batch.batch_id = $1
$$;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole,
    operator_role regrole,
    worker_role regrole,
    reader_role regrole
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    extension_owner oid;
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    target record;
    role_name name;
BEGIN
    SELECT extension.extowner INTO STRICT extension_owner
      FROM pg_catalog.pg_extension extension
     WHERE extension.extname = 'pg_react';
    IF caller_oid <> extension_owner
       AND NOT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE oid = caller_oid)
       AND NOT (to_regrole('pgreact_admin') IS NOT NULL
                AND pg_catalog.pg_has_role(
                    session_user, 'pgreact_admin', 'member')) THEN
        RAISE EXCEPTION 'M13_ROLE_ADMIN: only the extension owner or pgreact_admin may configure roles';
    END IF;
    IF cardinality(ARRAY[
        author_role::oid, operator_role::oid,
        worker_role::oid, reader_role::oid]) <> (
            SELECT count(DISTINCT role_oid)
              FROM unnest(ARRAY[
                author_role::oid, operator_role::oid,
                worker_role::oid, reader_role::oid]) role_oid) THEN
        RAISE EXCEPTION 'M13_ROLE_DISTINCT: author, operator, worker, and reader roles must be distinct';
    END IF;

    FOR target IN
        SELECT role_oid FROM pgreact_internal.application_roles
        UNION
        SELECT unnest(ARRAY[
            author_role::oid, operator_role::oid,
            worker_role::oid, reader_role::oid])
    LOOP
        SELECT rolname INTO role_name
          FROM pg_catalog.pg_roles WHERE oid = target.role_oid;
        CONTINUE WHEN role_name IS NULL;
        EXECUTE format(
            'REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM %I',
            role_name);
        EXECUTE format('REVOKE ALL ON SCHEMA pgreact_api FROM %I', role_name);
    END LOOP;
    DELETE FROM pgreact_internal.application_roles;
    INSERT INTO pgreact_internal.application_roles (role_kind, role_oid)
    VALUES ('author', author_role), ('operator', operator_role),
           ('worker', worker_role), ('reader', reader_role);

    FOREACH role_name IN ARRAY ARRAY[
        author_role::text, operator_role::text,
        worker_role::text, reader_role::text]::name[]
    LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA pgreact_api TO %I', role_name);
    END LOOP;
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION '
        'pgreact_api.validate_rule(regclass,name,text), '
        'pgreact_api.validate_rule(jsonb,jsonb), '
        'pgreact_api.validate_rule(regclass,name,name,name), '
        'pgreact_api.validate_rule(regclass,name,name,name,name,name), '
        'pgreact_api.author_rule(text,regclass,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer), '
        'pgreact_api.author_rule(jsonb,jsonb), '
        'pgreact_api.author_rule(text,regclass,name,name,name), '
        'pgreact_api.author_rule(text,regclass,name,name,name,name,name), '
        'pgreact_api.validate_deadline_rule(regclass,name,name,text), '
        'pgreact_api.validate_deadline_rule(regclass,name,name,name,name), '
        'pgreact_api.author_deadline_rule(text,regclass,name,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer), '
        'pgreact_api.author_deadline_rule(text,regclass,name,name,name,name) TO %I',
        author_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION '
        'pgreact_api.run(timestamptz), pgreact_api.run_rule(text), '
        'pgreact_api.pause_rule(text), pgreact_api.resume_rule(text), '
        'pgreact_api.reconcile_rule(text), '
        'pgreact_api.replace_deadline_rule(text,regclass,name,name,text,text,text,text,text), '
        'pgreact_api.remove_rule(text), pgreact_api.status(text), '
        'pgreact_api.explain(text), pgreact_api.matches(text), '
        'pgreact_api.jobs(text), pgreact_api.attempts(text), '
        'pgreact_api.rule_status(text), pgreact_api.explain_rule(text), '
        'pgreact_api.health(), pgreact_api.deadline_history(text) TO %I',
        operator_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION '
        'pgreact_api.claim(text,integer,interval), '
        'pgreact_api.execute(bigint,text,uuid), '
        'pgreact_api.worker_protocol_compatible(integer), '
        'pgreact_api.claim_batch(uuid,text,text,integer,interval), '
        'pgreact_api.execute_batch(uuid,text), '
        'pgreact_api.batch_status(uuid) TO %I',
        worker_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION '
        'pgreact_api.status(text), pgreact_api.explain(text), '
        'pgreact_api.matches(text), pgreact_api.jobs(text), '
        'pgreact_api.attempts(text), pgreact_api.rule_status(text), '
        'pgreact_api.explain_rule(text), pgreact_api.health(), '
        'pgreact_api.deadline_history(text) TO %I',
        reader_role::text);
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    pgreact_internal.derivation_program_graph(jsonb) TO PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M13 PostgreSQL-first authoring, coordinated runs, action resolution, and role grants';
