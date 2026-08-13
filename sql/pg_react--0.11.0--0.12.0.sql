-- M15 runtime and usability completion.

CREATE TABLE pgreact_internal.managed_processes (
    database_oid oid PRIMARY KEY,
    database_name name NOT NULL,
    backend_pid integer NOT NULL,
    state text NOT NULL CHECK (state IN ('ready', 'backpressure', 'standby', 'error')),
    protocol integer NOT NULL CHECK (protocol = 2),
    pending_jobs bigint NOT NULL DEFAULT 0 CHECK (pending_jobs >= 0),
    processed_jobs bigint NOT NULL DEFAULT 0 CHECK (processed_jobs >= 0),
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    heartbeat_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    detail text
);

CREATE FUNCTION pgreact_internal.key_component(value bigint)
RETURNS bytea
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT decode('01' || lpad(to_hex(octet_length(int8send($1))), 8, '0'), 'hex') || int8send($1) $$;

CREATE FUNCTION pgreact_internal.key_component(value uuid)
RETURNS bytea
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT decode('02' || lpad(to_hex(octet_length(uuid_send($1))), 8, '0'), 'hex') || uuid_send($1) $$;

CREATE FUNCTION pgreact_internal.key_component(value text)
RETURNS bytea
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT decode('03' || lpad(to_hex(octet_length(convert_to($1, 'UTF8'))), 8, '0'), 'hex') || convert_to($1, 'UTF8') $$;

CREATE FUNCTION pgreact_internal.canonical_key(components bytea[])
RETURNS bytea
LANGUAGE plpgsql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    component bytea;
    result bytea;
