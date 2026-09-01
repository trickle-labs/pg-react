-- M43 semantic policy differences over the existing canonical declaration model.

CREATE FUNCTION pgreact_internal.m43_finding(
    code text,
    severity text,
    message text,
    hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m43$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'message', $3,
        'hint', $4,
        'details', COALESCE($5, '{}'::jsonb))
$m43$;

CREATE FUNCTION pgreact_internal.m43_finding_registry()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m43$
SELECT jsonb_build_array(
    jsonb_build_object('code', 'M43_OPTIONS_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M43_INVALID_DECLARATION', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M43_TARGET_UNAVAILABLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M43_KIND_MISMATCH', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M43_NAME_MISMATCH', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M43_VERSION_STALE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M43_UNSUPPORTED_KIND', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M43_UNSUPPORTED_FIELD', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M43_OBJECT_UNAVAILABLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M43_OPAQUE_CHANGE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M43_LIMIT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M43_CHANGED_STATE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M43_NO_DIFFERENCE', 'severity', 'INFO'))
$m43$;

CREATE FUNCTION pgreact_internal.m43_digest(value jsonb)
RETURNS text
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m43$
    SELECT encode(sha256(convert_to($1::text, 'UTF8')), 'hex')
$m43$;

CREATE FUNCTION pgreact_internal.m43_declaration_digest(value jsonb)
RETURNS text
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m43$
    SELECT pgreact_internal.m43_digest($1)
$m43$;

CREATE FUNCTION pgreact_internal.m43_field_kind(target_kind text, field_path text)
RETURNS text
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m43$
SELECT CASE
    WHEN $1 = 'rule' AND $2 = 'spec.condition' THEN 'relation_identity'
    WHEN $1 = 'rule' AND $2 IN ('spec.on_activate', 'spec.on_deactivate', 'spec.on_change')
        THEN 'function_identity'
    WHEN $1 = 'rule' AND $2 IN ('spec.semantic_key', 'spec.change_columns', 'spec.conflict_key_columns')
        THEN CASE WHEN $2 = 'spec.semantic_key' THEN 'identifier' ELSE 'ordered_list' END
    WHEN $1 = 'rule' AND $2 IN ('spec.kind', 'spec.bootstrap_policy', 'spec.salience',
                               'spec.agenda_group', 'spec.max_attempts',
                               'spec.initial_backoff_seconds', 'spec.backoff_multiplier',
                               'spec.max_backoff_seconds', 'spec.delegate') THEN 'scalar'
    WHEN $1 = 'rule' AND $2 = 'spec.evidence_snapshot' THEN 'typed_value'
    WHEN $1 = 'decision_program' AND $2 = 'spec.candidate_relation' THEN 'relation_identity'
    WHEN $1 = 'decision_program' AND $2 IN ('spec.subject_key', 'spec.candidate_key', 'spec.priority')
        THEN 'identifier'
    WHEN $1 = 'decision_program' AND $2 = 'spec.results' THEN 'result_binding'
    WHEN $1 = 'decision_program' AND $2 IN ('spec.valid_from', 'spec.valid_to') THEN 'time_bound'
    WHEN $1 = 'decision_program' AND $2 IN ('spec.max_candidates', 'spec.delegate') THEN 'scalar'
    WHEN $1 = 'decision_program' AND $2 = 'spec.evidence_snapshot' THEN 'typed_value'
    WHEN $1 = 'policy_set' AND $2 = 'spec.members' THEN 'keyed_set'
    WHEN $1 = 'policy_set' AND $2 = 'spec.applicability.relation' THEN 'relation_identity'
    WHEN $1 = 'policy_set' AND $2 = 'spec.applicability.condition' THEN 'relation_identity'
    WHEN $1 = 'policy_set' AND $2 = 'spec.applicability.subject_keys' THEN 'ordered_list'
    WHEN $1 = 'policy_set' AND $2 IN ('spec.applicability.source_kind',
                                     'spec.applicability.version', 'spec.version',
                                     'spec.evidence_limit') THEN 'scalar'
    WHEN $1 = 'policy_set' AND $2 IN ('spec.valid_from', 'spec.valid_to') THEN 'time_bound'
    ELSE NULL
END
$m43$;

CREATE FUNCTION pgreact_internal.m43_field_inventory(target_kind text)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m43$
WITH fields(field_path, field_kind, order_semantics, opaque_boundary) AS (
    SELECT * FROM (VALUES
        ('spec.condition', 'relation_identity', 'not_applicable', 'relation_definition'),
        ('spec.semantic_key', 'identifier', 'not_applicable', 'none'),
        ('spec.kind', 'scalar', 'not_applicable', 'none'),
        ('spec.on_activate', 'function_identity', 'not_applicable', 'function_body'),
        ('spec.on_deactivate', 'function_identity', 'not_applicable', 'function_body'),
        ('spec.on_change', 'function_identity', 'not_applicable', 'function_body'),
        ('spec.bootstrap_policy', 'scalar', 'not_applicable', 'none'),
        ('spec.change_columns', 'ordered_list', 'semantic', 'none'),
        ('spec.salience', 'scalar', 'not_applicable', 'none'),
        ('spec.agenda_group', 'scalar', 'not_applicable', 'none'),
        ('spec.conflict_key_columns', 'ordered_list', 'semantic', 'none'),
        ('spec.max_attempts', 'scalar', 'not_applicable', 'none'),
        ('spec.initial_backoff_seconds', 'scalar', 'not_applicable', 'none'),
        ('spec.backoff_multiplier', 'scalar', 'not_applicable', 'none'),
        ('spec.max_backoff_seconds', 'scalar', 'not_applicable', 'none'),
        ('spec.evidence_snapshot', 'typed_value', 'key_order_insensitive', 'none')
    ) AS rule_fields
    WHERE $1 = 'rule'
    UNION ALL
    SELECT * FROM (VALUES
        ('spec.candidate_relation', 'relation_identity', 'not_applicable', 'relation_definition'),
        ('spec.subject_key', 'identifier', 'not_applicable', 'none'),
        ('spec.candidate_key', 'identifier', 'not_applicable', 'none'),
        ('spec.priority', 'identifier', 'not_applicable', 'none'),
        ('spec.results', 'result_binding', 'semantic', 'none'),
        ('spec.valid_from', 'time_bound', 'not_applicable', 'none'),
        ('spec.valid_to', 'time_bound', 'not_applicable', 'none'),
        ('spec.max_candidates', 'scalar', 'not_applicable', 'none'),
        ('spec.delegate', 'scalar', 'not_applicable', 'none'),
        ('spec.evidence_snapshot', 'typed_value', 'key_order_insensitive', 'none')
    ) AS decision_fields
    WHERE $1 = 'decision_program'
    UNION ALL
    SELECT * FROM (VALUES
        ('spec.version', 'scalar', 'not_applicable', 'none'),
        ('spec.members', 'keyed_set', 'key_order_insensitive', 'none'),
        ('spec.applicability.source_kind', 'scalar', 'not_applicable', 'none'),
        ('spec.applicability.relation', 'relation_identity', 'not_applicable', 'relation_definition'),
        ('spec.applicability.condition', 'relation_identity', 'not_applicable', 'relation_definition'),
        ('spec.applicability.version', 'scalar', 'not_applicable', 'none'),
        ('spec.applicability.subject_keys', 'ordered_list', 'semantic', 'none'),
        ('spec.valid_from', 'time_bound', 'not_applicable', 'none'),
        ('spec.valid_to', 'time_bound', 'not_applicable', 'none'),
        ('spec.evidence_limit', 'scalar', 'not_applicable', 'none')
    ) AS set_fields
    WHERE $1 = 'policy_set'
)
SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'field_path', field_path,
    'field_kind', field_kind,
    'order_semantics', order_semantics,
    'opaque_boundary', opaque_boundary,
    'missing', 'absent_is_distinct',
    'explicit_null', 'distinct_value'), '[]'::jsonb)
