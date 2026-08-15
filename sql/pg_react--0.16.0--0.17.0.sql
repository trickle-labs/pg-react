-- M20 explicit, versioned shared conditions over the existing keyed
-- derived-relation and derivation-program machinery.

CREATE TABLE pgreact_internal.shared_conditions (
    condition_id uuid PRIMARY KEY,
    condition_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.shared_condition_versions (
    condition_version_id uuid PRIMARY KEY,
    condition_id uuid NOT NULL REFERENCES pgreact_internal.shared_conditions,
    version integer NOT NULL CHECK (version > 0),
    owner_oid oid NOT NULL,
    source_view_oid oid NOT NULL,
    source_view_name text NOT NULL,
    source_definition text NOT NULL,
    source_definition_digest bytea NOT NULL,
    source_row_signature bytea NOT NULL,
    row_type_oid oid NOT NULL,
    row_type_name text NOT NULL,
    key_columns name[] NOT NULL CHECK (cardinality(key_columns) BETWEEN 1 AND 4),
    key_types regtype[] NOT NULL,
    key_collations regcollation[] NOT NULL,
    relation_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derived_relation_versions,
    program_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_program_versions,
    maintenance_mode text NOT NULL CHECK (maintenance_mode IN ('SCHEDULED', 'IMMEDIATE')),
    state text NOT NULL CHECK (state IN ('ACTIVE', 'REMOVED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (condition_id, version)
);

CREATE UNIQUE INDEX shared_condition_one_active_version
    ON pgreact_internal.shared_condition_versions (condition_id)
    WHERE state = 'ACTIVE';

CREATE TABLE pgreact_internal.shared_condition_consumers (
    condition_version_id uuid NOT NULL
        REFERENCES pgreact_internal.shared_condition_versions,
    consumer_kind text NOT NULL CHECK (consumer_kind IN ('RULE', 'PROGRAM')),
    consumer_name text NOT NULL,
    consumer_version_id uuid NOT NULL,
    owner_oid oid NOT NULL,
    registered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (condition_version_id, consumer_kind, consumer_name)
);

CREATE TABLE pgreact_internal.shared_condition_grants (
    condition_id uuid NOT NULL REFERENCES pgreact_internal.shared_conditions,
    role_oid oid NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (condition_id, role_oid)
);

CREATE FUNCTION pgreact_internal.condition_keys(definition jsonb)
RETURNS name[]
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE jsonb_typeof($1 -> 'key')
        WHEN 'string' THEN ARRAY[($1 ->> 'key')::name]
        WHEN 'array' THEN ARRAY(
            SELECT value::name FROM jsonb_array_elements_text($1 -> 'key'))
        ELSE NULL::name[]
    END
$$;

CREATE FUNCTION pgreact_internal.condition_program(definition jsonb, target_version integer)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    condition_name text := definition ->> 'name';
    source_name text := definition ->> 'source';
    keys name[] := pgreact_internal.condition_keys(definition);
    program_name text := '__pgreact.condition.' || condition_name;
BEGIN
    RETURN jsonb_build_object(
        'name', program_name,
        'version', target_version,
        'max_iterations', 8,
        'max_facts', 100000,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', program_name || '.maintain',
            'definition', source_name,
            'key', keys[1],
            'target', condition_name,
            'version', target_version)));
END
$$;

CREATE FUNCTION pgreact_api.validate_shared_condition(definition jsonb)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    source_oid oid;
    target_oid oid;
    row_type_oid oid;
    row_relid oid;
    row_owner oid;
    source_owner oid;
    keys name[];
    key_types regtype[];
    key_collations regcollation[];
    source_signature bytea;
    mode text := upper(COALESCE(definition ->> 'maintenance_mode', 'SCHEDULED'));
    condition_name text := definition ->> 'name';
BEGIN
    IF jsonb_typeof(definition) IS DISTINCT FROM 'object'
       OR condition_name IS NULL
       OR definition ->> 'source' IS NULL
       OR definition ->> 'row_type' IS NULL
       OR pgreact_internal.condition_keys(definition) IS NULL THEN
        RETURN QUERY SELECT 8, 'M20_DEFINITION_SHAPE', 'ERROR',
            COALESCE(condition_name, 'condition'),
            'shared condition definitions require name, source, row_type, and key',
            'Use a schema-qualified relation, an owned composite row type, and one to four named key columns.',
            '{}'::jsonb;
        RETURN;
    END IF;
    keys := pgreact_internal.condition_keys(definition);
    IF cardinality(keys) NOT BETWEEN 1 AND 4
       OR array_position(keys, NULL) IS NOT NULL
       OR (SELECT count(DISTINCT key) FROM unnest(keys) key) <> cardinality(keys) THEN
        RETURN QUERY SELECT 8, 'M20_KEY_ARITY', 'ERROR', condition_name,
            'shared condition keys require one to four distinct columns',
            'Use one to four non-null, distinct key names.', '{}'::jsonb;
        RETURN;
    END IF;
    IF mode NOT IN ('SCHEDULED', 'IMMEDIATE') THEN
        RETURN QUERY SELECT 8, 'M20_MAINTENANCE_MODE', 'ERROR', condition_name,
            'shared condition maintenance_mode is unsupported',
            'Choose SCHEDULED or IMMEDIATE.', jsonb_build_object('maintenance_mode', mode);
        RETURN;
    END IF;
    source_oid := to_regclass(definition ->> 'source');
    IF source_oid IS NULL THEN
        RETURN QUERY SELECT 8, 'M20_SOURCE_NOT_FOUND', 'ERROR', definition ->> 'source',
            'the shared condition source relation does not exist',
            'Create the schema-qualified source view before previewing the condition.', '{}'::jsonb;
        RETURN;
    END IF;
    IF (SELECT relkind FROM pg_class WHERE oid = source_oid) NOT IN ('v', 'm') THEN
        RETURN QUERY SELECT 8, 'M20_SOURCE_KIND', 'ERROR', source_oid::regclass::text,
            'shared condition sources must be views or materialized views',
            'Expose the SQL condition through a view.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT relowner INTO source_owner FROM pg_class WHERE oid = source_oid;
    IF source_owner <> (SELECT oid FROM pg_roles WHERE rolname = session_user) THEN
        RETURN QUERY SELECT 8, 'M20_SOURCE_OWNER', 'ERROR', source_oid::regclass::text,
            'the condition author must own the source view',
            'Use the source view owner to declare the shared condition.', '{}'::jsonb;
        RETURN;
    END IF;
    row_type_oid := to_regtype(definition ->> 'row_type');
    SELECT typrelid, typowner INTO row_relid, row_owner
    FROM pg_type WHERE oid = row_type_oid;
    IF row_type_oid IS NULL OR row_relid = 0 OR row_owner <> (SELECT oid FROM pg_roles WHERE rolname = session_user) THEN
        RETURN QUERY SELECT 8, 'M20_ROW_TYPE', 'ERROR', COALESCE(definition ->> 'row_type', 'row_type'),
            'the condition row_type must be an owned composite type',
            'Create and own a composite type matching the source view columns.', '{}'::jsonb;
        RETURN;
    END IF;
    IF pgreact_internal.source_row_signature(source_oid)
       IS DISTINCT FROM pgreact_internal.source_row_signature(row_relid) THEN
        RETURN QUERY SELECT 8, 'M20_SCHEMA_MISMATCH', 'ERROR', condition_name,
            'the source view columns do not match row_type',
            'Keep column names, order, types, and collations identical.',
            jsonb_build_object('source', source_oid::regclass::text,
                               'row_type', row_type_oid::regtype::text);
        RETURN;
    END IF;
    SELECT array_agg(attribute.atttypid::regtype ORDER BY key.ordinality),
           array_agg(attribute.attcollation::regcollation ORDER BY key.ordinality)
    INTO key_types, key_collations
    FROM unnest(keys) WITH ORDINALITY key(key_name, ordinality)
    LEFT JOIN pg_attribute attribute
      ON attribute.attrelid = row_relid AND attribute.attname = key.key_name
     AND attribute.attnum > 0 AND NOT attribute.attisdropped;
    IF COALESCE(cardinality(key_types), 0) <> cardinality(keys)
       OR EXISTS (SELECT 1 FROM unnest(COALESCE(key_types, ARRAY[]::regtype[])) key_type
                 WHERE key_type IS NULL) THEN
        RETURN QUERY SELECT 8, 'M20_KEY_NOT_FOUND', 'ERROR', condition_name,
            'every shared condition key must be a row_type attribute',
            'Use key columns present in the source view and row_type.',
            jsonb_build_object('key', keys);
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(key_types) key_type
               WHERE key_type NOT IN ('bigint'::regtype, 'uuid'::regtype, 'text'::regtype)) THEN
        RETURN QUERY SELECT 8, 'M20_KEY_TYPE', 'ERROR', condition_name,
            'shared condition keys use unsupported types',
            'Use bigint, uuid, or deterministic-C-collated text keys.',
            jsonb_build_object('key_types', key_types);
        RETURN;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute attribute
               JOIN pg_collation key_collation ON key_collation.oid = attribute.attcollation
               WHERE attribute.attrelid = row_relid
                 AND attribute.attname = ANY(keys)
                 AND attribute.atttypid = 'text'::regtype
                 AND (NOT key_collation.collisdeterministic OR key_collation.collname NOT IN ('C', 'default'))) THEN
        RETURN QUERY SELECT 8, 'M20_KEY_COLLATION', 'ERROR', condition_name,
            'text keys require a deterministic C collation',
            'Use COLLATE "C" for text semantic keys.', '{}'::jsonb;
        RETURN;
    END IF;
    IF EXISTS (
        WITH RECURSIVE dependencies(relid) AS (
            SELECT source_oid
            UNION
            SELECT dependency.refobjid
            FROM dependencies parent
            JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relid
            JOIN pg_depend dependency
              ON dependency.classid = 'pg_rewrite'::regclass
             AND dependency.objid = rewrite.oid
             AND dependency.refclassid = 'pg_class'::regclass
             AND dependency.deptype = 'n')
        SELECT 1 FROM dependencies
        JOIN pg_class relation ON relation.oid = dependencies.relid
        WHERE relation.relrowsecurity) THEN
        RETURN QUERY SELECT 8, 'M20_RLS_UNSUPPORTED', 'ERROR', condition_name,
            'shared condition sources may not depend on row-level-security relations',
            'Expose an authorized, non-RLS source view for this condition.', '{}'::jsonb;
        RETURN;
    END IF;
    target_oid := to_regclass(condition_name);
    IF target_oid IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pgreact_internal.shared_conditions
        WHERE shared_conditions.condition_name = condition_name) THEN
        RETURN QUERY SELECT 8, 'M20_RELATION_EXISTS', 'ERROR', condition_name,
            'the shared condition public relation already exists',
            'Choose a new condition name or remove the unrelated relation first.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_oid IS NOT NULL AND EXISTS (
        WITH RECURSIVE dependencies(relid) AS (
            SELECT source_oid
            UNION
            SELECT dependency.refobjid
            FROM dependencies parent
            JOIN pg_rewrite rewrite ON rewrite.ev_class = parent.relid
            JOIN pg_depend dependency
              ON dependency.classid = 'pg_rewrite'::regclass
             AND dependency.objid = rewrite.oid
             AND dependency.refclassid = 'pg_class'::regclass
             AND dependency.deptype = 'n')
        SELECT 1 FROM dependencies WHERE relid = target_oid) THEN
        RETURN QUERY SELECT 8, 'M20_CONDITION_CYCLE', 'ERROR', condition_name,
            'a shared condition cannot depend on its own public relation',
            'Remove the self-reference from the source view.', '{}'::jsonb;
        RETURN;
    END IF;
    source_signature := pgreact_internal.source_row_signature(source_oid);
    RETURN QUERY SELECT 8, 'OK', 'INFO', condition_name,
        'shared condition definition is valid',
        'Preview the condition before deployment.',
        jsonb_build_object('source', source_oid::regclass::text,
                           'row_type', row_type_oid::regtype::text,
                           'key_columns', keys,
                           'key_types', key_types,
                           'maintenance_mode', mode,
                           'source_row_signature', encode(source_signature, 'hex'));
EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT 8, 'M20_VALIDATION', 'ERROR',
        COALESCE(condition_name, 'condition'), SQLERRM,
        'Correct the shared condition definition and validate again.', '{}'::jsonb;
END
$$;

CREATE FUNCTION pgreact_api.preview_shared_condition(definition jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    normalized jsonb := definition;
    source_oid oid;
    source_digest text;
    next_version integer;
    expected_version integer;
    plan_digest text;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_api.validate_shared_condition(definition)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'M20_CONDITION_INVALID: % for %: %', diagnostic.code,
            diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    SELECT COALESCE(max(version), 0) + 1 INTO next_version
    FROM pgreact_internal.shared_condition_versions version
    JOIN pgreact_internal.shared_conditions condition USING (condition_id)
    WHERE condition.condition_name = definition ->> 'name';
    expected_version := COALESCE((definition ->> 'version')::integer, next_version);
    IF expected_version <> next_version THEN
        RAISE EXCEPTION 'M20_VERSION_ORDER: expected version %, received %',
            next_version, expected_version;
    END IF;
    normalized := jsonb_set(definition, '{version}', to_jsonb(next_version), true);
    source_oid := to_regclass(normalized ->> 'source');
    source_digest := encode(pgreact_internal.source_closure_digest(source_oid), 'hex');
    plan_digest := encode(sha256(convert_to(
        normalized::text || ':' || session_user || ':' || source_digest, 'UTF8')), 'hex');
    RETURN jsonb_build_object(
        'contract_version', 8,
        'condition', normalized,
        'relation', normalized ->> 'name',
        'version', next_version,
        'maintenance_mode', upper(COALESCE(normalized ->> 'maintenance_mode', 'SCHEDULED')),
        'source_digest', source_digest,
        'consumers', '[]'::jsonb,
        'program', pgreact_internal.condition_program(normalized, next_version),
        'plan_digest', plan_digest);
END
$$;

CREATE FUNCTION pgreact_internal.refresh_shared_condition_consumers(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    condition_relation uuid;
BEGIN
    SELECT relation_version_id INTO STRICT condition_relation
    FROM pgreact_internal.shared_condition_versions
    WHERE condition_version_id = target_version_id;
    DELETE FROM pgreact_internal.shared_condition_consumers
    WHERE condition_version_id = target_version_id;
    INSERT INTO pgreact_internal.shared_condition_consumers(
        condition_version_id, consumer_kind, consumer_name,
        consumer_version_id, owner_oid)
    SELECT target_version_id, 'RULE', rule.rule_name,
           version.rule_version_id, version.owner_oid
    FROM pgreact_internal.rule_versions version
    LEFT JOIN pgreact_internal.keyed_rule_versions keyed
      ON version.rule_version_id = keyed.rule_version_id
    JOIN pgreact_internal.rules rule USING (rule_id)
    WHERE (version.source_view_oid = (
               SELECT condition.condition_name::regclass
               FROM pgreact_internal.shared_condition_versions version
               JOIN pgreact_internal.shared_conditions condition
                 USING (condition_id)
               WHERE version.condition_version_id = target_version_id)
           OR keyed.public_condition = (
               SELECT condition.condition_name::regclass
               FROM pgreact_internal.shared_condition_versions version
               JOIN pgreact_internal.shared_conditions condition
                 USING (condition_id)
               WHERE version.condition_version_id = target_version_id))
      AND version.state IN ('ACTIVE', 'PAUSED');
    INSERT INTO pgreact_internal.shared_condition_consumers(
        condition_version_id, consumer_kind, consumer_name,
        consumer_version_id, owner_oid)
    SELECT DISTINCT target_version_id, 'PROGRAM', program.program_name,
           program_version.program_version_id, program_version.owner_oid
    FROM pgreact_internal.derivation_program_inputs input
    JOIN pgreact_internal.derivation_program_versions program_version
      ON program_version.program_version_id = input.program_version_id
    JOIN pgreact_internal.derivation_programs program
      USING (program_id)
    WHERE input.relation_version_id = condition_relation
      AND program_version.state = 'ACTIVE';
END
$$;

CREATE FUNCTION pgreact_api.deploy_shared_condition(
    definition jsonb,
    expected_plan_digest text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    preview jsonb;
    normalized jsonb;
    condition_row pgreact_internal.shared_conditions%ROWTYPE;
    prior pgreact_internal.shared_condition_versions%ROWTYPE;
    source_oid oid;
    row_type_oid oid;
    relation_version uuid;
    program_version uuid;
    condition_version uuid := gen_random_uuid();
    target_version integer;
    actual_plan_digest text;
    program_definition jsonb;
    program_preview jsonb;
    program_name text;
    mode text;
    keys name[];
    key_types regtype[];
    key_collations regcollation[];
    source_definition text;
    source_signature bytea;
    source_digest bytea;
    condition_owner oid := (SELECT oid FROM pg_roles WHERE rolname = session_user);
    incompatible boolean := false;
    consumer_count bigint;
    has_prior boolean := false;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(
        COALESCE(definition ->> 'name', 'condition'), 5788046901200004));
    preview := pgreact_api.preview_shared_condition(definition);
    normalized := preview -> 'condition';
    target_version := (normalized ->> 'version')::integer;
    actual_plan_digest := preview ->> 'plan_digest';
    IF expected_plan_digest IS NOT NULL AND expected_plan_digest <> actual_plan_digest THEN
        RAISE EXCEPTION 'M20_CONDITION_PREVIEW_STALE'
            USING HINT = 'Preview the shared condition again after source or deployment changes.';
    END IF;
    SELECT * INTO condition_row
    FROM pgreact_internal.shared_conditions
    WHERE condition_name = normalized ->> 'name'
    FOR UPDATE;
    IF FOUND AND condition_row.owner_oid <> condition_owner THEN
        RAISE EXCEPTION 'M20_CONDITION_OWNER: % is not owned by %',
            normalized ->> 'name', session_user;
    END IF;
    IF NOT FOUND THEN
        INSERT INTO pgreact_internal.shared_conditions(condition_id, condition_name, owner_oid)
        VALUES (condition_version, normalized ->> 'name', condition_owner)
        RETURNING * INTO condition_row;
        relation_version := pgreact_api.declare_derived_relation(
            normalized ->> 'name', (normalized ->> 'row_type')::regtype,
            pgreact_internal.condition_keys(normalized), 1);
        EXECUTE format('ALTER VIEW %s OWNER TO %I',
                       normalized ->> 'name', session_user);
    ELSE
        has_prior := true;
        SELECT * INTO STRICT prior
        FROM pgreact_internal.shared_condition_versions
        WHERE condition_id = condition_row.condition_id AND state = 'ACTIVE'
        FOR UPDATE;
        PERFORM pgreact_internal.refresh_shared_condition_consumers(prior.condition_version_id);
        SELECT count(*) INTO consumer_count
        FROM pgreact_internal.shared_condition_consumers
        WHERE condition_version_id = prior.condition_version_id;
        source_oid := to_regclass(normalized ->> 'source');
        row_type_oid := (normalized ->> 'row_type')::regtype;
        keys := pgreact_internal.condition_keys(normalized);
        SELECT array_agg(attribute.atttypid::regtype ORDER BY key.ordinality),
               array_agg(attribute.attcollation::regcollation ORDER BY key.ordinality)
        INTO key_types, key_collations
        FROM unnest(keys) WITH ORDINALITY key(key_name, ordinality)
        JOIN pg_attribute attribute
          ON attribute.attrelid = (SELECT typrelid FROM pg_type WHERE oid = row_type_oid)
         AND attribute.attname = key.key_name
         AND attribute.attnum > 0 AND NOT attribute.attisdropped;
        incompatible := prior.row_type_oid <> row_type_oid
            OR prior.key_columns <> keys
            OR prior.key_types <> key_types
            OR prior.key_collations <> key_collations
            OR prior.maintenance_mode <> upper(COALESCE(normalized ->> 'maintenance_mode', 'SCHEDULED'))
            OR prior.source_row_signature <> pgreact_internal.source_row_signature(source_oid);
        IF incompatible AND consumer_count > 0 THEN
            RAISE EXCEPTION 'M20_INCOMPATIBLE_REPLACEMENT: % has live consumers',
                normalized ->> 'name'
                USING HINT = 'Deploy a compatible schema or remove/replace every consumer atomically.';
        END IF;
        relation_version := prior.relation_version_id;
    END IF;
    source_oid := to_regclass(normalized ->> 'source');
    row_type_oid := (normalized ->> 'row_type')::regtype;
    keys := pgreact_internal.condition_keys(normalized);
    SELECT array_agg(attribute.atttypid::regtype ORDER BY key.ordinality),
           array_agg(attribute.attcollation::regcollation ORDER BY key.ordinality)
    INTO key_types, key_collations
    FROM unnest(keys) WITH ORDINALITY key(key_name, ordinality)
    JOIN pg_attribute attribute
      ON attribute.attrelid = (SELECT typrelid FROM pg_type WHERE oid = row_type_oid)
     AND attribute.attname = key.key_name
     AND attribute.attnum > 0 AND NOT attribute.attisdropped;
    source_definition := COALESCE(pg_get_viewdef(source_oid, true), source_oid::regclass::text);
    source_signature := pgreact_internal.source_row_signature(source_oid);
    source_digest := pgreact_internal.source_closure_digest(source_oid);
    mode := upper(COALESCE(normalized ->> 'maintenance_mode', 'SCHEDULED'));
    program_definition := pgreact_internal.condition_program(normalized, target_version);
    program_name := program_definition ->> 'name';
    IF mode = 'IMMEDIATE' THEN
        program_preview := pgreact_api.preview_immediate_program(program_definition);
        program_version := pgreact_api.deploy_immediate_program(
            program_definition, program_preview ->> 'plan_digest');
    ELSE
        program_preview := pgreact_api.preview_program(program_definition);
        program_version := pgreact_api.deploy_program(
            program_definition, program_preview ->> 'plan_digest');
    END IF;
    IF has_prior THEN
        UPDATE pgreact_internal.shared_condition_versions
        SET state = 'REMOVED'
        WHERE condition_version_id = prior.condition_version_id;
    END IF;
    INSERT INTO pgreact_internal.shared_condition_versions(
        condition_version_id, condition_id, version, owner_oid,
        source_view_oid, source_view_name, source_definition,
        source_definition_digest, source_row_signature, row_type_oid,
        row_type_name, key_columns, key_types, key_collations,
        relation_version_id, program_version_id, maintenance_mode, state)
    SELECT condition_version, condition_row.condition_id, target_version, condition_owner,
           source_oid, source_oid::regclass::text, source_definition,
           source_digest, source_signature,
           row_type_oid, normalized ->> 'row_type',
           keys, key_types, key_collations, relation_version, program_version,
           mode, 'ACTIVE';
    PERFORM pgreact_internal.refresh_shared_condition_consumers(condition_version);
    RETURN condition_version;
END
$$;

CREATE FUNCTION pgreact_api.register_shared_condition_consumer(
    condition_name text,
    consumer_kind text,
    consumer_name text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    condition_version pgreact_internal.shared_condition_versions%ROWTYPE;
    consumer_version uuid;
    consumer_owner oid;
    normalized_kind text := upper(consumer_kind);
    target_relation uuid;
BEGIN
    SELECT version.* INTO STRICT condition_version
    FROM pgreact_internal.shared_conditions condition
    JOIN pgreact_internal.shared_condition_versions version USING (condition_id)
    WHERE condition.condition_name = register_shared_condition_consumer.condition_name
      AND version.state = 'ACTIVE';
    PERFORM pgreact_internal.refresh_shared_condition_consumers(condition_version.condition_version_id);
    IF normalized_kind = 'RULE' THEN
        SELECT version.rule_version_id, version.owner_oid INTO consumer_version, consumer_owner
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        WHERE rule.rule_name = consumer_name AND version.state IN ('ACTIVE', 'PAUSED')
        ORDER BY version.created_at DESC LIMIT 1;
        IF consumer_version IS NULL THEN
            RAISE EXCEPTION 'M20_CONSUMER_NOT_FOUND: rule %', consumer_name;
        END IF;
        IF NOT EXISTS (
            SELECT 1
            FROM pgreact_internal.rule_versions version
            LEFT JOIN pgreact_internal.keyed_rule_versions keyed
              ON keyed.rule_version_id = version.rule_version_id
            WHERE version.rule_version_id = consumer_version
              AND (version.source_view_oid = register_shared_condition_consumer.condition_name::regclass
                   OR keyed.public_condition = (
                       register_shared_condition_consumer.condition_name::regclass))) THEN
            RAISE EXCEPTION 'M20_CONSUMER_DEPENDENCY: rule % does not consume %',
                consumer_name, condition_name;
        END IF;
    ELSIF normalized_kind = 'PROGRAM' THEN
        SELECT version.program_version_id, version.owner_oid INTO consumer_version, consumer_owner
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = consumer_name AND version.state = 'ACTIVE';
        IF consumer_version IS NULL THEN
            RAISE EXCEPTION 'M20_CONSUMER_NOT_FOUND: program %', consumer_name;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pgreact_internal.derivation_program_inputs input
            WHERE input.program_version_id = consumer_version
              AND input.relation_version_id = condition_version.relation_version_id) THEN
            RAISE EXCEPTION 'M20_CONSUMER_DEPENDENCY: program % does not consume %',
                consumer_name, condition_name;
        END IF;
    ELSE
        RAISE EXCEPTION 'M20_CONSUMER_KIND: use RULE or PROGRAM';
    END IF;
    IF consumer_owner <> (SELECT oid FROM pg_roles WHERE rolname = session_user) THEN
        RAISE EXCEPTION 'M20_CONSUMER_OWNER: % does not own %', session_user, consumer_name;
    END IF;
    IF condition_version.maintenance_mode = 'IMMEDIATE' AND (
        (normalized_kind = 'RULE' AND EXISTS (
            SELECT 1 FROM pgreact_internal.rule_versions version
            WHERE version.rule_version_id = consumer_version
              AND version.maintenance_mode <> 'IMMEDIATE'))
        OR (normalized_kind = 'PROGRAM' AND EXISTS (
            SELECT 1 FROM pgreact_internal.derivation_program_versions version
            WHERE version.program_version_id = consumer_version
              AND version.maintenance_mode <> 'IMMEDIATE'))
    ) THEN
        RAISE EXCEPTION 'M20_IMMEDIATE_CLOSURE: % must consume % in IMMEDIATE mode',
            consumer_name, condition_name
            USING HINT = 'Deploy the complete consumer closure with the M19 immediate capability contract.';
    END IF;
    EXECUTE format('GRANT SELECT ON %s TO %I',
                   condition_name::regclass, session_user);
    INSERT INTO pgreact_internal.shared_condition_consumers(
        condition_version_id, consumer_kind, consumer_name,
        consumer_version_id, owner_oid)
    VALUES (condition_version.condition_version_id, normalized_kind,
            consumer_name, consumer_version, consumer_owner)
    ON CONFLICT ON CONSTRAINT shared_condition_consumers_pkey DO UPDATE
    SET consumer_version_id = EXCLUDED.consumer_version_id,
        owner_oid = EXCLUDED.owner_oid,
        registered_at = clock_timestamp();
END
$$;

CREATE FUNCTION pgreact_api.grant_shared_condition_reader(
    condition_name text,
    reader_role regrole
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    condition_id uuid;
    owner_oid oid;
BEGIN
    SELECT condition.condition_id, condition.owner_oid INTO STRICT condition_id, owner_oid
    FROM pgreact_internal.shared_conditions condition
    WHERE condition.condition_name = grant_shared_condition_reader.condition_name;
    IF owner_oid <> (SELECT oid FROM pg_roles WHERE rolname = session_user) THEN
        RAISE EXCEPTION 'M20_CONDITION_OWNER: % is not owned by %', condition_name, session_user;
    END IF;
    EXECUTE format('GRANT SELECT ON %s TO %I', condition_name::regclass, reader_role::text);
    INSERT INTO pgreact_internal.shared_condition_grants(condition_id, role_oid)
    VALUES (condition_id, reader_role::oid)
    ON CONFLICT DO NOTHING;
END
$$;

CREATE FUNCTION pgreact_api.remove_shared_condition(condition_name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    condition_row pgreact_internal.shared_conditions%ROWTYPE;
    version_row pgreact_internal.shared_condition_versions%ROWTYPE;
    consumers bigint;
BEGIN
    SELECT condition.* INTO STRICT condition_row
    FROM pgreact_internal.shared_conditions condition
    WHERE condition.condition_name = remove_shared_condition.condition_name FOR UPDATE;
    IF condition_row.owner_oid <> (SELECT oid FROM pg_roles WHERE rolname = session_user) THEN
        RAISE EXCEPTION 'M20_CONDITION_OWNER: % is not owned by %', condition_name, session_user;
    END IF;
    SELECT * INTO STRICT version_row FROM pgreact_internal.shared_condition_versions
    WHERE condition_id = condition_row.condition_id AND state = 'ACTIVE' FOR UPDATE;
    PERFORM pgreact_internal.refresh_shared_condition_consumers(version_row.condition_version_id);
    SELECT count(*) INTO consumers FROM pgreact_internal.shared_condition_consumers
    WHERE condition_version_id = version_row.condition_version_id;
    IF consumers > 0 THEN
        RAISE EXCEPTION 'M20_CONDITION_IN_USE: % has % active consumers', condition_name, consumers
            USING HINT = 'Remove or replace consumers before removing the shared condition.';
    END IF;
    PERFORM pgreact_api.remove_program(
        '__pgreact.condition.' || condition_name, version_row.version);
    EXECUTE format('DROP VIEW %s', condition_name::regclass);
    DELETE FROM pgreact_internal.keyed_derived_relations
    WHERE relation_version_id = version_row.relation_version_id;
    UPDATE pgreact_internal.derived_relation_versions
    SET state = 'REMOVED'
    WHERE relation_version_id = version_row.relation_version_id;
    UPDATE pgreact_internal.shared_condition_versions
    SET state = 'REMOVED'
    WHERE condition_version_id = version_row.condition_version_id;
END
$$;

CREATE FUNCTION pgreact_api.reconcile_shared_condition(condition_name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE target_program uuid;
BEGIN
    SELECT version.program_version_id INTO STRICT target_program
    FROM pgreact_internal.shared_conditions condition
    JOIN pgreact_internal.shared_condition_versions version USING (condition_id)
    WHERE condition.condition_name = reconcile_shared_condition.condition_name
      AND version.state = 'ACTIVE';
    RETURN pgreact.reconcile_derivation_program(target_program);
EXCEPTION WHEN no_data_found THEN
    RAISE EXCEPTION 'M20_CONDITION_NOT_ACTIVE: %', condition_name
        USING HINT = 'Name an active shared condition.';
END
$$;

CREATE FUNCTION pgreact_api.shared_condition_cost(condition_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    relation_name text;
    relation_version uuid;
    rows bigint;
    consumers bigint;
BEGIN
    SELECT keyed.public_name, version.relation_version_id
    INTO STRICT relation_name, relation_version
    FROM pgreact_internal.shared_conditions condition
    JOIN pgreact_internal.shared_condition_versions version USING (condition_id)
    JOIN pgreact_internal.keyed_derived_relations keyed
      ON keyed.relation_version_id = version.relation_version_id
    WHERE condition.condition_name = shared_condition_cost.condition_name
      AND version.state = 'ACTIVE';
    EXECUTE format('SELECT count(*) FROM %s', relation_name::regclass) INTO rows;
    SELECT count(*) INTO consumers FROM pgreact_internal.shared_condition_consumers
    WHERE condition_version_id = (
        SELECT condition_version_id FROM pgreact_internal.shared_condition_versions
        WHERE relation_version_id = relation_version AND state = 'ACTIVE');
    RETURN jsonb_build_object(
        'condition', condition_name, 'rows', rows, 'consumers', consumers,
        'fan_out_limit', 1000,
        'admission', CASE WHEN consumers <= 1000 THEN 'accepted' ELSE 'rejected' END);
END
$$;

CREATE FUNCTION pgreact_api.shared_condition_status(condition_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb;
BEGIN
    IF condition_name IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pgreact_internal.shared_conditions
        WHERE shared_conditions.condition_name = shared_condition_status.condition_name) THEN
        RAISE EXCEPTION 'M20_CONDITION_NOT_FOUND: %', condition_name;
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'condition', condition.condition_name,
        'version', version.version,
        'owner', pg_get_userbyid(condition.owner_oid),
        'source', version.source_view_name,
        'relation', keyed.public_name,
        'row_type', version.row_type_name,
        'key', CASE WHEN cardinality(version.key_columns) = 1
                    THEN to_jsonb(version.key_columns[1])
                    ELSE to_jsonb(version.key_columns) END,
        'maintenance_mode', version.maintenance_mode,
        'state', lower(version.state),
        'drift', version.source_view_oid IS NULL
            OR pgreact_internal.source_closure_digest(version.source_view_oid)
               IS DISTINCT FROM version.source_definition_digest,
        'frontier', COALESCE(program.frontier, 0),
        'consumers', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'kind', lower(consumer.consumer_kind),
                'name', consumer.consumer_name,
                'version_id', consumer.consumer_version_id)
                ORDER BY consumer.consumer_kind, consumer.consumer_name)
            FROM pgreact_internal.shared_condition_consumers consumer
            WHERE consumer.condition_version_id = version.condition_version_id), '[]'::jsonb),
        'cost', CASE WHEN version.state = 'ACTIVE'
                     THEN pgreact_api.shared_condition_cost(condition.condition_name)
                     ELSE jsonb_build_object('admission', 'removed') END
    ) ORDER BY condition.condition_name)
    INTO result
    FROM pgreact_internal.shared_conditions condition
    JOIN LATERAL (
        SELECT version.* FROM pgreact_internal.shared_condition_versions version
        WHERE version.condition_id = condition.condition_id
        ORDER BY (version.state = 'ACTIVE') DESC, version.version DESC LIMIT 1
    ) version ON true
    LEFT JOIN pgreact_internal.keyed_derived_relations keyed
      ON keyed.relation_version_id = version.relation_version_id
    LEFT JOIN pgreact_internal.derivation_program_versions program
      ON program.program_version_id = version.program_version_id
    WHERE shared_condition_status.condition_name IS NULL
       OR condition.condition_name = shared_condition_status.condition_name;
    RETURN jsonb_build_object('contract_version', 8, 'conditions', COALESCE(result, '[]'::jsonb));
