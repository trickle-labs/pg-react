-- M5 safe rule-set deployment. Worker protocol and lifecycle semantics stay at v1.

CREATE TABLE pgreact_internal.rule_packs (
    pack_id uuid PRIMARY KEY,
    pack_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.rule_pack_versions (
    pack_version_id uuid PRIMARY KEY,
    pack_id uuid NOT NULL REFERENCES pgreact_internal.rule_packs,
    version text NOT NULL,
    definition jsonb NOT NULL,
    mappings jsonb NOT NULL,
    definition_digest bytea NOT NULL,
    plan_digest text NOT NULL,
    state text NOT NULL CHECK (state IN ('STAGED', 'ACTIVE', 'SUPERSEDED')),
    deployed_by name NOT NULL,
    deployed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (pack_id, version)
);

CREATE UNIQUE INDEX rule_pack_one_active_version
    ON pgreact_internal.rule_pack_versions (pack_id) WHERE state = 'ACTIVE';

CREATE TABLE pgreact_internal.rule_pack_members (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    rule_name text NOT NULL,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    dependencies text[] NOT NULL,
    PRIMARY KEY (pack_version_id, rule_name)
);

CREATE TABLE pgreact_internal.rule_pack_actions (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    action_order integer NOT NULL CHECK (action_order > 0),
    action text NOT NULL CHECK (action IN ('ADD', 'REPLACE', 'REMOVE')),
    rule_name text NOT NULL,
    old_rule_version_id uuid REFERENCES pgreact_internal.rule_versions,
    new_rule_version_id uuid REFERENCES pgreact_internal.rule_versions,
    old_work_policy text NOT NULL CHECK (old_work_policy IN ('DRAIN_OLD', 'CANCEL_OLD')),
    details jsonb NOT NULL,
    PRIMARY KEY (pack_version_id, action_order)
);

CREATE FUNCTION pgreact_internal.pack_mapping(mappings jsonb, category text, logical_identity text)
RETURNS text
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
    SELECT COALESCE($1 -> $2 ->> $3, $3)
$$;

CREATE FUNCTION pgreact.validate_pack(definition jsonb, mappings jsonb DEFAULT '{}'::jsonb)
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
    has_error boolean := false;
    pack_name text;
    pack_version text;
    logical_owner text;
    mapped_owner text;
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    owner_oid oid;
    pack_row record;
    active_pack_version uuid;
    unknown_key text;
    duplicate_name text;
    cycle_name text;
    rule_item record;
    rule_definition jsonb;
    rule_name text;
    logical_source text;
    mapped_source text;
    source_oid oid;
    source_type oid;
    key_name name;
    rule_kind text;
    policy text;
    diagnostic record;
    consequence record;
    logical_function text;
    mapped_function text;
    function_oid oid;
    function_row record;
    column_item jsonb;
    dependency_item jsonb;
    dependency_name text;
    dependency_order bigint;
    outbox_item record;
    removal_item record;
BEGIN
    IF pg_catalog.jsonb_typeof(definition) IS DISTINCT FROM 'object' THEN
        RETURN QUERY SELECT 1, 'PACK_NOT_OBJECT', 'ERROR', '<pack>',
            'pack definition must be a JSON object',
            'Pass one format-versioned pack object.', '{}'::jsonb;
        RETURN;
    END IF;
    IF pg_catalog.jsonb_typeof(mappings) IS DISTINCT FROM 'object'
       OR (mappings ? 'objects' AND pg_catalog.jsonb_typeof(mappings -> 'objects') <> 'object')
       OR (mappings ? 'roles' AND pg_catalog.jsonb_typeof(mappings -> 'roles') <> 'object') THEN
        RETURN QUERY SELECT 1, 'MAPPINGS_NOT_OBJECTS', 'ERROR', '<mappings>',
            'mappings must contain only objects and roles JSON objects',
            'Map logical identities to qualified names, never OIDs.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT key INTO unknown_key
    FROM pg_catalog.jsonb_object_keys(definition) AS key
    WHERE key <> ALL (ARRAY['format_version', 'pack', 'version', 'owner', 'rules', 'remove'])
    ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'pack definition contains an unknown field',
            'Remove the field or use a newer supported format_version.', '{}'::jsonb;
    END IF;
    SELECT key INTO unknown_key
    FROM pg_catalog.jsonb_object_keys(mappings) AS key
    WHERE key <> ALL (ARRAY['objects', 'roles'])
    ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'MAPPING_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'mapping definition contains an unknown field',
            'Use only objects and roles maps.', '{}'::jsonb;
    END IF;
    IF definition -> 'format_version' IS DISTINCT FROM '1'::jsonb THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_FORMAT_UNSUPPORTED', 'ERROR', '<pack>',
            'only rule-pack format_version 1 is supported',
            'Set format_version to 1.', jsonb_build_object('received', definition -> 'format_version');
    END IF;
    IF pg_catalog.jsonb_typeof(definition -> 'pack') IS DISTINCT FROM 'string'
       OR definition ->> 'pack' = ''
       OR pg_catalog.jsonb_typeof(definition -> 'version') IS DISTINCT FROM 'string'
       OR definition ->> 'version' = ''
       OR pg_catalog.jsonb_typeof(definition -> 'owner') IS DISTINCT FROM 'string'
       OR definition ->> 'owner' = '' THEN
        RETURN QUERY SELECT 1, 'PACK_IDENTITY_INVALID', 'ERROR', '<pack>',
            'pack, version, and owner must be non-empty strings',
            'Use portable logical names and map them per environment.', '{}'::jsonb;
        RETURN;
    END IF;
    IF pg_catalog.jsonb_typeof(definition -> 'rules') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'remove') IS DISTINCT FROM 'array' THEN
        RETURN QUERY SELECT 1, 'PACK_COLLECTION_INVALID', 'ERROR', '<pack>',
            'rules and remove must be JSON arrays',
            'Use an empty array when no rules are added or removed.', '{}'::jsonb;
        RETURN;
    END IF;

    pack_name := definition ->> 'pack';
    pack_version := definition ->> 'version';
    logical_owner := definition ->> 'owner';
    mapped_owner := pgreact_internal.pack_mapping(mappings, 'roles', logical_owner);
    SELECT oid INTO owner_oid FROM pg_catalog.pg_roles WHERE rolname = mapped_owner;
    IF owner_oid IS NULL OR owner_oid <> caller_oid THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_OWNER_UNSAFE', 'ERROR', logical_owner,
            'mapped pack owner must be the session user',
            'Run deployment as the mapped owner; role mapping never bypasses ownership.',
            jsonb_build_object('mapped_owner', mapped_owner, 'session_user', session_user);
    END IF;

    SELECT p.pack_id, p.owner_oid INTO pack_row
    FROM pgreact_internal.rule_packs p WHERE p.pack_name = pack_name;
    IF FOUND AND pack_row.owner_oid <> caller_oid THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_NAME_OWNED', 'ERROR', pack_name,
            'another owner already uses this pack name',
            'Choose a different pack name or deploy as its owner.', '{}'::jsonb;
    ELSIF FOUND THEN
        SELECT v.pack_version_id INTO active_pack_version
        FROM pgreact_internal.rule_pack_versions v
        WHERE v.pack_id = pack_row.pack_id AND v.state = 'ACTIVE';
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.rule_pack_versions v
            WHERE v.pack_id = pack_row.pack_id AND v.version = pack_version
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'PACK_VERSION_EXISTS', 'ERROR', pack_version,
                'pack version was already deployed',
                'Use a new immutable version string.', '{}'::jsonb;
        END IF;
    END IF;

    SELECT value ->> 'name' INTO duplicate_name
    FROM pg_catalog.jsonb_array_elements(definition -> 'rules') AS r(value)
    GROUP BY value ->> 'name' HAVING count(*) > 1
    ORDER BY value ->> 'name' LIMIT 1;
    IF duplicate_name IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'RULE_NAME_DUPLICATE', 'ERROR', duplicate_name,
            'rule names must be unique within a pack version',
            'Keep one complete definition for each rule name.', '{}'::jsonb;
    END IF;
    SELECT value ->> 'name' INTO duplicate_name
    FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    GROUP BY value ->> 'name' HAVING count(*) > 1
    ORDER BY value ->> 'name' LIMIT 1;
    IF duplicate_name IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'REMOVAL_DUPLICATE', 'ERROR', duplicate_name,
            'removal names must be unique within a pack version',
            'Keep one explicit removal policy for each rule.', '{}'::jsonb;
    END IF;

    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, ordinal)
    LOOP
        rule_definition := rule_item.value;
        IF pg_catalog.jsonb_typeof(rule_definition) IS DISTINCT FROM 'object' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_NOT_OBJECT', 'ERROR', rule_item.ordinal::text,
                'each rule must be a JSON object', 'Replace the array item with a rule object.', '{}'::jsonb;
            CONTINUE;
        END IF;
        rule_name := rule_definition ->> 'name';
        SELECT key INTO unknown_key
        FROM pg_catalog.jsonb_object_keys(rule_definition) AS key
        WHERE key <> ALL (ARRAY[
            'name', 'definition', 'key', 'kind', 'on_activate', 'on_deactivate',
            'on_change', 'outbox', 'bootstrap_policy', 'change_columns', 'salience',
            'agenda_group', 'conflict_key_columns', 'max_attempts',
            'initial_backoff_seconds', 'backoff_multiplier', 'max_backoff_seconds',
            'old_work_policy', 'depends_on'
        ]) ORDER BY key LIMIT 1;
        IF unknown_key IS NOT NULL THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_FIELD_UNKNOWN', 'ERROR', COALESCE(rule_name, rule_item.ordinal::text),
                'rule definition contains an unknown field',
                'Remove the field or use a newer supported format_version.',
                jsonb_build_object('field', unknown_key);
        END IF;
        IF pg_catalog.jsonb_typeof(rule_definition -> 'name') IS DISTINCT FROM 'string'
           OR rule_name = ''
           OR pg_catalog.jsonb_typeof(rule_definition -> 'definition') IS DISTINCT FROM 'string'
           OR pg_catalog.jsonb_typeof(rule_definition -> 'key') IS DISTINCT FROM 'string'
           OR pg_catalog.jsonb_typeof(rule_definition -> 'kind') IS DISTINCT FROM 'string' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_IDENTITY_INVALID', 'ERROR', COALESCE(rule_name, rule_item.ordinal::text),
                'name, definition, key, and kind must be non-empty strings',
                'Use logical object identities; mappings resolve environment names.', '{}'::jsonb;
            CONTINUE;
        END IF;
        IF EXISTS (
            SELECT 1 FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS x(value)
            WHERE x.value ->> 'name' = rule_name
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_AND_REMOVAL_CONFLICT', 'ERROR', rule_name,
                'a rule cannot be deployed and removed in the same pack version',
                'Keep it in exactly one collection.', '{}'::jsonb;
        END IF;
        rule_kind := rule_definition ->> 'kind';
        IF rule_kind NOT IN ('COMMAND', 'CONSTRAINT') THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_KIND_INVALID', 'ERROR', rule_name,
                'kind must be COMMAND or CONSTRAINT', 'Use an existing v1 rule kind.', '{}'::jsonb;
        END IF;
        policy := COALESCE(rule_definition ->> 'old_work_policy', 'DRAIN_OLD');
        IF policy NOT IN ('DRAIN_OLD', 'CANCEL_OLD') THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'OLD_WORK_POLICY_INVALID', 'ERROR', rule_name,
                'old_work_policy must be DRAIN_OLD or CANCEL_OLD',
                'Choose how pending and retrying work from the prior immutable version is handled.', '{}'::jsonb;
        END IF;
        IF rule_definition ? 'depends_on'
           AND pg_catalog.jsonb_typeof(rule_definition -> 'depends_on') <> 'array' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'DEPENDENCIES_NOT_ARRAY', 'ERROR', rule_name,
                'depends_on must be an array of earlier rule names',
                'Use deployment-order dependencies only.', '{}'::jsonb;
        ELSE
            FOR dependency_item IN
                SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(rule_definition -> 'depends_on', '[]'::jsonb)) AS d(value)
            LOOP
                IF pg_catalog.jsonb_typeof(dependency_item) <> 'string' THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'DEPENDENCY_INVALID', 'ERROR', rule_name,
                        'dependencies must be rule-name strings',
                        'Reference a rule in the same pack version.', jsonb_build_object('dependency', dependency_item);
                    CONTINUE;
                END IF;
                dependency_name := dependency_item #>> '{}';
                SELECT ordinal INTO dependency_order
                FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
                WITH ORDINALITY AS d(value, ordinal)
                WHERE d.value ->> 'name' = dependency_name;
                IF dependency_order IS NULL THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'DEPENDENCY_MISSING', 'ERROR', rule_name,
                        'dependency is not defined in this pack version',
                        'Add the dependency before this rule.', jsonb_build_object('dependency', dependency_name);
                ELSIF dependency_order >= rule_item.ordinal THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'DEPENDENCY_ORDER_INVALID', 'ERROR', rule_name,
                        'dependency must appear before the dependent rule',
                        'Order rules topologically in the manifest.', jsonb_build_object('dependency', dependency_name);
                END IF;
            END LOOP;
        END IF;

        logical_source := rule_definition ->> 'definition';
        mapped_source := pgreact_internal.pack_mapping(mappings, 'objects', logical_source);
        source_oid := pg_catalog.to_regclass(mapped_source);
        IF source_oid IS NULL THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'SOURCE_NOT_FOUND', 'ERROR', logical_source,
                'mapped source view does not exist',
                'Create it in this environment or correct the object mapping.',
                jsonb_build_object('mapped_identity', mapped_source);
            CONTINUE;
        END IF;
        SELECT reltype INTO source_type FROM pg_catalog.pg_class WHERE oid = source_oid;
        key_name := (rule_definition ->> 'key')::name;
        IF EXISTS (SELECT 1 FROM pgreact.validate_rule(source_oid::regclass, ARRAY[key_name], NULL)
                   WHERE severity = 'ERROR') THEN
            has_error := true;
            FOR diagnostic IN
                SELECT * FROM pgreact.validate_rule(source_oid::regclass, ARRAY[key_name], NULL)
                WHERE severity = 'ERROR'
            LOOP
                RETURN QUERY SELECT 1, diagnostic.code, diagnostic.severity, rule_name,
                    diagnostic.message, diagnostic.hint,
                    diagnostic.details || jsonb_build_object('source', logical_source, 'mapped_source', mapped_source);
            END LOOP;
        END IF;

        IF rule_definition ? 'change_columns'
           AND pg_catalog.jsonb_typeof(rule_definition -> 'change_columns') <> 'array'
           OR rule_definition ? 'conflict_key_columns'
           AND pg_catalog.jsonb_typeof(rule_definition -> 'conflict_key_columns') <> 'array' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'COLUMN_LIST_INVALID', 'ERROR', rule_name,
                'change_columns and conflict_key_columns must be arrays',
                'Use projected column-name strings.', '{}'::jsonb;
        ELSE
            FOR column_item IN
                SELECT value FROM pg_catalog.jsonb_array_elements(
                    COALESCE(rule_definition -> 'change_columns', '[]'::jsonb) ||
                    COALESCE(rule_definition -> 'conflict_key_columns', '[]'::jsonb)
                ) AS c(value)
            LOOP
                IF pg_catalog.jsonb_typeof(column_item) <> 'string'
                   OR NOT EXISTS (
                       SELECT 1 FROM pg_catalog.pg_attribute
                       WHERE attrelid = source_oid AND attname = (column_item #>> '{}')::name
                         AND attnum > 0 AND NOT attisdropped
                   ) THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'COLUMN_NOT_PROJECTED', 'ERROR', rule_name,
                        'policy column must be a projected source-view column',
                        'Correct the column name or source view.', jsonb_build_object('column', column_item);
                END IF;
            END LOOP;
        END IF;

        IF rule_definition ? 'outbox' AND pg_catalog.jsonb_typeof(rule_definition -> 'outbox') <> 'object' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'OUTBOX_INVALID', 'ERROR', rule_name,
                'outbox must be an object keyed by lifecycle event',
                'Use ACTIVATE, CHANGE, or DEACTIVATE sink identities.', '{}'::jsonb;
        END IF;
        IF rule_kind = 'CONSTRAINT' AND (
            rule_definition ->> 'on_activate' IS NOT NULL
            OR rule_definition ->> 'on_deactivate' IS NOT NULL
            OR rule_definition ->> 'on_change' IS NOT NULL
            OR COALESCE(rule_definition -> 'outbox', '{}'::jsonb) <> '{}'::jsonb
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'CONSTRAINT_HAS_CONSEQUENCE', 'ERROR', rule_name,
                'constraint rules cannot have consequences',
                'Remove typed and outbox bindings or use kind COMMAND.', '{}'::jsonb;
        END IF;

        FOR consequence IN
            SELECT * FROM (VALUES
                ('ACTIVATE', rule_definition ->> 'on_activate', 2),
                ('DEACTIVATE', rule_definition ->> 'on_deactivate', 2),
                ('CHANGE', rule_definition ->> 'on_change', 3)
            ) AS c(event_kind, identity, expected_args)
            WHERE identity IS NOT NULL
        LOOP
            logical_function := consequence.identity;
            mapped_function := pgreact_internal.pack_mapping(mappings, 'objects', logical_function);
            function_oid := pg_catalog.to_regprocedure(mapped_function);
            IF function_oid IS NULL THEN
                has_error := true;
                RETURN QUERY SELECT 1, 'CONSEQUENCE_NOT_FOUND', 'ERROR', logical_function,
                    'mapped typed consequence does not exist',
                    'Create it in this environment or correct the object mapping.',
                    jsonb_build_object('mapped_identity', mapped_function, 'rule', rule_name);
                CONTINUE;
            END IF;
            SELECT proowner, prorettype, pronargs, proargtypes INTO function_row
            FROM pg_catalog.pg_proc WHERE oid = function_oid;
            IF function_row.proowner <> caller_oid OR function_row.prorettype <> 'void'::regtype
               OR function_row.pronargs <> consequence.expected_args
               OR function_row.proargtypes[0] <> 'pgreact.activation_context'::regtype
               OR function_row.proargtypes[1] <> source_type
               OR (consequence.event_kind = 'CHANGE' AND function_row.proargtypes[2] <> source_type) THEN
                has_error := true;
                RETURN QUERY SELECT 1, 'CONSEQUENCE_SIGNATURE', 'ERROR', logical_function,
                    'typed consequence is not owned by the pack owner or has the wrong exact signature',
                    'Use the mapped source row type and return void.',
                    jsonb_build_object('mapped_identity', mapped_function, 'rule', rule_name, 'event_kind', consequence.event_kind);
            END IF;
        END LOOP;

        IF pg_catalog.jsonb_typeof(COALESCE(rule_definition -> 'outbox', '{}'::jsonb)) = 'object' THEN
            FOR outbox_item IN
                SELECT key AS event_kind, value #>> '{}' AS identity
                FROM pg_catalog.jsonb_each(COALESCE(rule_definition -> 'outbox', '{}'::jsonb))
            LOOP
                IF outbox_item.event_kind NOT IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE') THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'OUTBOX_EVENT_INVALID', 'ERROR', rule_name,
                        'outbox event must be ACTIVATE, CHANGE, or DEACTIVATE',
                        'Use a supported lifecycle event.', jsonb_build_object('event_kind', outbox_item.event_kind);
                    CONTINUE;
                END IF;
                IF rule_definition ->> ('on_' || lower(outbox_item.event_kind)) IS NOT NULL THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'CONSEQUENCE_DUPLICATE', 'ERROR', rule_name,
                        'one event cannot have both typed and outbox consequences',
                        'Choose exactly one binding kind.', jsonb_build_object('event_kind', outbox_item.event_kind);
                    CONTINUE;
                END IF;
                logical_function := outbox_item.identity;
                mapped_function := pgreact_internal.pack_mapping(mappings, 'objects', logical_function);
                function_oid := pg_catalog.to_regprocedure(mapped_function);
                SELECT proowner, prorettype, pronargs, proargtypes INTO function_row
                FROM pg_catalog.pg_proc WHERE oid = function_oid;
                IF function_oid IS NULL OR function_row.proowner <> caller_oid
                   OR function_row.prorettype <> 'void'::regtype OR function_row.pronargs <> 2
                   OR function_row.proargtypes[0] <> 'pgreact.activation_context'::regtype
                   OR function_row.proargtypes[1] <> 'jsonb'::regtype THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'OUTBOX_SIGNATURE', 'ERROR', logical_function,
                        'outbox sink must be owned by the pack owner and accept (pgreact.activation_context, jsonb)',
                        'Create the exact mapped sink before deployment.',
                        jsonb_build_object('mapped_identity', mapped_function, 'rule', rule_name);
                END IF;
            END LOOP;
        END IF;

        IF rule_definition ? 'salience' AND pg_catalog.jsonb_typeof(rule_definition -> 'salience') <> 'number'
           OR rule_definition ? 'max_attempts' AND pg_catalog.jsonb_typeof(rule_definition -> 'max_attempts') <> 'number'
           OR rule_definition ? 'initial_backoff_seconds' AND pg_catalog.jsonb_typeof(rule_definition -> 'initial_backoff_seconds') <> 'number'
           OR rule_definition ? 'backoff_multiplier' AND pg_catalog.jsonb_typeof(rule_definition -> 'backoff_multiplier') <> 'number'
           OR rule_definition ? 'max_backoff_seconds' AND pg_catalog.jsonb_typeof(rule_definition -> 'max_backoff_seconds') <> 'number'
           OR rule_definition ? 'agenda_group' AND pg_catalog.jsonb_typeof(rule_definition -> 'agenda_group') <> 'string'
           OR rule_definition ? 'bootstrap_policy' AND pg_catalog.jsonb_typeof(rule_definition -> 'bootstrap_policy') <> 'string' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_OPTION_TYPE', 'ERROR', rule_name,
                'rule options have invalid JSON types',
                'Use numbers for numeric policies and strings for named policies.', '{}'::jsonb;
        ELSIF COALESCE(rule_definition ->> 'bootstrap_policy', 'SEED_CURRENT') NOT IN ('SEED_CURRENT', 'REQUIRE_EMPTY')
           OR COALESCE(rule_definition ->> 'agenda_group', 'default') = ''
           OR COALESCE((rule_definition ->> 'salience')::numeric, 0) NOT BETWEEN -2147483648 AND 2147483647
           OR COALESCE((rule_definition ->> 'salience')::numeric, 0) <> trunc(COALESCE((rule_definition ->> 'salience')::numeric, 0))
           OR COALESCE((rule_definition ->> 'max_attempts')::numeric, 1) NOT BETWEEN 1 AND 100
           OR COALESCE((rule_definition ->> 'max_attempts')::numeric, 1) <> trunc(COALESCE((rule_definition ->> 'max_attempts')::numeric, 1))
           OR COALESCE((rule_definition ->> 'initial_backoff_seconds')::numeric, 1) NOT BETWEEN 1 AND 3600
           OR COALESCE((rule_definition ->> 'initial_backoff_seconds')::numeric, 1) <> trunc(COALESCE((rule_definition ->> 'initial_backoff_seconds')::numeric, 1))
           OR COALESCE((rule_definition ->> 'max_backoff_seconds')::numeric, 60) NOT BETWEEN 1 AND 86400
           OR COALESCE((rule_definition ->> 'max_backoff_seconds')::numeric, 60) <> trunc(COALESCE((rule_definition ->> 'max_backoff_seconds')::numeric, 60))
           OR COALESCE((rule_definition ->> 'backoff_multiplier')::numeric, 2) < 1 THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_OPTION_INVALID', 'ERROR', rule_name,
                'rule options are outside the supported v1 policy bounds',
                'Use an existing bootstrap policy, a non-empty agenda group, and bounded retry values.', '{}'::jsonb;
        END IF;

        SELECT v.owner_oid, v.state INTO function_row
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_name AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        IF FOUND AND (function_row.owner_oid <> caller_oid OR function_row.state NOT IN ('ACTIVE', 'PAUSED')) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_NOT_REPLACEABLE', 'ERROR', rule_name,
                'current rule is not owned by this pack owner or is still draining',
                'Finish old work before deploying this rule name.', jsonb_build_object('state', function_row.state);
        END IF;
    END LOOP;

    WITH RECURSIVE edges AS (
        SELECT r.value ->> 'name' AS rule_name, d.value #>> '{}' AS dependency
        FROM pg_catalog.jsonb_array_elements(definition -> 'rules') AS r(value)
        CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(
            CASE WHEN pg_catalog.jsonb_typeof(r.value -> 'depends_on') = 'array'
                 THEN r.value -> 'depends_on' ELSE '[]'::jsonb END
        ) AS d(value)
        WHERE pg_catalog.jsonb_typeof(d.value) = 'string'
    ), walk(origin, node, path, cycle) AS (
        SELECT e.rule_name, e.dependency, ARRAY[e.rule_name, e.dependency], e.rule_name = e.dependency
        FROM edges e
        UNION ALL
        SELECT w.origin, e.dependency, w.path || e.dependency, e.dependency = ANY(w.path)
        FROM walk w JOIN edges e ON e.rule_name = w.node
        WHERE NOT w.cycle
    )
    SELECT origin INTO cycle_name FROM walk WHERE cycle ORDER BY origin LIMIT 1;
    IF cycle_name IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'DEPENDENCY_CYCLE', 'ERROR', cycle_name,
            'pack dependency graph contains a cycle',
            'Remove the cycle and order dependencies before dependents.', '{}'::jsonb;
    END IF;

    IF active_pack_version IS NOT NULL THEN
        FOR rule_name IN
            SELECT m.rule_name FROM pgreact_internal.rule_pack_members m
            WHERE m.pack_version_id = active_pack_version
            ORDER BY m.rule_name
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_catalog.jsonb_array_elements(definition -> 'rules') AS x(value)
                WHERE x.value ->> 'name' = rule_name
            ) AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS x(value)
                WHERE x.value ->> 'name' = rule_name
            ) THEN
                has_error := true;
                RETURN QUERY SELECT 1, 'REMOVAL_NOT_EXPLICIT', 'ERROR', rule_name,
                    'a current pack member is absent without an explicit removal',
                    'Add it to remove with an old_work_policy.', '{}'::jsonb;
            END IF;
        END LOOP;
    END IF;

    FOR removal_item IN
        SELECT value FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    LOOP
        IF pg_catalog.jsonb_typeof(removal_item.value) IS DISTINCT FROM 'object'
           OR pg_catalog.jsonb_typeof(removal_item.value -> 'name') IS DISTINCT FROM 'string' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'REMOVAL_INVALID', 'ERROR', '<removal>',
                'each removal must contain a rule-name string',
                'Use {"name": "...", "old_work_policy": "DRAIN_OLD"}.', '{}'::jsonb;
            CONTINUE;
        END IF;
        rule_name := removal_item.value ->> 'name';
        policy := COALESCE(removal_item.value ->> 'old_work_policy', 'DRAIN_OLD');
        IF policy NOT IN ('DRAIN_OLD', 'CANCEL_OLD') THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'OLD_WORK_POLICY_INVALID', 'ERROR', rule_name,
                'old_work_policy must be DRAIN_OLD or CANCEL_OLD',
                'Choose how pending and retrying work is handled.', '{}'::jsonb;
        END IF;
        IF active_pack_version IS NULL OR NOT EXISTS (
            SELECT 1 FROM pgreact_internal.rule_pack_members m
            WHERE m.pack_version_id = active_pack_version AND m.rule_name = rule_name
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'REMOVAL_UNKNOWN', 'ERROR', rule_name,
                'only a current member of this pack can be removed',
                'Remove the entry or deploy the rule through this pack first.', '{}'::jsonb;
        END IF;
    END LOOP;

    IF NOT has_error THEN
        RETURN QUERY SELECT 1, 'OK', 'INFO', pack_name,
            'rule pack is valid for this environment',
            'Preview the atomic plan before deployment.',
            jsonb_build_object('version', pack_version, 'mapped_owner', mapped_owner,
                               'rule_count', jsonb_array_length(definition -> 'rules'),
                               'removal_count', jsonb_array_length(definition -> 'remove'));
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.pack_plan_digest(definition jsonb, mappings jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    material text := definition::text || E'\n' || mappings::text || E'\nowner:' || session_user;
    rule_item record;
    rule_name text;
    logical_identity text;
    mapped_identity text;
    object_oid oid;
    object_owner oid;
    current_version uuid;
    current_state text;
    current_match text;
    work_state jsonb;
    consequence record;
    active_pack_version uuid;
BEGIN
    SELECT v.pack_version_id INTO active_pack_version
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = definition ->> 'pack'
      AND p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND v.state = 'ACTIVE';
    material := material || E'\nactive_pack:' || COALESCE(active_pack_version::text, '<none>');
    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, ordinal)
    LOOP
        rule_name := rule_item.value ->> 'name';
        logical_identity := rule_item.value ->> 'definition';
        mapped_identity := pgreact_internal.pack_mapping(mappings, 'objects', logical_identity);
        object_oid := pg_catalog.to_regclass(mapped_identity);
        SELECT relowner INTO object_owner FROM pg_catalog.pg_class WHERE oid = object_oid;
        SELECT v.rule_version_id, v.state, v.match_name
          INTO current_version, current_state, current_match
        FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_name AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_version GROUP BY state) AS q;
        material := material || format(E'\nrule:%s:%s:%s:%s:%s:%s:%s:%s',
            rule_item.ordinal, rule_name, object_oid, object_owner,
            encode(sha256(convert_to(pg_get_viewdef(object_oid, true), 'UTF8')), 'hex'),
            encode(pgreact_internal.source_row_signature(object_oid), 'hex'),
            COALESCE(current_version::text || ':' || current_state || ':' || current_match, '<add>'),
            work_state::text);
        FOR consequence IN
            SELECT identity FROM (VALUES
                (rule_item.value ->> 'on_activate'),
                (rule_item.value ->> 'on_deactivate'),
                (rule_item.value ->> 'on_change')
            ) AS typed(identity) WHERE identity IS NOT NULL
            UNION ALL
            SELECT value #>> '{}' FROM pg_catalog.jsonb_each(COALESCE(rule_item.value -> 'outbox', '{}'::jsonb))
        LOOP
            mapped_identity := pgreact_internal.pack_mapping(mappings, 'objects', consequence.identity);
            object_oid := pg_catalog.to_regprocedure(mapped_identity);
            SELECT proowner INTO object_owner FROM pg_catalog.pg_proc WHERE oid = object_oid;
            material := material || format(E'\nfunction:%s:%s:%s:%s', consequence.identity,
                object_oid, object_owner,
                encode(sha256(convert_to(pg_get_functiondef(object_oid), 'UTF8')), 'hex'));
        END LOOP;
    END LOOP;
    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'remove')
        WITH ORDINALITY AS r(value, ordinal)
    LOOP
        rule_name := rule_item.value ->> 'name';
        SELECT m.rule_version_id, v.state, v.match_name
          INTO current_version, current_state, current_match
        FROM pgreact_internal.rule_packs p
        JOIN pgreact_internal.rule_pack_versions pv USING (pack_id)
        JOIN pgreact_internal.rule_pack_members m USING (pack_version_id)
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE p.pack_name = definition ->> 'pack' AND pv.state = 'ACTIVE' AND m.rule_name = rule_name;
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_version GROUP BY state) AS q;
        material := material || format(E'\nremove:%s:%s:%s:%s:%s:%s', rule_item.ordinal,
            rule_name, current_version, current_state, current_match, work_state::text);
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
$$;

