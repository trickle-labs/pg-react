-- M30 applicability foundation: canonical identities, relational eligibility,
-- migration classification, and inspection without authoritative runtime work.

ALTER TABLE pgreact_internal.policy_set_versions
    ADD COLUMN IF NOT EXISTS subject_keys name[],
    ADD COLUMN IF NOT EXISTS key_codec_version smallint,
    ADD COLUMN IF NOT EXISTS migration_state text;

UPDATE pgreact_internal.policy_set_versions
SET subject_keys = ARRAY[subject_key]::name[],
    key_codec_version = 2,
    migration_state = 'NEEDS_SCOPE_MIGRATION'
WHERE subject_keys IS NULL
   OR key_codec_version IS NULL
   OR migration_state IS NULL;

CREATE OR REPLACE FUNCTION pgreact_internal.m30_subject_keys_default()
RETURNS trigger
LANGUAGE plpgsql AS $m30$
BEGIN
    IF NEW.subject_keys IS NULL THEN
        NEW.subject_keys := ARRAY[NEW.subject_key]::name[];
    END IF;
    RETURN NEW;
END
$m30$;

DROP TRIGGER IF EXISTS policy_set_versions_subject_keys_default
    ON pgreact_internal.policy_set_versions;
CREATE TRIGGER policy_set_versions_subject_keys_default
BEFORE INSERT OR UPDATE ON pgreact_internal.policy_set_versions
FOR EACH ROW
EXECUTE FUNCTION pgreact_internal.m30_subject_keys_default();

ALTER TABLE pgreact_internal.policy_set_versions
    ALTER COLUMN subject_keys SET NOT NULL,
    ALTER COLUMN key_codec_version SET DEFAULT 2,
    ALTER COLUMN key_codec_version SET NOT NULL,
    ALTER COLUMN migration_state SET DEFAULT 'NEEDS_SCOPE_MIGRATION',
    ALTER COLUMN migration_state SET NOT NULL;

ALTER TABLE pgreact_internal.policy_set_versions
    DROP CONSTRAINT IF EXISTS policy_set_versions_migration_state_check;
ALTER TABLE pgreact_internal.policy_set_versions
    ADD CONSTRAINT policy_set_versions_migration_state_check
    CHECK (migration_state IN ('READY', 'NEEDS_SCOPE_MIGRATION'));

ALTER TABLE pgreact_internal.policy_set_members
    ADD COLUMN IF NOT EXISTS match_keys name[],
    ADD COLUMN IF NOT EXISTS subject_keys name[],
    ADD COLUMN IF NOT EXISTS scope_mode text,
    ADD COLUMN IF NOT EXISTS disposition text;

UPDATE pgreact_internal.policy_set_members member
SET subject_keys = version.subject_keys,
    scope_mode = COALESCE(member.scope_mode, 'GLOBAL'),
    disposition = COALESCE(member.disposition, 'SUPPORTED_LIMITED')
FROM pgreact_internal.policy_set_versions version
WHERE version.policy_set_version_id = member.policy_set_version_id;

ALTER TABLE pgreact_internal.policy_set_members
    ALTER COLUMN scope_mode SET DEFAULT 'GLOBAL',
    ALTER COLUMN scope_mode SET NOT NULL,
    ALTER COLUMN disposition SET DEFAULT 'SUPPORTED_LIMITED',
    ALTER COLUMN disposition SET NOT NULL;

ALTER TABLE pgreact_internal.policy_set_members
    DROP CONSTRAINT IF EXISTS policy_set_members_scope_mode_check;
ALTER TABLE pgreact_internal.policy_set_members
    ADD CONSTRAINT policy_set_members_scope_mode_check
    CHECK (scope_mode IN ('GLOBAL', 'POLICY_SET_REQUIRED'));

ALTER TABLE pgreact_internal.policy_set_members
    DROP CONSTRAINT IF EXISTS policy_set_members_disposition_check;
ALTER TABLE pgreact_internal.policy_set_members
    ADD CONSTRAINT policy_set_members_disposition_check
    CHECK (disposition IN ('FULLY_AUTHORITATIVE', 'SUPPORTED_LIMITED', 'UNSUPPORTED'));

CREATE TABLE IF NOT EXISTS pgreact_internal.policy_set_eligibility (
    policy_set_version_id uuid NOT NULL
        REFERENCES pgreact_internal.policy_set_versions ON DELETE CASCADE,
    subject_identity bytea NOT NULL,
    subject_values jsonb NOT NULL,
    key_types text[] NOT NULL,
    key_codec_version smallint NOT NULL CHECK (key_codec_version = 2),
    complete_frontier timestamptz NOT NULL,
    source_fingerprint text NOT NULL,
    PRIMARY KEY (policy_set_version_id, subject_identity)
);

CREATE INDEX IF NOT EXISTS policy_set_eligibility_subject_idx
    ON pgreact_internal.policy_set_eligibility (subject_identity, policy_set_version_id);

CREATE TABLE IF NOT EXISTS pgreact_internal.policy_set_scope_supports (
    scope_support_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_set_version_id uuid NOT NULL
        REFERENCES pgreact_internal.policy_set_versions ON DELETE CASCADE,
    member_kind text NOT NULL,
    member_name text NOT NULL,
    member_version text NOT NULL,
    match_identity bytea NOT NULL,
    subject_identity bytea NOT NULL,
    subject_values jsonb NOT NULL,
    support_generation bigint NOT NULL DEFAULT 1 CHECK (support_generation > 0),
    complete_frontier timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (policy_set_version_id, member_kind, member_name, member_version, match_identity)
);

CREATE INDEX IF NOT EXISTS policy_set_scope_support_member_idx
    ON pgreact_internal.policy_set_scope_supports
        (member_kind, member_name, member_version, match_identity);