END
$$;

CREATE FUNCTION pgreact_api.shared_condition_matches(condition_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_name text;
    result jsonb;
BEGIN
    SELECT keyed.public_name INTO STRICT relation_name
    FROM pgreact_internal.shared_conditions condition
    JOIN pgreact_internal.shared_condition_versions version USING (condition_id)
    JOIN pgreact_internal.keyed_derived_relations keyed
      ON keyed.relation_version_id = version.relation_version_id
    WHERE condition.condition_name = shared_condition_matches.condition_name
      AND version.state = 'ACTIVE';
    IF NOT has_table_privilege(session_user, relation_name::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'M20_CONDITION_FORBIDDEN: %', condition_name;
    END IF;
    EXECUTE format(
        'SELECT jsonb_build_object(''contract_version'', 8, ''condition'', %L, ''matches'', '
        'COALESCE(jsonb_agg(to_jsonb(value) ORDER BY to_jsonb(value)::text), ''[]''::jsonb)) FROM %s value',
        condition_name, relation_name::regclass) INTO result;
    RETURN result;
END
$$;

ALTER FUNCTION pgreact_api.status(text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.status(text) RENAME TO status_m19;
ALTER FUNCTION pgreact_api.explain(text, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.explain(text, jsonb) RENAME TO explain_m19;
ALTER FUNCTION pgreact_api.doctor() SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.doctor() RENAME TO doctor_m19;
ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m19;

CREATE FUNCTION pgreact_api.status(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb;
BEGIN
    IF EXISTS (SELECT 1 FROM pgreact_internal.shared_conditions
               WHERE condition_name = name) THEN
        RETURN pgreact_api.shared_condition_status(name);
    END IF;
    result := pgreact_internal.status_m19(name);
    IF name IS NULL AND EXISTS (SELECT 1 FROM pgreact_internal.shared_conditions) THEN
        result := jsonb_set(result, '{conditions}',
            pgreact_api.shared_condition_status() -> 'conditions', true);
        result := jsonb_set(result, '{contract_version}', '8'::jsonb, true);
    END IF;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_api.explain(target text, semantic_key jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb;
    condition_version uuid;
BEGIN
    result := pgreact_internal.explain_m19(target, semantic_key);
    SELECT version.condition_version_id INTO condition_version
    FROM pgreact_internal.shared_conditions condition
    JOIN pgreact_internal.shared_condition_versions version USING (condition_id)
    JOIN pgreact_internal.keyed_derived_relations keyed
      ON keyed.relation_version_id = version.relation_version_id
    WHERE keyed.public_name = target AND version.state = 'ACTIVE';
    IF condition_version IS NOT NULL THEN
        result := result || jsonb_build_object(
            'contract_version', 8,
            'shared_condition', jsonb_build_object(
                'name', target, 'version',
                (SELECT version FROM pgreact_internal.shared_condition_versions
                 WHERE condition_version_id = condition_version),
                'boundary', 'named shared condition'));
    END IF;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_api.shared_condition_explain(
    condition_name text,
    semantic_key jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_name text;
    result jsonb;
BEGIN
    SELECT keyed.public_name INTO STRICT relation_name
    FROM pgreact_internal.shared_conditions condition
    JOIN pgreact_internal.shared_condition_versions version USING (condition_id)
    JOIN pgreact_internal.keyed_derived_relations keyed
      ON keyed.relation_version_id = version.relation_version_id
    WHERE condition.condition_name = shared_condition_explain.condition_name
      AND version.state = 'ACTIVE';
    IF NOT has_table_privilege(session_user, relation_name::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'M20_CONDITION_FORBIDDEN: %', condition_name;
    END IF;
    result := pgreact_internal.explain_m19(relation_name, semantic_key);
    RETURN result || jsonb_build_object(
        'contract_version', 8,
        'shared_condition', jsonb_build_object(
            'name', condition_name, 'boundary', 'named shared condition'));
END
$$;

CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb;
    diagnostics jsonb;
BEGIN
    result := pgreact_internal.doctor_m19();
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.ordinality), '[]'::jsonb)
    INTO diagnostics
    FROM jsonb_array_elements(COALESCE(result -> 'diagnostics', '[]'::jsonb))
         WITH ORDINALITY item
    WHERE item.value ->> 'code' <> 'M19_EXTENSION_VERSION';
    diagnostics := diagnostics || CASE WHEN EXISTS (
        SELECT 1 FROM pg_extension
        WHERE extname = 'pg_react' AND extversion = '0.17.0')
        THEN '[]'::jsonb ELSE jsonb_build_array(jsonb_build_object(
            'code', 'M20_EXTENSION_VERSION', 'severity', 'ERROR',
            'object_identity', 'pg_react',
            'message', 'pg_react extension version is not 0.17.0',
            'hint', 'Install matching files and run ALTER EXTENSION pg_react UPDATE.')) END;
    diagnostics := diagnostics || COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'code', 'M20_CONDITION_DRIFT', 'severity', 'ERROR',
            'object_identity', condition.condition_name,
            'message', 'shared condition source definition has drifted',
            'hint', 'Reconcile or replace the shared condition through the public API.')
        )
        FROM pgreact_internal.shared_conditions condition
        JOIN pgreact_internal.shared_condition_versions version USING (condition_id)
        WHERE version.state = 'ACTIVE'
          AND (version.source_view_oid IS NULL
               OR pgreact_internal.source_closure_digest(version.source_view_oid)
                  IS DISTINCT FROM version.source_definition_digest)), '[]'::jsonb);
    result := jsonb_set(result, '{diagnostics}', diagnostics, true);
    result := jsonb_set(result, '{status}', CASE WHEN EXISTS (
        SELECT 1 FROM jsonb_array_elements(diagnostics) item
        WHERE item ->> 'severity' = 'ERROR')
        THEN '"attention"'::jsonb ELSE '"ready"'::jsonb END, true);
    IF EXISTS (SELECT 1 FROM pgreact_internal.shared_conditions) THEN
        result := jsonb_set(result, '{contract_version}', '8'::jsonb, true);
    END IF;
    RETURN result;
END
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
BEGIN
    PERFORM pgreact_internal.configure_roles_m19(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.validate_shared_condition(jsonb), '
        'pgreact_api.preview_shared_condition(jsonb), '
        'pgreact_api.deploy_shared_condition(jsonb,text), '
        'pgreact_api.register_shared_condition_consumer(text,text,text), '
        'pgreact_api.grant_shared_condition_reader(text,regrole), '
        'pgreact_api.remove_shared_condition(text), '
        'pgreact_api.reconcile_shared_condition(text) TO %I', author_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.status(text), '
        'pgreact_api.shared_condition_status(text), '
        'pgreact_api.shared_condition_cost(text), '
        'pgreact_api.shared_condition_matches(text), '
        'pgreact_api.shared_condition_explain(text,jsonb), '
        'pgreact_api.explain(text,jsonb), pgreact_api.doctor() TO %I', reader_role::text);
END
$$;

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

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M20 explicit versioned shared conditions over the durable rule and derivation engine';