BEGIN
    IF cardinality(components) NOT BETWEEN 1 AND 4
       OR array_position(components, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'M15_KEY_ARITY: semantic keys require one to four non-null components';
    END IF;
    result := decode('02' || lpad(to_hex(cardinality(components)), 2, '0'), 'hex');
    FOREACH component IN ARRAY components LOOP
        result := result || component;
    END LOOP;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_internal.key_surrogate(canonical bytea)
RETURNS bigint
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$ SELECT ('x' || encode(substring(sha256($1) FROM 1 FOR 8), 'hex'))::bit(64)::bigint $$;

CREATE TABLE pgreact_internal.keyed_rule_versions (
    rule_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.rule_versions,
    public_condition oid NOT NULL,
    wrapper_condition oid NOT NULL,
    key_columns name[] NOT NULL CHECK (cardinality(key_columns) BETWEEN 1 AND 4),
    key_types regtype[] NOT NULL,
    key_collations regcollation[] NOT NULL
);

CREATE TABLE pgreact_internal.key_wrappers (
    wrapper_condition oid PRIMARY KEY,
    public_condition oid NOT NULL
);

CREATE TABLE pgreact_internal.semantic_key_identities (
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    semantic_key bigint NOT NULL,
    canonical_key bytea NOT NULL,
    public_key jsonb NOT NULL,
    first_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_seen_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (rule_version_id, semantic_key),
    UNIQUE (rule_version_id, canonical_key)
);

CREATE TABLE pgreact_internal.action_proxies (
    proxy_oid oid PRIMARY KEY,
    action_oid oid NOT NULL
);

CREATE FUNCTION pgreact_internal.assert_key_columns(condition regclass, key_columns name[])
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    source_owner oid;
    column_row record;
    found_columns integer := 0;
BEGIN
    IF cardinality(key_columns) NOT BETWEEN 1 AND 4
       OR array_position(key_columns, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'M15_KEY_ARITY: semantic keys require one to four named columns';
    END IF;
    IF (SELECT count(DISTINCT key_column) FROM unnest(key_columns) key_column)
       <> cardinality(key_columns) THEN
        RAISE EXCEPTION 'M15_KEY_DUPLICATE_COLUMN: semantic key columns must be distinct';
    END IF;
    SELECT relowner INTO STRICT source_owner FROM pg_class WHERE oid = condition;
    IF source_owner <> (SELECT oid FROM pg_roles WHERE rolname = session_user) THEN
        RAISE EXCEPTION 'M15_KEY_OWNER: the author must own condition %', condition;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute
               WHERE attrelid = condition AND left(attname, 10) = '__pgreact_'
                 AND attnum > 0 AND NOT attisdropped) THEN
        RAISE EXCEPTION 'M15_KEY_RESERVED: condition % uses a reserved __pgreact_ column', condition;
    END IF;
    FOR column_row IN
        SELECT key.ordinality, key.key_column, attribute.atttypid,
               attribute.attcollation, key_collation.collname,
               key_collation.collisdeterministic, current_database_row.datcollate
        FROM unnest(key_columns) WITH ORDINALITY key(key_column, ordinality)
        LEFT JOIN pg_attribute attribute
          ON attribute.attrelid = condition AND attribute.attname = key.key_column
         AND attribute.attnum > 0 AND NOT attribute.attisdropped
        LEFT JOIN pg_collation key_collation ON key_collation.oid = attribute.attcollation
        CROSS JOIN pg_database current_database_row
        WHERE current_database_row.datname = current_database()
        ORDER BY key.ordinality
    LOOP
        IF column_row.atttypid IS NULL THEN
            RAISE EXCEPTION 'M15_KEY_COLUMN: column % does not exist in %',
                column_row.key_column, condition;
        END IF;
        found_columns := found_columns + 1;
        IF column_row.atttypid NOT IN ('bigint'::regtype, 'uuid'::regtype, 'text'::regtype) THEN
            RAISE EXCEPTION 'M15_KEY_TYPE: %.% has unsupported type %',
                condition, column_row.key_column, column_row.atttypid::regtype
                USING HINT = 'Use bigint, uuid, or text directly; domains and implicit casts are not key codecs.';
        END IF;
        IF column_row.atttypid = 'text'::regtype
           AND NOT column_row.collisdeterministic THEN
            RAISE EXCEPTION 'M15_KEY_COLLATION: %.% uses nondeterministic collation %',
                condition, column_row.key_column, column_row.collname;
        END IF;
        IF column_row.atttypid = 'text'::regtype
           AND column_row.collname <> 'C'
           AND NOT (column_row.collname = 'default'
                    AND column_row.datcollate IN ('C', 'C.UTF-8', 'C.utf8')) THEN
            RAISE EXCEPTION 'M15_KEY_COLLATION: %.% requires C collation for portable identity',
                condition, column_row.key_column
                USING HINT = 'Declare the text key column with COLLATE "C".';
        END IF;
    END LOOP;
    IF found_columns <> cardinality(key_columns) THEN
        RAISE EXCEPTION 'M15_KEY_COLUMN: semantic key columns could not be resolved';
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.create_key_wrapper(condition regclass, key_columns name[])
RETURNS regclass
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    key_column name;
    key_type oid;
    computed_name name := ('m15_key_base_' || md5(condition::text || ':' || key_columns::text))::name;
    wrapper_name name := ('m15_key_' || md5(condition::text || ':' || key_columns::text))::name;
    wrapper regclass;
    components text[] := ARRAY[]::text[];
    public_values text[] := ARRAY[]::text[];
    canonical_expression text;
BEGIN
    PERFORM pgreact_internal.assert_key_columns(condition, key_columns);
    FOREACH key_column IN ARRAY key_columns LOOP
        SELECT atttypid INTO STRICT key_type
        FROM pg_attribute
        WHERE attrelid = condition AND attname = key_column
          AND attnum > 0 AND NOT attisdropped;
        components := components || CASE key_type
            WHEN 'bigint'::regtype THEN format(
                '(decode(''01'' || lpad(to_hex(octet_length(int8send(m.%1$I))), 8, ''0''), ''hex'') || int8send(m.%1$I))',
                key_column)
            WHEN 'uuid'::regtype THEN format(
                '(decode(''02'' || lpad(to_hex(octet_length(uuid_send(m.%1$I))), 8, ''0''), ''hex'') || uuid_send(m.%1$I))',
                key_column)
            WHEN 'text'::regtype THEN format(
                '(decode(''03'' || lpad(to_hex(octet_length(convert_to(m.%1$I, ''UTF8''))), 8, ''0''), ''hex'') || convert_to(m.%1$I, ''UTF8''))',
                key_column)
        END;
        public_values := public_values || format('to_jsonb(m.%I)', key_column);
    END LOOP;
    canonical_expression := format(
        '(decode(''02'' || lpad(to_hex(%s), 2, ''0''), ''hex'') || %s)',
        cardinality(key_columns), array_to_string(components, ' || '));
    EXECUTE format(
        'CREATE OR REPLACE VIEW pgreact_runtime.%I WITH (security_barrier=true) AS '
        'SELECT m.*, %s AS __pgreact_canonical, '
        '(''x'' || encode(substring(sha256(%s) FROM 1 FOR 8), ''hex''))::bit(64)::bigint '
        'AS __pgreact_key, %s AS __pgreact_public_key '
        'FROM %s m',
        computed_name, canonical_expression, canonical_expression,
        CASE WHEN cardinality(public_values) = 1 THEN public_values[1]
             ELSE format('jsonb_build_array(%s)', array_to_string(public_values, ', ')) END,
        condition);
    EXECUTE format(
        'CREATE OR REPLACE VIEW pgreact_runtime.%I WITH (security_barrier=true) AS '
        'SELECT * FROM pgreact_runtime.%I', wrapper_name, computed_name);
    EXECUTE format('ALTER VIEW pgreact_runtime.%I OWNER TO %I', computed_name, session_user);
    EXECUTE format('ALTER VIEW pgreact_runtime.%I OWNER TO %I', wrapper_name, session_user);
    EXECUTE format('GRANT USAGE ON SCHEMA pgreact_runtime TO %I', session_user);
    wrapper := format('pgreact_runtime.%I', wrapper_name)::regclass;
    INSERT INTO pgreact_internal.key_wrappers VALUES (wrapper, condition)
    ON CONFLICT (wrapper_condition) DO UPDATE
    SET public_condition = EXCLUDED.public_condition;
    RETURN wrapper;
END
$$;

ALTER FUNCTION pgreact.validate_rule(regclass, name[], regprocedure)
SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.validate_rule(regclass, name[], regprocedure)
RENAME TO validate_rule_m14;

CREATE FUNCTION pgreact.validate_rule(
    definition regclass,
    key_columns name[],
    on_activate regprocedure DEFAULT NULL
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM pgreact_internal.key_wrappers
               WHERE wrapper_condition = definition) THEN
        RETURN QUERY SELECT 5, 'OK', 'INFO', definition::text,
            'M15 typed-key wrapper is valid',
            'Use the public typed-key authoring API.',
            jsonb_build_object('key_codec', 'tuple-v2');
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM pgreact_internal.validate_rule_m14(definition, key_columns, on_activate);
END
$$;

CREATE FUNCTION pgreact_internal.create_action_proxy(
    target_version_id uuid,
    event_kind text,
    action regprocedure,
    public_condition regclass,
    wrapper_condition regclass
)
RETURNS regprocedure
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    proxy_name name := ('m15_action_' || replace(gen_random_uuid()::text, '-', ''))::name;
    proxy_qualified text := format('%I.%I', 'pgreact_runtime', proxy_name);
    action_qualified text;
    has_context boolean;
    argument_declarations text;
    argument_types text;
    invocation text;
    proxy regprocedure;
BEGIN
    SELECT format('%I.%I', namespace.nspname, procedure.proname),
           procedure.proargtypes[0] = 'pgreact.activation_context'::regtype
    INTO STRICT action_qualified, has_context
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE procedure.oid = action;
    IF event_kind = 'CHANGE' AND has_context THEN
        argument_declarations := format(
            'context pgreact.activation_context, old_row %s, new_row %s',
            wrapper_condition, wrapper_condition);
        argument_types := format('pgreact.activation_context,%s,%s', wrapper_condition, wrapper_condition);
        invocation := format(
            '%s($1, jsonb_populate_record(NULL::%s, to_jsonb($2)), jsonb_populate_record(NULL::%s, to_jsonb($3)))',
            action_qualified, public_condition, public_condition);
    ELSIF event_kind = 'CHANGE' THEN
        argument_declarations := format('old_row %s, new_row %s', wrapper_condition, wrapper_condition);
        argument_types := format('%s,%s', wrapper_condition, wrapper_condition);
        invocation := format(
            '%s(jsonb_populate_record(NULL::%s, to_jsonb($1)), jsonb_populate_record(NULL::%s, to_jsonb($2)))',
            action_qualified, public_condition, public_condition);
    ELSIF has_context THEN
        argument_declarations := format('context pgreact.activation_context, row_value %s', wrapper_condition);
        argument_types := format('pgreact.activation_context,%s', wrapper_condition);
        invocation := format(
            '%s($1, jsonb_populate_record(NULL::%s, to_jsonb($2)))',
            action_qualified, public_condition);
    ELSE
        argument_declarations := format('row_value %s', wrapper_condition);
        argument_types := wrapper_condition::text;
        invocation := format(
            '%s(jsonb_populate_record(NULL::%s, to_jsonb($1)))',
            action_qualified, public_condition);
    END IF;
    EXECUTE format(
        'CREATE FUNCTION %s(%s) RETURNS void LANGUAGE SQL SECURITY DEFINER '
        'SET search_path = pg_catalog, pg_temp AS $proxy$ SELECT %s $proxy$',
        proxy_qualified, argument_declarations, invocation);
    EXECUTE format('ALTER FUNCTION %s(%s) OWNER TO %I',
                   proxy_qualified, argument_types, session_user);
    proxy := to_regprocedure(format('%s(%s)', proxy_qualified, argument_types));
    INSERT INTO pgreact_internal.action_proxies VALUES (proxy, action);
    RETURN proxy;
END
$$;

CREATE FUNCTION pgreact_internal.author_keyed_rule(
    rule_name text,
    condition regclass,
    key_columns name[],
    action_schema name,
    on_activate name,
    on_deactivate name DEFAULT NULL,
    on_change name DEFAULT NULL,
    deadline_column name DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    wrapper regclass;
    version_id uuid;
    action_event text;
    selected_action name;
    action regprocedure;
    proxy regprocedure;
    key_types regtype[];
    key_collations regcollation[];
BEGIN
    PERFORM pgreact_internal.assert_key_columns(condition, key_columns);
    IF on_activate IS NULL THEN
        RAISE EXCEPTION 'M15_ACTION_REQUIRED: on_activate must name an action';
    END IF;
    SELECT array_agg(attribute.atttypid::regtype ORDER BY key.ordinality),
           array_agg(attribute.attcollation::regcollation ORDER BY key.ordinality)
    INTO key_types, key_collations
    FROM unnest(key_columns) WITH ORDINALITY key(key_column, ordinality)
    JOIN pg_attribute attribute
      ON attribute.attrelid = condition AND attribute.attname = key.key_column
     AND attribute.attnum > 0 AND NOT attribute.attisdropped;
    wrapper := pgreact_internal.create_key_wrapper(condition, key_columns);
    IF deadline_column IS NULL THEN
        version_id := pgreact.create_rule(
            rule_name, wrapper, ARRAY['__pgreact_key'::name], 'COMMAND',
            NULL, NULL, NULL, 'SEED_CURRENT', NULL, 0, 'default', NULL,
            3, 1, 2, 60);
    ELSE
        version_id := pgreact.create_deadline_rule(
            rule_name, wrapper, ARRAY['__pgreact_key'::name], deadline_column,
            'COMMAND', NULL, NULL, NULL, 'SEED_CURRENT', NULL, 0, 'default', NULL,
            3, 1, 2, 60);
    END IF;
    INSERT INTO pgreact_internal.keyed_rule_versions VALUES (
        version_id, condition, wrapper, key_columns, key_types, key_collations);
    FOR action_event, selected_action IN
        SELECT * FROM (VALUES
            ('ACTIVATE'::text, on_activate),
            ('DEACTIVATE'::text, on_deactivate),
            ('CHANGE'::text, on_change)) actions(selected_event, selected_name)
        WHERE selected_name IS NOT NULL
    LOOP
        action := pgreact_internal.resolve_action(
            action_schema, selected_action, condition, action_event);
        proxy := pgreact_internal.create_action_proxy(
            version_id, action_event, action, condition, wrapper);
        PERFORM pgreact_internal.add_resolved_binding(version_id, action_event, proxy);
        UPDATE pgreact_internal.consequence_bindings
        SET max_attempts = 3
        WHERE rule_version_id = version_id
          AND consequence_bindings.event_kind = action_event;
    END LOOP;
    RETURN version_id;
END
$$;

CREATE FUNCTION pgreact_api.validate_rule(
    condition regclass,
    semantic_keys name[],
    action_schema name,
    on_activate name,
    on_deactivate name DEFAULT NULL,
    on_change name DEFAULT NULL
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_key_columns(condition, semantic_keys);
    PERFORM pgreact_internal.resolve_action(action_schema, on_activate, condition, 'ACTIVATE');
    IF on_deactivate IS NOT NULL THEN
        PERFORM pgreact_internal.resolve_action(action_schema, on_deactivate, condition, 'DEACTIVATE');
    END IF;
    IF on_change IS NOT NULL THEN
        PERFORM pgreact_internal.resolve_action(action_schema, on_change, condition, 'CHANGE');
    END IF;
    RETURN QUERY SELECT 5, 'OK', 'INFO', condition::text,
        'typed semantic key and actions are valid',
        'Call author_rule with the same ordered key columns.',
        jsonb_build_object('key_columns', semantic_keys);
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 5, split_part(SQLERRM, ':', 1), 'ERROR', condition::text,
        SQLERRM, 'Correct the named key or action and validate again.', '{}'::jsonb;
END
$$;

CREATE FUNCTION pgreact_api.author_rule(
    rule_name text,
    condition regclass,
    semantic_keys name[],
    action_schema name,
    on_activate name
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.author_keyed_rule($1, $2, $3, $4, $5)
$$;

CREATE FUNCTION pgreact_api.author_rule(
    rule_name text,
    condition regclass,
    semantic_keys name[],
    action_schema name,
    on_activate name,
    on_deactivate name,
    on_change name
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.author_keyed_rule($1, $2, $3, $4, $5, $6, $7)
$$;

CREATE FUNCTION pgreact_api.author_deadline_rule(
    rule_name text,
    condition regclass,
    semantic_keys name[],
    deadline_column name,
    action_schema name,
    on_activate name
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.author_keyed_rule($1, $2, $3, $5, $6, NULL, NULL, $4)
$$;

CREATE FUNCTION pgreact_api.author_deadline_rule(
    rule_name text,
    condition regclass,
    semantic_keys name[],
    deadline_column name,
    action_schema name,
    on_activate name,
    on_deactivate name,
    on_change name
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.author_keyed_rule($1, $2, $3, $5, $6, $7, $8, $4)
$$;

CREATE FUNCTION pgreact_internal.replace_keyed_rule(
    rule_name text,
    condition regclass,
    key_columns name[],
    action_schema name,
    on_activate name,
    on_deactivate name DEFAULT NULL,
    on_change name DEFAULT NULL,
    deadline_column name DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    prior_version uuid;
    wrapper regclass;
    next_version uuid;
    event_kind text;
    selected_action name;
    action regprocedure;
    activate_proxy regprocedure;
    deactivate_proxy regprocedure;
    change_proxy regprocedure;
    key_types regtype[];
    key_collations regcollation[];
BEGIN
    PERFORM pgreact_internal.assert_key_columns(condition, key_columns);
    SELECT version.rule_version_id INTO prior_version
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = replace_keyed_rule.rule_name
      AND version.state IN ('ACTIVE', 'PAUSED')
    ORDER BY version.created_at DESC LIMIT 1;
    IF prior_version IS NULL THEN
        RAISE EXCEPTION 'M15_RULE_NOT_FOUND: %', rule_name;
    END IF;
    wrapper := pgreact_internal.create_key_wrapper(condition, key_columns);
    FOR event_kind, selected_action IN
        SELECT * FROM (VALUES
            ('ACTIVATE'::text, on_activate),
            ('DEACTIVATE'::text, on_deactivate),
            ('CHANGE'::text, on_change)) actions(selected_event, selected_name)
        WHERE selected_name IS NOT NULL
    LOOP
        action := pgreact_internal.resolve_action(
            action_schema, selected_action, condition, event_kind);
        action := pgreact_internal.create_action_proxy(
            prior_version, event_kind, action, condition, wrapper);
        CASE event_kind
            WHEN 'ACTIVATE' THEN activate_proxy := action;
            WHEN 'DEACTIVATE' THEN deactivate_proxy := action;
            WHEN 'CHANGE' THEN change_proxy := action;
        END CASE;
    END LOOP;
    next_version := pgreact.replace_rule(
        prior_version, wrapper, ARRAY['__pgreact_key'::name], NULL,
        'SEED_CURRENT', NULL, NULL, 'DRAIN_OLD');
    IF activate_proxy IS NOT NULL THEN
        PERFORM pgreact_internal.add_resolved_binding(
            next_version, 'ACTIVATE', activate_proxy);
    END IF;
    IF deactivate_proxy IS NOT NULL THEN
        PERFORM pgreact_internal.add_resolved_binding(
            next_version, 'DEACTIVATE', deactivate_proxy);
    END IF;
    IF change_proxy IS NOT NULL THEN
        PERFORM pgreact_internal.add_resolved_binding(
            next_version, 'CHANGE', change_proxy);
    END IF;
    IF deadline_column IS NOT NULL THEN
        next_version := pgreact_internal.mark_deadline_rule(
            next_version, deadline_column, 'SEED_CURRENT');
    END IF;
    UPDATE pgreact_internal.consequence_bindings
    SET max_attempts = 3
    WHERE rule_version_id = next_version;
    SELECT array_agg(attribute.atttypid::regtype ORDER BY key.ordinality),
           array_agg(attribute.attcollation::regcollation ORDER BY key.ordinality)
    INTO key_types, key_collations
    FROM unnest(key_columns) WITH ORDINALITY key(key_column, ordinality)
    JOIN pg_attribute attribute
      ON attribute.attrelid = condition AND attribute.attname = key.key_column
     AND attribute.attnum > 0 AND NOT attribute.attisdropped;
    INSERT INTO pgreact_internal.keyed_rule_versions VALUES (
        next_version, condition, wrapper, key_columns, key_types, key_collations);
    RETURN next_version;
END
$$;

CREATE FUNCTION pgreact_api.replace_rule(
    rule_name text,
    condition regclass,
    semantic_keys name[],
    action_schema name,
    on_activate name,
    on_deactivate name DEFAULT NULL,
    on_change name DEFAULT NULL
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.replace_keyed_rule($1, $2, $3, $4, $5, $6, $7)
$$;

CREATE FUNCTION pgreact_api.replace_deadline_rule(
    rule_name text,
    condition regclass,
    semantic_keys name[],
    deadline_column name,
    action_schema name,
    on_activate name,
    on_deactivate name DEFAULT NULL,
    on_change name DEFAULT NULL
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact_internal.replace_keyed_rule($1, $2, $3, $5, $6, $7, $8, $4)
$$;

CREATE TABLE pgreact_internal.keyed_derived_relations (
    relation_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.derived_relation_versions,
    public_name text NOT NULL UNIQUE,
    internal_name text NOT NULL UNIQUE,
    public_row_type regtype NOT NULL,
    internal_row_type regtype NOT NULL,
    key_columns name[] NOT NULL CHECK (cardinality(key_columns) BETWEEN 1 AND 4),
    key_types regtype[] NOT NULL,
    key_collations regcollation[] NOT NULL
);

CREATE FUNCTION pgreact_api.declare_derived_relation(
    relation_name text,
    row_type regtype,
    semantic_keys name[],
    relation_version integer DEFAULT 1
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    identity_parts text[] := parse_ident(relation_name, true);
    public_schema name;
    public_relation name;
    type_relation oid;
    type_owner oid;
    attribute record;
    key_column name;
    key_types regtype[] := ARRAY[]::regtype[];
    key_collations regcollation[] := ARRAY[]::regcollation[];
    attribute_definitions text[] := ARRAY[]::text[];
    public_columns text[] := ARRAY[]::text[];
    internal_suffix text := md5(relation_name || ':' || relation_version::text);
    internal_type_name name;
    internal_relation_name name;
    internal_type regtype;
    created_version uuid;
BEGIN
    IF cardinality(identity_parts) <> 2 THEN
        RAISE EXCEPTION 'M15_RELATION_NAME: derived relation names must be schema-qualified';
    END IF;
    public_schema := identity_parts[1];
    public_relation := identity_parts[2];
    IF NOT has_schema_privilege(session_user, public_schema, 'CREATE') THEN
        RAISE EXCEPTION 'M15_RELATION_SCHEMA: % cannot create in schema %', session_user, public_schema;
    END IF;
    SELECT type.typrelid, type.typowner INTO STRICT type_relation, type_owner
    FROM pg_type type WHERE type.oid = row_type;
    IF type_relation = 0 OR type_owner <> (SELECT oid FROM pg_roles WHERE rolname = session_user) THEN
        RAISE EXCEPTION 'M15_RELATION_TYPE: the author must own composite row type %', row_type;
    END IF;
    IF cardinality(semantic_keys) NOT BETWEEN 1 AND 4
       OR array_position(semantic_keys, NULL) IS NOT NULL
       OR (SELECT count(DISTINCT key) FROM unnest(semantic_keys) key)
          <> cardinality(semantic_keys) THEN
        RAISE EXCEPTION 'M15_KEY_ARITY: semantic keys require one to four distinct named attributes';
    END IF;
    FOR attribute IN
        SELECT value.attname, value.atttypid, value.atttypmod, value.attcollation,
               attribute_collation.collname, attribute_collation.collisdeterministic
        FROM pg_attribute value
        LEFT JOIN pg_collation attribute_collation
          ON attribute_collation.oid = value.attcollation
        WHERE value.attrelid = type_relation AND value.attnum > 0 AND NOT value.attisdropped
        ORDER BY value.attnum
    LOOP
        attribute_definitions := attribute_definitions || format(
            '%I %s%s', attribute.attname,
            format_type(attribute.atttypid, attribute.atttypmod),
            CASE WHEN attribute.attcollation = 0 THEN ''
                 ELSE format(' COLLATE %I', attribute.collname) END);
        public_columns := public_columns || format('%I', attribute.attname);
    END LOOP;
    FOREACH key_column IN ARRAY semantic_keys LOOP
        SELECT value.atttypid::regtype, value.attcollation::regcollation,
               key_collation.collname, key_collation.collisdeterministic,
               current_database_row.datcollate
        INTO STRICT attribute
        FROM pg_attribute value
        LEFT JOIN pg_collation key_collation ON key_collation.oid = value.attcollation
        CROSS JOIN pg_database current_database_row
        WHERE value.attrelid = type_relation AND value.attname = key_column
          AND value.attnum > 0 AND NOT value.attisdropped
          AND current_database_row.datname = current_database();
        IF attribute.atttypid NOT IN ('bigint'::regtype, 'uuid'::regtype, 'text'::regtype) THEN
            RAISE EXCEPTION 'M15_KEY_TYPE: %.% has unsupported type %',
                row_type, key_column, attribute.atttypid;
        END IF;
        IF attribute.atttypid = 'text'::regtype
           AND (NOT attribute.collisdeterministic
                OR (attribute.collname <> 'C'
                    AND NOT (attribute.collname = 'default'
                             AND attribute.datcollate IN ('C', 'C.UTF-8', 'C.utf8')))) THEN
            RAISE EXCEPTION 'M15_KEY_COLLATION: %.% requires deterministic C collation',
                row_type, key_column;
        END IF;
        key_types := key_types || attribute.atttypid;
        key_collations := key_collations || attribute.attcollation;
    END LOOP;
    internal_type_name := ('m15_type_' || internal_suffix)::name;
    internal_relation_name := ('m15_relation_' || internal_suffix)::name;
    EXECUTE format(
        'CREATE TYPE pgreact_runtime.%I AS (%s, __pgreact_canonical bytea, '
        '__pgreact_key bigint, __pgreact_public_key jsonb)',
        internal_type_name, array_to_string(attribute_definitions, ', '));
    EXECUTE format('ALTER TYPE pgreact_runtime.%I OWNER TO %I',
                   internal_type_name, session_user);
    EXECUTE format('GRANT USAGE ON SCHEMA pgreact_runtime TO %I', session_user);
    internal_type := format('pgreact_runtime.%I', internal_type_name)::regtype;
    EXECUTE format('GRANT CREATE ON SCHEMA pgreact_runtime TO %I', session_user);
    created_version := pgreact.create_derived_relation(
        format('pgreact_runtime.%I', internal_relation_name), internal_type,
        ARRAY['__pgreact_key'::name], relation_version);
    EXECUTE format('REVOKE CREATE ON SCHEMA pgreact_runtime FROM %I', session_user);
    EXECUTE format(
        'CREATE VIEW %I.%I AS SELECT %s FROM pgreact_runtime.%I',
        public_schema, public_relation, array_to_string(public_columns, ', '),
        internal_relation_name);
    EXECUTE format('GRANT SELECT ON %I.%I TO %I WITH GRANT OPTION',
                   public_schema, public_relation, session_user);
    INSERT INTO pgreact_internal.keyed_derived_relations VALUES (
        created_version, format('%I.%I', public_schema, public_relation),
        format('pgreact_runtime.%I', internal_relation_name), row_type, internal_type,
        semantic_keys, key_types, key_collations);
    RETURN created_version;
END
$$;

CREATE FUNCTION pgreact_internal.normalize_program(definition jsonb)
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
        wrapper := pgreact_internal.create_key_wrapper(source, derived.key_columns);
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
            wrapper := pgreact_internal.create_key_wrapper(source, derived.key_columns);
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
            wrapper := pgreact_internal.create_key_wrapper(source, derived.key_columns);
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

ALTER FUNCTION pgreact_api.validate_program(jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.validate_program(jsonb) RENAME TO validate_program_m14;
ALTER FUNCTION pgreact_api.preview_program(jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.preview_program(jsonb) RENAME TO preview_program_m14;
ALTER FUNCTION pgreact_api.deploy_program(jsonb, text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.deploy_program(jsonb, text) RENAME TO deploy_program_m14;

CREATE FUNCTION pgreact_api.validate_program(definition jsonb)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE normalized jsonb;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(definition -> 'rules') rule
        JOIN pgreact_internal.keyed_derived_relations relation_spec
          ON relation_spec.public_name = rule ->> 'target') THEN
        RETURN QUERY SELECT * FROM pgreact_internal.validate_program_m14(definition);
        RETURN;
    END IF;
    normalized := pgreact_internal.normalize_program(definition);
    RETURN QUERY
    SELECT 5, diagnostic.code, diagnostic.severity, diagnostic.object_identity,
           diagnostic.message, diagnostic.hint,
           diagnostic.details || jsonb_build_object('normalized_definition', normalized)
    FROM pgreact.validate_derivation_program(normalized) diagnostic;
END
$$;

CREATE FUNCTION pgreact_api.preview_program(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    normalized jsonb;
    inferred jsonb;
    diagnostic record;
    plan text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(definition -> 'rules') rule
        JOIN pgreact_internal.keyed_derived_relations relation_spec
          ON relation_spec.public_name = rule ->> 'target') THEN
        RETURN pgreact_internal.preview_program_m14(definition);
    END IF;
    normalized := pgreact_internal.normalize_program(definition);
    SELECT * INTO diagnostic FROM pgreact.validate_derivation_program(normalized)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M15_PROGRAM_INVALID: % for %', diagnostic.code, diagnostic.object_identity
            USING HINT = diagnostic.hint;
    END IF;
    inferred := pgreact_api.infer_program(definition);
    plan := encode(sha256(convert_to(normalized::text || ':' || session_user, 'UTF8')), 'hex');
    RETURN jsonb_build_object(
        'contract_version', 5, 'program', inferred, 'plan_digest', plan);
END
$$;

CREATE FUNCTION pgreact_api.deploy_program(definition jsonb, expected_plan_digest text)
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
    normalized := pgreact_internal.normalize_program(definition);
    actual_plan_digest := encode(
        sha256(convert_to(normalized::text || ':' || session_user, 'UTF8')), 'hex');
    IF expected_plan_digest IS NOT NULL AND expected_plan_digest <> actual_plan_digest THEN
        RAISE EXCEPTION 'M15_PROGRAM_PREVIEW_STALE'
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
            SELECT 1 FROM pgreact_internal.application_roles application_role
            WHERE application_role.role_kind = 'operator'
              AND pg_catalog.pg_has_role(session_user, application_role.role_oid, 'member'))
        OR EXISTS (
            SELECT 1 FROM pgreact_internal.managed_processes process
            WHERE process.database_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
              AND process.backend_pid = pg_backend_pid())
$$;

CREATE FUNCTION pgreact_internal.sync_semantic_keys()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    keyed record;
    identity record;
    existing bytea;
BEGIN
    FOR keyed IN
        SELECT spec.*
        FROM pgreact_internal.keyed_rule_versions spec
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE version.state = 'ACTIVE'
        ORDER BY spec.public_condition::regclass::text, spec.rule_version_id
    LOOP
        FOR identity IN EXECUTE format(
            'SELECT __pgreact_key AS semantic_key, __pgreact_canonical AS canonical_key, '
            '__pgreact_public_key AS public_key, count(*) OVER (PARTITION BY __pgreact_key) AS occurrences '
            'FROM %s', keyed.wrapper_condition::regclass)
        LOOP
            IF identity.semantic_key IS NULL OR identity.canonical_key IS NULL
               OR identity.public_key IS NULL THEN
                RAISE EXCEPTION 'M15_KEY_NULL: every semantic key component in % must be non-null',
                    keyed.public_condition::regclass;
            END IF;
            IF identity.occurrences <> 1 THEN
                RAISE EXCEPTION 'M15_KEY_DUPLICATE: key % occurs % times in %',
                    identity.public_key, identity.occurrences, keyed.public_condition::regclass;
            END IF;
            SELECT canonical_key INTO existing
            FROM pgreact_internal.semantic_key_identities
            WHERE rule_version_id = keyed.rule_version_id
              AND semantic_key = identity.semantic_key;
            IF existing IS NOT NULL AND existing <> identity.canonical_key THEN
                RAISE EXCEPTION 'M15_KEY_COLLISION: distinct typed keys share one internal identity in %',
                    keyed.public_condition::regclass
                    USING HINT = 'Change a key component or report the SHA-256 prefix collision.';
            END IF;
            INSERT INTO pgreact_internal.semantic_key_identities (
                rule_version_id, semantic_key, canonical_key, public_key)
            VALUES (
                keyed.rule_version_id, identity.semantic_key,
                identity.canonical_key, identity.public_key)
            ON CONFLICT (rule_version_id, semantic_key) DO UPDATE
            SET public_key = EXCLUDED.public_key, last_seen_at = clock_timestamp();
        END LOOP;
    END LOOP;
END
$$;

ALTER FUNCTION pgreact_api.run(timestamptz) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.run(timestamptz) RENAME TO run_m14;

CREATE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb;
BEGIN
    PERFORM pgreact_internal.sync_semantic_keys();
    result := pgreact_internal.run_m14(sampled_time);
    RETURN jsonb_set(result, '{contract_version}', '5'::jsonb);
END
$$;

CREATE FUNCTION pgreact_internal.managed_cycle(process_pid integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    worker text := format('pg-react-managed/%s/%s', current_database(), process_pid);
    batch_limit integer := current_setting('pg_react.batch_size')::integer;
    pending_limit integer := current_setting('pg_react.max_pending_jobs')::integer;
    pending bigint;
    processed bigint := 0;
    claimed record;
    runtime_state text := 'ready';
    run_result jsonb;
BEGIN
    SELECT count(*) INTO pending
    FROM pgreact_internal.agenda job
    WHERE job.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    INSERT INTO pgreact_internal.managed_processes (
        database_oid, database_name, backend_pid, state, protocol, pending_jobs)
    VALUES ((SELECT oid FROM pg_database WHERE datname = current_database()),
            current_database(), process_pid, 'ready', 2, pending)
    ON CONFLICT (database_oid) DO UPDATE
    SET database_name = EXCLUDED.database_name, backend_pid = EXCLUDED.backend_pid,
        state = EXCLUDED.state, protocol = EXCLUDED.protocol,
        pending_jobs = EXCLUDED.pending_jobs, started_at = CASE
            WHEN pgreact_internal.managed_processes.backend_pid = EXCLUDED.backend_pid
            THEN pgreact_internal.managed_processes.started_at ELSE clock_timestamp() END,
        heartbeat_at = clock_timestamp(), detail = NULL;

    IF pg_is_in_recovery() THEN
        runtime_state := 'standby';
    ELSIF NOT pgreact.worker_protocol_compatible(2) THEN
        runtime_state := 'error';
        UPDATE pgreact_internal.managed_processes
        SET state = runtime_state, detail = 'worker protocol 2 is incompatible',
            heartbeat_at = clock_timestamp()
        WHERE database_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
        RETURN jsonb_build_object('state', runtime_state, 'pending_jobs', pending, 'processed_jobs', 0);
    ELSE
        IF pending >= pending_limit THEN
            runtime_state := 'backpressure';
        ELSE
            run_result := pgreact_api.run();
        END IF;
        FOR claimed IN
            SELECT * FROM pgreact_api.claim(worker, batch_limit, interval '60 seconds')
        LOOP
            PERFORM pgreact_api.execute(claimed.episode_id, worker, claimed.lease_token);
            processed := processed + 1;
        END LOOP;
    END IF;
    SELECT count(*) INTO pending
    FROM pgreact_internal.agenda job
    WHERE job.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    UPDATE pgreact_internal.managed_processes
    SET state = runtime_state, pending_jobs = pending,
        processed_jobs = processed_jobs + processed,
        heartbeat_at = clock_timestamp(), detail = NULL
    WHERE database_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
    RETURN jsonb_build_object(
        'state', runtime_state, 'pending_jobs', pending, 'processed_jobs', processed,
        'run', run_result);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO pgreact_internal.managed_processes (
        database_oid, database_name, backend_pid, state, protocol, detail)
    VALUES ((SELECT oid FROM pg_database WHERE datname = current_database()),
            current_database(), process_pid, 'error', 2, SQLSTATE || ': ' || SQLERRM)
    ON CONFLICT (database_oid) DO UPDATE
    SET backend_pid = EXCLUDED.backend_pid, state = 'error',
        heartbeat_at = clock_timestamp(), detail = EXCLUDED.detail;
    RETURN jsonb_build_object('state', 'error', 'sqlstate', SQLSTATE, 'message', SQLERRM);
END
$$;

CREATE FUNCTION pgreact_api.managed_cycle()
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$ SELECT pgreact_internal.managed_cycle(pg_backend_pid()) $$;

CREATE FUNCTION pgreact_api.managed_status()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 5,
        'database', current_database(),
        'configured', current_database() = ANY (regexp_split_to_array(
            current_setting('pg_react.databases', true), '\\s*,\\s*')),
        'process', CASE WHEN process.database_oid IS NULL THEN NULL ELSE jsonb_build_object(
            'pid', process.backend_pid, 'state', process.state,
            'protocol', process.protocol, 'pending_jobs', process.pending_jobs,
            'processed_jobs', process.processed_jobs,
            'started_at', process.started_at, 'heartbeat_at', process.heartbeat_at,
            'detail', process.detail) END)
    FROM (SELECT 1) singleton
    LEFT JOIN pgreact_internal.managed_processes process
      ON process.database_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
$$;

CREATE FUNCTION pgreact_api.key_codecs()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 5, 'codec_version', 2, 'max_arity', 4,
        'scalar_types', jsonb_build_array('bigint', 'uuid', 'text'),
        'null_components', false, 'component_order', 'declared',
        'text_collation', 'C')
$$;

CREATE OR REPLACE FUNCTION pgreact_api.status(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 5,
        'rules', COALESCE(jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name,
            'condition', COALESCE(spec.public_condition::regclass::text, rule.source_view_name),
            'key', CASE WHEN spec.rule_version_id IS NULL THEN to_jsonb(rule.key_column)
                        WHEN cardinality(spec.key_columns) = 1 THEN to_jsonb(spec.key_columns[1])
                        ELSE to_jsonb(spec.key_columns) END,
            'state', lower(rule.state),
            'actions', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'action', lower(binding.event_kind),
                    'function', COALESCE(proxy.action_oid::regprocedure::text,
                                         binding.function_identity))
                    ORDER BY binding.event_kind)
                FROM pgreact_internal.consequence_bindings binding
                LEFT JOIN pgreact_internal.action_proxies proxy
                  ON proxy.proxy_oid = binding.function_oid
                WHERE binding.rule_version_id = rule.rule_version_id
            ), '[]'::jsonb)) ORDER BY rule.rule_name), '[]'::jsonb))
    FROM pgreact.rules rule
    LEFT JOIN pgreact_internal.keyed_rule_versions spec USING (rule_version_id)
    WHERE $1 IS NULL OR rule.rule_name = $1
$$;

CREATE OR REPLACE FUNCTION pgreact_api.matches(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 5,
        'matches', COALESCE(jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name,
            'key', COALESCE(identity.public_key, to_jsonb(match.semantic_key)),
            'matched_at', match.first_seen_at,
            'observed_at', match.last_seen_at)
            ORDER BY rule.rule_name, COALESCE(identity.public_key, to_jsonb(match.semantic_key))), '[]'::jsonb))
    FROM pgreact_internal.activation_state match
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    JOIN pgreact_internal.rules rule USING (rule_id)
    LEFT JOIN pgreact_internal.semantic_key_identities identity
      ON identity.rule_version_id = match.rule_version_id
     AND identity.semantic_key = match.semantic_key
    WHERE match.active AND ($1 IS NULL OR rule.rule_name = $1)
$$;

CREATE OR REPLACE FUNCTION pgreact_api.jobs(name text DEFAULT NULL)
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
            'idempotency_key', job.idempotency_key) ||
            CASE WHEN spec.rule_version_id IS NULL THEN '{}'::jsonb
                 ELSE jsonb_build_object('key', identity.public_key) END
            ORDER BY job.episode_id), '[]'::jsonb))
    FROM pgreact_internal.agenda job
    JOIN pgreact_internal.rules rule USING (rule_id)
    LEFT JOIN pgreact_internal.keyed_rule_versions spec USING (rule_version_id)
    LEFT JOIN pgreact_internal.activation_state activation
      ON activation.rule_version_id = job.rule_version_id
     AND activation.activation_id = job.activation_id
    LEFT JOIN pgreact_internal.semantic_key_identities identity
      ON identity.rule_version_id = job.rule_version_id
     AND identity.semantic_key = activation.semantic_key
    WHERE $1 IS NULL OR rule.rule_name = $1