CREATE TABLE IF NOT EXISTS pgreact_internal.policy_set_scope_support_history (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scope_support_id uuid NOT NULL,
    policy_set_version_id uuid NOT NULL
        REFERENCES pgreact_internal.policy_set_versions ON DELETE CASCADE,
    member_kind text NOT NULL,
    member_name text NOT NULL,
    member_version text NOT NULL,
    match_identity bytea NOT NULL,
    subject_identity bytea NOT NULL,
    event_kind text NOT NULL CHECK (event_kind IN ('ADDED', 'REMOVED')),
    complete_frontier timestamptz NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS policy_set_scope_support_history_idx
    ON pgreact_internal.policy_set_scope_support_history
        (member_kind, member_name, member_version, match_identity, occurred_at);

CREATE TABLE IF NOT EXISTS pgreact_internal.policy_set_runtime_barriers (
    policy_set_version_id uuid PRIMARY KEY
        REFERENCES pgreact_internal.policy_set_versions ON DELETE CASCADE,
    code text NOT NULL,
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    cleared_at timestamptz
);

CREATE TABLE IF NOT EXISTS pgreact_internal.declaration_migrations (
    migration_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    declaration_id uuid REFERENCES pgreact_internal.api_declarations ON DELETE CASCADE,
    kind text NOT NULL,
    object_name text NOT NULL,
    object_version text NOT NULL DEFAULT '',
    state text NOT NULL CHECK (state IN ('GLOBAL', 'LEGACY_METADATA', 'NEEDS_SCOPE_MIGRATION', 'READY')),
    reason text NOT NULL,
    remediation text NOT NULL,
    observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (kind, object_name, object_version)
);

CREATE INDEX IF NOT EXISTS declaration_migrations_state_idx
    ON pgreact_internal.declaration_migrations (state, kind, object_name);

CREATE FUNCTION pgreact_internal.m30_finding(
    code text,
    severity text,
    object_identity text,
    field_path text,
    message text,
    hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE AS $m30$
    SELECT jsonb_build_object(
        'code', $1, 'severity', $2, 'blocker', $2 = 'ERROR',
        'object_identity', $3, 'field_path', $4, 'message', $5,
        'hint', $6, 'details', COALESCE($7, '{}'::jsonb),
        'evidence', '[]'::jsonb, 'truncated', false)
$m30$;

CREATE FUNCTION pgreact_internal.m30_key_array(
    source jsonb,
    canonical text,
    plural_alias text,
    scalar_alias text
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $m30$
DECLARE value jsonb;
BEGIN
    value := source -> canonical;
    IF jsonb_typeof(value) = 'array' THEN
        RETURN value;
    END IF;
    IF plural_alias IS NOT NULL THEN
        value := source -> plural_alias;
        IF jsonb_typeof(value) = 'array' THEN
            RETURN value;
        END IF;
    END IF;
    IF scalar_alias IS NOT NULL THEN
        value := source -> scalar_alias;
        IF jsonb_typeof(value) = 'string' THEN
            RETURN jsonb_build_array(value);
        END IF;
    END IF;
    RETURN '[]'::jsonb;
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_member_disposition(kind text)
RETURNS text
LANGUAGE SQL IMMUTABLE STRICT AS $m30$
    SELECT CASE
        WHEN $1 IN ('rule', 'decision_program') THEN 'FULLY_AUTHORITATIVE'
        WHEN $1 IN ('derived_program', 'temporal_policy', 'effective_policy', 'parameter_family')
            THEN 'SUPPORTED_LIMITED'
        ELSE 'UNSUPPORTED'
    END
$m30$;

CREATE FUNCTION pgreact_internal.m30_normalize(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT AS $m30$
    SELECT jsonb_build_object(
        'api_version', (declaration).api_version,
        'kind', (declaration).kind,
        'name', (declaration).name,
        'spec', jsonb_build_object(
            'version', (declaration).spec ->> 'version',
            'members', CASE
                WHEN jsonb_typeof((declaration).spec -> 'members') = 'array' THEN COALESCE((
                    SELECT jsonb_agg(
                        jsonb_build_object(
                            'kind', value ->> 'kind',
                            'name', value ->> 'name',
                            'version', value ->> 'version',
                            'match_keys', pgreact_internal.m30_key_array(
                                value, 'match_keys', 'semantic_keys', 'semantic_key'),
                            'subject_keys', COALESCE(
                                NULLIF(pgreact_internal.m30_key_array(
                                    value, 'subject_keys', NULL, 'subject_key'), '[]'::jsonb),
                                pgreact_internal.m30_key_array(
                                    value, 'match_keys', 'semantic_keys', 'semantic_key')),
                            'scope_mode', COALESCE(value ->> 'scope_mode', 'GLOBAL'),
                            'disposition', pgreact_internal.m30_member_disposition(value ->> 'kind'))
                        ORDER BY value ->> 'kind', value ->> 'name', value ->> 'version')
                    FROM jsonb_array_elements((declaration).spec -> 'members') value
                ), '[]'::jsonb)
                ELSE '[]'::jsonb
            END,
            'applicability', jsonb_build_object(
                'source_kind', (declaration).spec -> 'applicability' ->> 'source_kind',
                'relation', (declaration).spec -> 'applicability' ->> 'relation',
                'condition', (declaration).spec -> 'applicability' ->> 'condition',
                'version', (declaration).spec -> 'applicability' ->> 'version',
                'subject_keys', pgreact_internal.m30_key_array(
                    (declaration).spec -> 'applicability', 'subject_keys', NULL, 'subject_key')),
            'valid_from', (declaration).spec ->> 'valid_from',
            'valid_to', (declaration).spec ->> 'valid_to',
            'evidence_limit', COALESCE(
                (declaration).spec -> 'evidence_limit', '100'::jsonb)))
$m30$;

CREATE FUNCTION pgreact_internal.m30_key_identity(key_types text[], key_values jsonb)
RETURNS bytea
LANGUAGE plpgsql IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE result bytea := decode('0202', 'hex') || int4send(cardinality(key_types));
    value jsonb;
    raw bytea;
    type_name text;
    type_tag text;
    position integer;
BEGIN
    IF cardinality(key_types) < 1 OR cardinality(key_types) > 4
       OR jsonb_typeof(key_values) IS DISTINCT FROM 'array'
       OR jsonb_array_length(key_values) <> cardinality(key_types) THEN
        RAISE EXCEPTION 'M30_KEY_ARITY: key identity needs one to four typed values';
    END IF;
    FOR position IN 1..cardinality(key_types) LOOP
        type_name := lower(key_types[position]);
        value := key_values -> (position - 1);
        IF jsonb_typeof(value) IS NULL OR jsonb_typeof(value) = 'null' THEN
            RAISE EXCEPTION 'M30_KEY_NULL: key identity components cannot be null';
        END IF;
        IF type_name = 'bigint' AND jsonb_typeof(value) = 'number' THEN
            raw := int8send((value #>> '{}')::bigint);
            type_tag := '01';
        ELSIF type_name = 'uuid' AND jsonb_typeof(value) = 'string' THEN
            raw := uuid_send((value #>> '{}')::uuid);
            type_tag := '02';
        ELSIF type_name = 'text' AND jsonb_typeof(value) = 'string' THEN
            raw := convert_to(value #>> '{}', 'UTF8');
            type_tag := '03';
        ELSE
            RAISE EXCEPTION 'M30_KEY_TYPE: value does not match supported key type %', type_name;
        END IF;
        result := result || decode(type_tag, 'hex') || int4send(length(raw)) || raw;
    END LOOP;
    RETURN result;
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_relation_details(source_oid oid, key_names name[])
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE key_types text[];
    values_expression text;
    row_expression text;
    complete_expression text;
    details jsonb;
BEGIN
    SELECT array_agg(a.atttypid::regtype::text ORDER BY requested.ordinal)
    INTO key_types
    FROM unnest(key_names) WITH ORDINALITY requested(key_name, ordinal)
    JOIN pg_attribute a ON a.attrelid = source_oid
                       AND a.attname = requested.key_name
                       AND a.attnum > 0 AND NOT a.attisdropped;
    IF cardinality(key_types) <> cardinality(key_names) THEN
        RAISE EXCEPTION 'M30_SOURCE_KEY: applicability key column is missing';
    END IF;
    SELECT string_agg(format('to_jsonb(s.%I)', requested.key_name), ', '
                      ORDER BY requested.ordinal),
           string_agg(format('s.%I', requested.key_name), ', '
                      ORDER BY requested.ordinal),
           string_agg(format('s.%I IS NOT NULL', requested.key_name), ' AND '
                      ORDER BY requested.ordinal)
    INTO values_expression, row_expression, complete_expression
    FROM unnest(key_names) WITH ORDINALITY requested(key_name, ordinal);
    values_expression := 'jsonb_build_array(' || values_expression || ')';
    EXECUTE format(
        'SELECT jsonb_build_object(
            ''row_count'', count(*),
            ''null_count'', count(*) FILTER (WHERE NOT (%3$s)),
            ''distinct_count'', count(DISTINCT ROW(%2$s)),
             ''eligible_subjects'', COALESCE(
                 jsonb_agg(x.subject_values ORDER BY x.subject_values::text) FILTER (WHERE x.complete),
                ''[]''::jsonb),
            ''eligibility_rows'', COALESCE(
                jsonb_agg(jsonb_build_object(
                    ''subject_identity'', encode(pgreact_internal.m30_key_identity($1, x.subject_values), ''hex''),
                    ''subject_values'', x.subject_values,
                    ''key_types'', to_jsonb($1),
                    ''key_codec_version'', 2)
                    ORDER BY x.subject_values::text) FILTER (WHERE x.complete),
                ''[]''::jsonb))
         FROM %1$s s
         CROSS JOIN LATERAL (SELECT %4$s AS subject_values, %3$s AS complete) x',
        source_oid::regclass, row_expression, complete_expression, values_expression)
    INTO details
    USING key_types;
    RETURN details;
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_relation_fingerprint(
    source_oid oid,
    key_names name[],
    complete_frontier timestamptz
)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE details jsonb;
    signature bytea;
BEGIN
    IF source_oid IS NULL THEN
        RETURN NULL;
    END IF;
    details := pgreact_internal.m30_relation_details(source_oid, key_names);
    signature := pgreact_internal.source_row_signature(source_oid);
    RETURN encode(sha256(convert_to(
        COALESCE(details -> 'eligibility_rows', '[]'::jsonb)::text
        || ':' || encode(signature, 'hex') || ':'
        || COALESCE(complete_frontier::text, ''), 'UTF8')), 'hex');
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE findings jsonb := '[]'::jsonb;
    normalized jsonb;
    spec jsonb;
    member jsonb;
    app jsonb;
    field text;
    member_kind text;
    member_name text;
    member_version text;
    source_kind text;
    source_name text;
    source_oid oid;
    source_owner oid;
    source_rls boolean;
    relation_kind "char";
    key_names name[];
    key_name name;
    key_types text[];
    details jsonb;
    source jsonb := '{}'::jsonb;
    valid_from timestamptz;
    valid_to timestamptz;
    evidence_limit integer;
    condition_version_id uuid;
BEGIN
    IF declaration IS NULL THEN
        RETURN jsonb_build_object('normalized', NULL, 'findings', jsonb_build_array(
            pgreact_internal.m30_finding('M30_DECLARATION_NULL', 'ERROR', '<unnamed>',
                '<declaration>', 'policy-set declaration is required',
                'Build it with pgreact_api.declaration().')));
    END IF;
    normalized := pgreact_internal.m30_normalize(declaration);
    spec := COALESCE((declaration).spec, '{}'::jsonb);
    IF (declaration).api_version IS DISTINCT FROM '1' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_API_VERSION', 'ERROR', (declaration).name, 'api_version',
            'only declaration API version 1 is supported', 'Set api_version to 1.'));
    END IF;
    IF (declaration).kind IS DISTINCT FROM 'policy_set' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_KIND', 'ERROR', COALESCE((declaration).name, '<unnamed>'), 'kind',
            'this validator accepts policy_set declarations', 'Use kind policy_set.'));
    END IF;
    IF (declaration).name IS NULL OR (declaration).name !~ '^[A-Za-z_][A-Za-z0-9_.-]*$' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_NAME', 'ERROR', COALESCE((declaration).name, '<unnamed>'), 'name',
            'name must be a stable non-empty public name',
            'Use letters, digits, underscore, dot, or hyphen.'));
    END IF;
    IF jsonb_typeof(spec) IS DISTINCT FROM 'object' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_SPEC', 'ERROR', COALESCE((declaration).name, '<unnamed>'), 'spec',
            'spec must be a JSON object',
            'Provide version, members, applicability, and effective bounds.'));
        RETURN jsonb_build_object('normalized', normalized, 'findings', findings);
    END IF;
    FOR field IN SELECT key FROM jsonb_object_keys(spec) key LOOP
        IF field NOT IN ('version', 'members', 'applicability', 'valid_from',
                         'valid_to', 'evidence_limit') THEN
            findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                'M30_FIELD_UNKNOWN', 'ERROR', (declaration).name, 'spec.' || field,
                'policy-set declaration contains an unknown field',
                'Remove it or use a field in the M30 policy-set contract.',
                jsonb_build_object('field', field)));
            EXIT;
        END IF;
    END LOOP;
    IF NULLIF(btrim(spec ->> 'version'), '') IS NULL
       OR length(spec ->> 'version') > 64
       OR spec ->> 'version' !~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_VERSION', 'ERROR', (declaration).name, 'spec.version',
            'version must be a stable non-empty immutable identifier',
            'Use a short value such as 2 or 2026-08.'));
    END IF;
    IF jsonb_typeof(spec -> 'members') IS DISTINCT FROM 'array'
       OR jsonb_array_length(COALESCE(spec -> 'members', '[]'::jsonb)) = 0 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_MEMBERS', 'ERROR', (declaration).name, 'spec.members',
            'members must be a non-empty array',
            'List already-deployed policy targets.'));
    ELSIF jsonb_array_length(spec -> 'members') > 64 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_LIMIT', 'ERROR', (declaration).name, 'spec.members',
            'a policy set may contain at most 64 members',
            'Split the population into smaller policy sets.'));
    ELSE
        FOR member IN SELECT value FROM jsonb_array_elements(spec -> 'members') value LOOP
            member_kind := member ->> 'kind';
            member_name := member ->> 'name';
            member_version := member ->> 'version';
            IF jsonb_typeof(member) IS DISTINCT FROM 'object' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_MEMBER_SHAPE', 'ERROR', (declaration).name, 'spec.members',
                    'each member must be an object',
                    'Use kind, name, version, keys, and scope_mode.'));
                CONTINUE;
            END IF;
            SELECT key INTO field FROM jsonb_object_keys(member) key
            WHERE key NOT IN ('kind', 'name', 'version', 'match_keys',
                              'semantic_key', 'semantic_keys', 'subject_keys',
                              'subject_key', 'scope_mode')
            ORDER BY key LIMIT 1;
            IF field IS NOT NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_MEMBER_FIELD_UNKNOWN', 'ERROR', COALESCE(member_name, (declaration).name),
                    'spec.members.' || field, 'member contains an unknown field',
                    'Use the frozen M30 member identity fields.',
                    jsonb_build_object('field', field)));
            END IF;
            IF pgreact_internal.m30_member_disposition(member_kind) = 'UNSUPPORTED' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_MEMBER_KIND', 'ERROR', COALESCE(member_name, (declaration).name),
                    'spec.members', 'member kind is unsupported by the frozen M30 matrix',
                    'Use rule, decision_program, or a documented specialized member kind.'));
            END IF;
            IF NULLIF(btrim(member_name), '') IS NULL
               OR NULLIF(btrim(member_version), '') IS NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_MEMBER_IDENTITY', 'ERROR', (declaration).name, 'spec.members',
                    'every member needs kind, name, and immutable version',
                    'Copy the exact deployed target identity.'));
            ELSIF NOT pgreact_internal.m29_member_exists(member_kind, member_name, member_version) THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_MEMBER_NOT_FOUND', 'ERROR', member_name, 'spec.members',
                    'the member target is not deployed',
                    'Deploy the member first and use its exact version.'));
            END IF;
            IF member ->> 'scope_mode' IS DISTINCT FROM 'POLICY_SET_REQUIRED' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_SCOPE_MODE', 'ERROR', COALESCE(member_name, (declaration).name),
                    'spec.members.scope_mode',
                    'policy-set members must explicitly require policy-set scope',
                    'Set scope_mode to POLICY_SET_REQUIRED.'));
            END IF;
            key_names := ARRAY(SELECT jsonb_array_elements_text(
                pgreact_internal.m30_key_array(member, 'match_keys', 'semantic_keys', 'semantic_key'))
                )::name[];
            IF cardinality(key_names) NOT BETWEEN 1 AND 4
               OR cardinality(key_names) <> (
                   SELECT count(DISTINCT value) FROM unnest(key_names) value) THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_MATCH_KEYS', 'ERROR', COALESCE(member_name, (declaration).name),
                    'spec.members.match_keys',
                    'match_keys must contain one to four distinct columns',
                    'Use the canonical match identity or a compatibility alias.'));
            END IF;
            FOREACH key_name IN ARRAY COALESCE(key_names, ARRAY[]::name[]) LOOP
                IF key_name !~ '^[A-Za-z_][A-Za-z0-9_]*$' THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                        'M30_MATCH_KEY_NAME', 'ERROR', COALESCE(member_name, (declaration).name),
                        'spec.members.match_keys',
                        'identity column names must be simple PostgreSQL names',
                        'Use an unquoted column name.'));
                END IF;
            END LOOP;
        END LOOP;
    END IF;
    app := spec -> 'applicability';
    source_kind := app ->> 'source_kind';
    source_name := COALESCE(app ->> 'relation', app ->> 'condition');
    key_names := ARRAY(SELECT jsonb_array_elements_text(
        normalized -> 'spec' -> 'applicability' -> 'subject_keys'))::name[];
    IF jsonb_typeof(app) IS DISTINCT FROM 'object'
       OR source_kind NOT IN ('relation', 'shared_condition')
       OR NULLIF(source_name, '') IS NULL THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_APPLICABILITY', 'ERROR', (declaration).name, 'spec.applicability',
            'applicability must name one relation or shared condition',
            'Use source_kind, source identity, and subject_keys.'));
    ELSIF cardinality(key_names) NOT BETWEEN 1 AND 4
          OR cardinality(key_names) <> (
              SELECT count(DISTINCT value) FROM unnest(key_names) value) THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_SUBJECT_KEYS', 'ERROR', (declaration).name,
            'spec.applicability.subject_keys',
            'subject_keys must contain one to four distinct columns',
            'Use bigint, uuid, or text COLLATE "C" columns.'));
    ELSE
        IF source_name !~ '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$' THEN
            findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                'M30_SOURCE_NAME', 'ERROR', (declaration).name,
                'spec.applicability', 'applicability sources must be schema-qualified',
                'Use schema_name.object_name.'));
        ELSE
            source_oid := to_regclass(source_name);
            IF source_kind = 'shared_condition' THEN
                SELECT version.condition_version_id INTO condition_version_id
                FROM pgreact_internal.shared_condition_versions version
                JOIN pgreact_internal.shared_conditions condition USING (condition_id)
                WHERE condition.condition_name = source_name
                  AND version.state = 'ACTIVE'
                  AND (app ->> 'version' IS NULL
                       OR version.version::text = app ->> 'version');
                IF condition_version_id IS NULL THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                        'M30_SHARED_CONDITION_NOT_FOUND', 'ERROR', source_name,
                        'spec.applicability.condition',
                        'the named shared condition version is not active',
                        'Deploy the shared condition and use its active version.'));
                END IF;
            END IF;
            IF source_oid IS NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                    'M30_SOURCE_NOT_FOUND', 'ERROR', source_name,
                    'spec.applicability', 'the applicability source does not exist',
                    'Create or restore it before previewing the policy set.'));
            ELSE
                SELECT c.relkind, c.relrowsecurity, c.relowner
                INTO relation_kind, source_rls, source_owner
                FROM pg_class c WHERE c.oid = source_oid;
                IF relation_kind NOT IN ('r', 'p', 'v', 'm', 'f') THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                        'M30_SOURCE_KIND', 'ERROR', source_name, 'spec.applicability',
                        'the applicability source is not a finite PostgreSQL relation',
                        'Use a table, partitioned table, view, materialized view, or foreign table.'));
                END IF;
                IF source_rls THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                        'M30_RLS_UNSUPPORTED', 'ERROR', source_name, 'spec.applicability',
                        'row-level-security sources are not supported',
                        'Expose an authorized non-RLS relation or view.'));
                END IF;
                IF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                        'M30_SOURCE_UNAUTHORIZED', 'ERROR', source_name, 'spec.applicability',
                        'the caller does not have SELECT on the applicability source',
                        'Grant SELECT on the source to the policy-set author.'));
                END IF;
                SELECT array_agg(a.atttypid::regtype::text ORDER BY requested.ordinal)
                INTO key_types
                FROM unnest(key_names) WITH ORDINALITY requested(key_name, ordinal)
                JOIN pg_attribute a ON a.attrelid = source_oid
                                   AND a.attname = requested.key_name
                                   AND a.attnum > 0 AND NOT a.attisdropped;
                IF cardinality(COALESCE(key_types, ARRAY[]::text[]))
                   <> cardinality(key_names) THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                        'M30_SUBJECT_KEY_NOT_FOUND', 'ERROR', source_name,
                        'spec.applicability.subject_keys',
                        'one or more subject key columns do not exist',
                        'Use columns present in the source relation.'));
                ELSIF EXISTS (
                    SELECT 1 FROM unnest(key_types) type_name
                    WHERE type_name NOT IN ('bigint', 'uuid', 'text')
                ) THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                        'M30_SUBJECT_KEY_TYPE', 'ERROR', source_name,
                        'spec.applicability.subject_keys',
                        'subject keys must be bigint, uuid, or text',
                        'Use the supported typed-key codec v2.'));
                ELSE
                    IF EXISTS (
                        SELECT 1
                        FROM unnest(key_names) WITH ORDINALITY requested(key_name, ordinal)
                        JOIN pg_attribute a ON a.attrelid = source_oid
                                             AND a.attname = requested.key_name
                        JOIN pg_collation c ON c.oid = a.attcollation
                        WHERE a.atttypid = 'text'::regtype
                          AND (NOT c.collisdeterministic OR c.collname NOT IN ('C', 'default'))
                    ) THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                            'M30_SUBJECT_KEY_COLLATION', 'ERROR', source_name,
                            'spec.applicability.subject_keys',
                            'text subject keys require deterministic C collation',
                            'Use text COLLATE "C" for the applicability key.'));
                    END IF;
                    details := pgreact_internal.m30_relation_details(source_oid, key_names);
                    IF (details ->> 'null_count')::bigint > 0 THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                            'M30_SUBJECT_NULL', 'ERROR', source_name,
                            'spec.applicability.subject_keys',
                            'applicability rows must have non-null subject keys',
                            'Remove null gate rows before deployment.', details));
                    END IF;
                    IF (details ->> 'distinct_count')::bigint
                       <> (details ->> 'row_count')::bigint THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                            'M30_SUBJECT_DUPLICATE', 'ERROR', source_name,
                            'spec.applicability.subject_keys',
                            'subject identities must be unique',
                            'Keep one row per eligible subject identity.', details));
                    END IF;
                    IF (details ->> 'row_count')::bigint > 100000 THEN
                        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                            'M30_LIMIT', 'ERROR', source_name, 'spec.applicability',
                            'applicability source exceeds the 100000-row limit',
                            'Partition or narrow the source before deployment.', details));
                    END IF;
                    source := jsonb_build_object(
                        'source_kind', source_kind,
                        'source_name', source_name,
                        'relation_oid', source_oid::text,
                        'condition_version_id', condition_version_id,
                        'subject_keys', to_jsonb(key_names),
                        'subject_types', to_jsonb(key_types));
                END IF;
            END IF;
        END IF;
    END IF;
    BEGIN
        valid_from := (spec ->> 'valid_from')::timestamptz;
    EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
        valid_from := NULL;
    END;
    IF valid_from IS NULL THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_VALID_FROM', 'ERROR', (declaration).name, 'spec.valid_from',
            'valid_from must be a timestamp',
            'Use an ISO-8601 PostgreSQL timestamptz.'));
    END IF;
    IF NULLIF(spec ->> 'valid_to', '') IS NOT NULL THEN
        BEGIN
            valid_to := (spec ->> 'valid_to')::timestamptz;
        EXCEPTION WHEN invalid_text_representation OR datetime_field_overflow THEN
            valid_to := NULL;
        END;
        IF valid_to IS NULL OR valid_from IS NULL OR valid_to <= valid_from THEN
            findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
                'M30_VALID_BOUNDS', 'ERROR', (declaration).name, 'spec.valid_to',
                'valid_to must be later than valid_from',
                'Use a half-open [valid_from, valid_to) interval.'));
        END IF;
    END IF;
    BEGIN
        evidence_limit := COALESCE((spec ->> 'evidence_limit')::integer, 100);
    EXCEPTION WHEN invalid_text_representation THEN
        evidence_limit := 0;
    END;
    IF evidence_limit < 1 OR evidence_limit > 1000 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m30_finding(
            'M30_EVIDENCE_LIMIT', 'ERROR', (declaration).name, 'spec.evidence_limit',
            'evidence_limit must be between 1 and 1000',
            'Choose a bounded evidence limit.'));
    END IF;
    RETURN jsonb_build_object(
        'normalized', normalized,
        'findings', findings,
        'source', source,
        'valid_from', valid_from,
        'valid_to', valid_to);
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_snapshot(normalized jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE app jsonb := normalized -> 'spec' -> 'applicability';
    source_oid oid := (app ->> 'relation_oid')::oid;
    key_names name[] := ARRAY(
        SELECT jsonb_array_elements_text(app -> 'subject_keys'))::name[];
    frontier timestamptz := (
        SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton);
    details jsonb;
    fingerprint text;
BEGIN
    IF source_oid IS NULL THEN
        source_oid := to_regclass(COALESCE(app ->> 'relation', app ->> 'condition'));
    END IF;
    details := pgreact_internal.m30_relation_details(source_oid, key_names);
    fingerprint := pgreact_internal.m30_relation_fingerprint(source_oid, key_names, frontier);
    RETURN jsonb_build_object(
        'source_kind', app ->> 'source_kind',
        'source_name', COALESCE(app ->> 'relation', app ->> 'condition'),
        'source_oid', source_oid,
        'subject_keys', to_jsonb(key_names),
        'complete_frontier', frontier,
        'applicability_fingerprint', fingerprint,
        'eligible_subject_count', details -> 'row_count',
        'eligible_subjects', details -> 'eligible_subjects',
        'eligibility_rows', details -> 'eligibility_rows');
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_digest(normalized jsonb, snapshot jsonb)
RETURNS text
LANGUAGE SQL IMMUTABLE STRICT AS $m30$
    SELECT encode(sha256(convert_to($1::text || ':' || $2::text, 'UTF8')), 'hex')
$m30$;

CREATE FUNCTION pgreact_internal.m30_envelope(
    operation text,
    normalized jsonb,
    state text,
    summary jsonb,
    findings jsonb DEFAULT '[]'::jsonb,
    evidence jsonb DEFAULT '{}'::jsonb,
    diagnostics jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE AS $m30$
    SELECT jsonb_build_object(
        'contract_version', 18,
        'operation', $1,
        'target', jsonb_build_object(
            'kind', COALESCE($2 ->> 'kind', '<unknown>'),
            'name', COALESCE($2 ->> 'name', '<unknown>')),
        'state', $3,
        'summary', COALESCE($4, '{}'::jsonb),
        'findings', COALESCE($5, '[]'::jsonb),
        'evidence', COALESCE($6, '{}'::jsonb),
        'diagnostics', COALESCE($7, '[]'::jsonb),
        'truncated', false)
$m30$;

CREATE FUNCTION pgreact_internal.m30_preview(
    declaration pgreact_api.declaration,
    operation text DEFAULT 'preview'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE checked jsonb;
    normalized jsonb;
    findings jsonb;
    snapshot jsonb;
    digest text;
    evidence_limit integer;
BEGIN
    checked := pgreact_internal.m30_validate(declaration);
    normalized := checked -> 'normalized';
    findings := checked -> 'findings';
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(findings) item
               WHERE item ->> 'severity' = 'ERROR') THEN
        RETURN pgreact_internal.m30_envelope(operation, normalized, 'attention',
            jsonb_build_object('read_only', true), findings);
    END IF;
    snapshot := pgreact_internal.m30_snapshot(normalized);
    digest := pgreact_internal.m30_digest(normalized, snapshot);
    evidence_limit := COALESCE((normalized -> 'spec' ->> 'evidence_limit')::integer, 100);
    RETURN pgreact_internal.m30_envelope(operation, normalized, 'ready',
        jsonb_build_object(
            'read_only', true,
            'preview_digest', digest,
            'version', normalized -> 'spec' ->> 'version',
            'member_count', jsonb_array_length(normalized -> 'spec' -> 'members'),
            'source_kind', snapshot ->> 'source_kind',
            'source_name', snapshot ->> 'source_name',
            'subject_keys', snapshot -> 'subject_keys',
            'complete_frontier', snapshot ->> 'complete_frontier',
            'applicability_fingerprint', snapshot ->> 'applicability_fingerprint',
            'eligible_subject_count', snapshot -> 'eligible_subject_count',
            'migration_state', 'READY'),
        findings,
        jsonb_build_object(
            'normalized_declaration', normalized,
            'raw_truth', jsonb_build_object('eligible_subjects', COALESCE(
                (SELECT jsonb_agg(value ORDER BY ordinal)
                 FROM jsonb_array_elements(snapshot -> 'eligible_subjects')
                      WITH ORDINALITY rows(value, ordinal)
                 WHERE ordinal <= evidence_limit), '[]'::jsonb)),
            'effective_truth', jsonb_build_object('scope_supports', 0),
            'subject_identity', jsonb_build_object(
                'keys', snapshot -> 'subject_keys',
                'codec_version', 2),
            'runtime_barriers', '[]'::jsonb,
            'work_recheck', jsonb_build_object('state', 'M31_REQUIRED')),
        '[]'::jsonb);
END
$m30$;

ALTER FUNCTION pgreact_api.validate(pgreact_api.declaration) RENAME TO validate_m29;
ALTER FUNCTION pgreact_api.preview(pgreact_api.declaration, jsonb) RENAME TO preview_m29;
ALTER FUNCTION pgreact_api.deploy(pgreact_api.declaration, jsonb) RENAME TO deploy_m29;
ALTER FUNCTION pgreact_api.status(pgreact_api.target, jsonb) RENAME TO status_m29;
ALTER FUNCTION pgreact_api.explain(pgreact_api.target, jsonb, jsonb) RENAME TO explain_m29;
ALTER FUNCTION pgreact_api.doctor(pgreact_api.target, jsonb) RENAME TO doctor_m29;
ALTER FUNCTION pgreact_api.run(pgreact_api.target, timestamptz) RENAME TO run_m29;
ALTER FUNCTION pgreact_api.remove(pgreact_api.target, jsonb) RENAME TO remove_m29;

CREATE FUNCTION pgreact_api.validate(declaration pgreact_api.declaration)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m30$
    SELECT CASE WHEN ($1).kind = 'policy_set'
        THEN pgreact_internal.m30_preview($1, 'validate')
        ELSE pgreact_api.validate_m29($1) END
$m30$;

CREATE FUNCTION pgreact_api.preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M30_OPTIONS: options must be a JSON object';
    END IF;
    IF (declaration).kind = 'policy_set' THEN
        RETURN pgreact_internal.m30_preview(declaration);
    END IF;
    RETURN pgreact_api.preview_m29(declaration, options);
END
$m30$;

CREATE FUNCTION pgreact_api.deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE checked jsonb;
    normalized jsonb;
    findings jsonb;
    snapshot jsonb;
    source jsonb;
    digest text;
    set_row pgreact_internal.policy_sets%ROWTYPE;
    existing pgreact_internal.policy_set_versions%ROWTYPE;
    set_id uuid;
    version_id uuid;
    owner_id oid := (SELECT oid FROM pg_roles WHERE rolname = session_user);
    set_version text;
    set_valid_from timestamptz;
    set_valid_to timestamptz;
    member jsonb;
    ordinal integer := 0;
BEGIN
    IF (declaration).kind <> 'policy_set' THEN
        RETURN pgreact_api.deploy_m29(declaration, preconditions);
    END IF;
    IF preconditions IS NULL OR jsonb_typeof(preconditions) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M30_PRECONDITIONS: preconditions must be a JSON object';
    END IF;
    checked := pgreact_internal.m30_validate(declaration);
    normalized := checked -> 'normalized';
    findings := checked -> 'findings';
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(findings) item
               WHERE item ->> 'severity' = 'ERROR') THEN
        RAISE EXCEPTION 'M30_VALIDATION: %', findings;
    END IF;
    snapshot := pgreact_internal.m30_snapshot(normalized);
    source := checked -> 'source';
    digest := pgreact_internal.m30_digest(normalized, snapshot);
    IF preconditions ->> 'preview_digest' IS NOT NULL
       AND preconditions ->> 'preview_digest' <> digest THEN
        RAISE EXCEPTION 'M30_PREVIEW_STALE'
            USING HINT = 'Preview the policy set again after source or member changes.';
    END IF;
    set_version := normalized -> 'spec' ->> 'version';
    set_valid_from := (normalized -> 'spec' ->> 'valid_from')::timestamptz;
    set_valid_to := NULLIF(normalized -> 'spec' ->> 'valid_to', '')::timestamptz;
    PERFORM pg_advisory_xact_lock(hashtextextended((declaration).name, 5788046901200004));
    SELECT * INTO set_row FROM pgreact_internal.policy_sets
    WHERE set_name = (declaration).name FOR UPDATE;
    IF FOUND THEN
        IF NOT pg_has_role(session_user, set_row.owner_oid, 'USAGE')
           AND NOT pgreact_internal.is_operator_admin() THEN
            RAISE EXCEPTION 'M30_OWNER: only the policy-set owner or operator may deploy this target';
        END IF;
        set_id := set_row.policy_set_id;
    ELSE
        INSERT INTO pgreact_internal.policy_sets(set_name, owner_oid)
        VALUES ((declaration).name, owner_id) RETURNING policy_set_id INTO set_id;
    END IF;
    SELECT * INTO existing FROM pgreact_internal.policy_set_versions
    WHERE policy_set_id = set_id AND version = set_version FOR UPDATE;
    IF FOUND THEN
        IF existing.declaration_digest IS DISTINCT FROM sha256(convert_to(normalized::text, 'UTF8')) THEN
            RAISE EXCEPTION 'M30_VERSION_IMMUTABLE: policy-set version % already has a different declaration',
                set_version;
        END IF;
        IF existing.state = 'DEPLOYED'
           AND COALESCE((preconditions ->> 'allow_create')::boolean, true) THEN
            RAISE EXCEPTION 'M30_EXISTS: policy-set version % is already deployed', set_version;
        END IF;
        version_id := existing.policy_set_version_id;
        UPDATE pgreact_internal.policy_set_versions
        SET state = 'DEPLOYED', removed_at = NULL, deployed_at = clock_timestamp(),
            subject_key = (source -> 'subject_keys' ->> 0)::name,
            subject_keys = ARRAY(SELECT jsonb_array_elements_text(source -> 'subject_keys'))::name[],
            subject_type = (source -> 'subject_types' ->> 0)::regtype,
            key_codec_version = 2, migration_state = 'READY',
            valid_from = set_valid_from, valid_to = set_valid_to,
            complete_frontier = (snapshot ->> 'complete_frontier')::timestamptz,
            applicability_fingerprint = snapshot ->> 'applicability_fingerprint',
            eligible_subjects = snapshot -> 'eligible_subjects',
            eligible_subject_count = (snapshot ->> 'eligible_subject_count')::bigint
        WHERE policy_set_version_id = version_id;
        DELETE FROM pgreact_internal.policy_set_members
        WHERE policy_set_version_id = version_id;
    ELSE
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.policy_set_versions other
            WHERE other.policy_set_id = set_id AND other.state = 'DEPLOYED'
              AND tstzrange(other.valid_from, COALESCE(other.valid_to, 'infinity'::timestamptz), '[)')
                  && tstzrange(set_valid_from, COALESCE(set_valid_to, 'infinity'::timestamptz), '[)')) THEN
            RAISE EXCEPTION 'M30_EFFECTIVE_OVERLAP: policy-set effective intervals overlap';
        END IF;
        INSERT INTO pgreact_internal.policy_set_versions(
            policy_set_id, version, normalized, declaration_digest, applicability_kind,
            applicability_source, applicability_source_oid, applicability_condition_version_id,
            subject_key, subject_keys, subject_type, key_codec_version,
            valid_from, valid_to, complete_frontier, applicability_fingerprint,
            eligible_subjects, eligible_subject_count, migration_state, state, deployed_at)
        VALUES (
            set_id, set_version, normalized, sha256(convert_to(normalized::text, 'UTF8')),
            source ->> 'source_kind', source ->> 'source_name',
            (source ->> 'relation_oid')::oid, (source ->> 'condition_version_id')::uuid,
            (source -> 'subject_keys' ->> 0)::name,
            ARRAY(SELECT jsonb_array_elements_text(source -> 'subject_keys'))::name[],
            (source -> 'subject_types' ->> 0)::regtype, 2,
            set_valid_from, set_valid_to,
            (snapshot ->> 'complete_frontier')::timestamptz,
            snapshot ->> 'applicability_fingerprint',
            snapshot -> 'eligible_subjects',
            (snapshot ->> 'eligible_subject_count')::bigint,
            'READY', 'DEPLOYED', clock_timestamp())
        RETURNING policy_set_version_id INTO version_id;
    END IF;
    FOR member IN SELECT value FROM jsonb_array_elements(normalized -> 'spec' -> 'members') value LOOP
        ordinal := ordinal + 1;
        INSERT INTO pgreact_internal.policy_set_members(
            policy_set_version_id, ordinal, member_kind, member_name, member_version,
            member_target, match_keys, subject_keys, scope_mode, disposition)
        VALUES (
            version_id, ordinal, member ->> 'kind', member ->> 'name', member ->> 'version',
            member,
            ARRAY(SELECT jsonb_array_elements_text(member -> 'match_keys'))::name[],
            ARRAY(SELECT jsonb_array_elements_text(member -> 'subject_keys'))::name[],
            member ->> 'scope_mode', member ->> 'disposition');
    END LOOP;
    DELETE FROM pgreact_internal.policy_set_eligibility
    WHERE policy_set_version_id = version_id;
    INSERT INTO pgreact_internal.policy_set_eligibility(
        policy_set_version_id, subject_identity, subject_values, key_types,
        key_codec_version, complete_frontier, source_fingerprint)
    SELECT version_id, decode(row_data ->> 'subject_identity', 'hex'),
           row_data -> 'subject_values',
           ARRAY(SELECT jsonb_array_elements_text(row_data -> 'key_types'))::text[],
           2, (snapshot ->> 'complete_frontier')::timestamptz,
           snapshot ->> 'applicability_fingerprint'
    FROM jsonb_array_elements(snapshot -> 'eligibility_rows') row_data;
    INSERT INTO pgreact_internal.policy_set_history(
        policy_set_version_id, event_kind, frontier, details)
    VALUES (version_id, 'DEPLOYED',
        (snapshot ->> 'complete_frontier')::timestamptz,
        jsonb_build_object('preview_digest', digest,
            'eligible_subject_count', snapshot -> 'eligible_subject_count',
            'key_codec_version', 2));
    INSERT INTO pgreact_internal.declaration_migrations(
        declaration_id, kind, object_name, object_version, state, reason, remediation)
    VALUES (
        (SELECT declaration_id FROM pgreact_internal.api_declarations
         WHERE kind = 'policy_set' AND object_name = (declaration).name),
        'policy_set', (declaration).name, set_version, 'READY',
        'M30 canonical applicability foundation is deployed',
        'Use status, explain, and the relational inspection views.')
    ON CONFLICT (kind, object_name, object_version) DO UPDATE SET
        state = EXCLUDED.state, reason = EXCLUDED.reason,
        remediation = EXCLUDED.remediation, observed_at = clock_timestamp();
    RETURN pgreact_internal.m30_envelope('deploy', normalized, 'deployed',
        jsonb_build_object(
            'read_only', false,
            'policy_set_version_id', version_id,
            'version', set_version,
            'subject_keys', snapshot -> 'subject_keys',
            'eligible_subject_count', snapshot -> 'eligible_subject_count',
            'migration_state', 'READY',
            'runtime_state', 'FOUNDATION_ONLY'),
        findings,
        jsonb_build_object(
            'raw_truth', jsonb_build_object('eligible_subject_count',
                snapshot -> 'eligible_subject_count'),
            'effective_truth', jsonb_build_object('scope_supports', 0),
            'subject_identity', jsonb_build_object(
                'keys', snapshot -> 'subject_keys', 'codec_version', 2),
            'runtime_barriers', '[]'::jsonb,
            'work_recheck', jsonb_build_object('state', 'M31_REQUIRED')));
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_status(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE version_row pgreact_internal.policy_set_versions%ROWTYPE;
    normalized jsonb;
    members jsonb;
    barrier_count bigint;
    migration_state text;
BEGIN
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND ((target).version IS NULL OR version.version = (target).version)
    ORDER BY version.valid_from DESC, version.created_at DESC LIMIT 1;
    IF NOT FOUND THEN
        normalized := jsonb_build_object('api_version', '1', 'kind', 'policy_set',
            'name', (target).name, 'spec', '{}'::jsonb);
        RETURN pgreact_internal.m30_envelope('status', normalized, 'not_found',
            jsonb_build_object('read_only', true),
            jsonb_build_array(pgreact_internal.m30_finding(
                'M30_TARGET_NOT_FOUND', 'ERROR', (target).name, 'target',
                'policy-set target was not found',
                'Use the stable policy-set name and version.')));
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
        'ordinal', ordinal, 'kind', member_kind, 'name', member_name,
        'version', member_version, 'match_keys', to_jsonb(match_keys),
        'subject_keys', to_jsonb(subject_keys), 'scope_mode', scope_mode,
        'disposition', disposition) ORDER BY ordinal)
    INTO members
    FROM pgreact_internal.policy_set_members
    WHERE policy_set_version_id = version_row.policy_set_version_id;
    SELECT count(*) INTO barrier_count
    FROM pgreact_internal.policy_set_runtime_barriers
    WHERE policy_set_version_id = version_row.policy_set_version_id
      AND cleared_at IS NULL;
    migration_state := version_row.migration_state;
    RETURN pgreact_internal.m30_envelope('status', version_row.normalized,
        CASE WHEN barrier_count > 0 THEN 'blocked' ELSE lower(version_row.state) END,
        jsonb_build_object(
            'read_only', true,
            'declaration_state', lower(version_row.state),
            'runtime_state', 'FOUNDATION_ONLY',
            'migration_state', migration_state,
            'policy_set_version_id', version_row.policy_set_version_id,
            'version', version_row.version,
            'owner', pg_get_userbyid(
                (SELECT owner_oid FROM pgreact_internal.policy_sets
                 WHERE policy_set_id = version_row.policy_set_id)),
            'subject_keys', to_jsonb(version_row.subject_keys),
            'valid_from', version_row.valid_from, 'valid_to', version_row.valid_to,
            'complete_frontier', version_row.complete_frontier,
            'applicability_fingerprint', version_row.applicability_fingerprint,
            'eligible_subject_count', version_row.eligible_subject_count,
            'scope_support_count', (SELECT count(*) FROM pgreact_internal.policy_set_scope_supports
                                    WHERE policy_set_version_id = version_row.policy_set_version_id),
            'runtime_barrier_count', barrier_count,
            'members', COALESCE(members, '[]'::jsonb)),
        '[]'::jsonb,
        jsonb_build_object(
            'normalized_declaration', version_row.normalized,
            'raw_truth', jsonb_build_object(
                'eligible_subjects', COALESCE(
                    (SELECT jsonb_agg(subject_values ORDER BY subject_values::text)
                     FROM (
                         SELECT subject_values
                         FROM pgreact_internal.policy_set_eligibility
                         WHERE policy_set_version_id = version_row.policy_set_version_id
                         ORDER BY subject_values::text LIMIT 1000
                     ) bounded), '[]'::jsonb)),
            'effective_truth', jsonb_build_object('scope_supports', 0),
            'subject_identity', jsonb_build_object(
                'keys', to_jsonb(version_row.subject_keys), 'codec_version', 2),
            'runtime_barriers', COALESCE(
                (SELECT jsonb_agg(to_jsonb(barrier) ORDER BY barrier.code)
                 FROM pgreact_internal.policy_set_runtime_barriers barrier
                 WHERE barrier.policy_set_version_id = version_row.policy_set_version_id
                   AND barrier.cleared_at IS NULL), '[]'::jsonb),
            'work_recheck', jsonb_build_object('state', 'M31_REQUIRED')),
        CASE WHEN barrier_count > 0 THEN jsonb_build_array(pgreact_internal.m30_finding(
            'M30_RUNTIME_BARRIER', 'ERROR', (target).name, 'applicability',
            'applicability is blocked by a runtime barrier',
            'Repair the source and run the coordinated M31 maintenance path.'))
        ELSE '[]'::jsonb END);
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_subject_eligible(
    target pgreact_api.target,
    subject jsonb
)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE version_row pgreact_internal.policy_set_versions%ROWTYPE;
    requested_key_values jsonb := '[]'::jsonb;
    requested_key_types text[];
    key_name name;
    position integer := 0;