CREATE FUNCTION pgreact.preview_pack(definition jsonb, mappings jsonb DEFAULT '{}'::jsonb)
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
    rule_item record;
    current_row record;
    dependency_names text[];
    work_state jsonb;
    digest text;
    ordinal integer := 0;
BEGIN
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    digest := pgreact_internal.pack_plan_digest(definition, mappings);
    FOR rule_item IN
        SELECT value, array_ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, array_ordinal)
    LOOP
        ordinal := ordinal + 1;
        SELECT v.rule_version_id, v.state, v.match_name INTO current_row
        FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT array_agg(value #>> '{}' ORDER BY dependency_ordinal)::text[] INTO dependency_names
        FROM pg_catalog.jsonb_array_elements(COALESCE(rule_item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY AS d(value, dependency_ordinal);
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_row.rule_version_id GROUP BY state) AS q;
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_row.rule_version_id IS NULL THEN 'ADD' ELSE 'REPLACE' END;
        rule_name := rule_item.value ->> 'name';
        dependencies := COALESCE(dependency_names, ARRAY[]::text[]);
        generated_object_changes := jsonb_build_object(
            'create', jsonb_build_array('match_relation', 'lifecycle_triggers') ||
                CASE WHEN rule_item.value ->> 'on_activate' IS NOT NULL
                       OR rule_item.value ->> 'on_deactivate' IS NOT NULL
                       OR rule_item.value ->> 'on_change' IS NOT NULL
                     THEN jsonb_build_array('typed_dispatchers') ELSE '[]'::jsonb END,
            'retire', CASE WHEN current_row.rule_version_id IS NULL THEN '[]'::jsonb
                           ELSE jsonb_build_array(current_row.match_name) END
        );
        lifecycle_risks := CASE WHEN current_row.rule_version_id IS NULL
            THEN jsonb_build_array(COALESCE(rule_item.value ->> 'bootstrap_policy', 'SEED_CURRENT') || ' may seed current matches')
            ELSE jsonb_build_array(COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD') ||
                                   ' applies to prior pending, retrying, and leased work') END;
        details := jsonb_build_object(
            'source', rule_item.value ->> 'definition',
            'mapped_source', pgreact_internal.pack_mapping(mappings, 'objects', rule_item.value ->> 'definition'),
            'prior_rule_version_id', current_row.rule_version_id,
            'prior_state', current_row.state,
            'prior_work', work_state
        );
        RETURN NEXT;
    END LOOP;
    FOR rule_item IN
        SELECT value FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    LOOP
        ordinal := ordinal + 1;
        SELECT m.rule_version_id, v.state, v.match_name INTO current_row
        FROM pgreact_internal.rule_packs p
        JOIN pgreact_internal.rule_pack_versions pv USING (pack_id)
        JOIN pgreact_internal.rule_pack_members m USING (pack_version_id)
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE p.pack_name = definition ->> 'pack' AND pv.state = 'ACTIVE'
          AND m.rule_name = rule_item.value ->> 'name';
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_row.rule_version_id GROUP BY state) AS q;
        plan_digest := digest;
        action_order := ordinal;
        action := 'REMOVE';
        rule_name := rule_item.value ->> 'name';
        dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object('retire', jsonb_build_array(current_row.match_name));
        lifecycle_risks := jsonb_build_array(COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD') ||
                                             ' applies to pending, retrying, and leased work');
        details := jsonb_build_object('prior_rule_version_id', current_row.rule_version_id,
                                      'prior_state', current_row.state, 'prior_work', work_state);
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.replace_pack_rule(
    target_version_id uuid,
    rule_name text,
    definition regclass,
    key_columns name[],
    kind text,
    on_activate regprocedure,
    on_deactivate regprocedure,
    on_change regprocedure,
    bootstrap_policy text,
    change_columns name[],
    salience integer,
    agenda_group text,
    conflict_key_columns name[],
    max_attempts integer,
    initial_backoff_seconds integer,
    backoff_multiplier numeric,
    max_backoff_seconds integer,
    old_work_policy text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    prior pgreact_internal.rule_versions%ROWTYPE;
    next_version uuid;
    orphan_rule uuid;
    temporary_name text := rule_name || '#pack-' || replace(gen_random_uuid()::text, '-', '');
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    IF prior.state NOT IN ('ACTIVE', 'PAUSED') THEN
        RAISE EXCEPTION 'only active or paused versions can be replaced';
    END IF;
    IF old_work_policy = 'CANCEL_OLD' THEN
        UPDATE pgreact_internal.agenda SET state = 'CANCELLED', completed_at = clock_timestamp()
        WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'RETRY_WAIT');
    END IF;
    -- Older immutable versions may still be draining under the same logical
    -- rule identity. Hide that identity only inside this deployment transaction
    -- so create_rule can compile the next version without weakening old work.
    UPDATE pgreact_internal.rules SET rule_name = temporary_name WHERE rule_id = prior.rule_id;
    UPDATE pgreact_internal.rule_versions SET state = 'REMOVED' WHERE rule_version_id = target_version_id;
    next_version := pgreact.create_rule(rule_name, definition, key_columns, kind,
        on_activate, on_deactivate, on_change, bootstrap_policy, change_columns,
        salience, agenda_group, conflict_key_columns, max_attempts,
        initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
    SELECT rule_id INTO orphan_rule FROM pgreact_internal.rule_versions WHERE rule_version_id = next_version;
    UPDATE pgreact_internal.rule_versions SET rule_id = prior.rule_id WHERE rule_version_id = next_version;
    DELETE FROM pgreact_internal.rules WHERE rule_id = orphan_rule;
    UPDATE pgreact_internal.rules SET rule_name = replace_pack_rule.rule_name WHERE rule_id = prior.rule_id;
    IF prior.match_relid IS NOT NULL THEN
        PERFORM pgtrickle.drop_stream_table(prior.match_name, true);
    END IF;
    UPDATE pgreact_internal.rule_versions
    SET match_relid = NULL,
        state = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.agenda
            WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'LEASED', 'RETRY_WAIT')
        ) THEN 'DRAINING' ELSE 'REMOVED' END
    WHERE rule_version_id = target_version_id;
    RETURN next_version;