FROM fields
$m43$;

CREATE FUNCTION pgreact_internal.m43_prepare_declaration(declaration pgreact_api.declaration)
RETURNS pgreact_api.declaration
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m43$
DECLARE spec jsonb;
    field text;
    relation_name text;
    relation_oid oid;
    function_oid oid;
BEGIN
    IF declaration IS NULL THEN RETURN NULL; END IF;
    spec := COALESCE((declaration).spec, '{}'::jsonb);
    FOREACH field IN ARRAY ARRAY['condition', 'candidate_relation'] LOOP
        IF spec ? field THEN
            relation_name := spec ->> field;
            relation_oid := to_regclass(relation_name);
            IF relation_oid IS NOT NULL THEN
                spec := jsonb_set(spec, ARRAY[field], to_jsonb(relation_oid::regclass::text), true);
            END IF;
        END IF;
    END LOOP;
    IF (declaration).kind = 'policy_set'
       AND jsonb_typeof(spec -> 'applicability') = 'object' THEN
        relation_name := spec -> 'applicability' ->> 'relation';
        relation_oid := to_regclass(relation_name);
        IF relation_oid IS NOT NULL THEN
            spec := jsonb_set(spec, '{applicability,relation}',
                              to_jsonb(relation_oid::regclass::text), true);
        END IF;
        relation_name := spec -> 'applicability' ->> 'condition';
        relation_oid := to_regclass(relation_name);
        IF relation_oid IS NOT NULL THEN
            spec := jsonb_set(spec, '{applicability,condition}',
                              to_jsonb(relation_oid::regclass::text), true);
        END IF;
    END IF;
    FOREACH field IN ARRAY ARRAY['on_activate', 'on_deactivate', 'on_change'] LOOP
        IF spec ? field THEN
            BEGIN
                function_oid := to_regprocedure(spec ->> field);
                IF function_oid IS NOT NULL THEN
                    spec := jsonb_set(spec, ARRAY[field],
                                      to_jsonb(function_oid::regprocedure::text), true);
                END IF;
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END IF;
    END LOOP;
    RETURN ROW((declaration).api_version, (declaration).kind, (declaration).name, spec)
        ::pgreact_api.declaration;
END
$m43$;

