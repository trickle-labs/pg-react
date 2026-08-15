-- M25 parameterized policy families. Parameters remain ordinary PostgreSQL
-- rows; the consuming condition or program owns the relational join.

CREATE TABLE pgreact_internal.parameter_families (
    family_id uuid PRIMARY KEY,
    family_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    parameter_relation_oid oid NOT NULL,
    parameter_relation_name text NOT NULL,
    parameter_key_column name NOT NULL,
    parameter_value_columns name[] NOT NULL CHECK (cardinality(parameter_value_columns) > 0),
    parameter_value_types jsonb NOT NULL,
    source_signature bytea NOT NULL,
    state text NOT NULL DEFAULT 'ACTIVE' CHECK (state IN ('ACTIVE', 'REMOVED')),
    max_rows integer NOT NULL DEFAULT 100000 CHECK (max_rows > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.parameter_family_consumers (
    family_id uuid NOT NULL REFERENCES pgreact_internal.parameter_families,
    policy_version_id uuid NOT NULL REFERENCES pgreact_internal.effective_policy_versions,
    bound_by oid NOT NULL,
    bound_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (family_id, policy_version_id)
);

CREATE TABLE pgreact_internal.parameter_family_editors (
    family_id uuid NOT NULL REFERENCES pgreact_internal.parameter_families ON DELETE CASCADE,
    role_oid oid NOT NULL,
    granted_by oid NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (family_id, role_oid)
);

CREATE TABLE pgreact_internal.parameter_family_events (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    family_id uuid NOT NULL REFERENCES pgreact_internal.parameter_families,
    policy_version_id uuid REFERENCES pgreact_internal.effective_policy_versions,
    event_kind text NOT NULL CHECK (event_kind IN (
        'FAMILY_CREATED', 'CONSUMER_BOUND', 'EDITOR_GRANTED', 'EDITOR_REVOKED',
        'PARAMETER_CHANGED', 'DEFINITION_REPLACED')),
    parameter_key bigint,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX parameter_family_consumer_policy_idx
    ON pgreact_internal.parameter_family_consumers (policy_version_id);

CREATE INDEX parameter_family_event_idx
    ON pgreact_internal.parameter_family_events (family_id, occurred_at, event_id);

CREATE VIEW pgreact.parameter_families AS
SELECT family.family_id,
       family.family_name,
       pg_get_userbyid(family.owner_oid) AS owner,
       family.parameter_relation_oid::regclass AS parameter_relation,
       family.parameter_key_column,
       family.parameter_value_columns,
       family.parameter_value_types,
       family.state,
       family.max_rows,
       family.source_signature,
       (SELECT count(*) FROM pgreact_internal.parameter_family_consumers consumer
        WHERE consumer.family_id = family.family_id) AS consumer_count,
       family.created_at
FROM pgreact_internal.parameter_families family
WHERE family.state = 'ACTIVE';

CREATE VIEW pgreact.parameter_family_consumers AS
SELECT consumer.family_id,
       family.family_name,
       consumer.policy_version_id,
       policy.policy_name,
       version.target_kind,
       version.rule_version_id,
       version.program_version_id,
       consumer.bound_at
FROM pgreact_internal.parameter_family_consumers consumer
JOIN pgreact_internal.parameter_families family USING (family_id)
JOIN pgreact_internal.effective_policy_versions version USING (policy_version_id)
JOIN pgreact_internal.effective_policies policy USING (policy_id);

CREATE FUNCTION pgreact_internal.parameter_family_project(target_family_id uuid, row_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    column_name name;
    projected jsonb := '{}'::jsonb;
BEGIN
    IF row_data IS NULL THEN RETURN NULL; END IF;
    SELECT * INTO STRICT family_row FROM pgreact_internal.parameter_families
    WHERE family_id = target_family_id AND state = 'ACTIVE';
    FOREACH column_name IN ARRAY ARRAY[family_row.parameter_key_column] || family_row.parameter_value_columns LOOP
        projected := projected || jsonb_build_object(column_name::text, row_data -> (column_name::text));
    END LOOP;
    RETURN projected;
END
$m25$;

CREATE FUNCTION pgreact_internal.parameter_family_editor_allowed(target_family_id uuid)
RETURNS boolean
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
    SELECT EXISTS (
        SELECT 1
        FROM pgreact_internal.parameter_families family
        WHERE family.family_id = $1
          AND pg_has_role(session_user, family.owner_oid, 'USAGE')
    )
    OR EXISTS (
        SELECT 1
        FROM pgreact_internal.parameter_family_editors editor
        WHERE editor.family_id = $1
          AND pg_has_role(session_user, editor.role_oid, 'USAGE')
    )
    OR pgreact_internal.is_operator_admin()
$m25$;

CREATE FUNCTION pgreact_internal.parameter_family_dml_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE target_family_id uuid := TG_ARGV[0]::uuid;
    parameter_key bigint;
    values jsonb;
BEGIN
    IF NOT pgreact_internal.parameter_family_editor_allowed(target_family_id) THEN
        RAISE EXCEPTION 'M25_PARAMETER_EDITOR_FORBIDDEN: % cannot change parameter family %',
            session_user, target_family_id USING ERRCODE = '42501';
    END IF;
    IF TG_OP <> 'DELETE' THEN
        values := to_jsonb(NEW);
        parameter_key := (values ->> (SELECT parameter_key_column::text
            FROM pgreact_internal.parameter_families WHERE parameter_families.family_id = target_family_id))::bigint;
    ELSE
        values := to_jsonb(OLD);
        parameter_key := (values ->> (SELECT parameter_key_column::text
            FROM pgreact_internal.parameter_families WHERE parameter_families.family_id = target_family_id))::bigint;
    END IF;
    INSERT INTO pgreact_internal.parameter_family_events(
        family_id, event_kind, parameter_key, details)
    VALUES (
        target_family_id, 'PARAMETER_CHANGED', parameter_key,
        jsonb_build_object('operation', TG_OP,
                           'old', CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE
                               pgreact_internal.parameter_family_project(target_family_id, to_jsonb(OLD)) END,
                           'new', CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE
                               pgreact_internal.parameter_family_project(target_family_id, to_jsonb(NEW)) END));
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END
$m25$;

CREATE FUNCTION pgreact_internal.parameter_family_ddl_guard()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.parameter_families family
        WHERE family.state = 'ACTIVE'
          AND NOT EXISTS (
              SELECT 1
              FROM pg_trigger trigger_row
              WHERE trigger_row.tgrelid = family.parameter_relation_oid
                AND trigger_row.tgname = 'pgreact_parameter_family_guard'
                AND trigger_row.tgenabled = 'O'
                AND trigger_row.tgfoid = 'pgreact_internal.parameter_family_dml_guard()'::regprocedure
                AND trigger_row.tgtype = 29
                AND trigger_row.tgconstraint <> 0
                AND trigger_row.tgdeferrable
                AND trigger_row.tginitdeferred))
    THEN
        RAISE EXCEPTION 'M25_PARAMETER_GUARD: an active parameter family has no enabled guard trigger';
    END IF;
END
$m25$;

CREATE EVENT TRIGGER pgreact_parameter_family_ddl_guard
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE', 'ALTER TRIGGER', 'DROP TABLE', 'DROP TRIGGER')
    EXECUTE FUNCTION pgreact_internal.parameter_family_ddl_guard();

CREATE FUNCTION pgreact_internal.validate_parameter_family(
    target_family_name text,
    target_relation regclass,
    target_key_column name,
    target_value_columns name[]
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
AS $m25$
DECLARE relation_row record;
    key_row record;
    value_name name;
    value_row record;
    value_types jsonb := '[]'::jsonb;
    duplicate_name name;
    unique_key boolean;
BEGIN
    IF target_family_name IS NULL OR btrim(target_family_name) = '' THEN
        RETURN QUERY SELECT 13, 'M25_FAMILY_NAME', 'ERROR', '<unnamed>',
            'parameter family name must not be empty',
            'Choose one stable family identity.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT c.relkind, c.relowner, c.relrowsecurity, c.relnamespace,
           n.nspname, c.relname
    INTO relation_row
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = target_relation;
    IF NOT FOUND OR relation_row.relkind NOT IN ('r', 'p') THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_RELATION', 'ERROR', target_relation::text,
            'parameter source must be an ordinary table or partitioned table',
            'Use a PostgreSQL table owned by the parameter author.', '{}'::jsonb;
        RETURN;
    END IF;
    IF relation_row.relrowsecurity THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_RLS', 'ERROR', target_relation::text,
            'row-level security is not supported for a parameter source',
            'Use a private table with ordinary grants and no row-level security policy.', '{}'::jsonb;
        RETURN;
    END IF;
    IF NOT pg_has_role(session_user, relation_row.relowner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_OWNER', 'ERROR', target_relation::text,
            'the parameter source must be owned by the author',
            'Use the table owner or the configured operator role.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT a.attnum, a.atttypid, a.attnotnull, a.attgenerated
    INTO key_row
    FROM pg_attribute a
    WHERE a.attrelid = target_relation AND a.attname = target_key_column
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF NOT FOUND THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_KEY', 'ERROR', target_relation::text,
            format('parameter key column %I does not exist', target_key_column),
            'Declare one existing, non-null bigint key column.', '{}'::jsonb;
        RETURN;
    END IF;
    IF key_row.atttypid <> 'int8'::regtype OR NOT key_row.attnotnull OR key_row.attgenerated <> '' THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_KEY_TYPE', 'ERROR', target_relation::text,
            'the parameter key must be a stored NOT NULL bigint column',
            'Use bigint PRIMARY KEY or a bigint UNIQUE NOT NULL key.',
            jsonb_build_object('column', target_key_column,
                               'type', format_type(key_row.atttypid, NULL),
                               'not_null', key_row.attnotnull);
        RETURN;
    END IF;
    SELECT EXISTS (
        SELECT 1
        FROM pg_index i
        WHERE i.indrelid = target_relation AND i.indisunique
          AND i.indpred IS NULL AND i.indexprs IS NULL
          AND (SELECT count(*) FROM unnest(i.indkey) k) = 1
          AND i.indkey[0] = key_row.attnum
    ) INTO unique_key;
    IF NOT unique_key THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_KEY_UNIQUE', 'ERROR', target_relation::text,
            'the parameter key must have a non-partial unique constraint or index',
            'Make the bigint key the table primary key or add a single-column UNIQUE constraint.', '{}'::jsonb;
        RETURN;
    END IF;
    IF target_value_columns IS NULL OR cardinality(target_value_columns) = 0 THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_VALUES', 'ERROR', target_relation::text,
            'at least one required parameter value column is needed',
            'Declare the typed columns that the condition view consumes.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT value FROM unnest(target_value_columns) value
    GROUP BY value HAVING count(*) > 1 LIMIT 1 INTO duplicate_name;
    IF duplicate_name IS NOT NULL OR target_key_column = ANY(target_value_columns) THEN
        RETURN QUERY SELECT 13, 'M25_PARAMETER_COLUMNS', 'ERROR', target_relation::text,
            'parameter key and value columns must be distinct',
            'List each projected column once and omit the key from the value list.', '{}'::jsonb;
        RETURN;
    END IF;
    FOREACH value_name IN ARRAY target_value_columns LOOP
        SELECT a.atttypid, a.attnotnull, a.attgenerated
        INTO value_row
        FROM pg_attribute a
        WHERE a.attrelid = target_relation AND a.attname = value_name
          AND a.attnum > 0 AND NOT a.attisdropped;
        IF NOT FOUND THEN
            RETURN QUERY SELECT 13, 'M25_PARAMETER_VALUE_COLUMN', 'ERROR', target_relation::text,
                format('parameter value column %I does not exist', value_name),
                'Declare only existing scalar PostgreSQL columns.', '{}'::jsonb;
            RETURN;
        END IF;
        IF value_row.attgenerated <> '' OR NOT value_row.attnotnull OR value_row.atttypid NOT IN (
            'bool'::regtype, 'int2'::regtype, 'int4'::regtype, 'int8'::regtype,
            'numeric'::regtype, 'text'::regtype, 'varchar'::regtype, 'uuid'::regtype,
            'date'::regtype, 'timestamp'::regtype, 'timestamptz'::regtype
        ) THEN
            RETURN QUERY SELECT 13, 'M25_PARAMETER_VALUE_TYPE', 'ERROR', target_relation::text,
                format('parameter value column %I must be a required supported scalar type', value_name),
                'Use NOT NULL boolean, integer, numeric, text, uuid, date, timestamp, or timestamptz columns.',
                jsonb_build_object('column', value_name,
                                   'type', format_type(value_row.atttypid, NULL),
                                   'not_null', value_row.attnotnull);
            RETURN;
        END IF;
        value_types := value_types || jsonb_build_array(jsonb_build_object(
            'column', value_name, 'type', format_type(value_row.atttypid, NULL)));
    END LOOP;
    RETURN QUERY SELECT 13, 'OK', 'INFO', target_family_name,
        'typed parameter family declaration is valid',
        'Join the ordinary parameter relation from each consuming condition or program input.',
        jsonb_build_object('parameter_relation', target_relation::text,
                           'key_column', target_key_column,
                           'value_columns', target_value_columns,
                           'value_types', value_types,
                           'key_codec', 'bigint-v1',
                           'maintenance', 'INHERITED_RELATIONAL_COORDINATOR');
END
$m25$;

CREATE FUNCTION pgreact_api.validate_parameter_family(
    family_name text,
    parameter_relation regclass,
    parameter_key_column name,
    parameter_value_columns name[]
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
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
    SELECT * FROM pgreact_internal.validate_parameter_family($1, $2, $3, $4)
$m25$;

CREATE FUNCTION pgreact_internal.insert_parameter_rows(target_family_id uuid, rows jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    item jsonb;
    inserted bigint := 0;
BEGIN
    IF rows IS NULL THEN RETURN 0; END IF;
    IF jsonb_typeof(rows) <> 'array' THEN
        RAISE EXCEPTION 'M25_PARAMETER_DATA: initial parameter data must be a JSON array'
            USING HINT = 'Pass one object per parameter row, or pass an empty array.';
    END IF;
    SELECT * INTO STRICT family_row FROM pgreact_internal.parameter_families
    WHERE family_id = target_family_id AND state = 'ACTIVE';
    IF NOT pgreact_internal.parameter_family_editor_allowed(target_family_id) THEN
        RAISE EXCEPTION 'M25_PARAMETER_EDITOR_FORBIDDEN: % cannot seed parameter family %',
            session_user, target_family_id USING ERRCODE = '42501';
    END IF;
    FOR item IN SELECT value FROM jsonb_array_elements(rows) LOOP
        IF jsonb_typeof(item) <> 'object' THEN
            RAISE EXCEPTION 'M25_PARAMETER_DATA: every initial parameter row must be a JSON object';
        END IF;
        EXECUTE format(
            'INSERT INTO %s SELECT * FROM jsonb_populate_record(NULL::%s, $1)',
            family_row.parameter_relation_oid::regclass,
            family_row.parameter_relation_oid::regclass)
        USING item;
        inserted := inserted + 1;
    END LOOP;
    RETURN inserted;
END
$m25$;

CREATE FUNCTION pgreact_internal.parameter_family_value(target_family_id uuid, target_key bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    result jsonb;
BEGIN
    SELECT * INTO STRICT family_row FROM pgreact_internal.parameter_families
    WHERE family_id = target_family_id AND state = 'ACTIVE';
    EXECUTE format(
        'SELECT to_jsonb(p) FROM %s p WHERE p.%I = $1',
        family_row.parameter_relation_oid::regclass, family_row.parameter_key_column)
    INTO result USING target_key;
    RETURN pgreact_internal.parameter_family_project(target_family_id, result);
END
$m25$;

CREATE FUNCTION pgreact_internal.register_parameter_family(
    target_family_name text,
    target_relation regclass,
    target_key_column name,
    target_value_columns name[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE diagnostic record;
    family_id uuid := gen_random_uuid();
    owner_id oid := (SELECT oid FROM pg_roles WHERE rolname = session_user);
    value_types jsonb;
    signature bytea;
    row_count bigint;
BEGIN
    SELECT result.* INTO diagnostic
    FROM pgreact_internal.validate_parameter_family(
        target_family_name, target_relation, target_key_column, target_value_columns) result
    WHERE result.severity = 'ERROR'
    ORDER BY result.code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react parameter-family validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.parameter_families
               WHERE family_name = target_family_name AND state = 'ACTIVE') THEN
        RAISE EXCEPTION 'an active parameter family named % already exists', target_family_name;
    END IF;
    SELECT details -> 'value_types' INTO value_types
    FROM pgreact_internal.validate_parameter_family(
        target_family_name, target_relation, target_key_column, target_value_columns)
    WHERE code = 'OK';
    signature := pgreact_internal.source_row_signature(target_relation);
    EXECUTE format('SELECT count(*) FROM %s', target_relation::regclass) INTO row_count;
    IF row_count > 100000 THEN
        RAISE EXCEPTION 'M25_PARAMETER_LIMIT: parameter relation % has % rows; maximum is 100000',
            target_relation, row_count USING HINT = 'Partition or archive parameter data before declaring the family.';
    END IF;
    INSERT INTO pgreact_internal.parameter_families(
        family_id, family_name, owner_oid, parameter_relation_oid,
        parameter_relation_name, parameter_key_column, parameter_value_columns,
        parameter_value_types, source_signature)
    VALUES (
        family_id, target_family_name, owner_id, target_relation,
        target_relation::text, target_key_column, target_value_columns,
        value_types, signature);
    EXECUTE format(
        'CREATE CONSTRAINT TRIGGER pgreact_parameter_family_guard '
        'AFTER INSERT OR UPDATE OR DELETE ON %s DEFERRABLE INITIALLY DEFERRED '
        'FOR EACH ROW EXECUTE FUNCTION pgreact_internal.parameter_family_dml_guard(%L)',
        target_relation::regclass, family_id::text);
    INSERT INTO pgreact_internal.parameter_family_events(family_id, event_kind, details)
    VALUES (family_id, 'FAMILY_CREATED', jsonb_build_object(
        'relation', target_relation::text, 'key_column', target_key_column,
        'value_columns', target_value_columns, 'row_count', row_count));
    RETURN family_id;
END
$m25$;

CREATE FUNCTION pgreact_api.author_parameter_family(
    family_name text,
    parameter_relation regclass,
    parameter_key_column name,
    parameter_value_columns name[]
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
    SELECT pgreact_internal.register_parameter_family($1, $2, $3, $4)
$m25$;

CREATE FUNCTION pgreact_api.grant_parameter_family_editor(family_name text, editor_role regrole)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE target_family_id uuid;
    owner_id oid;
BEGIN
    SELECT family.family_id, family.owner_oid INTO STRICT target_family_id, owner_id
    FROM pgreact_internal.parameter_families family
    WHERE family.family_name = grant_parameter_family_editor.family_name
      AND family.state = 'ACTIVE' FOR UPDATE;
    IF NOT pg_has_role(session_user, owner_id, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M25_PARAMETER_EDITOR_FORBIDDEN: only the family owner or operator may grant an editor'
            USING ERRCODE = '42501';
    END IF;
    INSERT INTO pgreact_internal.parameter_family_editors(family_id, role_oid, granted_by)
    VALUES (target_family_id, editor_role, (SELECT oid FROM pg_roles WHERE rolname = session_user))
    ON CONFLICT (family_id, role_oid) DO NOTHING;
    INSERT INTO pgreact_internal.parameter_family_events(family_id, event_kind, details)
    VALUES (target_family_id, 'EDITOR_GRANTED', jsonb_build_object('role', editor_role::text));
END
$m25$;

CREATE FUNCTION pgreact_api.revoke_parameter_family_editor(family_name text, editor_role regrole)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE target_family_id uuid;
    owner_id oid;
BEGIN
    SELECT family.family_id, family.owner_oid INTO STRICT target_family_id, owner_id
    FROM pgreact_internal.parameter_families family
    WHERE family.family_name = revoke_parameter_family_editor.family_name
      AND family.state = 'ACTIVE' FOR UPDATE;
    IF NOT pg_has_role(session_user, owner_id, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M25_PARAMETER_EDITOR_FORBIDDEN: only the family owner or operator may revoke an editor'
            USING ERRCODE = '42501';
    END IF;
    DELETE FROM pgreact_internal.parameter_family_editors
    WHERE parameter_family_editors.family_id = target_family_id
      AND role_oid = editor_role::oid;
    INSERT INTO pgreact_internal.parameter_family_events(family_id, event_kind, details)
    VALUES (target_family_id, 'EDITOR_REVOKED', jsonb_build_object('role', editor_role::text));
END
$m25$;

CREATE FUNCTION pgreact_internal.bind_parameter_family(
    target_family_name text,
    target_policy_version_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    policy_row record;
BEGIN
    SELECT * INTO STRICT family_row FROM pgreact_internal.parameter_families
    WHERE family_name = target_family_name AND state = 'ACTIVE' FOR UPDATE;
    SELECT version.policy_version_id, version.target_kind, version.rule_version_id,
           version.program_definition, policy.owner_oid, policy.policy_name
    INTO STRICT policy_row
    FROM pgreact_internal.effective_policy_versions version
    JOIN pgreact_internal.effective_policies policy USING (policy_id)
    WHERE version.policy_version_id = target_policy_version_id;
    IF NOT pg_has_role(session_user, family_row.owner_oid, 'USAGE')
       AND NOT pg_has_role(session_user, policy_row.owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M25_PARAMETER_BIND_FORBIDDEN: family or consuming policy owner is required'
            USING ERRCODE = '42501';
    END IF;
    IF policy_row.target_kind = 'RULE' AND NOT EXISTS (
        SELECT 1
        FROM pgreact_internal.rule_versions rule
        JOIN pg_depend dependency
          ON dependency.refclassid = 'pg_class'::regclass
         AND dependency.refobjid = family_row.parameter_relation_oid
         AND ((dependency.classid = 'pg_class'::regclass
               AND dependency.objid = rule.source_view_oid)
              OR (dependency.classid = 'pg_rewrite'::regclass
                  AND dependency.objid = (SELECT oid FROM pg_rewrite
                                          WHERE ev_class = rule.source_view_oid)))
        WHERE rule.rule_version_id = policy_row.rule_version_id
    ) THEN
        RAISE EXCEPTION 'M25_PARAMETER_DEPENDENCY: policy % does not depend directly on parameter relation %',
            policy_row.policy_name, family_row.parameter_relation_name
            USING HINT = 'Bind only a rule or program whose declared input joins the family relation.';
    ELSIF policy_row.target_kind = 'PROGRAM' AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(policy_row.program_definition -> 'rules') rule_item
        JOIN pg_depend dependency
          ON dependency.refclassid = 'pg_class'::regclass
         AND dependency.refobjid = family_row.parameter_relation_oid
         AND (dependency.objid = to_regclass(rule_item ->> 'definition')
              OR EXISTS (SELECT 1 FROM pg_rewrite rewrite
                         WHERE rewrite.oid = dependency.objid
                           AND rewrite.ev_class = to_regclass(rule_item ->> 'definition')))
        WHERE to_regclass(rule_item ->> 'definition') IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'M25_PARAMETER_DEPENDENCY: policy % does not depend directly on parameter relation %',
            policy_row.policy_name, family_row.parameter_relation_name
            USING HINT = 'Bind only a rule or program whose declared input joins the family relation.';
    END IF;
    INSERT INTO pgreact_internal.parameter_family_consumers(family_id, policy_version_id, bound_by)
    VALUES (family_row.family_id, target_policy_version_id,
            (SELECT oid FROM pg_roles WHERE rolname = session_user))
    ON CONFLICT (family_id, policy_version_id) DO NOTHING;
    INSERT INTO pgreact_internal.parameter_family_events(
        family_id, policy_version_id, event_kind, details)
    VALUES (family_row.family_id, target_policy_version_id, 'CONSUMER_BOUND',
            jsonb_build_object('policy', policy_row.policy_name));
END
$m25$;

CREATE FUNCTION pgreact_api.bind_parameter_family(family_name text, policy_version_id uuid)
RETURNS void
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
    SELECT pgreact_internal.bind_parameter_family($1, $2)
$m25$;

CREATE FUNCTION pgreact_api.author_parameterized_rule(
    policy_name text,
    rule_name text,
    condition regclass,
    semantic_key name,
    family_name text,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL,
    kind text DEFAULT 'CONSTRAINT',
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60,
    initial_parameters jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    policy_version_id uuid;
BEGIN
    SELECT * INTO STRICT family_row FROM pgreact_internal.parameter_families
    WHERE parameter_families.family_name = author_parameterized_rule.family_name
      AND parameter_families.state = 'ACTIVE';
    IF NOT EXISTS (
        SELECT 1 FROM pg_depend dependency
        WHERE dependency.refclassid = 'pg_class'::regclass
          AND dependency.refobjid = family_row.parameter_relation_oid
          AND ((dependency.classid = 'pg_class'::regclass AND dependency.objid = condition)
               OR (dependency.classid = 'pg_rewrite'::regclass AND dependency.objid = (
                   SELECT oid FROM pg_rewrite WHERE ev_class = condition)))
    ) THEN
        RAISE EXCEPTION 'M25_PARAMETER_DEPENDENCY: condition % does not depend directly on parameter relation %',
            condition, family_row.parameter_relation_name
            USING HINT = 'Join the declared ordinary parameter relation from the condition view.';
    END IF;
    PERFORM pgreact_internal.insert_parameter_rows(family_row.family_id, initial_parameters);
    policy_version_id := pgreact_api.author_effective_rule(
        policy_name, rule_name, condition, semantic_key, valid_from, valid_to, kind,
        on_activate, on_deactivate, on_change, bootstrap_policy, change_columns,
        salience, agenda_group, conflict_key_columns, max_attempts,
        initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
    PERFORM pgreact_internal.bind_parameter_family(family_name, policy_version_id);
    RETURN policy_version_id;
END
$m25$;

CREATE FUNCTION pgreact_api.author_parameterized_program(
    policy_name text,
    definition jsonb,
    family_name text,
    valid_from timestamptz,
    valid_to timestamptz DEFAULT NULL,
    initial_parameters jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    created_policy_version_id uuid;
BEGIN
    SELECT * INTO STRICT family_row
    FROM pgreact_internal.parameter_families
    WHERE parameter_families.family_name = author_parameterized_program.family_name
      AND state = 'ACTIVE';
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(definition -> 'rules') rule_item
        JOIN pg_depend dependency
          ON dependency.refclassid = 'pg_class'::regclass
         AND dependency.refobjid = family_row.parameter_relation_oid
         AND (dependency.objid = to_regclass(rule_item ->> 'definition')
              OR EXISTS (SELECT 1 FROM pg_rewrite rewrite
                         WHERE rewrite.oid = dependency.objid
                           AND rewrite.ev_class = to_regclass(rule_item ->> 'definition')))
        WHERE to_regclass(rule_item ->> 'definition') IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'M25_PARAMETER_DEPENDENCY: program % does not depend directly on parameter relation %',
            policy_name, family_row.parameter_relation_name
            USING HINT = 'Join the declared ordinary parameter relation from a program input view.';
    END IF;
    PERFORM pgreact_internal.insert_parameter_rows(family_row.family_id, initial_parameters);
    created_policy_version_id := pgreact_api.author_effective_program(
        policy_name, definition, valid_from, valid_to);
    PERFORM pgreact_internal.bind_parameter_family(family_name, created_policy_version_id);
    RETURN created_policy_version_id;
END
$m25$;

CREATE FUNCTION pgreact_api.parameter_family_preview(
    family_name text,
    parameter_key bigint,
    proposed_values jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    current_values jsonb;
    proposed_row jsonb;
    consumers jsonb;
BEGIN
    SELECT * INTO family_row FROM pgreact_internal.parameter_families
    WHERE parameter_families.family_name = parameter_family_preview.family_name
      AND state = 'ACTIVE';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('contract_version', 13, 'available', false,
                                  'family', parameter_family_preview.family_name);
    END IF;
    current_values := pgreact_internal.parameter_family_value(family_row.family_id, parameter_key);
    EXECUTE format(
        'SELECT to_jsonb(r) FROM jsonb_populate_record(NULL::%s, $1) r',
        family_row.parameter_relation_oid::regclass)
    INTO proposed_row USING proposed_values || jsonb_build_object(
        family_row.parameter_key_column::text, parameter_key);
    proposed_row := pgreact_internal.parameter_family_project(family_row.family_id, proposed_row);
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'policy_version_id', consumer.policy_version_id,
        'policy', policy.policy_name,
        'target_kind', version.target_kind,
        'rule_version_id', version.rule_version_id,
        'match_before', CASE WHEN version.rule_version_id IS NULL THEN NULL ELSE EXISTS (
            SELECT 1 FROM pgreact_internal.activation_state state
            WHERE state.rule_version_id = version.rule_version_id
              AND state.semantic_key = parameter_key AND state.active) END
    ) ORDER BY policy.policy_name), '[]'::jsonb)
    INTO consumers
    FROM pgreact_internal.parameter_family_consumers consumer
    JOIN pgreact_internal.effective_policy_versions version USING (policy_version_id)
    JOIN pgreact_internal.effective_policies policy USING (policy_id)
    WHERE consumer.family_id = family_row.family_id;
    RETURN jsonb_build_object(
        'contract_version', 13,
        'family', family_row.family_name,
        'family_id', family_row.family_id,
        'parameter_key', parameter_key,
        'current', current_values,
        'proposed', proposed_row,
        'changed', current_values IS DISTINCT FROM proposed_row,
        'consumers', consumers,
        'maintenance', 'ordinary relational refresh after commit',
        'note', 'The preview is side-effect free; commit the ordinary table change to evaluate the joined condition.')
    ;
END
$m25$;

CREATE FUNCTION pgreact_api.parameter_family_explain(
    family_name text,
    policy_name text,
    semantic_key bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row pgreact_internal.parameter_families%ROWTYPE;
    consumer_row record;
    parameter_values jsonb;
    match_details jsonb;
BEGIN
    SELECT * INTO family_row FROM pgreact_internal.parameter_families
    WHERE parameter_families.family_name = parameter_family_explain.family_name
      AND state = 'ACTIVE';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('contract_version', 13, 'available', false,
                                  'family', parameter_family_explain.family_name);
    END IF;
    SELECT consumer.policy_version_id, version.rule_version_id,
           policy.policy_name, version.target_kind
    INTO consumer_row
    FROM pgreact_internal.parameter_family_consumers consumer
    JOIN pgreact_internal.effective_policy_versions version USING (policy_version_id)
    JOIN pgreact_internal.effective_policies policy USING (policy_id)
    WHERE consumer.family_id = family_row.family_id
      AND policy.policy_name = parameter_family_explain.policy_name
      AND (policy.authoritative_version_id = consumer.policy_version_id
           OR policy.authoritative_version_id IS NULL)
    ORDER BY consumer.bound_at DESC LIMIT 1;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('contract_version', 13, 'available', false,
                                  'family', family_row.family_name,
                                  'policy', parameter_family_explain.policy_name);
    END IF;
    parameter_values := pgreact_internal.parameter_family_value(family_row.family_id, semantic_key);
    IF consumer_row.rule_version_id IS NOT NULL THEN
        SELECT jsonb_build_object('activation_id', state.activation_id,
                                  'active', state.active,
                                  'generation', state.generation,
                                  'revision', state.revision,
                                  'bindings', state.current_bindings)
        INTO match_details
        FROM pgreact_internal.activation_state state
        WHERE state.rule_version_id = consumer_row.rule_version_id
          AND state.semantic_key = parameter_family_explain.semantic_key;
    END IF;
    RETURN jsonb_build_object(
        'contract_version', 13,
        'family', family_row.family_name,
        'family_id', family_row.family_id,
        'policy', consumer_row.policy_name,
        'policy_version_id', consumer_row.policy_version_id,
        'target_kind', consumer_row.target_kind,
        'rule_version_id', consumer_row.rule_version_id,
        'parameter_key', semantic_key,
        'parameter_value', parameter_values,
        'match', match_details,
        'provenance', jsonb_build_object('source', family_row.parameter_relation_name,
                                         'key_column', family_row.parameter_key_column,
                                         'value_columns', family_row.parameter_value_columns));
END
$m25$;

CREATE FUNCTION pgreact_api.parameter_family_status(target_family_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE family_row record;
    row_count bigint;
    drift boolean;
    result jsonb := '[]'::jsonb;
BEGIN
    FOR family_row IN
        SELECT * FROM pgreact_internal.parameter_families
        WHERE state = 'ACTIVE'
          AND (target_family_name IS NULL OR family_name = target_family_name)
        ORDER BY family_name
    LOOP
        EXECUTE format('SELECT count(*) FROM %s', family_row.parameter_relation_oid::regclass)
        INTO row_count;
        drift := family_row.source_signature IS DISTINCT FROM
            pgreact_internal.source_row_signature(family_row.parameter_relation_oid);
        result := result || jsonb_build_array(jsonb_build_object(
            'family_id', family_row.family_id,
            'family', family_row.family_name,
            'owner', pg_get_userbyid(family_row.owner_oid),
            'parameter_relation', family_row.parameter_relation_name,
            'parameter_key', family_row.parameter_key_column,
            'parameter_values', family_row.parameter_value_columns,
            'value_types', family_row.parameter_value_types,
            'row_count', row_count,
            'max_rows', family_row.max_rows,
            'source_drift', drift,
            'consumers', (SELECT count(*) FROM pgreact_internal.parameter_family_consumers consumer
                          WHERE consumer.family_id = family_row.family_id)));
    END LOOP;
    RETURN jsonb_build_object('contract_version', 13,
                              'families', result,
                              'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier));
END
$m25$;

CREATE FUNCTION pgreact_api.parameter_family_history(target_family_name text)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
    SELECT COALESCE(jsonb_agg(to_jsonb(event) ORDER BY event.occurred_at, event.event_id), '[]'::jsonb)
    FROM pgreact_internal.parameter_family_events event
    JOIN pgreact_internal.parameter_families family USING (family_id)
    WHERE family.family_name = $1
$m25$;

CREATE FUNCTION pgreact_api.parameter_family_doctor()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE diagnostics jsonb := '[]'::jsonb;
    family_row record;
    row_count bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_react' AND extversion = '0.22.0') THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
            'code', 'M25_EXTENSION_VERSION', 'severity', 'ERROR',
            'object_identity', 'pg_react',
            'message', 'pg_react extension version is not 0.22.0',
            'hint', 'Install the matching extension files and run ALTER EXTENSION pg_react UPDATE TO ''0.22.0''.'));
    END IF;
    FOR family_row IN SELECT * FROM pgreact_internal.parameter_families WHERE state = 'ACTIVE' LOOP
        EXECUTE format('SELECT count(*) FROM %s', family_row.parameter_relation_oid::regclass)
        INTO row_count;
        IF family_row.source_signature IS DISTINCT FROM
           pgreact_internal.source_row_signature(family_row.parameter_relation_oid) THEN
            diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M25_PARAMETER_DRIFT', 'severity', 'ERROR',
                'object_identity', family_row.family_name,
                'message', 'the parameter relation definition changed after declaration',
                'hint', 'Stop parameter maintenance, restore the declared columns, or declare a replacement family.'));
        END IF;
        IF row_count > family_row.max_rows THEN
            diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M25_PARAMETER_LIMIT', 'severity', 'ERROR',
                'object_identity', family_row.family_name,
                'message', 'the parameter relation exceeds its admission limit',
                'hint', 'Archive or partition parameter rows before continuing.'));
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_trigger trigger_row
            WHERE trigger_row.tgrelid = family_row.parameter_relation_oid
              AND trigger_row.tgname = 'pgreact_parameter_family_guard'
              AND trigger_row.tgenabled IN ('O', 'A')) THEN
            diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
                'code', 'M25_PARAMETER_GUARD', 'severity', 'ERROR',
                'object_identity', family_row.family_name,
                'message', 'the parameter relation guard trigger is missing or disabled',
                'hint', 'Restore the extension guard trigger before changing parameter rows.'));
        END IF;
    END LOOP;
    RETURN jsonb_build_object('contract_version', 13,
        'status', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(diagnostics) item
                                    WHERE item ->> 'severity' = 'ERROR')
                       THEN 'attention' ELSE 'ready' END,
        'diagnostics', diagnostics);
END
$m25$;

ALTER FUNCTION pgreact_api.run(timestamptz) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.run(timestamptz) RENAME TO run_m24;

CREATE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
DECLARE result jsonb;
BEGIN
    result := pgreact_internal.run_m24(sampled_time);
    RETURN jsonb_set(
        result || jsonb_build_object('parameter_families', pgreact_api.parameter_family_status()),
        '{contract_version}', '13'::jsonb, true);
END
$m25$;

ALTER FUNCTION pgreact_api.status(text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.status(text) RENAME TO status_m24;

CREATE FUNCTION pgreact_api.status(target_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
    SELECT pgreact_internal.status_m24($1)
        || jsonb_build_object('parameter_families', pgreact_api.parameter_family_status(),
                              'contract_version', 13)
$m25$;

ALTER FUNCTION pgreact_api.doctor() SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.doctor() RENAME TO doctor_m24;

CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m25$
    SELECT jsonb_build_object(
        'contract_version', 13,
        'status', CASE WHEN EXISTS (
            SELECT 1
            FROM jsonb_array_elements(
                COALESCE(pgreact_internal.doctor_m24() -> 'diagnostics', '[]'::jsonb)
                || (pgreact_api.parameter_family_doctor() -> 'diagnostics')) item
            WHERE item ->> 'severity' = 'ERROR'
        ) THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE(pgreact_internal.doctor_m24() -> 'diagnostics', '[]'::jsonb)
            || (pgreact_api.parameter_family_doctor() -> 'diagnostics'))
$m25$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m24;

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
AS $m25$
BEGIN
    PERFORM pgreact_internal.configure_roles_m24(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT SELECT ON pgreact.parameter_families, pgreact.parameter_family_consumers TO %I, %I',
        reader_role::text, operator_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.validate_parameter_family(text,regclass,name,name[]), '
        'pgreact_api.author_parameter_family(text,regclass,name,name[]), '
        'pgreact_api.grant_parameter_family_editor(text,regrole), '
        'pgreact_api.revoke_parameter_family_editor(text,regrole), '
        'pgreact_api.bind_parameter_family(text,uuid), '
        'pgreact_api.author_parameterized_rule(text,text,regclass,name,text,timestamptz,timestamptz,text,regprocedure,regprocedure,regprocedure,text,name[],integer,text,name[],integer,integer,numeric,integer,jsonb), '
        'pgreact_api.author_parameterized_program(text,jsonb,text,timestamptz,timestamptz,jsonb) TO %I',
        author_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.parameter_family_preview(text,bigint,jsonb), '
        'pgreact_api.parameter_family_explain(text,text,bigint), '
        'pgreact_api.parameter_family_status(text), '
        'pgreact_api.parameter_family_history(text), '
        'pgreact_api.parameter_family_doctor() TO %I', reader_role::text);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.parameter_family_preview(text,bigint,jsonb), '
        'pgreact_api.parameter_family_explain(text,text,bigint), '
        'pgreact_api.parameter_family_status(text), '
        'pgreact_api.parameter_family_history(text), '
        'pgreact_api.parameter_family_doctor() TO %I', operator_role::text);
END
$m25$;

DO $m25$
DECLARE author_role regrole;
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
$m25$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M25 typed parameterized policy families over the M24 effective-dated policy platform';
