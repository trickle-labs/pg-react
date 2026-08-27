-- M36 read-only caller-supplied historical replay over the M35 evaluator.

CREATE OR REPLACE FUNCTION pgreact_internal.m36_finding(
    code text,
    severity text,
    target text,
    field text,
    message text,
    hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m36$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'target', $3,
        'field', $4,
        'message', $5,
        'hint', $6,
        'details', COALESCE($7, '{}'::jsonb))
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_finding_registry()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
    SELECT jsonb_build_object(
        'schema_version', 1,
        'milestone', 'M36',
        'finding_shape', jsonb_build_array(
            'code', 'severity', 'blocking', 'target',
            'field', 'message', 'hint', 'details'),
        'severity', jsonb_build_array('ERROR', 'WARNING', 'INFO'),
        'codes', jsonb_build_array(
            jsonb_build_object('code', 'M36_SNAPSHOT_INVALID', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_SNAPSHOT_REQUIRED_FIELD', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_SNAPSHOT_UNKNOWN_FIELD', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_SNAPSHOT_RELATION', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_SNAPSHOT_SCHEMA', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_SNAPSHOT_ROW', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_SNAPSHOT_DUPLICATE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_INVALID', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_REQUIRED_FIELD', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_UNKNOWN_FIELD', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_ORDINAL', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_DUPLICATE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_NONMONOTONE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_LATE_INPUT', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_FINALIZED', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_CONFLICT', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_STALE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_UNAUTHORIZED_TARGET', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_UNAUTHORIZED_SOURCE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_RLS_UNSUPPORTED', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_UNSUPPORTED_TARGET', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_UNSUPPORTED_SOURCE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_AMBIGUOUS', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_CYCLIC', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_RESOURCE_LIMIT', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_AUTHORITATIVE_CHANGED', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M36_REPLAY_INCOMPLETE', 'severity', 'WARNING'),
            jsonb_build_object('code', 'M36_NO_EFFECT', 'severity', 'INFO')))
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_schema_fingerprint(source_oid oid)
RETURNS text
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
    SELECT encode(sha256(convert_to(COALESCE((
        SELECT string_agg(format('%s:%s:%s:%s:%s:%s:%s',
                              a.attnum, a.attname, a.atttypid::regtype,
                              a.atttypmod, a.attcollation::oid,
                              a.attnotnull, a.attgenerated), '|'
                         ORDER BY a.attnum)
        FROM pg_attribute a
        WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped),
        ''), 'UTF8')), 'hex')
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_require_source(
    source_oid oid,
    source_name text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
DECLARE
    relation_kind "char";
    rls_enabled boolean;
BEGIN
    IF source_oid IS NULL THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_RELATION: source relation % no longer exists', source_name;
    END IF;
    SELECT relkind, relrowsecurity
    INTO relation_kind, rls_enabled
    FROM pg_class
    WHERE oid = source_oid;
    IF relation_kind NOT IN ('r', 'p') THEN
        RAISE EXCEPTION 'M36_UNSUPPORTED_SOURCE: source relation % must be a table', source_name;
    END IF;
    IF rls_enabled THEN
        RAISE EXCEPTION 'M36_RLS_UNSUPPORTED: source relation % uses row-level security', source_name;
    END IF;
    IF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
        RAISE EXCEPTION 'M36_UNAUTHORIZED_SOURCE: caller lacks SELECT on source relation %', source_name;
    END IF;
END
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_snapshot_digest(relations jsonb)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $m36$
DECLARE
    relation_item jsonb;
    row_material text;
    material text := '';
BEGIN
    FOR relation_item IN
        SELECT value
        FROM jsonb_array_elements($1) item(value)
        ORDER BY value ->> 'relation'
    LOOP
        SELECT COALESCE(string_agg(value::text, ',' ORDER BY value::text), '')
        INTO row_material
        FROM jsonb_array_elements(relation_item -> 'rows') row(value);
        material := material || (relation_item ->> 'relation') || '=' || row_material || E'\n';
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_validate_rows(
    source_oid oid,
    key_column name,
    rows jsonb,
    source_label text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
DECLARE
    duplicate_count bigint;
    row_item jsonb;
BEGIN
    IF jsonb_typeof(rows) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_ROW: rows for % must be a JSON array', source_label;
    END IF;
    FOR row_item IN SELECT value FROM jsonb_array_elements(rows) item(value)
    LOOP
        BEGIN
            PERFORM pgreact_internal.m35_check_image(source_oid, row_item, 'snapshot row');
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'M36_SNAPSHOT_ROW: row in % does not match the source schema', source_label;
        END;
        IF row_item ->> key_column::text IS NULL
           OR row_item ->> key_column::text !~ '^-?[0-9]+$' THEN
            RAISE EXCEPTION 'M36_SNAPSHOT_ROW: % identity must be a bigint value', source_label;
        END IF;
    END LOOP;
    SELECT count(*) INTO duplicate_count
    FROM (
        SELECT value ->> key_column::text
        FROM jsonb_array_elements(rows) item(value)
        GROUP BY value ->> key_column::text
        HAVING count(*) > 1
    ) duplicates;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_DUPLICATE: % contains duplicate identities', source_label;
    END IF;
END
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_apply_changes(
    source_oid oid,
    key_column name,
    source_label text,
    rows jsonb,
    change_set jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
DECLARE
    item jsonb;
    operation text;
    key_text text;
    existing jsonb;
    row_count bigint;
    unknown_field text;
BEGIN
    IF jsonb_typeof(change_set) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'M36_REPLAY_INVALID: change_set must be a JSON array';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(change_set) item(value)
        WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
           OR NOT (item.value ?& ARRAY['relation', 'operation', 'ordinal', 'key', 'before', 'after'])
           OR (SELECT count(*) FROM jsonb_object_keys(item.value)) <> 6
    ) THEN
        RAISE EXCEPTION 'M36_REPLAY_REQUIRED_FIELD: every change must contain relation, operation, ordinal, key, before, and after';
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_array_elements(change_set) item(value),
         jsonb_object_keys(item.value) AS key
    WHERE key NOT IN ('relation', 'operation', 'ordinal', 'key', 'before', 'after')
    ORDER BY key
    LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        RAISE EXCEPTION 'M36_REPLAY_UNKNOWN_FIELD: change field % is not supported', unknown_field;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(change_set) item(value)
        WHERE jsonb_typeof(item.value -> 'ordinal') IS DISTINCT FROM 'number'
           OR item.value ->> 'ordinal' !~ '^[1-9][0-9]*$'
    ) THEN
        RAISE EXCEPTION 'M36_REPLAY_ORDINAL: change ordinals must be positive integers';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(change_set) item(value)
        GROUP BY (item.value ->> 'ordinal')::bigint
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'M36_REPLAY_DUPLICATE: change ordinals must be unique';
    END IF;
    FOR item IN
        SELECT value
        FROM jsonb_array_elements(change_set) change(value)
        ORDER BY (value ->> 'ordinal')::bigint
    LOOP
        IF to_regclass(item ->> 'relation') IS DISTINCT FROM source_oid THEN
            RAISE EXCEPTION 'M36_SNAPSHOT_RELATION: change relation % does not match %',
                item ->> 'relation', source_label;
        END IF;
        operation := item ->> 'operation';
        IF operation IS NULL OR operation NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
            RAISE EXCEPTION 'M36_REPLAY_INVALID: operation % is not supported', operation;
        END IF;
        IF jsonb_typeof(item -> 'key') IS DISTINCT FROM 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(item -> 'key')) <> 1
           OR NOT (item -> 'key' ? key_column::text)
           OR jsonb_typeof(item -> 'key' -> key_column::text) IS DISTINCT FROM 'number'
           OR item -> 'key' ->> key_column::text !~ '^-?[0-9]+$' THEN
            RAISE EXCEPTION 'M36_REPLAY_INVALID: key must contain one integer % value', key_column;
        END IF;
        key_text := item -> 'key' ->> key_column::text;
        IF operation = 'INSERT' THEN
            IF jsonb_typeof(item -> 'before') IS DISTINCT FROM 'null'
               OR jsonb_typeof(item -> 'after') IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION 'M36_REPLAY_INVALID: INSERT requires a null before image and an after image';
            END IF;
            BEGIN
                PERFORM pgreact_internal.m35_check_image(source_oid, item -> 'after', 'after');
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'M36_REPLAY_INVALID: after image does not match the source schema';
            END;
            IF item -> 'after' ->> key_column::text IS DISTINCT FROM key_text THEN
                RAISE EXCEPTION 'M36_REPLAY_INVALID: INSERT key does not match its after image';
            END IF;
            SELECT count(*) INTO row_count
            FROM jsonb_array_elements(rows) current_row(value)
            WHERE current_row.value ->> key_column::text = key_text;
            IF row_count > 0 THEN
                RAISE EXCEPTION 'M36_REPLAY_CONFLICT: INSERT identity % already exists', key_text;
            END IF;
            rows := rows || jsonb_build_array(item -> 'after');
        ELSE
            IF jsonb_typeof(item -> 'before') IS DISTINCT FROM 'object'
               OR jsonb_typeof(item -> 'after') IS DISTINCT FROM
                  (CASE WHEN operation = 'UPDATE' THEN 'object' ELSE 'null' END) THEN
                RAISE EXCEPTION 'M36_REPLAY_INVALID: % requires the correct before and after images', operation;
            END IF;
            BEGIN
                PERFORM pgreact_internal.m35_check_image(source_oid, item -> 'before', 'before');
            EXCEPTION WHEN OTHERS THEN
                RAISE EXCEPTION 'M36_REPLAY_INVALID: before image does not match the source schema';
            END;
            IF operation = 'UPDATE' THEN
                BEGIN
                    PERFORM pgreact_internal.m35_check_image(source_oid, item -> 'after', 'after');
                EXCEPTION WHEN OTHERS THEN
                    RAISE EXCEPTION 'M36_REPLAY_INVALID: after image does not match the source schema';
                END;
                IF item -> 'after' ->> key_column::text IS DISTINCT FROM key_text THEN
                    RAISE EXCEPTION 'M36_REPLAY_INVALID: UPDATE cannot change its identity';
                END IF;
            END IF;
            SELECT count(*), (array_agg(current_row.value))[1]
            INTO row_count, existing
            FROM jsonb_array_elements(rows) current_row(value)
            WHERE current_row.value ->> key_column::text = key_text;
            IF row_count = 0 THEN
                RAISE EXCEPTION 'M36_REPLAY_STALE: identity % is not present', key_text;
            ELSIF row_count > 1 THEN
                RAISE EXCEPTION 'M36_REPLAY_DUPLICATE: identity % is ambiguous', key_text;
            ELSIF existing IS DISTINCT FROM item -> 'before' THEN
                RAISE EXCEPTION 'M36_REPLAY_STALE: before image for identity % is stale', key_text;
            END IF;
            SELECT COALESCE(jsonb_agg(
                       CASE WHEN current_row.value ->> key_column::text = key_text
                            THEN CASE WHEN operation = 'UPDATE'
                                      THEN item -> 'after' ELSE NULL END
                            ELSE current_row.value END
                       ORDER BY current_row.ordinality), '[]'::jsonb)
            INTO rows
            FROM jsonb_array_elements(rows) WITH ORDINALITY current_row(value, ordinality)
            WHERE NOT (operation = 'DELETE'
                       AND current_row.value ->> key_column::text = key_text);
        END IF;
    END LOOP;
    RETURN rows;