CREATE FUNCTION pgreact_internal.m43_field_paths(
    target_kind text,
    current_normalized jsonb,
    proposed_normalized jsonb
)
RETURNS text[]
LANGUAGE SQL
IMMUTABLE
AS $m43$
WITH all_specs AS (
    SELECT COALESCE($2 -> 'spec', '{}'::jsonb) AS spec
    UNION ALL
    SELECT COALESCE($3 -> 'spec', '{}'::jsonb)
), top_paths AS (
    SELECT 'spec.' || key AS field_path
    FROM all_specs, LATERAL jsonb_object_keys(spec) AS keys(key)
    WHERE $1 <> 'policy_set' OR key <> 'applicability'
    GROUP BY key
), applicability_paths AS (
    SELECT 'spec.applicability.' || key AS field_path
    FROM all_specs,
         LATERAL jsonb_object_keys(COALESCE(spec -> 'applicability', '{}'::jsonb)) AS keys(key)
    WHERE $1 = 'policy_set'
    GROUP BY key
)
SELECT COALESCE(array_agg(field_path ORDER BY field_path), ARRAY[]::text[])
FROM (SELECT field_path FROM top_paths UNION SELECT field_path FROM applicability_paths) paths
$m43$;

CREATE FUNCTION pgreact_internal.m43_json_depth(value jsonb)
RETURNS integer
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m43$
SELECT CASE jsonb_typeof($1)
    WHEN 'object' THEN 1 + COALESCE((
        SELECT max(pgreact_internal.m43_json_depth(item.value))
        FROM jsonb_each($1) item), 0)
    WHEN 'array' THEN 1 + COALESCE((
        SELECT max(pgreact_internal.m43_json_depth(item.value))
        FROM jsonb_array_elements($1) item(value)), 0)
    ELSE 0
END
$m43$;