BEGIN
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND ((target).version IS NULL OR version.version = (target).version)
      AND version.state = 'DEPLOYED'
    ORDER BY version.valid_from DESC LIMIT 1;
    IF NOT FOUND OR subject IS NULL THEN
        RETURN false;
    END IF;
    FOREACH key_name IN ARRAY version_row.subject_keys LOOP
        position := position + 1;
        requested_key_values := requested_key_values || jsonb_build_array(
            CASE WHEN jsonb_typeof(subject) = 'object'
                 THEN subject -> key_name::text
                 ELSE subject -> (position - 1) END);
    END LOOP;
    SELECT eligibility.key_types INTO requested_key_types
    FROM pgreact_internal.policy_set_eligibility eligibility
    WHERE eligibility.policy_set_version_id = version_row.policy_set_version_id
    LIMIT 1;
    IF requested_key_types IS NULL THEN
        SELECT array_agg(a.atttypid::regtype::text ORDER BY requested.ordinal)
        INTO requested_key_types
        FROM unnest(version_row.subject_keys) WITH ORDINALITY requested(key_name, ordinal)
        JOIN pg_attribute a ON a.attrelid = version_row.applicability_source_oid
                           AND a.attname = requested.key_name
                           AND a.attnum > 0 AND NOT a.attisdropped;
    END IF;
    RETURN EXISTS (
        SELECT 1 FROM pgreact_internal.policy_set_eligibility eligibility
        WHERE eligibility.policy_set_version_id = version_row.policy_set_version_id
          AND eligibility.subject_identity =
              pgreact_internal.m30_key_identity(requested_key_types, requested_key_values));