END
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_model(
    normalized jsonb,
    target_kind text,
    rows jsonb,
    source_label text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
DECLARE
    key_column name;
    subject_column name;
    candidate_column name;
    priority_column name;
    result_columns name[];
    max_candidates integer;
    member_rows jsonb;
    subject_model jsonb;
    member_count bigint;
BEGIN
    IF target_kind = 'rule' THEN
        key_column := (normalized -> 'spec' ->> 'semantic_key')::name;
        RETURN pgreact_internal.m35_rule_rows(rows, key_column, source_label, evidence_limit);
    ELSIF target_kind = 'decision_program' THEN
        subject_column := (normalized -> 'spec' ->> 'subject_key')::name;
        candidate_column := (normalized -> 'spec' ->> 'candidate_key')::name;
        priority_column := (normalized -> 'spec' ->> 'priority')::name;
        SELECT array_agg(value::name ORDER BY ordinal)
        INTO result_columns
        FROM jsonb_array_elements_text(normalized -> 'spec' -> 'results')
             WITH ORDINALITY item(value, ordinal);
        max_candidates := COALESCE(
            (normalized -> 'spec' ->> 'max_candidates')::integer, 1000);
        RETURN pgreact_internal.m35_decision_rows(
            rows, subject_column, candidate_column, priority_column,
            result_columns, max_candidates, source_label, evidence_limit);
    ELSIF target_kind = 'policy_set' THEN
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'subject_key', 'member:' || (item.value ->> 'kind') || ':' ||
                                  (item.value ->> 'name') || ':' || (item.value ->> 'version'),
                   'result_key', 'member:' || (item.value ->> 'kind') || ':' ||
                                 (item.value ->> 'name') || ':' || (item.value ->> 'version'),
                   'state', 'MEMBER',
                   'value', item.value,
                   'work', jsonb_build_object('would_be_work', false),
                   'evidence', jsonb_build_object(
                       'source', 'pgreact.policy_set_members', 'complete', true))
                   ORDER BY item.value ->> 'kind', item.value ->> 'name', item.value ->> 'version'),
               '[]'::jsonb)
        INTO member_rows
        FROM jsonb_array_elements(COALESCE(normalized -> 'spec' -> 'members', '[]'::jsonb)) item(value);
        member_count := jsonb_array_length(COALESCE(normalized -> 'spec' -> 'members', '[]'::jsonb));
        subject_model := pgreact_internal.m35_policy_subject_rows(
            rows,
            ((normalized -> 'spec' -> 'applicability' -> 'subject_keys' ->> 0)::name),
            source_label,
            evidence_limit);
        RETURN jsonb_build_object(
            'rows', member_rows || (subject_model -> 'rows'),
            'rows_considered', member_count + (subject_model ->> 'rows_considered')::bigint,
            'truncated', member_count > evidence_limit
                OR COALESCE((subject_model ->> 'truncated')::boolean, false));
    END IF;
    RAISE EXCEPTION 'M36_UNSUPPORTED_TARGET: target kind % is not supported', target_kind;