$$;

CREATE OR REPLACE FUNCTION pgreact_api.attempts(name text DEFAULT NULL)
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
            'error_message', attempt.error_message) ||
            CASE WHEN spec.rule_version_id IS NULL THEN '{}'::jsonb
                 ELSE jsonb_build_object('key', identity.public_key) END
            ORDER BY attempt.episode_id, attempt.attempt_no), '[]'::jsonb))
    FROM pgreact_internal.executions attempt
    JOIN pgreact_internal.agenda job USING (episode_id)
    JOIN pgreact_internal.rules rule USING (rule_id)
    LEFT JOIN pgreact_internal.keyed_rule_versions spec USING (rule_version_id)
    LEFT JOIN pgreact_internal.activation_state activation
      ON activation.rule_version_id = job.rule_version_id
     AND activation.activation_id = job.activation_id
    LEFT JOIN pgreact_internal.semantic_key_identities identity
      ON identity.rule_version_id = job.rule_version_id
     AND identity.semantic_key = activation.semantic_key
    WHERE $1 IS NULL OR rule.rule_name = $1
$$;

CREATE OR REPLACE FUNCTION pgreact_api.deadline_history(name text)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 2,
        'rule_name', $1,
        'events', COALESCE(jsonb_agg(jsonb_build_object(
            'rule_name', rule.rule_name,
            'semantic_key', COALESCE(identity.public_key, to_jsonb(activation.semantic_key)),
            'generation', event.generation,
            'revision', event.revision,
            'event_kind', event.event_kind,
            'declared_deadline', deadline.declared_deadline,
            'clock_frontier', deadline.observed_frontier)
            ORDER BY event.event_id), '[]'::jsonb))
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.lifecycle_events event USING (rule_version_id)
    JOIN pgreact_internal.deadline_lifecycle deadline USING (event_id)
    JOIN pgreact_internal.activation_state activation
      ON activation.rule_version_id = event.rule_version_id
     AND activation.activation_id = event.activation_id
    LEFT JOIN pgreact_internal.semantic_key_identities identity
      ON identity.rule_version_id = activation.rule_version_id
     AND identity.semantic_key = activation.semantic_key
    WHERE rule.rule_name = $1