END
$m30$;

CREATE FUNCTION pgreact_internal.m30_explain(
    target pgreact_api.target,
    subject jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
    SELECT pgreact_internal.m30_status($1) || jsonb_build_object(
        'operation', 'explain',
        'evidence', jsonb_build_object(
            'subject', $2,
            'scope_mode', 'POLICY_SET_REQUIRED',
            'eligible', CASE WHEN $2 IS NULL THEN NULL
                ELSE pgreact_internal.m30_subject_eligible($1, $2) END,
            'supporting_policy_sets', '[]'::jsonb,
            'effective_match', false,
            'reason', CASE WHEN $2 IS NULL THEN 'SUBJECT_NOT_PROVIDED'
                WHEN pgreact_internal.m30_subject_eligible($1, $2)
                    THEN 'FOUNDATION_ELIGIBLE'
                ELSE 'SUBJECT_NOT_ELIGIBLE' END,
            'activation', NULL,
            'work', '[]'::jsonb))
$m30$;

CREATE FUNCTION pgreact_internal.m30_doctor(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE result jsonb := pgreact_internal.m30_status(target);
    version_row pgreact_internal.policy_set_versions%ROWTYPE;
    current_fingerprint text;
    diagnostics jsonb;
BEGIN
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND ((target).version IS NULL OR version.version = (target).version)
      AND version.state = 'DEPLOYED'
    ORDER BY version.valid_from DESC LIMIT 1;
    IF NOT FOUND THEN
        diagnostics := jsonb_build_array(pgreact_internal.m30_finding(
            'M30_TARGET_NOT_FOUND', 'ERROR', (target).name, 'target',
            'no deployed policy-set version is available',
            'Deploy a valid policy-set version.'));
    ELSE
        current_fingerprint := pgreact_internal.m30_relation_fingerprint(
            version_row.applicability_source_oid, version_row.subject_keys,
            (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton));
        IF current_fingerprint IS DISTINCT FROM version_row.applicability_fingerprint THEN
            diagnostics := jsonb_build_array(pgreact_internal.m30_finding(
                'M30_SOURCE_DRIFT', 'ERROR', (target).name, 'applicability',
                'the applicability source changed after deployment',
                'Run the foundation refresh or deploy a new immutable version.',
                jsonb_build_object('deployed', version_row.applicability_fingerprint,
                                   'current', current_fingerprint)));
        ELSE
            diagnostics := jsonb_build_array(jsonb_build_object(
                'code', 'M30_FOUNDATION_READY', 'severity', 'INFO', 'blocker', false,
                'object_identity', (target).name,
                'message', 'relational applicability foundation is current',
                'hint', 'M31 must add authoritative runtime transitions.'));
        END IF;
    END IF;
    RETURN result || jsonb_build_object('operation', 'doctor', 'diagnostics', diagnostics);
END
$m30$;

CREATE FUNCTION pgreact_api.status(
    target pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m30$
    SELECT CASE WHEN ($1).kind = 'policy_set'
        THEN pgreact_internal.m30_status($1)
        ELSE pgreact_api.status_m29($1, $2) END
$m30$;

CREATE FUNCTION pgreact_api.explain(
    target pgreact_api.target,
    subject jsonb DEFAULT NULL,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m30$
    SELECT CASE WHEN ($1).kind = 'policy_set'
        THEN pgreact_internal.m30_explain($1, $2)
        ELSE pgreact_api.explain_m29($1, $2, $3) END
$m30$;

CREATE FUNCTION pgreact_api.doctor(
    target pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m30$
    SELECT CASE WHEN ($1).kind = 'policy_set'
        THEN pgreact_internal.m30_doctor($1)
        ELSE pgreact_api.doctor_m29($1, $2) END
$m30$;

CREATE FUNCTION pgreact_api.run(
    target pgreact_api.target,
    sampled_time timestamptz DEFAULT clock_timestamp()
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE version_row pgreact_internal.policy_set_versions%ROWTYPE;
    normalized jsonb;
    snapshot jsonb;
BEGIN
    IF (target).kind <> 'policy_set' THEN
        RETURN pgreact_api.run_m29(target, sampled_time);
    END IF;
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND ((target).version IS NULL OR version.version = (target).version)
      AND version.state = 'DEPLOYED'
      AND version.valid_from <= sampled_time
      AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
    ORDER BY version.valid_from DESC LIMIT 1;
    IF NOT FOUND THEN
        RETURN pgreact_internal.m30_status(target) || jsonb_build_object(
            'operation', 'run', 'sampled_time', sampled_time);
    END IF;
    normalized := version_row.normalized;
    snapshot := pgreact_internal.m30_snapshot(normalized);
    UPDATE pgreact_internal.policy_set_versions
    SET complete_frontier = (snapshot ->> 'complete_frontier')::timestamptz,
        applicability_fingerprint = snapshot ->> 'applicability_fingerprint',
        eligible_subjects = snapshot -> 'eligible_subjects',
        eligible_subject_count = (snapshot ->> 'eligible_subject_count')::bigint
    WHERE policy_set_version_id = version_row.policy_set_version_id;
    DELETE FROM pgreact_internal.policy_set_eligibility
    WHERE policy_set_version_id = version_row.policy_set_version_id;
    INSERT INTO pgreact_internal.policy_set_eligibility(
        policy_set_version_id, subject_identity, subject_values, key_types,
        key_codec_version, complete_frontier, source_fingerprint)
    SELECT version_row.policy_set_version_id, decode(row_data ->> 'subject_identity', 'hex'),
           row_data -> 'subject_values',
           ARRAY(SELECT jsonb_array_elements_text(row_data -> 'key_types'))::text[],
           2, (snapshot ->> 'complete_frontier')::timestamptz,
           snapshot ->> 'applicability_fingerprint'
    FROM jsonb_array_elements(snapshot -> 'eligibility_rows') row_data;
    INSERT INTO pgreact_internal.policy_set_history(
        policy_set_version_id, event_kind, frontier, details)
    VALUES (version_row.policy_set_version_id, 'REFRESHED',
        (snapshot ->> 'complete_frontier')::timestamptz,
        jsonb_build_object('eligible_subject_count',
            snapshot -> 'eligible_subject_count', 'foundation_only', true));
    RETURN pgreact_internal.m30_status(target) || jsonb_build_object(
        'operation', 'run', 'sampled_time', sampled_time,
        'foundation_refreshed', true);
END
$m30$;

CREATE FUNCTION pgreact_api.remove(
    target pgreact_api.target,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
DECLARE version_row pgreact_internal.policy_set_versions%ROWTYPE;
    owner_id oid;
BEGIN
    IF (target).kind <> 'policy_set' THEN
        RETURN pgreact_api.remove_m29(target, preconditions);
    END IF;
    SELECT version.* INTO version_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (target).name
      AND ((target).version IS NULL OR version.version = (target).version)
    ORDER BY version.valid_from DESC LIMIT 1 FOR UPDATE;
    IF NOT FOUND THEN
        RETURN pgreact_internal.m30_status(target);
    END IF;
    SELECT set.owner_oid INTO owner_id FROM pgreact_internal.policy_sets set
    WHERE set.policy_set_id = version_row.policy_set_id;
    IF NOT pg_has_role(session_user, owner_id, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M30_OWNER: only the policy-set owner or operator may remove this target';
    END IF;
    UPDATE pgreact_internal.policy_set_versions
    SET state = 'REMOVED', removed_at = clock_timestamp()
    WHERE policy_set_version_id = version_row.policy_set_version_id;
    INSERT INTO pgreact_internal.policy_set_history(
        policy_set_version_id, event_kind, frontier, details)
    VALUES (version_row.policy_set_version_id, 'REMOVED',
        (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton),
        jsonb_build_object('foundation_only', true));
    RETURN pgreact_internal.m30_envelope('remove', version_row.normalized, 'removed',
        jsonb_build_object('read_only', false,
            'policy_set_version_id', version_row.policy_set_version_id,
            'migration_state', version_row.migration_state,
            'runtime_state', 'FOUNDATION_ONLY'));
END
$m30$;

DROP VIEW IF EXISTS pgreact.policy_set_eligible_subjects;

CREATE VIEW pgreact.policy_set_eligible_subjects AS
SELECT eligibility.policy_set_version_id,
       set.set_name,
       version.version,
       CASE WHEN jsonb_array_length(eligibility.subject_values) = 1
            THEN eligibility.subject_values -> 0
            ELSE eligibility.subject_values END AS subject,
       encode(eligibility.subject_identity, 'hex') AS subject_identity,
       eligibility.subject_values,
       eligibility.key_types,
       eligibility.key_codec_version,
       eligibility.complete_frontier,
       eligibility.source_fingerprint
FROM pgreact_internal.policy_set_eligibility eligibility
JOIN pgreact_internal.policy_set_versions version
  USING (policy_set_version_id)
JOIN pgreact_internal.policy_sets set USING (policy_set_id);

CREATE VIEW pgreact.policy_set_scope_supports AS
SELECT support.scope_support_id,
       set.set_name,
       version.version,
       support.member_kind,
       support.member_name,
       support.member_version,
       encode(support.match_identity, 'hex') AS match_identity,
       encode(support.subject_identity, 'hex') AS subject_identity,
       support.subject_values,
       support.support_generation,
       support.complete_frontier,
       support.created_at
FROM pgreact_internal.policy_set_scope_supports support
JOIN pgreact_internal.policy_set_versions version
  USING (policy_set_version_id)
JOIN pgreact_internal.policy_sets set USING (policy_set_id);

CREATE VIEW pgreact.match_scope_supports AS
SELECT * FROM pgreact.policy_set_scope_supports;

CREATE VIEW pgreact.policy_set_runtime_barriers AS
SELECT barrier.policy_set_version_id,
       set.set_name,
       version.version,
       barrier.code,
       barrier.details,
       barrier.created_at,
       barrier.cleared_at
FROM pgreact_internal.policy_set_runtime_barriers barrier
JOIN pgreact_internal.policy_set_versions version
  USING (policy_set_version_id)
JOIN pgreact_internal.policy_sets set USING (policy_set_id);

CREATE VIEW pgreact.declaration_migrations AS
SELECT migration_id, declaration_id, kind, object_name, object_version,
       state, reason, remediation, observed_at
FROM pgreact_internal.declaration_migrations;

UPDATE pgreact_internal.policy_set_members
SET match_keys = COALESCE(match_keys, ARRAY[]::name[]);

INSERT INTO pgreact_internal.policy_set_eligibility(
    policy_set_version_id, subject_identity, subject_values, key_types,
    key_codec_version, complete_frontier, source_fingerprint)
SELECT version.policy_set_version_id,
       pgreact_internal.m30_key_identity(
           ARRAY[version.subject_type::text],
           jsonb_build_array(value)),
       jsonb_build_array(value),
       ARRAY[version.subject_type::text],
       2, version.complete_frontier, version.applicability_fingerprint
FROM pgreact_internal.policy_set_versions version
CROSS JOIN LATERAL jsonb_array_elements(version.eligible_subjects) value
ON CONFLICT (policy_set_version_id, subject_identity) DO NOTHING;

INSERT INTO pgreact_internal.declaration_migrations(
    declaration_id, kind, object_name, object_version, state, reason, remediation)
SELECT declaration.declaration_id,
       declaration.kind,
       declaration.object_name,
       COALESCE(declaration.spec ->> 'version', ''),
       CASE WHEN declaration.kind = 'policy_set' THEN 'NEEDS_SCOPE_MIGRATION'
            WHEN declaration.delegated_id IS NULL THEN 'LEGACY_METADATA'
            ELSE 'GLOBAL' END,
       CASE WHEN declaration.kind = 'policy_set'
            THEN 'M29 policy-set metadata has no explicit M30 scope mode'
            WHEN declaration.delegated_id IS NULL
            THEN 'declaration metadata has no authoritative delegated identity'
            ELSE 'existing delegated declaration remains global' END,
       CASE WHEN declaration.kind = 'policy_set'
            THEN 'Declare, preview, and deploy a new POLICY_SET_REQUIRED member version'
            WHEN declaration.delegated_id IS NULL
            THEN 'Use the supported specialized API or redeclare with an authoritative adapter'
            ELSE 'No migration is required for the existing global declaration' END
FROM pgreact_internal.api_declarations declaration
ON CONFLICT (kind, object_name, object_version) DO UPDATE SET
    declaration_id = EXCLUDED.declaration_id,
    state = EXCLUDED.state,
    reason = EXCLUDED.reason,
    remediation = EXCLUDED.remediation,
    observed_at = clock_timestamp();

ALTER FUNCTION pgreact_api.configure_roles(
    regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m29;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole,
    operator_role regrole,
    worker_role regrole,
    reader_role regrole,
    advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m30$
BEGIN
    PERFORM pgreact_internal.configure_roles_m29(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT SELECT ON pgreact.policy_set_eligible_subjects, '
                   'pgreact.policy_set_scope_supports, pgreact.match_scope_supports, '
                   'pgreact.policy_set_runtime_barriers, pgreact.declaration_migrations '
                   'TO %I, %I', reader_role::text, operator_role::text);
END
$m30$;

DO $m30$
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
$m30$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;
REVOKE ALL ON pgreact.policy_sets, pgreact.policy_set_versions,
    pgreact.policy_set_members, pgreact.policy_set_eligible_subjects,
    pgreact.policy_set_scope_supports, pgreact.match_scope_supports,
    pgreact.policy_set_runtime_barriers, pgreact.declaration_migrations FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M30 applicability foundation: typed relational eligibility and inspectable scope state';