END
$m36$;

CREATE OR REPLACE FUNCTION pgreact_internal.m36_replay(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    initial_snapshot jsonb,
    replay_steps jsonb,
    options jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
DECLARE
    target_kind text := (deployed).kind;
    target_name text := (deployed).name;
    target_version text := (deployed).version;
    target_owner oid;
    frozen_normalized jsonb;
    normalized jsonb;
    validation jsonb;
    source_label text;
    source_oid oid;
    key_column name;
    source_schema_before text;
    source_schema_after text;
    target_digest_before text;
    target_digest_after text;
    source_rows jsonb;
    initial_snapshot_digest text;
    current_rows jsonb;
    previous_model_rows jsonb;
    initial_model jsonb;
    model jsonb;
    delta_model jsonb;
    delta_rows jsonb;
    lifecycle_rows jsonb;
    work_rows jsonb;
    initial_result jsonb;
    step_result jsonb;
    step_results jsonb := '[]'::jsonb;
    snapshot_relations jsonb;
    snapshot_relation jsonb;
    step jsonb;
    snapshot_digest text;
    replay_digest text;
    declaration_digest text;
    authoritative_checksum_before text;
    authoritative_checksum_after text;
    evidence_limit integer := 100;
    max_steps integer := 100;
    max_changes integer := 1000;
    max_snapshot_rows integer := 10000;
    max_total_changes integer := 10000;
    snapshot_row_count bigint;
    total_changes bigint := 0;
    step_count integer := 0;
    previous_ordinal bigint := 0;
    ordinal bigint;
    previous_frontier timestamptz;
    previous_sampled_time timestamptz;
    previous_watermark timestamptz;
    current_frontier timestamptz;
    current_sampled_time timestamptz;
    current_watermark timestamptz;
    starting_frontier timestamptz;
    starting_sampled_time timestamptz;
    starting_watermark timestamptz;
    finalized boolean := false;
    final_step boolean;
    key_not_null boolean;
    replay_complete boolean := true;
    step_complete boolean;
    rows_considered bigint := 0;
    affected_subjects bigint := 0;
    started_at timestamptz := clock_timestamp();
    unknown_field text;
    expected_source text;
BEGIN
    IF deployed IS NULL OR target_kind IS NULL OR target_name IS NULL THEN
        RAISE EXCEPTION 'M36_UNSUPPORTED_TARGET: deployed target kind and name are required';
    END IF;
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M36_REPLAY_INVALID: options must be a JSON object';
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_object_keys(options) AS key
    WHERE key NOT IN ('evidence_limit', 'max_steps', 'max_changes',
                      'max_snapshot_rows', 'max_total_changes')
    ORDER BY key
    LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        RAISE EXCEPTION 'M36_REPLAY_UNKNOWN_FIELD: option % is not supported', unknown_field;
    END IF;
    IF options ? 'evidence_limit' THEN
        IF jsonb_typeof(options -> 'evidence_limit') IS DISTINCT FROM 'number'
           OR options ->> 'evidence_limit' !~ '^[1-9][0-9]*$'
           OR (options ->> 'evidence_limit')::integer > 1000 THEN
            RAISE EXCEPTION 'M36_RESOURCE_LIMIT: evidence_limit must be between 1 and 1000';
        END IF;
        evidence_limit := (options ->> 'evidence_limit')::integer;
    END IF;
    IF options ? 'max_steps' THEN
        IF jsonb_typeof(options -> 'max_steps') IS DISTINCT FROM 'number'
           OR options ->> 'max_steps' !~ '^[1-9][0-9]*$'
           OR (options ->> 'max_steps')::integer > 1000 THEN
            RAISE EXCEPTION 'M36_RESOURCE_LIMIT: max_steps must be between 1 and 1000';
        END IF;
        max_steps := (options ->> 'max_steps')::integer;
    END IF;
    IF options ? 'max_changes' THEN
        IF jsonb_typeof(options -> 'max_changes') IS DISTINCT FROM 'number'
           OR options ->> 'max_changes' !~ '^[1-9][0-9]*$'
           OR (options ->> 'max_changes')::integer > 1000 THEN
            RAISE EXCEPTION 'M36_RESOURCE_LIMIT: max_changes must be between 1 and 1000';
        END IF;
        max_changes := (options ->> 'max_changes')::integer;
    END IF;
    IF options ? 'max_snapshot_rows' THEN
        IF jsonb_typeof(options -> 'max_snapshot_rows') IS DISTINCT FROM 'number'
           OR options ->> 'max_snapshot_rows' !~ '^[1-9][0-9]*$'
           OR (options ->> 'max_snapshot_rows')::integer > 100000 THEN
            RAISE EXCEPTION 'M36_RESOURCE_LIMIT: max_snapshot_rows must be between 1 and 100000';
        END IF;
        max_snapshot_rows := (options ->> 'max_snapshot_rows')::integer;
    END IF;
    IF options ? 'max_total_changes' THEN
        IF jsonb_typeof(options -> 'max_total_changes') IS DISTINCT FROM 'number'
           OR options ->> 'max_total_changes' !~ '^[1-9][0-9]*$'
           OR (options ->> 'max_total_changes')::integer > 100000 THEN
            RAISE EXCEPTION 'M36_RESOURCE_LIMIT: max_total_changes must be between 1 and 100000';
        END IF;
        max_total_changes := (options ->> 'max_total_changes')::integer;
    END IF;
    IF jsonb_typeof(replay_steps) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'M36_REPLAY_INVALID: replay_steps must be a JSON array';
    END IF;
    IF jsonb_array_length(replay_steps) > max_steps THEN
        RAISE EXCEPTION 'M36_RESOURCE_LIMIT: replay_steps exceeds max_steps';
    END IF;

    IF target_kind = 'policy_set' THEN
        SELECT version.normalized, set.owner_oid
        INTO frozen_normalized, target_owner
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = target_name
          AND version.state = 'DEPLOYED'
          AND (target_version IS NULL OR version.version = target_version)
        ORDER BY version.valid_from DESC, version.created_at DESC
        LIMIT 1;
    ELSE
        SELECT row_data.normalized, row_data.owner_oid
        INTO frozen_normalized, target_owner
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = target_kind
          AND row_data.object_name = target_name
          AND row_data.state = 'DEPLOYED';
        IF target_version IS NOT NULL AND target_version <> '1' THEN
            RAISE EXCEPTION 'M36_UNSUPPORTED_TARGET: only deployed declaration version 1 is supported';
        END IF;
    END IF;
    IF frozen_normalized IS NULL THEN
        RAISE EXCEPTION 'M36_UNSUPPORTED_TARGET: deployed % % was not found', target_kind, target_name;
    END IF;
    target_digest_before := encode(sha256(convert_to(frozen_normalized::text, 'UTF8')), 'hex');
    IF NOT pg_has_role(session_user, target_owner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin()
       AND NOT EXISTS (
           SELECT 1 FROM pgreact_internal.application_roles role_row
           WHERE role_row.role_kind = 'reader'
             AND pg_has_role(session_user, role_row.role_oid, 'member')) THEN
        RAISE EXCEPTION 'M36_UNAUTHORIZED_TARGET: caller is not allowed to inspect %', target_name;
    END IF;
    IF proposed IS NULL THEN
        normalized := frozen_normalized;
    ELSE
        IF (proposed).kind IS DISTINCT FROM target_kind
           OR (proposed).name IS DISTINCT FROM target_name THEN
            RAISE EXCEPTION 'M36_UNSUPPORTED_TARGET: proposed and deployed targets must match';
        END IF;
        validation := pgreact_internal.m28_validate(proposed);
        IF EXISTS (
            SELECT 1 FROM jsonb_array_elements(validation -> 'findings') finding(value)
            WHERE value ->> 'severity' = 'ERROR'
        ) THEN
            RAISE EXCEPTION 'M36_UNSUPPORTED_TARGET: proposed declaration is invalid: %',
                validation -> 'findings';
        END IF;
        normalized := pgreact_internal.m28_normalize(proposed);
    END IF;

    IF target_kind = 'rule' THEN
        source_label := normalized -> 'spec' ->> 'condition';
        key_column := (normalized -> 'spec' ->> 'semantic_key')::name;
    ELSIF target_kind = 'decision_program' THEN
        source_label := normalized -> 'spec' ->> 'candidate_relation';
        key_column := (normalized -> 'spec' ->> 'candidate_key')::name;
    ELSIF target_kind = 'policy_set' THEN
        source_label := normalized -> 'spec' -> 'applicability' ->> 'relation';
        IF jsonb_array_length(COALESCE(
               normalized -> 'spec' -> 'applicability' -> 'subject_keys', '[]'::jsonb)) <> 1 THEN
            RAISE EXCEPTION 'M36_UNSUPPORTED_SOURCE: M36 requires one bigint policy subject key';
        END IF;
        key_column := (normalized -> 'spec' -> 'applicability' -> 'subject_keys' ->> 0)::name;
    ELSE
        RAISE EXCEPTION 'M36_UNSUPPORTED_TARGET: target kind % is not supported', target_kind;
    END IF;
    source_oid := to_regclass(source_label);
    PERFORM pgreact_internal.m36_require_source(source_oid, source_label);
    SELECT a.atttypid::regtype, a.attnotnull
    INTO expected_source, key_not_null
    FROM pg_attribute a
    WHERE a.attrelid = source_oid AND a.attname = key_column
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF expected_source IS DISTINCT FROM 'bigint' OR NOT key_not_null THEN
        RAISE EXCEPTION 'M36_UNSUPPORTED_SOURCE: identity column % must be non-null bigint', key_column;
    END IF;
    source_schema_before := pgreact_internal.m36_schema_fingerprint(source_oid);

    IF initial_snapshot IS NULL OR jsonb_typeof(initial_snapshot) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_INVALID: initial_snapshot must be a JSON object';
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_object_keys(initial_snapshot) AS key
    WHERE key NOT IN ('relations', 'source_frontier', 'sampled_time', 'event_time_watermark')
    ORDER BY key
    LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_UNKNOWN_FIELD: snapshot field % is not supported', unknown_field;
    END IF;
    IF NOT (initial_snapshot ?& ARRAY['relations', 'source_frontier', 'sampled_time', 'event_time_watermark'])
       OR jsonb_typeof(initial_snapshot -> 'relations') IS DISTINCT FROM 'array'
       OR jsonb_array_length(initial_snapshot -> 'relations') <> 1 THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_REQUIRED_FIELD: snapshot needs one relation and its three starting times';
    END IF;
    snapshot_relations := initial_snapshot -> 'relations';
    snapshot_relation := snapshot_relations -> 0;
    IF jsonb_typeof(snapshot_relation) IS DISTINCT FROM 'object'
       OR NOT (snapshot_relation ?& ARRAY['relation', 'rows', 'schema_fingerprint']) THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_REQUIRED_FIELD: relation needs relation, rows, and schema_fingerprint fields';
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_object_keys(snapshot_relation) AS key
    WHERE key NOT IN ('relation', 'rows', 'schema_fingerprint')
    ORDER BY key
    LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_UNKNOWN_FIELD: relation field % is not supported', unknown_field;
    END IF;
    IF to_regclass(snapshot_relation ->> 'relation') IS DISTINCT FROM source_oid THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_RELATION: snapshot relation % does not match %',
            snapshot_relation ->> 'relation', source_label;
    END IF;
    IF snapshot_relation ->> 'relation' IS DISTINCT FROM source_oid::regclass::text THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_RELATION: snapshot relation must use canonical name %',
            source_oid::regclass;
    END IF;
    PERFORM pgreact_internal.m36_validate_rows(
        source_oid, key_column, snapshot_relation -> 'rows', source_label);
    SELECT COALESCE(jsonb_array_length(snapshot_relation -> 'rows'), 0)
    INTO snapshot_row_count;
    IF snapshot_row_count > max_snapshot_rows THEN
        RAISE EXCEPTION 'M36_RESOURCE_LIMIT: initial snapshot exceeds max_snapshot_rows';
    END IF;
    IF snapshot_relation ? 'schema_fingerprint'
       AND snapshot_relation ->> 'schema_fingerprint' IS DISTINCT FROM source_schema_before THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_SCHEMA: supplied schema_fingerprint does not match %', source_label;
    END IF;
    BEGIN
        starting_frontier := (initial_snapshot ->> 'source_frontier')::timestamptz;
        starting_sampled_time := (initial_snapshot ->> 'sampled_time')::timestamptz;
        starting_watermark := (initial_snapshot ->> 'event_time_watermark')::timestamptz;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_INVALID: snapshot times must be valid timestamps';
    END;
    IF starting_frontier IS NULL OR starting_sampled_time IS NULL OR starting_watermark IS NULL THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_REQUIRED_FIELD: snapshot times cannot be null';
    END IF;
    IF starting_sampled_time > starting_frontier THEN
        RAISE EXCEPTION 'M36_SNAPSHOT_INVALID: sampled_time cannot be after source_frontier';
    END IF;

    authoritative_checksum_before := pgreact_internal.m34_authoritative_checksum();
    source_rows := snapshot_relation -> 'rows';
    snapshot_digest := pgreact_internal.m36_snapshot_digest(snapshot_relations);
    initial_snapshot_digest := snapshot_digest;
    declaration_digest := encode(sha256(convert_to(normalized::text, 'UTF8')), 'hex');
    initial_model := pgreact_internal.m36_model(
        normalized, target_kind, source_rows, source_label, evidence_limit);
    previous_model_rows := initial_model -> 'rows';
    previous_frontier := starting_frontier;
    previous_sampled_time := starting_sampled_time;
    previous_watermark := starting_watermark;
    replay_complete := NOT COALESCE((initial_model ->> 'truncated')::boolean, false);
    rows_considered := rows_considered + (initial_model ->> 'rows_considered')::bigint;
    initial_result := jsonb_build_object(
        'result_set', 'initial',
        'ordinal', 0,
        'source_frontier', starting_frontier,
        'sampled_time', starting_sampled_time,
        'event_time_watermark', starting_watermark,
        'change_set', '[]'::jsonb,
        'rows', initial_model -> 'rows',
        'rows_considered', initial_model -> 'rows_considered',
        'delta', '[]'::jsonb,
        'lifecycle', '[]'::jsonb,
        'work', '[]'::jsonb,
        'snapshot_checksum_before', initial_snapshot_digest,
        'snapshot_checksum_after', initial_snapshot_digest,
        'complete', replay_complete);

    FOR step IN SELECT value FROM jsonb_array_elements(replay_steps) item(value)
    LOOP
        step_count := step_count + 1;
        IF jsonb_typeof(step) IS DISTINCT FROM 'object'
           OR NOT (step ?& ARRAY['ordinal', 'source_frontier', 'sampled_time',
                                 'event_time_watermark', 'change_set']) THEN
            RAISE EXCEPTION 'M36_REPLAY_REQUIRED_FIELD: every step needs ordinal, source_frontier, sampled_time, event_time_watermark, and change_set';
        END IF;
        SELECT key INTO unknown_field
        FROM jsonb_object_keys(step) AS key
        WHERE key NOT IN ('ordinal', 'source_frontier', 'sampled_time',
                          'event_time_watermark', 'change_set', 'final')
        ORDER BY key
        LIMIT 1;
        IF unknown_field IS NOT NULL THEN
            RAISE EXCEPTION 'M36_REPLAY_UNKNOWN_FIELD: step field % is not supported', unknown_field;
        END IF;
        IF step ->> 'ordinal' !~ '^[1-9][0-9]*$' THEN
            RAISE EXCEPTION 'M36_REPLAY_ORDINAL: step ordinals must be positive integers';
        END IF;
        ordinal := (step ->> 'ordinal')::bigint;
        IF ordinal <= previous_ordinal THEN
            IF ordinal = previous_ordinal THEN
                RAISE EXCEPTION 'M36_REPLAY_DUPLICATE: step ordinals must be unique';
            END IF;
            RAISE EXCEPTION 'M36_REPLAY_NONMONOTONE: step ordinals must increase';
        END IF;
        BEGIN
            current_frontier := (step ->> 'source_frontier')::timestamptz;
            current_sampled_time := (step ->> 'sampled_time')::timestamptz;
            current_watermark := (step ->> 'event_time_watermark')::timestamptz;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'M36_REPLAY_INVALID: step times must be valid timestamps';
        END;
        IF current_frontier IS NULL OR current_sampled_time IS NULL OR current_watermark IS NULL THEN
            RAISE EXCEPTION 'M36_REPLAY_REQUIRED_FIELD: step times cannot be null';
        END IF;
        IF current_frontier < previous_frontier OR current_sampled_time < previous_sampled_time THEN
            RAISE EXCEPTION 'M36_REPLAY_NONMONOTONE: source_frontier and sampled_time cannot move backward';
        END IF;
        IF current_watermark < previous_watermark THEN
            RAISE EXCEPTION 'M36_REPLAY_LATE_INPUT: event_time_watermark cannot move backward';
        END IF;
        IF current_sampled_time > current_frontier THEN
            RAISE EXCEPTION 'M36_REPLAY_INVALID: sampled_time cannot be after source_frontier';
        END IF;
        IF finalized THEN
            RAISE EXCEPTION 'M36_REPLAY_FINALIZED: replay cannot continue after a final step';
        END IF;
        IF jsonb_typeof(step -> 'change_set') IS DISTINCT FROM 'array' THEN
            RAISE EXCEPTION 'M36_REPLAY_INVALID: change_set must be a JSON array';
        END IF;
        IF jsonb_array_length(step -> 'change_set') > max_changes THEN
            RAISE EXCEPTION 'M36_RESOURCE_LIMIT: step change_set exceeds max_changes';
        END IF;
        total_changes := total_changes + jsonb_array_length(step -> 'change_set');
        IF total_changes > max_total_changes THEN
            RAISE EXCEPTION 'M36_RESOURCE_LIMIT: replay changes exceed max_total_changes';
        END IF;
        IF step ? 'final' AND jsonb_typeof(step -> 'final') IS DISTINCT FROM 'boolean' THEN
            RAISE EXCEPTION 'M36_REPLAY_INVALID: final must be boolean';
        END IF;
        final_step := COALESCE((step ->> 'final')::boolean, false);
        snapshot_digest := pgreact_internal.m36_snapshot_digest(
            jsonb_build_array(jsonb_build_object('relation', source_label, 'rows', source_rows)));
        current_rows := pgreact_internal.m36_apply_changes(
            source_oid, key_column, source_label, source_rows, step -> 'change_set');
        snapshot_digest := pgreact_internal.m36_snapshot_digest(
            jsonb_build_array(jsonb_build_object('relation', source_label, 'rows', current_rows)));
        model := pgreact_internal.m36_model(
            normalized, target_kind, current_rows, source_label, evidence_limit);
        delta_model := pgreact_internal.m34_delta(previous_model_rows, model -> 'rows');
        delta_rows := delta_model -> 'rows';
        SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value ->> 'subject_key'), '[]'::jsonb)
        INTO lifecycle_rows
        FROM jsonb_array_elements(delta_rows) item(value)
        WHERE item.value ->> 'change' <> 'UNCHANGED';
        SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value ->> 'subject_key'), '[]'::jsonb)
        INTO work_rows
        FROM jsonb_array_elements(model -> 'rows') item(value)
        WHERE (item.value -> 'work' ->> 'would_be_work')::boolean;
        step_complete := replay_complete
            AND NOT COALESCE((model ->> 'truncated')::boolean, false)
            AND jsonb_array_length(delta_rows) <= evidence_limit;
        step_result := jsonb_build_object(
            'result_set', 'step',
            'ordinal', ordinal,
            'source_frontier', current_frontier,
            'sampled_time', current_sampled_time,
            'event_time_watermark', current_watermark,
            'change_set', step -> 'change_set',
            'rows', model -> 'rows',
            'rows_considered', model -> 'rows_considered',
            'delta', delta_rows,
            'lifecycle', lifecycle_rows,
            'work', work_rows,
            'snapshot_checksum_before', pgreact_internal.m36_snapshot_digest(
                jsonb_build_array(jsonb_build_object('relation', source_label, 'rows', source_rows))),
            'snapshot_checksum_after', snapshot_digest,
            'complete', step_complete);
        step_results := step_results || jsonb_build_array(step_result);
        previous_model_rows := model -> 'rows';
        source_rows := current_rows;
        previous_ordinal := ordinal;
        previous_frontier := current_frontier;
        previous_sampled_time := current_sampled_time;
        previous_watermark := current_watermark;
        replay_complete := step_complete;
        IF final_step THEN
            finalized := true;
        END IF;
        rows_considered := rows_considered + (model ->> 'rows_considered')::bigint;
        IF step_complete THEN
            affected_subjects := affected_subjects
                + COALESCE((delta_model -> 'counts' ->> 'added')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'removed')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'changed')::bigint, 0);
        END IF;
    END LOOP;
    authoritative_checksum_after := pgreact_internal.m34_authoritative_checksum();
    source_schema_after := pgreact_internal.m36_schema_fingerprint(source_oid);
    IF authoritative_checksum_before IS DISTINCT FROM authoritative_checksum_after
       OR source_schema_before IS DISTINCT FROM source_schema_after THEN
        RAISE EXCEPTION 'M36_AUTHORITATIVE_CHANGED: authoritative source or pg-react state changed during replay';
    END IF;
    IF target_kind = 'policy_set' THEN
        SELECT version.normalized INTO frozen_normalized
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = target_name
          AND version.state = 'DEPLOYED'
          AND (target_version IS NULL OR version.version = target_version)
        ORDER BY version.valid_from DESC, version.created_at DESC
        LIMIT 1;
    ELSE
        SELECT row_data.normalized INTO frozen_normalized
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = target_kind
          AND row_data.object_name = target_name
          AND row_data.state = 'DEPLOYED';
    END IF;
    target_digest_after := encode(sha256(convert_to(frozen_normalized::text, 'UTF8')), 'hex');
    IF target_digest_before IS DISTINCT FROM target_digest_after THEN
        RAISE EXCEPTION 'M36_AUTHORITATIVE_CHANGED: deployed declaration changed during replay';
    END IF;
    replay_digest := encode(sha256(convert_to(
        initial_snapshot_digest || E'\n' || replay_steps::text, 'UTF8')), 'hex');
    initial_result := initial_result
        || jsonb_build_object(
            'declaration_digest', declaration_digest,
            'snapshot_digest', initial_snapshot_digest,
            'replay_digest', replay_digest);
    RETURN jsonb_build_object(
        'contract_version', 23,
        'operation', 'replay',
        'simulation', 'historical_replay',
        'target', jsonb_build_object(
            'kind', target_kind, 'name', target_name, 'version', target_version),
        'state', CASE WHEN replay_complete THEN 'ready' ELSE 'partial' END,
        'summary', jsonb_build_object(
            'read_only', true,
            'initial_row_count', snapshot_row_count,
            'replay_step_count', step_count,
            'replay_change_count', total_changes,
            'final_row_count', jsonb_array_length(previous_model_rows),
            'counts_exact', replay_complete,
            'affected_subject_count', CASE WHEN replay_complete THEN affected_subjects END),
        'snapshot', jsonb_build_object(
            'relations', jsonb_build_array(jsonb_build_object(
                'relation', source_label,
                'schema_fingerprint', source_schema_before,
                'snapshot_checksum', initial_snapshot_digest)),
            'starting_source_frontier', starting_frontier,
            'starting_sampled_time', starting_sampled_time,
            'starting_event_time_watermark', starting_watermark,
            'ending_source_frontier', previous_frontier,
            'ending_sampled_time', previous_sampled_time,
            'ending_event_time_watermark', previous_watermark,
            'authoritative_checksum_before', authoritative_checksum_before,
            'authoritative_checksum_after', authoritative_checksum_after,
            'source_schema_fingerprint_before', source_schema_before,
            'source_schema_fingerprint_after', source_schema_after),
        'evidence', jsonb_build_object(
            'declaration_digest', declaration_digest,
            'snapshot_digest', initial_snapshot_digest,
            'replay_digest', replay_digest,
            'source_frontier', jsonb_build_object(
                'start', starting_frontier, 'end', previous_frontier),
            'sampled_time', jsonb_build_object(
                'start', starting_sampled_time, 'end', previous_sampled_time),
            'event_time_watermark', jsonb_build_object(
                'start', starting_watermark, 'end', previous_watermark),
            'causal', jsonb_build_object(
                'changed_facts', total_changes,
                'steps', step_count,
                'complete', replay_complete),
            'complete', replay_complete,
            'evidence_limit', evidence_limit),
        'cost', jsonb_build_object(
            'snapshot_rows', snapshot_row_count,
            'replay_steps', step_count,
            'change_rows', total_changes,
            'rows_considered', rows_considered,
            'affected_subjects', CASE WHEN replay_complete THEN affected_subjects END,
            'dependency_fan_out', 0,
            'reevaluation', rows_considered,
            'cascade_depth', 0,
            'temporary_storage_bytes', 0,
            'memory_bytes', NULL,
            'elapsed_ms', extract(epoch FROM clock_timestamp() - started_at) * 1000),
        'findings', CASE WHEN replay_complete THEN
            jsonb_build_array(pgreact_internal.m36_finding(
                'M36_NO_EFFECT', 'INFO', target_name, '<replay>',
                'historical replay completed without changing source or pg-react state',
                'Apply reviewed production changes separately if you want to change data.'))
            ELSE jsonb_build_array(pgreact_internal.m36_finding(
                'M36_REPLAY_INCOMPLETE', 'WARNING', target_name, '<replay>',
                'historical replay evidence was truncated at the requested limit',
                'Increase evidence_limit or reduce the supplied snapshot.')) END,
        'initial', initial_result,
        'steps', step_results,
        'final', jsonb_build_object(
            'result_set', 'final',
            'ordinal', previous_ordinal,
            'source_frontier', previous_frontier,
            'sampled_time', previous_sampled_time,
            'event_time_watermark', previous_watermark,
            'rows', previous_model_rows,
            'complete', replay_complete,
            'snapshot_checksum', pgreact_internal.m36_snapshot_digest(
                jsonb_build_array(jsonb_build_object('relation', source_label, 'rows', source_rows)))));