CREATE FUNCTION pgreact_internal.m43_object_access(object_kind text, object_identity text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m43$
DECLARE object_oid oid;
    owner_oid oid;
    has_rls boolean;
BEGIN
    IF object_identity IS NULL THEN RETURN true; END IF;
    IF object_kind = 'relation_identity' THEN
        object_oid := to_regclass(object_identity);
        IF object_oid IS NULL THEN
            SELECT condition.owner_oid INTO owner_oid
            FROM pgreact_internal.shared_conditions condition
            WHERE condition.condition_name = object_identity;
            RETURN FOUND AND (pg_has_role(session_user, owner_oid, 'USAGE')
                              OR pgreact_internal.is_operator_admin());
        END IF;
        SELECT c.relowner, c.relrowsecurity INTO owner_oid, has_rls
        FROM pg_class c WHERE c.oid = object_oid;
        RETURN NOT COALESCE(has_rls, false)
            AND (pg_has_role(session_user, owner_oid, 'USAGE')
                 OR has_table_privilege(session_user, object_oid, 'SELECT')
                 OR pgreact_internal.is_operator_admin());
    ELSIF object_kind = 'function_identity' THEN
        object_oid := to_regprocedure(object_identity);
        IF object_oid IS NULL THEN RETURN false; END IF;
        SELECT p.proowner INTO owner_oid FROM pg_proc p WHERE p.oid = object_oid;
        RETURN pg_has_role(session_user, owner_oid, 'USAGE')
            OR has_function_privilege(session_user, object_oid, 'EXECUTE')
            OR pgreact_internal.is_operator_admin();
    END IF;
    RETURN true;
EXCEPTION WHEN OTHERS THEN
    RETURN false;
END
$m43$;

CREATE FUNCTION pgreact_internal.m43_opaque_record(
    target_kind text,
    field_path text,
    public_identity text,
    stored_digest text,
    delegated_id uuid,
    subject_keys name[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m43$
DECLARE object_oid oid;
    live_digest text;
    action_row record;
    event_kind text;
BEGIN
    IF public_identity IS NULL THEN RETURN NULL; END IF;
    IF field_path LIKE 'spec.applicability.%' OR field_path IN ('spec.condition', 'spec.candidate_relation') THEN
        IF stored_digest IS NULL THEN RETURN NULL; END IF;
        object_oid := to_regclass(public_identity);
        IF object_oid IS NULL THEN RETURN NULL; END IF;
        IF target_kind = 'policy_set' AND field_path = 'spec.applicability.relation' THEN
            live_digest := pgreact_internal.m31_source_definition_digest(
                object_oid, COALESCE(subject_keys, ARRAY[]::name[]));
        ELSIF target_kind = 'decision_program' THEN
            live_digest := encode(pgreact_internal.decision_source_digest(object_oid), 'hex');
        ELSE
            live_digest := encode(sha256(convert_to(
                COALESCE(pg_get_viewdef(object_oid, true), object_oid::regclass::text), 'UTF8')), 'hex');
        END IF;
    ELSIF field_path IN ('spec.on_activate', 'spec.on_deactivate', 'spec.on_change') THEN
        event_kind := upper(replace(split_part(field_path, '.', 2), 'on_', ''));
        SELECT binding.function_digest INTO action_row
        FROM pgreact_internal.consequence_bindings binding
        WHERE binding.rule_version_id = delegated_id
          AND binding.event_kind = event_kind;
        object_oid := to_regprocedure(public_identity);
        IF object_oid IS NULL OR action_row.function_digest IS NULL THEN RETURN NULL; END IF;
        live_digest := encode(sha256(convert_to(pg_get_functiondef(object_oid), 'UTF8')), 'hex');
        stored_digest := encode(action_row.function_digest, 'hex');
    ELSE
        RETURN NULL;
    END IF;
    IF live_digest IS NOT DISTINCT FROM stored_digest THEN RETURN NULL; END IF;
    RETURN jsonb_build_object(
        'field_path', field_path,
        'field_kind', CASE WHEN field_path LIKE 'spec.on_%' THEN 'function_identity'
                           ELSE 'relation_identity' END,
        'change_kind', 'opaque',
        'identity', public_identity,
        'before_digest', stored_digest,
        'after_digest', live_digest,
        'meaning', 'the stored public object evidence changed; SQL meaning is opaque');
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END
$m43$;

CREATE FUNCTION pgreact_internal.m43_typed_value(
    field_kind text,
    present boolean,
    value jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m43$
SELECT CASE WHEN NOT $2 THEN jsonb_build_object('type', 'absent', 'present', false, 'value', NULL)
            ELSE jsonb_build_object(
                'type', CASE $1
                    WHEN 'identifier' THEN 'name'
                    WHEN 'relation_identity' THEN 'regclass'
                    WHEN 'function_identity' THEN 'regprocedure'
                    WHEN 'time_bound' THEN 'timestamptz'
                    WHEN 'ordered_list' THEN 'jsonb_array'
                    WHEN 'result_binding' THEN 'jsonb_array'
                    WHEN 'keyed_set' THEN 'jsonb_keyed_set'
                    WHEN 'typed_value' THEN 'jsonb'
                    ELSE COALESCE(jsonb_typeof($3), 'null') END,
                'json_type', COALESCE(jsonb_typeof($3), 'null'),
                'present', true,
                'value', $3)
       END
$m43$;

CREATE FUNCTION pgreact_internal.m43_limit_value(value jsonb, member_limit integer)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m43$
SELECT CASE WHEN jsonb_typeof($1) <> 'array' OR jsonb_array_length($1) <= $2 THEN $1
            ELSE COALESCE((SELECT jsonb_agg(item.value ORDER BY item.ordinality)
                           FROM jsonb_array_elements($1) WITH ORDINALITY item(value, ordinality)
                           WHERE item.ordinality <= $2), '[]'::jsonb)
       END
$m43$;

CREATE FUNCTION pgreact_internal.m43_result(
    result_state text,
    target_identity jsonb,
    proposed_digest text,
    deployed_digest text,
    differences jsonb,
    opaque jsonb,
    completeness jsonb,
    limits jsonb,
    findings jsonb,
    cost jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m43$
WITH body AS (
    SELECT jsonb_build_object(
        'target', $2,
        'proposed_declaration_digest', $3,
        'deployed_declaration_digest', $4,
        'differences', COALESCE($5, '[]'::jsonb),
        'opaque', COALESCE($6, '[]'::jsonb),
        'completeness', COALESCE($7, '{}'::jsonb)) AS value
)
SELECT jsonb_build_object(
    'contract_version', 43,
    'operation', 'semantic_diff',
    'state', $1,
    'target', $2,
    'proposed_declaration_digest', $3,
    'deployed_declaration_digest', $4,
    'differences', COALESCE($5, '[]'::jsonb),
    'opaque', COALESCE($6, '[]'::jsonb),
    'completeness', COALESCE($7, '{}'::jsonb),
    'limits', COALESCE($8, '{}'::jsonb),
    'findings', COALESCE($9, '[]'::jsonb),
    'semantic_digest', pgreact_internal.m43_digest(body.value),
    'cost', COALESCE($10, '{}'::jsonb),
    'read_only', true,
    'truncated', $1 = 'partial')
FROM body
$m43$;

CREATE FUNCTION pgreact_api.semantic_diff(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m43$
DECLARE target_kind text := (deployed).kind;
    target_name text := (deployed).name;
    target_version text := (deployed).version;
    target_identity jsonb;
    current_normalized jsonb;
    proposed_normalized jsonb;
    current_digest text;
    proposed_digest text;
    current_owner oid;
    current_delegate uuid;
    current_source_oid oid;
    current_source_digest text;
    current_subject_keys name[];
    current_rule record;
    validation jsonb;
    prepared pgreact_api.declaration;
    paths text[];
    field_path text;
    field_name text;
    field_kind text;
    current_spec jsonb;
    proposed_spec jsonb;
    current_value jsonb;
    proposed_value jsonb;
    current_present boolean;
    proposed_present boolean;
    differences jsonb := '[]'::jsonb;
    opaque jsonb := '[]'::jsonb;
    findings jsonb := '[]'::jsonb;
    reached_limits jsonb := '[]'::jsonb;
    current_typed jsonb;
    proposed_typed jsonb;
    opaque_record jsonb;
    live_digest text;
    action_row record;
    source_oid oid;
    object_oid oid;
    before_checksum text;
    after_checksum text;
    started_at timestamptz := clock_timestamp();
    field_count integer;
    fields_compared integer := 0;
    collection_members bigint := 0;
    difference_count integer := 0;
    opaque_count integer := 0;
    max_declaration_bytes integer := 65536;
    max_fields integer := 128;
    max_collection_members integer := 256;
    max_differences integer := 128;
    max_opaque_records integer := 64;
    max_nesting_depth integer := 8;
    max_payload_bytes integer := 1048576;
    complete boolean := true;
    unsupported boolean := false;
    option_name text;
    option_value integer;
    cost jsonb;
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RETURN pgreact_internal.m43_result(
            'invalid', NULL, NULL, NULL, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_OPTIONS_INVALID', 'ERROR', 'options must be a JSON object',
                'Pass bounded JSON options or omit the argument.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    FOREACH option_name IN ARRAY ARRAY[
        'max_declaration_bytes', 'max_fields', 'max_collection_members',
        'max_differences', 'max_opaque_records', 'max_nesting_depth',
        'max_payload_bytes'] LOOP
        IF options ? option_name THEN
            IF jsonb_typeof(options -> option_name) IS DISTINCT FROM 'number' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
                    'M43_OPTIONS_INVALID', 'ERROR', option_name || ' must be an integer',
                    'Use a positive integer within the published bound.'));
            ELSE
                BEGIN
                    option_value := (options ->> option_name)::integer;
                    IF option_value < 1
                       OR (option_name = 'max_declaration_bytes' AND option_value > 1048576)
                       OR (option_name = 'max_fields' AND option_value > 1024)
                       OR (option_name = 'max_collection_members' AND option_value > 10000)
                       OR (option_name = 'max_differences' AND option_value > 1024)
                       OR (option_name = 'max_opaque_records' AND option_value > 256)
                       OR (option_name = 'max_nesting_depth' AND option_value > 32)
                       OR (option_name = 'max_payload_bytes' AND option_value > 16777216) THEN
                        RAISE EXCEPTION 'outside published bound';
                    END IF;
                    CASE option_name
                        WHEN 'max_declaration_bytes' THEN max_declaration_bytes := option_value;
                        WHEN 'max_fields' THEN max_fields := option_value;
                        WHEN 'max_collection_members' THEN max_collection_members := option_value;
                        WHEN 'max_differences' THEN max_differences := option_value;
                        WHEN 'max_opaque_records' THEN max_opaque_records := option_value;
                        WHEN 'max_nesting_depth' THEN max_nesting_depth := option_value;
                        WHEN 'max_payload_bytes' THEN max_payload_bytes := option_value;
                    END CASE;
                EXCEPTION WHEN OTHERS THEN
                    findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
                        'M43_OPTIONS_INVALID', 'ERROR', option_name || ' is outside the supported integer range',
                        'Use a positive integer within the published bound.'));
                END;
            END IF;
        END IF;
    END LOOP;
    IF jsonb_array_length(findings) > 0 THEN
        RETURN pgreact_internal.m43_result(
            'invalid', NULL, NULL, NULL, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), jsonb_build_object(
                'max_declaration_bytes', max_declaration_bytes, 'max_fields', max_fields,
                'max_collection_members', max_collection_members, 'max_differences', max_differences,
                'max_opaque_records', max_opaque_records, 'max_nesting_depth', max_nesting_depth,
                'max_payload_bytes', max_payload_bytes, 'reached', reached_limits), findings,
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    IF target_kind IS NULL OR target_name IS NULL OR deployed IS NULL THEN
        RETURN pgreact_internal.m43_result(
            'unavailable', NULL, NULL, NULL, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_TARGET_UNAVAILABLE', 'WARNING', 'the deployed target is unavailable',
                'Check the public target name, kind, version, and your granted access.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;

    IF target_kind = 'policy_set' THEN
        SELECT version.normalized, encode(version.declaration_digest, 'hex'), set.owner_oid,
               version.policy_set_version_id, version.applicability_source_oid,
               version.applicability_source_definition_digest, version.subject_keys,
               version.version
        INTO current_normalized, current_digest, current_owner, current_delegate,
             current_source_oid, current_source_digest, current_subject_keys, target_version
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = target_name
          AND version.state = 'DEPLOYED'
          AND (target_version IS NULL OR version.version = target_version)
        ORDER BY version.valid_from DESC, version.created_at DESC
        LIMIT 1;
    ELSE
        SELECT row_data.normalized, encode(row_data.declaration_digest, 'hex'),
               row_data.owner_oid, row_data.delegated_id
        INTO current_normalized, current_digest, current_owner, current_delegate
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = target_kind
          AND row_data.object_name = target_name
          AND row_data.state = 'DEPLOYED';
        IF current_normalized IS NOT NULL THEN target_version := COALESCE(target_version, '1'); END IF;
    END IF;
    IF current_normalized IS NOT NULL AND target_kind = 'rule' THEN
        SELECT encode(version.source_definition_digest, 'hex'), version.rule_version_id
        INTO current_source_digest, current_delegate
        FROM pgreact_internal.rule_versions version
        JOIN pgreact_internal.rules rule USING (rule_id)
        WHERE version.rule_version_id = current_delegate
           OR (current_delegate IS NULL AND rule.rule_name = target_name)
        ORDER BY version.created_at DESC
        LIMIT 1;
    ELSIF current_normalized IS NOT NULL AND target_kind = 'decision_program' THEN
        SELECT encode(version.source_definition_digest, 'hex'), version.version_id
        INTO current_source_digest, current_delegate
        FROM pgreact_internal.decision_program_versions version
        JOIN pgreact_internal.decision_programs program USING (program_id)
        WHERE version.version_id = current_delegate
           OR (current_delegate IS NULL AND program.program_name = target_name)
        ORDER BY version.valid_from DESC, version.version_no DESC
        LIMIT 1;
    END IF;
    IF current_normalized IS NULL
       OR (target_kind <> 'policy_set' AND (deployed).version IS NOT NULL AND (deployed).version <> '1') THEN
        RETURN pgreact_internal.m43_result(
            'unavailable', NULL, NULL, NULL, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_TARGET_UNAVAILABLE', 'WARNING', 'the deployed target is unavailable',
                'Check the public target name, kind, version, and your granted access.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    IF NOT pg_has_role(session_user, current_owner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin()
       AND NOT EXISTS (
           SELECT 1 FROM pgreact_internal.application_roles role_row
           WHERE role_row.role_kind = 'reader'
             AND pg_has_role(session_user, role_row.role_oid, 'member')) THEN
        RETURN pgreact_internal.m43_result(
            'unavailable', NULL, NULL, NULL, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_TARGET_UNAVAILABLE', 'WARNING', 'the deployed target is unavailable',
                'Check the public target name, kind, version, and your granted access.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    target_identity := jsonb_build_object('kind', target_kind, 'name', target_name, 'version', target_version);
    IF target_kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
        RETURN pgreact_internal.m43_result(
            'unsupported', target_identity, NULL, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_UNSUPPORTED_KIND', 'ERROR', 'this declaration kind has no M43 field inventory',
                'Use rule, decision_program, or policy_set.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    IF proposed IS NULL THEN
        RETURN pgreact_internal.m43_result(
            'invalid', target_identity, NULL, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_INVALID_DECLARATION', 'ERROR', 'the proposed declaration is required',
                'Build it with pgreact_api.declaration().')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    IF (proposed).kind IS DISTINCT FROM target_kind THEN
        RETURN pgreact_internal.m43_result(
            'invalid', target_identity, NULL, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_KIND_MISMATCH', 'ERROR', 'proposed and deployed kinds must match',
                'Use the deployed target kind in the proposed declaration.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    IF (proposed).name IS DISTINCT FROM target_name THEN
        RETURN pgreact_internal.m43_result(
            'invalid', target_identity, NULL, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb,
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_NAME_MISMATCH', 'ERROR', 'proposed and deployed names must match',
                'Use the deployed target name in the proposed declaration.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    prepared := pgreact_internal.m43_prepare_declaration(proposed);
    validation := pgreact_api.validate(prepared);
    proposed_normalized := validation -> 'evidence' -> 'normalized_declaration';
    IF proposed_normalized IS NULL THEN proposed_normalized := validation -> 'normalized'; END IF;
    IF validation ->> 'state' = 'attention'
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(validation -> 'findings', '[]'::jsonb)) f
                  WHERE f ->> 'severity' = 'ERROR')
       OR proposed_normalized IS NULL THEN
        findings := jsonb_build_array(pgreact_internal.m43_finding(
            'M43_INVALID_DECLARATION', 'ERROR', 'the proposed declaration is not valid',
            'Correct the declaration using the existing validation findings.'))
            || COALESCE(validation -> 'findings', '[]'::jsonb);
        RETURN pgreact_internal.m43_result(
            'invalid', target_identity, NULL, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), '{}'::jsonb, findings,
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    proposed_digest := pgreact_internal.m43_declaration_digest(proposed_normalized);
    IF pgreact_internal.m43_json_depth(current_normalized) > max_nesting_depth
       OR pgreact_internal.m43_json_depth(proposed_normalized) > max_nesting_depth THEN
        RETURN pgreact_internal.m43_result(
            'partial', target_identity, proposed_digest, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), jsonb_build_object(
                'max_nesting_depth', max_nesting_depth,
                'reached', jsonb_build_array('max_nesting_depth')),
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_LIMIT', 'WARNING', 'a declaration exceeded the nesting-depth limit',
                'Flatten the declaration or raise max_nesting_depth within the published ceiling.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    IF length(convert_to(proposed_normalized::text, 'UTF8')) > max_declaration_bytes
       OR length(convert_to(current_normalized::text, 'UTF8')) > max_declaration_bytes THEN
        RETURN pgreact_internal.m43_result(
            'partial', target_identity, proposed_digest, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), jsonb_build_object(
                'max_declaration_bytes', max_declaration_bytes,
                'reached', jsonb_build_array('max_declaration_bytes')),
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_LIMIT', 'WARNING', 'a declaration exceeded the byte limit',
                'Reduce the declaration size or raise max_declaration_bytes within the published ceiling.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    paths := pgreact_internal.m43_field_paths(target_kind, current_normalized, proposed_normalized);
    field_count := cardinality(paths);
    FOREACH field_path IN ARRAY paths LOOP
        field_kind := pgreact_internal.m43_field_kind(target_kind, field_path);
        IF field_kind IS NULL THEN
            unsupported := true;
            findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
                'M43_UNSUPPORTED_FIELD', 'ERROR', 'the declaration contains an unsupported modeled field',
                'Use only fields in pgreact_internal.m43_field_inventory().',
                jsonb_build_object('field_path', field_path)));
        END IF;
    END LOOP;
    IF unsupported THEN
        RETURN pgreact_internal.m43_result(
            'unsupported', target_identity, proposed_digest, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false, 'fields_considered', field_count),
            jsonb_build_object('max_fields', max_fields, 'reached', reached_limits), findings,
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    FOREACH field_path IN ARRAY paths LOOP
        field_kind := pgreact_internal.m43_field_kind(target_kind, field_path);
        IF field_path LIKE 'spec.applicability.%' THEN
            field_name := substring(field_path FROM length('spec.applicability.') + 1);
            current_spec := COALESCE(current_normalized -> 'spec' -> 'applicability', '{}'::jsonb);
            proposed_spec := COALESCE(proposed_normalized -> 'spec' -> 'applicability', '{}'::jsonb);
        ELSE
            field_name := substring(field_path FROM length('spec.') + 1);
            current_spec := COALESCE(current_normalized -> 'spec', '{}'::jsonb);
            proposed_spec := COALESCE(proposed_normalized -> 'spec', '{}'::jsonb);
        END IF;
        IF field_kind IN ('relation_identity', 'function_identity') THEN
            IF current_spec ? field_name
               AND NOT pgreact_internal.m43_object_access(field_kind, current_spec ->> field_name) THEN
                RETURN pgreact_internal.m43_result(
                    'unavailable', NULL, NULL, NULL, '[]'::jsonb, '[]'::jsonb,
                    jsonb_build_object('complete', false), '{}'::jsonb,
                    jsonb_build_array(pgreact_internal.m43_finding(
                        'M43_TARGET_UNAVAILABLE', 'WARNING', 'the deployed target is unavailable',
                        'Check the public target name, kind, version, and your granted access.')),
                    jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                                       extract(epoch FROM clock_timestamp() - started_at) * 1000));
            END IF;
            IF proposed_spec ? field_name
               AND NOT pgreact_internal.m43_object_access(field_kind, proposed_spec ->> field_name) THEN
                RETURN pgreact_internal.m43_result(
                    'unavailable', NULL, NULL, NULL, '[]'::jsonb, '[]'::jsonb,
                    jsonb_build_object('complete', false), '{}'::jsonb,
                    jsonb_build_array(pgreact_internal.m43_finding(
                        'M43_TARGET_UNAVAILABLE', 'WARNING', 'the deployed target is unavailable',
                        'Check the public target name, kind, version, and your granted access.')),
                    jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                                       extract(epoch FROM clock_timestamp() - started_at) * 1000));
            END IF;
        END IF;
    END LOOP;
    IF field_count > max_fields THEN
        complete := false;
        reached_limits := reached_limits || jsonb_build_array('max_fields');
        findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
            'M43_LIMIT', 'WARNING', 'the field limit was reached',
            'Raise max_fields within the published ceiling or split the review.'));
    END IF;
    before_checksum := pgreact_internal.m34_authoritative_checksum();
    FOREACH field_path IN ARRAY paths LOOP
        EXIT WHEN fields_compared >= max_fields;
        field_kind := pgreact_internal.m43_field_kind(target_kind, field_path);
        IF field_path LIKE 'spec.applicability.%' THEN
            field_name := substring(field_path FROM length('spec.applicability.') + 1);
            current_spec := COALESCE(current_normalized -> 'spec' -> 'applicability', '{}'::jsonb);
            proposed_spec := COALESCE(proposed_normalized -> 'spec' -> 'applicability', '{}'::jsonb);
        ELSE
            field_name := substring(field_path FROM length('spec.') + 1);
            current_spec := COALESCE(current_normalized -> 'spec', '{}'::jsonb);
            proposed_spec := COALESCE(proposed_normalized -> 'spec', '{}'::jsonb);
        END IF;
        current_present := current_spec ? field_name;
        proposed_present := proposed_spec ? field_name;
        current_value := current_spec -> field_name;
        proposed_value := proposed_spec -> field_name;
        fields_compared := fields_compared + 1;
        IF jsonb_typeof(current_value) = 'array' THEN
            collection_members := collection_members + jsonb_array_length(current_value);
            IF jsonb_array_length(current_value) > max_collection_members THEN
                complete := false;
                reached_limits := reached_limits || jsonb_build_array('max_collection_members');
            END IF;
        END IF;
        IF jsonb_typeof(proposed_value) = 'array' THEN
            collection_members := collection_members + jsonb_array_length(proposed_value);
            IF jsonb_array_length(proposed_value) > max_collection_members THEN
                complete := false;
                reached_limits := reached_limits || jsonb_build_array('max_collection_members');
            END IF;
        END IF;
        IF current_present AND proposed_present
           AND current_value IS NOT DISTINCT FROM proposed_value THEN
            IF field_kind IN ('relation_identity', 'function_identity') THEN
                opaque_record := pgreact_internal.m43_opaque_record(
                    target_kind, field_path, current_value #>> '{}',
                    current_source_digest, current_delegate, current_subject_keys);
                IF opaque_record IS NOT NULL AND opaque_count < max_opaque_records THEN
                    opaque := opaque || jsonb_build_array(opaque_record);
                    opaque_count := opaque_count + 1;
                    findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
                        'M43_OPAQUE_CHANGE', 'WARNING', 'a stored public object definition changed',
                        'Review the public object outside pg-react; no business meaning is assigned.',
                        jsonb_build_object('field_path', field_path,
                                           'identity', current_value #>> '{}')));
                END IF;
            END IF;
            CONTINUE;
        END IF;
        IF difference_count >= max_differences THEN
            complete := false;
            reached_limits := reached_limits || jsonb_build_array('max_differences');
            CONTINUE;
        END IF;
        current_typed := pgreact_internal.m43_typed_value(
            field_kind, current_present,
            pgreact_internal.m43_limit_value(current_value, max_collection_members));
        proposed_typed := pgreact_internal.m43_typed_value(
            field_kind, proposed_present,
            pgreact_internal.m43_limit_value(proposed_value, max_collection_members));
        differences := differences || jsonb_build_array(jsonb_build_object(
            'field_path', field_path,
            'field_kind', field_kind,
            'change_kind', CASE WHEN NOT current_present THEN 'added'
                                WHEN NOT proposed_present THEN 'removed'
                                ELSE 'changed' END,
            'before', current_typed,
            'after', proposed_typed,
            'complete', NOT ((jsonb_typeof(current_value) = 'array'
                             AND jsonb_array_length(current_value) > max_collection_members)
                            OR (jsonb_typeof(proposed_value) = 'array'
                                AND jsonb_array_length(proposed_value) > max_collection_members))));
        difference_count := difference_count + 1;
        IF difference_count >= max_differences THEN complete := false; END IF;

    END LOOP;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(reached_limits) item
               WHERE item.value #>> '{}' = 'max_collection_members') THEN
        findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
            'M43_LIMIT', 'WARNING', 'a collection limit was reached',
            'Raise max_collection_members within the published ceiling or split the review.'));
    END IF;
    IF opaque_count >= max_opaque_records THEN
        complete := false;
        reached_limits := reached_limits || jsonb_build_array('max_opaque_records');
    END IF;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF before_checksum IS DISTINCT FROM after_checksum THEN
        RETURN pgreact_internal.m43_result(
            'changed', target_identity, proposed_digest, current_digest, '[]'::jsonb, '[]'::jsonb,
            jsonb_build_object('complete', false), jsonb_build_object('reached', '[]'::jsonb),
            jsonb_build_array(pgreact_internal.m43_finding(
                'M43_CHANGED_STATE', 'WARNING', 'authoritative state changed during the review',
                'Run the same read-only review again.')),
            jsonb_build_object('fields_compared', 0, 'elapsed_ms',
                               extract(epoch FROM clock_timestamp() - started_at) * 1000));
    END IF;
    IF length(convert_to((differences || opaque)::text, 'UTF8')) > max_payload_bytes THEN
        complete := false;
        reached_limits := reached_limits || jsonb_build_array('max_payload_bytes');
        differences := '[]'::jsonb;
        opaque := '[]'::jsonb;
        findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
            'M43_LIMIT', 'WARNING', 'the returned payload limit was reached',
            'Raise max_payload_bytes within the published ceiling or split the review.'));
    END IF;
    IF complete AND jsonb_array_length(differences) = 0 AND jsonb_array_length(opaque) = 0 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m43_finding(
            'M43_NO_DIFFERENCE', 'INFO', 'the modeled declarations are semantically equal',
            'No deployment is required for this result.'));
    END IF;
    cost := jsonb_build_object(
        'fields_compared', fields_compared,
        'collection_members', collection_members,
        'differences_returned', jsonb_array_length(differences),
        'opaque_records', jsonb_array_length(opaque),
        'object_lookups', 0,
        'serialization_bytes', length(convert_to((current_normalized || proposed_normalized)::text, 'UTF8')),
        'hashing_bytes', length(convert_to((current_normalized || proposed_normalized || differences || opaque)::text, 'UTF8')),
        'elapsed_ms', extract(epoch FROM clock_timestamp() - started_at) * 1000,
        'memory_bytes', NULL,
        'temporary_storage_bytes', 0);
    RETURN pgreact_internal.m43_result(
        CASE WHEN complete THEN 'complete' ELSE 'partial' END,
        target_identity, proposed_digest, current_digest, differences, opaque,
        jsonb_build_object('complete', complete, 'fields_considered', field_count,
                           'fields_compared', fields_compared,
                           'differences_complete', complete OR difference_count < max_differences,
                           'opaque_complete', opaque_count < max_opaque_records),
        jsonb_build_object(
            'max_declaration_bytes', max_declaration_bytes,
            'max_fields', max_fields,
            'max_collection_members', max_collection_members,
            'max_differences', max_differences,
            'max_opaque_records', max_opaque_records,
            'max_nesting_depth', max_nesting_depth,
            'max_payload_bytes', max_payload_bytes,
            'reached', reached_limits),
        findings, cost);
END
$m43$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m42;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m43$
BEGIN
    PERFORM pgreact_api.configure_roles_m42(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact_api.semantic_diff(pgreact_api.declaration,pgreact_api.target,jsonb) TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
END
$m43$;

REVOKE ALL ON FUNCTION pgreact_internal.m43_finding(text,text,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_digest(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_declaration_digest(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_field_kind(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_field_inventory(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_prepare_declaration(pgreact_api.declaration) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_field_paths(text,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_json_depth(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_object_access(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_typed_value(text,boolean,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_limit_value(jsonb,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m43_result(text,jsonb,text,text,jsonb,jsonb,jsonb,jsonb,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.semantic_diff(pgreact_api.declaration,pgreact_api.target,jsonb) FROM PUBLIC;

COMMENT ON FUNCTION pgreact_api.semantic_diff(pgreact_api.declaration,pgreact_api.target,jsonb) IS
    'M43 bounded read-only semantic differences between one proposed declaration and one deployed target';
COMMENT ON EXTENSION pg_react IS
    'M43 semantic policy differences over canonical declarations';