$$;

CREATE FUNCTION pgreact_internal.public_json(input_value jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    result jsonb;
    member record;
    item jsonb;
    public_key jsonb;
    public_name text;
BEGIN
    CASE jsonb_typeof(input_value)
    WHEN 'object' THEN
        result := '{}'::jsonb;
        public_key := input_value -> '__pgreact_public_key';
        FOR member IN
            SELECT entry.key, entry.value
            FROM jsonb_each(input_value) entry ORDER BY entry.key
        LOOP
            IF left(member.key, 10) = '__pgreact_' THEN CONTINUE; END IF;
            item := member.value;
            IF member.key IN ('key', 'semantic_key', 'group_key')
               AND jsonb_typeof(item) = 'number' THEN
                IF public_key IS NULL THEN
                    SELECT identity.public_key INTO public_key
                    FROM pgreact_internal.semantic_key_identities identity
                    WHERE identity.semantic_key = (item #>> '{}')::bigint
                    ORDER BY identity.rule_version_id LIMIT 1;
                END IF;
                item := COALESCE(public_key, item);
            END IF;
            result := result || jsonb_build_object(
                member.key, pgreact_internal.public_json(item));
        END LOOP;
        RETURN result;
    WHEN 'array' THEN
        SELECT COALESCE(jsonb_agg(pgreact_internal.public_json(element) ORDER BY ordinal), '[]'::jsonb)
        INTO result
        FROM jsonb_array_elements(input_value) WITH ORDINALITY item(element, ordinal);
        RETURN result;
    WHEN 'string' THEN
        SELECT spec.public_name || substring(input_value #>> '{}'
            FROM length(spec.internal_name) + 1) INTO public_name
        FROM pgreact_internal.keyed_derived_relations spec
        WHERE input_value #>> '{}' = spec.internal_name
           OR input_value #>> '{}' LIKE spec.internal_name || '@%';
        IF public_name IS NULL THEN
            SELECT wrapper.public_condition::regclass::text INTO public_name
            FROM pgreact_internal.key_wrappers wrapper
            WHERE wrapper.wrapper_condition::regclass::text = input_value #>> '{}';
        END IF;
        RETURN COALESCE(to_jsonb(public_name), input_value);
    ELSE
        RETURN input_value;
    END CASE;
END
$$;

CREATE FUNCTION pgreact_api.explain(target text, semantic_key jsonb)
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
            RETURN jsonb_build_object(
                'contract_version', 5,
                'target', jsonb_build_object('kind', 'fact', 'name', target, 'key', semantic_key),
                'evidence', NULL);
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
            'target', jsonb_build_object('kind', 'match', 'rule', target, 'key', semantic_key),
            'evidence', NULL);
    END IF;
    RETURN pgreact_internal.public_json(jsonb_set(
        pgreact_api.explain(target, activation), '{contract_version}', '5'::jsonb)
        || jsonb_build_object(
            'target', jsonb_build_object('kind', 'match', 'rule', target, 'key', semantic_key)));
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
            'code', 'M15_EXTENSION_VERSION', 'severity', 'ERROR', 'object_identity', 'pg_react',
            'message', 'pg_react extension version is not 0.12.0',
            'hint', 'Install matching files and run ALTER EXTENSION pg_react UPDATE.')
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.12.0')
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

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
RENAME TO configure_roles_m14;

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
    PERFORM pgreact_internal.configure_roles_m14(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT USAGE ON SCHEMA pgtrickle TO %I', author_role::text);
    EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA pgtrickle TO %I',
                   author_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.managed_status() TO %I, %I',
        operator_role::text, reader_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.key_codecs(), '
        'pgreact_api.explain(text,jsonb) TO %I, %I',
        operator_role::text, reader_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.managed_cycle() TO %I',
        worker_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.validate_rule(regclass,name[],name,name,name,name), '
        'pgreact_api.author_rule(text,regclass,name[],name,name), '
        'pgreact_api.author_rule(text,regclass,name[],name,name,name,name), '
        'pgreact_api.author_deadline_rule(text,regclass,name[],name,name,name), '
        'pgreact_api.author_deadline_rule(text,regclass,name[],name,name,name,name,name), '
        'pgreact_api.replace_rule(text,regclass,name[],name,name,name,name), '
        'pgreact_api.replace_deadline_rule(text,regclass,name[],name,name,name,name,name), '
        'pgreact_api.declare_derived_relation(text,regtype,name[],integer) TO %I',
        author_role::text);
END
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
    'M15 PostgreSQL-managed runtime, typed semantic keys, and qualified public workflow';