END
$m36$;

CREATE FUNCTION pgreact.replay(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    initial_snapshot jsonb,
    replay_steps jsonb,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
    SELECT pgreact_internal.m36_replay($1, $2, $3, $4, $5)
$m36$;

CREATE FUNCTION pgreact.replay_results(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    initial_snapshot jsonb,
    replay_steps jsonb,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
    result_set text,
    step_ordinal bigint,
    kind text,
    name text,
    subject_key text,
    result_key text,
    state text,
    delta text,
    current_value jsonb,
    proposed_value jsonb,
    evidence jsonb,
    complete boolean,
    sampled_time timestamptz,
    source_frontier timestamptz,
    event_time_watermark timestamptz,
    declaration_digest text,
    snapshot_digest text,
    replay_digest text,
    snapshot_checksum_before text,
    snapshot_checksum_after text
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m36$
WITH replay AS (
    SELECT pgreact.replay($1, $2, $3, $4, $5) AS value
), envelopes AS (
    SELECT value -> 'initial' AS envelope FROM replay
    UNION ALL
    SELECT item.value FROM replay, jsonb_array_elements(value -> 'steps') item(value)
    UNION ALL
    SELECT value -> 'final' FROM replay
), rows AS (
    SELECT envelope, envelope ->> 'result_set' AS result_set,
           (envelope ->> 'ordinal')::bigint AS step_ordinal, item.value
    FROM envelopes, jsonb_array_elements(envelope -> 'rows') item(value)
    UNION ALL
    SELECT envelope, 'delta', (envelope ->> 'ordinal')::bigint, item.value
    FROM envelopes, jsonb_array_elements(envelope -> 'delta') item(value)
    WHERE envelope ->> 'result_set' = 'step'
)
SELECT result_set,
       step_ordinal,
       replay.value -> 'target' ->> 'kind',
       replay.value -> 'target' ->> 'name',
       rows.value ->> 'subject_key',
       rows.value ->> 'result_key',
       rows.value ->> 'state',
       rows.value ->> 'change',
       rows.value -> 'current_value',
       rows.value -> 'proposed_value',
       rows.value -> 'evidence',
       (rows.envelope ->> 'complete')::boolean,
       (rows.envelope ->> 'sampled_time')::timestamptz,
       (rows.envelope ->> 'source_frontier')::timestamptz,
       (rows.envelope ->> 'event_time_watermark')::timestamptz,
       replay.value -> 'evidence' ->> 'declaration_digest',
       replay.value -> 'evidence' ->> 'snapshot_digest',
       replay.value -> 'evidence' ->> 'replay_digest',
       rows.envelope ->> 'snapshot_checksum_before',
       rows.envelope ->> 'snapshot_checksum_after'
FROM replay
JOIN rows ON true
$m36$;

REVOKE ALL ON FUNCTION pgreact_internal.m36_finding(text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_schema_fingerprint(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_require_source(oid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_snapshot_digest(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_validate_rows(oid, name, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_apply_changes(oid, name, text, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_model(jsonb, text, jsonb, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m36_replay(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.replay(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.replay_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) FROM PUBLIC;

DO $m36$
DECLARE
    role_row record;
BEGIN
    FOR role_row IN
        SELECT role_oid::regrole AS role_name
        FROM pgreact_internal.application_roles
        WHERE role_kind IN ('author', 'operator', 'reader')
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION pgreact.replay(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb), '
            'pgreact.replay_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) TO %I',
            role_row.role_name::text);
    END LOOP;
END
$m36$;

COMMENT ON FUNCTION pgreact.replay(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) IS
    'M36 bounded read-only replay of a caller-supplied typed snapshot and historical changes';
COMMENT ON FUNCTION pgreact.replay_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) IS
    'M36 relational initial, step, delta, and final rows for historical replay';
COMMENT ON EXTENSION pg_react IS
    'M36 historical replay: bounded read-only evaluation of caller-supplied typed history';