END
$$;

CREATE FUNCTION pgreact_internal.retire_pack_rule(target_version_id uuid, old_work_policy text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE prior pgreact_internal.rule_versions%ROWTYPE;
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    IF old_work_policy = 'CANCEL_OLD' THEN
        UPDATE pgreact_internal.agenda SET state = 'CANCELLED', completed_at = clock_timestamp()
        WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'RETRY_WAIT');
    END IF;
    IF prior.match_relid IS NOT NULL THEN
        PERFORM pgtrickle.drop_stream_table(prior.match_name, true);
    END IF;
    UPDATE pgreact_internal.rule_versions
    SET match_relid = NULL,
        state = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.agenda
            WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'LEASED', 'RETRY_WAIT')
        ) THEN 'DRAINING' ELSE 'REMOVED' END
    WHERE rule_version_id = target_version_id;
END
$$;

CREATE FUNCTION pgreact_internal.maybe_fail_pack(phase text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
BEGIN
    IF pg_catalog.current_setting('pgreact.test_fail_pack_phase', true) = phase THEN
        RAISE EXCEPTION 'injected rule-pack failure after % phase', phase;
    END IF;
END
$$;

CREATE FUNCTION pgreact.deploy_pack(
    definition jsonb,
    expected_plan_digest text,
    mappings jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    diagnostic record;
    actual_plan_digest text;
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    pack_id uuid;
    prior_pack_version uuid;
    next_pack_version uuid := gen_random_uuid();
    rule_item record;
    current_version uuid;
    next_rule_version uuid;
    source_oid oid;
    on_activate_oid oid;
    on_deactivate_oid oid;
    on_change_oid oid;
    change_columns name[];
    conflict_columns name[];
    dependencies text[];
    policy text;
    action_name text;
    action_number integer := 0;
    outbox_item record;
BEGIN
    -- ponytail: global deployment/DDL locks are the smallest correct boundary;
    -- shard by pack only if measured deployment concurrency requires it.
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    actual_plan_digest := pgreact_internal.pack_plan_digest(definition, mappings);
    IF expected_plan_digest IS DISTINCT FROM actual_plan_digest THEN
        RAISE EXCEPTION 'rule-pack preview is stale'
            USING HINT = 'Run pgreact.preview_pack again after concurrent DDL, work, or deployment changes.',
                  DETAIL = format('expected %s, current %s', expected_plan_digest, actual_plan_digest);
    END IF;
    SELECT p.pack_id INTO pack_id FROM pgreact_internal.rule_packs p
    WHERE p.owner_oid = caller_oid AND p.pack_name = definition ->> 'pack';
    IF pack_id IS NULL THEN
        pack_id := gen_random_uuid();
        INSERT INTO pgreact_internal.rule_packs(pack_id, pack_name, owner_oid)
        VALUES (pack_id, definition ->> 'pack', caller_oid);
    ELSE
        SELECT v.pack_version_id INTO prior_pack_version
        FROM pgreact_internal.rule_pack_versions v
        WHERE v.pack_id = pack_id AND v.state = 'ACTIVE';
    END IF;
    INSERT INTO pgreact_internal.rule_pack_versions(
        pack_version_id, pack_id, version, definition, mappings, definition_digest,
        plan_digest, state, deployed_by
    ) VALUES (
        next_pack_version, pack_id, definition ->> 'version', definition, mappings,
        sha256(convert_to(definition::text, 'UTF8')), actual_plan_digest, 'STAGED', session_user
    );
    PERFORM pgreact_internal.maybe_fail_pack('catalog');

    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, ordinal) ORDER BY ordinal
    LOOP
        action_number := action_number + 1;
        SELECT v.rule_version_id INTO current_version
        FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        source_oid := pg_catalog.to_regclass(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'definition'));
        on_activate_oid := pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'on_activate'));
        on_deactivate_oid := pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'on_deactivate'));
        on_change_oid := pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'on_change'));
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::name[] INTO change_columns
        FROM pg_catalog.jsonb_array_elements(rule_item.value -> 'change_columns')
        WITH ORDINALITY AS c(value, ordinal);
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::name[] INTO conflict_columns
        FROM pg_catalog.jsonb_array_elements(rule_item.value -> 'conflict_key_columns')
        WITH ORDINALITY AS c(value, ordinal);
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::text[] INTO dependencies
        FROM pg_catalog.jsonb_array_elements(COALESCE(rule_item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY AS d(value, ordinal);
        policy := COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD');
        action_name := CASE WHEN current_version IS NULL THEN 'ADD' ELSE 'REPLACE' END;
        IF current_version IS NULL THEN
            next_rule_version := pgreact.create_rule(
                rule_item.value ->> 'name', source_oid::regclass,
                ARRAY[(rule_item.value ->> 'key')::name], rule_item.value ->> 'kind',
                on_activate_oid::regprocedure, on_deactivate_oid::regprocedure, on_change_oid::regprocedure,
                COALESCE(rule_item.value ->> 'bootstrap_policy', 'SEED_CURRENT'), change_columns,
                COALESCE((rule_item.value ->> 'salience')::integer, 0),
                COALESCE(rule_item.value ->> 'agenda_group', 'default'), conflict_columns,
                COALESCE((rule_item.value ->> 'max_attempts')::integer, 1),
                COALESCE((rule_item.value ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((rule_item.value ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((rule_item.value ->> 'max_backoff_seconds')::integer, 60));
        ELSE
            next_rule_version := pgreact_internal.replace_pack_rule(
                current_version, rule_item.value ->> 'name', source_oid::regclass,
                ARRAY[(rule_item.value ->> 'key')::name], rule_item.value ->> 'kind',
                on_activate_oid::regprocedure, on_deactivate_oid::regprocedure, on_change_oid::regprocedure,
                COALESCE(rule_item.value ->> 'bootstrap_policy', 'SEED_CURRENT'), change_columns,
                COALESCE((rule_item.value ->> 'salience')::integer, 0),
                COALESCE(rule_item.value ->> 'agenda_group', 'default'), conflict_columns,
                COALESCE((rule_item.value ->> 'max_attempts')::integer, 1),
                COALESCE((rule_item.value ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((rule_item.value ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((rule_item.value ->> 'max_backoff_seconds')::integer, 60), policy);
        END IF;
        FOR outbox_item IN
            SELECT key AS event_kind, value #>> '{}' AS identity
            FROM pg_catalog.jsonb_each(COALESCE(rule_item.value -> 'outbox', '{}'::jsonb))
        LOOP
            PERFORM pgreact.bind_outbox_consequence(next_rule_version, outbox_item.event_kind,
                pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(mappings, 'objects', outbox_item.identity)),
                COALESCE((rule_item.value ->> 'max_attempts')::integer, 1),
                COALESCE((rule_item.value ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((rule_item.value ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((rule_item.value ->> 'max_backoff_seconds')::integer, 60));
        END LOOP;
        INSERT INTO pgreact_internal.rule_pack_members
            (pack_version_id, rule_name, rule_version_id, dependencies)
        VALUES (next_pack_version, rule_item.value ->> 'name', next_rule_version,
                COALESCE(dependencies, ARRAY[]::text[]));
        INSERT INTO pgreact_internal.rule_pack_actions(
            pack_version_id, action_order, action, rule_name, old_rule_version_id,
            new_rule_version_id, old_work_policy, details
        ) VALUES (
            next_pack_version, action_number, action_name, rule_item.value ->> 'name',
            current_version, next_rule_version, policy,
            jsonb_build_object('dependencies', COALESCE(to_jsonb(dependencies), '[]'::jsonb),
                               'source', rule_item.value ->> 'definition')
        );
        current_version := NULL;
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_pack('rules');

    FOR rule_item IN
        SELECT value FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    LOOP
        action_number := action_number + 1;
        SELECT m.rule_version_id INTO current_version
        FROM pgreact_internal.rule_pack_members m
        WHERE m.pack_version_id = prior_pack_version AND m.rule_name = rule_item.value ->> 'name';
        policy := COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD');
        PERFORM pgreact_internal.retire_pack_rule(current_version, policy);
        INSERT INTO pgreact_internal.rule_pack_actions(
            pack_version_id, action_order, action, rule_name, old_rule_version_id,
            old_work_policy, details
        ) VALUES (next_pack_version, action_number, 'REMOVE', rule_item.value ->> 'name',
                  current_version, policy, '{}'::jsonb);
        current_version := NULL;
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_pack('removals');

    UPDATE pgreact_internal.rule_pack_versions SET state = 'SUPERSEDED'
    WHERE pack_version_id = prior_pack_version;
    UPDATE pgreact_internal.rule_pack_versions SET state = 'ACTIVE'
    WHERE pack_version_id = next_pack_version;
    PERFORM pgreact_internal.maybe_fail_pack('activation');
    RETURN next_pack_version;
END
$$;

CREATE FUNCTION pgreact.pack_history(target_pack_name text DEFAULT NULL)
RETURNS TABLE(
    pack_name text,
    version text,
    status text,
    definition_digest text,
    plan_digest text,
    deployed_at timestamptz,
    deployed_by name,
    actions jsonb
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT p.pack_name, v.version, v.state,
           encode(v.definition_digest, 'hex'), v.plan_digest, v.deployed_at, v.deployed_by,
           COALESCE(jsonb_agg(jsonb_build_object(
               'order', a.action_order, 'action', a.action, 'rule', a.rule_name,
               'old_rule_version_id', a.old_rule_version_id,
               'new_rule_version_id', a.new_rule_version_id,
               'old_work_policy', a.old_work_policy, 'details', a.details
           ) ORDER BY a.action_order) FILTER (WHERE a.action_order IS NOT NULL), '[]'::jsonb)
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    LEFT JOIN pgreact_internal.rule_pack_actions a USING (pack_version_id)
    WHERE p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND ($1 IS NULL OR p.pack_name = $1)
    GROUP BY p.pack_name, v.pack_version_id
    ORDER BY p.pack_name, v.deployed_at
$$;

CREATE FUNCTION pgreact.explain_pack(target_pack_name text)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'pack', jsonb_build_object('name', p.pack_name, 'version', v.version,
                                   'plan_digest', v.plan_digest, 'deployed_at', v.deployed_at),
        'members', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'rule', m.rule_name, 'rule_version_id', m.rule_version_id,
                'dependencies', m.dependencies, 'state', rv.state,
                'source_drift', d.status,
                'outstanding_work', (SELECT count(*) FROM pgreact_internal.agenda a
                                     WHERE a.rule_version_id = m.rule_version_id
                                       AND a.state IN ('PENDING', 'RETRY_WAIT', 'LEASED'))
            ) ORDER BY m.rule_name)
            FROM pgreact_internal.rule_pack_members m
            JOIN pgreact_internal.rule_versions rv USING (rule_version_id)
            LEFT JOIN pgreact.source_drift() d USING (rule_version_id)
            WHERE m.pack_version_id = v.pack_version_id
        ), '[]'::jsonb),
        'draining_old_work', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'rule', a.rule_name, 'rule_version_id', a.old_rule_version_id,
                'state', rv.state,
                'outstanding_work', (SELECT count(*) FROM pgreact_internal.agenda q
                                     WHERE q.rule_version_id = a.old_rule_version_id
                                       AND q.state IN ('PENDING', 'RETRY_WAIT', 'LEASED'))
            ) ORDER BY a.action_order)
            FROM pgreact_internal.rule_pack_actions a
            JOIN pgreact_internal.rule_versions rv ON rv.rule_version_id = a.old_rule_version_id
            WHERE a.pack_version_id = v.pack_version_id AND rv.state = 'DRAINING'
        ), '[]'::jsonb),
        'history', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.deployed_at)
                            FROM pgreact.pack_history(target_pack_name) h), '[]'::jsonb)
    )
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = target_pack_name
      AND p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND v.state = 'ACTIVE'
$$;

DROP EVENT TRIGGER pgreact_binding_ddl_lock;
CREATE EVENT TRIGGER pgreact_binding_ddl_lock
    ON ddl_command_start
    WHEN TAG IN (
        'CREATE FUNCTION', 'ALTER FUNCTION', 'DROP FUNCTION',
        'CREATE TABLE', 'ALTER TABLE', 'DROP TABLE',
        'CREATE VIEW', 'ALTER VIEW', 'DROP VIEW',
        'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW', 'DROP MATERIALIZED VIEW'
    )
    EXECUTE FUNCTION pgreact_internal.binding_ddl_lock();

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M5 safe rule-set deployment over the frozen v1 lifecycle and worker protocol';
