-- M35 read-only hypothetical row-change comparison over the M34 evaluator.

CREATE OR REPLACE FUNCTION pgreact_internal.m35_finding(
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
AS $m35$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'target', $3,
        'field', $4,
        'message', $5,
        'hint', $6,
        'details', COALESCE($7, '{}'::jsonb))
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_finding_registry()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
    SELECT jsonb_build_object(
        'schema_version', 1,
        'milestone', 'M35',
        'finding_shape', jsonb_build_array(
            'code', 'severity', 'blocking', 'target',
            'field', 'message', 'hint', 'details'),
        'severity', jsonb_build_array('ERROR', 'WARNING', 'INFO'),
        'codes', jsonb_build_array(
            jsonb_build_object('code', 'M35_CHANGE_SET_INVALID', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_REQUIRED_FIELD', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_UNKNOWN_FIELD', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_RELATION', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_OPERATION', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_ORDINAL', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_DUPLICATE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_CONFLICT', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_KEY', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_ROW', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_CHANGE_STALE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_UNAUTHORIZED_SOURCE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_RLS_UNSUPPORTED', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_UNSUPPORTED_SOURCE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_RESOURCE_LIMIT', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_AUTHORITATIVE_CHANGED', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M35_COMPARISON_INCOMPLETE', 'severity', 'WARNING'),
            jsonb_build_object('code', 'M35_NO_EFFECT', 'severity', 'INFO')))
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_require_source(
    source_oid oid,
    source_name text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
-- ponytail: direct tables and one bigint key keep simulation bounded; add
-- typed composite-key and view adapters only with a new evidence-backed contract.
DECLARE relation_kind "char";
    rls_enabled boolean;
BEGIN
    IF source_oid IS NULL THEN
        RAISE EXCEPTION 'M35_CHANGE_RELATION: source relation % no longer exists', source_name;
    END IF;
    SELECT relkind, relrowsecurity
    INTO relation_kind, rls_enabled
    FROM pg_class
    WHERE oid = source_oid;
    IF relation_kind NOT IN ('r', 'p') THEN
        RAISE EXCEPTION 'M35_UNSUPPORTED_SOURCE: source relation % must be a table', source_name;
    END IF;
    IF rls_enabled THEN
        RAISE EXCEPTION 'M35_RLS_UNSUPPORTED: source relation % uses row-level security', source_name;
    END IF;
    IF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
        RAISE EXCEPTION 'M35_UNAUTHORIZED_SOURCE: caller lacks SELECT on source relation %', source_name;
    END IF;
END
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_source_checksum(
    source_oid oid,
    key_column name
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
DECLARE checksum text;
BEGIN
    EXECUTE format(
        'SELECT encode(sha256(convert_to(COALESCE(
             (SELECT jsonb_agg(to_jsonb(s) ORDER BY s.%1$I, to_jsonb(s)::text)::text
                FROM %2$s s), ''[]''), ''UTF8'')), ''hex'')',
        key_column, source_oid::regclass)
    INTO checksum;
    RETURN checksum;
END
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_check_image(
    source_oid oid,
    image jsonb,
    image_name text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
DECLARE expected_count bigint;
    actual_count bigint;
    unknown_field text;
    missing_field text;
    converted jsonb;
BEGIN
    IF jsonb_typeof(image) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M35_CHANGE_ROW: % must be a complete JSON object', image_name;
    END IF;
    SELECT count(*) INTO expected_count
    FROM pg_attribute
    WHERE attrelid = source_oid AND attnum > 0 AND NOT attisdropped;
    SELECT count(*) INTO actual_count FROM jsonb_object_keys(image);
    SELECT key INTO unknown_field
    FROM jsonb_object_keys(image) AS key
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_attribute
        WHERE attrelid = source_oid AND attnum > 0 AND NOT attisdropped
          AND attname = key)
    ORDER BY key
    LIMIT 1;
    SELECT a.attname INTO missing_field
    FROM pg_attribute a
    WHERE a.attrelid = source_oid AND a.attnum > 0 AND NOT a.attisdropped
      AND NOT (image ? a.attname)
    ORDER BY a.attnum
    LIMIT 1;
    IF actual_count IS DISTINCT FROM expected_count OR unknown_field IS NOT NULL
       OR missing_field IS NOT NULL THEN
        RAISE EXCEPTION 'M35_CHANGE_ROW: % must contain exactly the source columns', image_name;
    END IF;
    BEGIN
        EXECUTE format(
            'SELECT to_jsonb(jsonb_populate_record(NULL::%s, $1))',
            source_oid::regclass)
        INTO converted
        USING image;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'M35_CHANGE_ROW: % does not match the source column types', image_name;
    END;
END
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_apply_changes(
    source_oid oid,
    key_column name,
    change_set jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
DECLARE rows jsonb;
    item jsonb;
    operation text;
    key_text text;
    existing jsonb;
    row_count bigint;
    duplicate_count bigint;
    null_count bigint;
    unknown_field text;
    key_type regtype;
BEGIN
    PERFORM pgreact_internal.m35_require_source(source_oid, source_oid::regclass::text);
    IF jsonb_typeof(change_set) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'M35_CHANGE_SET_INVALID: change_set must be a JSON array';
    END IF;
    SELECT a.atttypid::regtype INTO key_type
    FROM pg_attribute a
    WHERE a.attrelid = source_oid AND a.attname = key_column
      AND a.attnum > 0 AND NOT a.attisdropped;
    IF key_type IS DISTINCT FROM 'bigint'::regtype THEN
        RAISE EXCEPTION 'M35_CHANGE_KEY: identity column % must be bigint', key_column;
    END IF;
    EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NULL', source_oid::regclass, key_column)
    INTO null_count;
    IF null_count > 0 THEN
        RAISE EXCEPTION 'M35_CHANGE_KEY: source relation contains null identities';
    END IF;
    EXECUTE format(
        'SELECT count(*) FROM (SELECT %1$I FROM %2$s GROUP BY %1$I HAVING count(*) > 1) d',
        key_column, source_oid::regclass)
    INTO duplicate_count;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M35_CHANGE_DUPLICATE: source relation contains duplicate identities';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(change_set) item(value)
        WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
           OR NOT (item.value ?& ARRAY['relation', 'operation', 'ordinal', 'key', 'before', 'after'])
           OR (SELECT count(*) FROM jsonb_object_keys(item.value)) <> 6
    ) THEN
        RAISE EXCEPTION 'M35_CHANGE_REQUIRED_FIELD: every change must contain relation, operation, ordinal, key, before, and after';
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_array_elements(change_set) item(value),
         jsonb_object_keys(item.value) AS key
    WHERE key NOT IN ('relation', 'operation', 'ordinal', 'key', 'before', 'after')
    ORDER BY key
    LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        RAISE EXCEPTION 'M35_CHANGE_UNKNOWN_FIELD: change field % is not supported', unknown_field;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(change_set) item(value)
        WHERE jsonb_typeof(item.value -> 'ordinal') IS DISTINCT FROM 'number'
           OR item.value ->> 'ordinal' !~ '^[1-9][0-9]*$'
    ) THEN
        RAISE EXCEPTION 'M35_CHANGE_ORDINAL: ordinals must be positive integers';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(change_set) item(value)
        GROUP BY (item.value ->> 'ordinal')::bigint
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'M35_CHANGE_DUPLICATE: ordinals must be unique';
    END IF;
    EXECUTE format(
        'SELECT COALESCE(jsonb_agg(to_jsonb(s) ORDER BY s.%1$I), ''[]''::jsonb)
         FROM %2$s s', key_column, source_oid::regclass)
    INTO rows;
    FOR item IN
        SELECT value
        FROM jsonb_array_elements(change_set) AS change(value)
        ORDER BY (value ->> 'ordinal')::bigint
    LOOP
        IF to_regclass(item ->> 'relation') IS DISTINCT FROM source_oid THEN
            RAISE EXCEPTION 'M35_CHANGE_RELATION: change relation % does not match %',
                item ->> 'relation', source_oid::regclass;
        END IF;
        operation := item ->> 'operation';
        IF operation IS NULL OR operation NOT IN ('INSERT', 'UPDATE', 'DELETE') THEN
            RAISE EXCEPTION 'M35_CHANGE_OPERATION: operation % is not supported', operation;
        END IF;
        IF jsonb_typeof(item -> 'key') IS DISTINCT FROM 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(item -> 'key')) <> 1
           OR NOT (item -> 'key' ? key_column::text)
           OR jsonb_typeof(item -> 'key' -> key_column::text) IS DISTINCT FROM 'number'
           OR item -> 'key' ->> key_column::text !~ '^-?[0-9]+$' THEN
            RAISE EXCEPTION 'M35_CHANGE_KEY: key must contain one integer % value', key_column;
        END IF;
        key_text := item -> 'key' ->> key_column::text;
        IF operation = 'INSERT' THEN
            IF jsonb_typeof(item -> 'before') IS DISTINCT FROM 'null'
               OR jsonb_typeof(item -> 'after') IS DISTINCT FROM 'object' THEN
                RAISE EXCEPTION 'M35_CHANGE_ROW: INSERT requires a null before image and an after image';
            END IF;
            PERFORM pgreact_internal.m35_check_image(source_oid, item -> 'after', 'after');
            IF item -> 'after' ->> key_column::text IS DISTINCT FROM key_text THEN
                RAISE EXCEPTION 'M35_CHANGE_KEY: INSERT key does not match its after image';
            END IF;
            SELECT count(*) INTO row_count
            FROM jsonb_array_elements(rows) current_row(value)
            WHERE current_row.value ->> key_column::text = key_text;
            IF row_count > 0 THEN
                RAISE EXCEPTION 'M35_CHANGE_CONFLICT: INSERT identity % already exists', key_text;
            END IF;
            rows := rows || jsonb_build_array(item -> 'after');
        ELSE
            IF jsonb_typeof(item -> 'before') IS DISTINCT FROM 'object'
               OR jsonb_typeof(item -> 'after') IS DISTINCT FROM
                  (CASE WHEN operation = 'UPDATE' THEN 'object' ELSE 'null' END) THEN
                RAISE EXCEPTION 'M35_CHANGE_ROW: % requires the correct before and after images', operation;
            END IF;
            PERFORM pgreact_internal.m35_check_image(source_oid, item -> 'before', 'before');
            IF operation = 'UPDATE' THEN
                PERFORM pgreact_internal.m35_check_image(source_oid, item -> 'after', 'after');
                IF item -> 'after' ->> key_column::text IS DISTINCT FROM key_text THEN
                    RAISE EXCEPTION 'M35_CHANGE_KEY: UPDATE cannot change its identity';
                END IF;
            END IF;
            SELECT count(*), (array_agg(current_row.value))[1]
            INTO row_count, existing
            FROM jsonb_array_elements(rows) current_row(value)
            WHERE current_row.value ->> key_column::text = key_text;
            IF row_count = 0 THEN
                RAISE EXCEPTION 'M35_CHANGE_STALE: identity % is not present', key_text;
            ELSIF row_count > 1 THEN
                RAISE EXCEPTION 'M35_CHANGE_DUPLICATE: identity % is ambiguous', key_text;
            ELSIF existing IS DISTINCT FROM item -> 'before' THEN
                RAISE EXCEPTION 'M35_CHANGE_STALE: before image for identity % is stale', key_text;
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
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_rule_rows(
    rows jsonb,
    key_column name,
    source_label text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
SELECT jsonb_build_object(
    'rows', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'subject_key', item.value ->> $2,
                   'result_key', item.value ->> $2,
                   'state', 'MATCH',
                   'value', item.value,
                   'work', jsonb_build_object('would_be_work', true),
                   'evidence', jsonb_build_object(
                       'source', $3, 'hypothetical', true, 'complete', true))
                   ORDER BY (item.value ->> $2)::bigint)
        FROM (
            SELECT value
            FROM jsonb_array_elements($1) item(value)
            ORDER BY (item.value ->> $2)::bigint
            LIMIT $4
        ) item), '[]'::jsonb),
    'rows_considered', jsonb_array_length($1),
    'truncated', jsonb_array_length($1) > $4)
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_decision_rows(
    rows jsonb,
    subject_column name,
    candidate_column name,
    priority_column name,
    result_columns name[],
    max_candidates integer,
    source_label text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
DECLARE total_count bigint;
    duplicate_count bigint;
    over_limit_count bigint;
    result_rows jsonb;
BEGIN
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(rows) item(value)
        WHERE item.value ->> subject_column::text IS NULL
           OR item.value ->> candidate_column::text IS NULL
           OR item.value ->> priority_column::text IS NULL
    ) THEN
        RAISE EXCEPTION 'M35_CHANGE_ROW: decision rows require subject, candidate, and priority values';
    END IF;
    SELECT count(*) INTO duplicate_count
    FROM (
        SELECT item.value ->> subject_column::text, item.value ->> candidate_column::text
        FROM jsonb_array_elements(rows) item(value)
        GROUP BY item.value ->> subject_column::text, item.value ->> candidate_column::text
        HAVING count(*) > 1
    ) duplicates;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M35_CHANGE_DUPLICATE: decision source contains duplicate candidates';
    END IF;
    SELECT count(*) INTO over_limit_count
    FROM (
        SELECT item.value ->> subject_column::text
        FROM jsonb_array_elements(rows) item(value)
        GROUP BY item.value ->> subject_column::text
        HAVING count(*) > max_candidates
    ) over_limit;
    IF over_limit_count > 0 THEN
        RAISE EXCEPTION 'M35_RESOURCE_LIMIT: decision source exceeds max_candidates';
    END IF;
    SELECT count(DISTINCT (item.value ->> subject_column::text)::bigint)
    INTO total_count
    FROM jsonb_array_elements(rows) item(value);
    WITH candidates AS (
        SELECT item.value AS row_data,
               (item.value ->> subject_column::text)::bigint AS subject_key,
               (item.value ->> candidate_column::text)::bigint AS candidate_key,
               (item.value ->> priority_column::text)::bigint AS priority
        FROM jsonb_array_elements(rows) item(value)
    ), ranked AS (
        SELECT candidates.*, min(priority) OVER (PARTITION BY subject_key) AS best_priority
        FROM candidates
    ), grouped AS (
        SELECT subject_key,
               min(priority) AS best_priority,
               count(*) AS candidate_count,
               count(*) FILTER (WHERE priority = best_priority) AS top_count,
               min(candidate_key) FILTER (WHERE priority = best_priority) AS winner_candidate,
               (array_agg(row_data ORDER BY candidate_key)
                   FILTER (WHERE priority = best_priority))[1] AS winner_row,
               jsonb_agg(jsonb_build_object(
                   'candidate', candidate_key::text,
                   'priority', priority,
                   'value', row_data) ORDER BY candidate_key) AS competitors
        FROM ranked
        GROUP BY subject_key
    ), limited AS (
        SELECT * FROM grouped ORDER BY subject_key LIMIT evidence_limit
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'subject_key', subject_key::text,
               'result_key', CASE WHEN top_count = 1 THEN winner_candidate::text END,
               'state', CASE WHEN top_count = 1 THEN 'WINNER' ELSE 'AMBIGUOUS' END,
               'value', jsonb_build_object(
                   'candidate', CASE WHEN top_count = 1 THEN winner_candidate END,
                   'priority', best_priority,
                   'result', CASE WHEN top_count = 1
                                  THEN pgreact_internal.decision_result(winner_row, result_columns)
                             END,
                   'claimable', top_count = 1),
               'work', jsonb_build_object('would_be_work', top_count = 1),
               'evidence', jsonb_build_object(
                   'source', source_label,
                   'candidate_count', candidate_count,
                   'competitors', competitors,
                   'hypothetical', true,
                   'complete', true)) ORDER BY subject_key), '[]'::jsonb)
    INTO result_rows
    FROM limited;
    RETURN jsonb_build_object(
        'rows', result_rows,
        'rows_considered', total_count,
        'truncated', total_count > evidence_limit);
END
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_policy_subject_rows(
    rows jsonb,
    key_column name,
    source_label text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
WITH subjects AS (
    SELECT DISTINCT (item.value ->> $2)::bigint AS subject_key
    FROM jsonb_array_elements($1) item(value)
), limited AS (
    SELECT subject_key
    FROM subjects
    ORDER BY subject_key
    LIMIT $4
)
SELECT jsonb_build_object(
    'rows', COALESCE(jsonb_agg(jsonb_build_object(
        'subject_key', 'subject:' || encode(
            pgreact_internal.m30_key_identity(
                ARRAY['bigint']::text[], jsonb_build_array(subject_key)), 'hex'),
        'result_key', 'subject:' || encode(
            pgreact_internal.m30_key_identity(
                ARRAY['bigint']::text[], jsonb_build_array(subject_key)), 'hex'),
        'state', 'ELIGIBLE',
        'value', jsonb_build_array(subject_key),
        'work', jsonb_build_object('would_be_work', false),
        'evidence', jsonb_build_object(
            'source', $3, 'hypothetical', true, 'complete', true))
        ORDER BY subject_key), '[]'::jsonb),
    'rows_considered', (SELECT count(*) FROM subjects),
    'truncated', (SELECT count(*) FROM subjects) > $4)
FROM limited
$m35$;

CREATE OR REPLACE FUNCTION pgreact_internal.m35_compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    change_set jsonb,
    options jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
DECLARE effective_proposed pgreact_api.declaration;
    proposed_normalized jsonb;
    base jsonb;
    base_options jsonb;
    source_oid oid;
    source_label text;
    key_column name;
    target_kind text := (deployed).kind;
    target_name text := (deployed).name;
    target_version text := (deployed).version;
    evidence_limit integer := 100;
    max_changes integer := 1000;
    source_frontier timestamptz;
    sampled_time timestamptz;
    started_at timestamptz := clock_timestamp();
    source_checksum_before text;
    source_checksum_after text;
    authoritative_checksum_before text;
    authoritative_checksum_after text;
    source_rows jsonb;
    current_rows jsonb;
    proposed_rows jsonb;
    delta_rows jsonb;
    lifecycle_rows jsonb;
    work_rows jsonb;
    proposed_model jsonb;
    delta_model jsonb;
    current_count bigint;
    proposed_count bigint;
    missing_count bigint := 0;
    comparison_complete boolean;
    change_set_digest text;
    member_rows jsonb;
    subject_model jsonb;
    member_count bigint := 0;
    subject_count bigint := 0;
    key_names name[];
    result_columns name[];
    max_candidates integer;
BEGIN
    target_kind := (deployed).kind;
    target_name := (deployed).name;
    target_version := (deployed).version;
    effective_proposed := proposed;
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M35_CHANGE_SET_INVALID: options must be a JSON object';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_object_keys(options) AS key
        WHERE key NOT IN ('evidence_limit', 'sampled_time', 'max_changes')
    ) THEN
        RAISE EXCEPTION 'M35_CHANGE_UNKNOWN_FIELD: unsupported comparison option';
    END IF;
    IF options ? 'evidence_limit' THEN
        IF jsonb_typeof(options -> 'evidence_limit') IS DISTINCT FROM 'number'
           OR options ->> 'evidence_limit' !~ '^[1-9][0-9]*$'
           OR (options ->> 'evidence_limit')::integer > 1000 THEN
            RAISE EXCEPTION 'M35_RESOURCE_LIMIT: evidence_limit must be between 1 and 1000';
        END IF;
        evidence_limit := (options ->> 'evidence_limit')::integer;
    END IF;
    IF options ? 'max_changes' THEN
        IF jsonb_typeof(options -> 'max_changes') IS DISTINCT FROM 'number'
           OR options ->> 'max_changes' !~ '^[1-9][0-9]*$'
           OR (options ->> 'max_changes')::integer > 1000 THEN
            RAISE EXCEPTION 'M35_RESOURCE_LIMIT: max_changes must be between 1 and 1000';
        END IF;
        max_changes := (options ->> 'max_changes')::integer;
    END IF;
    IF jsonb_typeof(change_set) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'M35_CHANGE_SET_INVALID: change_set must be a JSON array';
    END IF;
    IF jsonb_array_length(change_set) > max_changes THEN
        RAISE EXCEPTION 'M35_RESOURCE_LIMIT: change_set exceeds max_changes';
    END IF;
    IF options ? 'sampled_time'
       AND jsonb_typeof(options -> 'sampled_time') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'M35_CHANGE_SET_INVALID: sampled_time must be an RFC3339 timestamp string';
    END IF;
    IF effective_proposed IS NULL THEN
        SELECT ROW(row_data.api_version, row_data.kind, row_data.object_name,
                   row_data.spec)::pgreact_api.declaration
        INTO effective_proposed
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = target_kind
          AND row_data.object_name = target_name
          AND row_data.state = 'DEPLOYED';
        SELECT row_data.normalized INTO proposed_normalized
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = target_kind
          AND row_data.object_name = target_name
          AND row_data.state = 'DEPLOYED';
        IF effective_proposed IS NULL THEN
            RAISE EXCEPTION 'M35_CHANGE_SET_INVALID: deployed declaration is required';
        END IF;
    ELSE
        proposed_normalized := pgreact_internal.m28_normalize(effective_proposed);
    END IF;
    IF target_kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
        RAISE EXCEPTION 'M35_UNSUPPORTED_SOURCE: target kind % is not supported', target_kind;
    END IF;
    IF (effective_proposed).kind IS DISTINCT FROM target_kind
       OR (effective_proposed).name IS DISTINCT FROM target_name THEN
        RAISE EXCEPTION 'M35_CHANGE_SET_INVALID: proposed and deployed targets must match';
    END IF;
    IF target_kind = 'rule' THEN
        source_label := proposed_normalized -> 'spec' ->> 'condition';
        key_column := (proposed_normalized -> 'spec' ->> 'semantic_key')::name;
    ELSIF target_kind = 'decision_program' THEN
        source_label := proposed_normalized -> 'spec' ->> 'candidate_relation';
        key_column := (proposed_normalized -> 'spec' ->> 'candidate_key')::name;
    ELSE
        source_label := proposed_normalized -> 'spec' -> 'applicability' ->> 'relation';
        SELECT array_agg(value::name ORDER BY ordinal)
        INTO key_names
        FROM jsonb_array_elements_text(
                 proposed_normalized -> 'spec' -> 'applicability' -> 'subject_keys')
             WITH ORDINALITY requested(value, ordinal);
        IF cardinality(key_names) IS DISTINCT FROM 1 THEN
            RAISE EXCEPTION 'M35_UNSUPPORTED_SOURCE: M35 requires one bigint policy subject key';
        END IF;
        key_column := key_names[1];
    END IF;
    source_oid := to_regclass(source_label);
    PERFORM pgreact_internal.m35_require_source(source_oid, source_label);
    source_checksum_before := pgreact_internal.m35_source_checksum(source_oid, key_column);
    base_options := options - 'max_changes';
    base := pgreact.compare(effective_proposed, deployed, base_options);
    IF base ->> 'state' = 'attention' THEN
        RETURN base || jsonb_build_object(
            'contract_version', 22,
            'simulation', 'hypothetical_fact_changes',
            'change_set_digest', encode(
                sha256(convert_to(change_set::text, 'UTF8')), 'hex'));
    END IF;
    source_rows := pgreact_internal.m35_apply_changes(source_oid, key_column, change_set);
    current_rows := base -> 'current';
    current_count := (base -> 'summary' ->> 'current_count')::bigint;
    IF target_kind = 'rule' THEN
        proposed_model := pgreact_internal.m35_rule_rows(
            source_rows, key_column, source_label, evidence_limit);
    ELSIF target_kind = 'decision_program' THEN
        SELECT array_agg(value::name ORDER BY ordinal)
        INTO result_columns
        FROM jsonb_array_elements_text(proposed_normalized -> 'spec' -> 'results')
             WITH ORDINALITY item(value, ordinal);
        max_candidates := COALESCE(
            (proposed_normalized -> 'spec' ->> 'max_candidates')::integer, 1000);
        proposed_model := pgreact_internal.m35_decision_rows(
            source_rows,
            (proposed_normalized -> 'spec' ->> 'subject_key')::name,
            (proposed_normalized -> 'spec' ->> 'candidate_key')::name,
            (proposed_normalized -> 'spec' ->> 'priority')::name,
            result_columns, max_candidates, source_label, evidence_limit);
        SELECT count(*) INTO missing_count
        FROM jsonb_array_elements(current_rows) current_row
        WHERE NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(proposed_model -> 'rows') proposed_row
            WHERE proposed_row.value ->> 'subject_key' = current_row.value ->> 'subject_key');
        IF missing_count > 0 THEN
            SELECT COALESCE(jsonb_agg(row_data ORDER BY row_data ->> 'subject_key'), '[]'::jsonb)
            INTO proposed_rows
            FROM (
                SELECT proposed_row.value AS row_data
                FROM jsonb_array_elements(proposed_model -> 'rows') proposed_row
                UNION ALL
                SELECT jsonb_build_object(
                           'subject_key', current_row.value ->> 'subject_key',
                           'result_key', NULL,
                           'state', 'NO_CANDIDATE',
                           'value', jsonb_build_object(
                               'candidate', NULL, 'priority', NULL, 'result', NULL),
                           'work', jsonb_build_object('would_be_work', false),
                           'evidence', jsonb_build_object(
                               'source', 'pgreact.decision_winners',
                               'hypothetical', true, 'complete', true))
                FROM jsonb_array_elements(current_rows) current_row
                WHERE NOT EXISTS (
                    SELECT 1 FROM jsonb_array_elements(proposed_model -> 'rows') proposed_row
                    WHERE proposed_row.value ->> 'subject_key' = current_row.value ->> 'subject_key')
            ) rows;
            proposed_model := jsonb_build_object(
                'rows', proposed_rows,
                'rows_considered', (proposed_model ->> 'rows_considered')::bigint + missing_count,
                'truncated', COALESCE((proposed_model ->> 'truncated')::boolean, false)
                    OR (proposed_model ->> 'rows_considered')::bigint + missing_count
                       > evidence_limit);
        END IF;
    ELSE
        subject_model := pgreact_internal.m35_policy_subject_rows(
            source_rows, key_column, source_label, evidence_limit);
        SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value ->> 'subject_key'), '[]'::jsonb)
        INTO member_rows
        FROM jsonb_array_elements(base -> 'proposed') item(value)
        WHERE item.value ->> 'subject_key' NOT LIKE 'subject:%';
        member_count := jsonb_array_length(
            COALESCE(proposed_normalized -> 'spec' -> 'members', '[]'::jsonb));
        subject_count := (subject_model ->> 'rows_considered')::bigint;
        proposed_model := jsonb_build_object(
            'rows', COALESCE(member_rows, '[]'::jsonb) || (subject_model -> 'rows'),
            'rows_considered', member_count + subject_count,
            'truncated', COALESCE((base ->> 'truncated')::boolean, false)
                OR COALESCE((subject_model ->> 'truncated')::boolean, false)
                OR member_count > evidence_limit);
    END IF;
    proposed_rows := proposed_model -> 'rows';
    proposed_count := (proposed_model ->> 'rows_considered')::bigint;
    delta_model := pgreact_internal.m34_delta(current_rows, proposed_rows);
    delta_rows := delta_model -> 'rows';
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value ->> 'subject_key'), '[]'::jsonb)
    INTO lifecycle_rows
    FROM jsonb_array_elements(delta_rows) item(value)
    WHERE item.value ->> 'change' <> 'UNCHANGED';
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value ->> 'subject_key'), '[]'::jsonb)
    INTO work_rows
    FROM jsonb_array_elements(proposed_rows) item(value)
    WHERE (item.value -> 'work' ->> 'would_be_work')::boolean;
    source_checksum_after := pgreact_internal.m35_source_checksum(source_oid, key_column);
    authoritative_checksum_before := base -> 'evidence' ->> 'authoritative_checksum_before';
    authoritative_checksum_after := pgreact_internal.m34_authoritative_checksum();
    IF source_checksum_before IS DISTINCT FROM source_checksum_after
       OR authoritative_checksum_before IS DISTINCT FROM authoritative_checksum_after THEN
        RAISE EXCEPTION 'M35_AUTHORITATIVE_CHANGED: authoritative source or pg-react state changed during comparison';
    END IF;
    source_frontier := (base -> 'evidence' ->> 'source_frontier')::timestamptz;
    sampled_time := (base -> 'evidence' ->> 'sampled_time')::timestamptz;
    comparison_complete := NOT COALESCE((base ->> 'truncated')::boolean, false)
        AND NOT COALESCE((proposed_model ->> 'truncated')::boolean, false)
        AND jsonb_array_length(delta_rows) <= evidence_limit;
    change_set_digest := encode(sha256(convert_to(change_set::text, 'UTF8')), 'hex');
    RETURN jsonb_build_object(
        'contract_version', 22,
        'operation', 'compare',
        'simulation', 'hypothetical_fact_changes',
        'target', jsonb_build_object(
            'kind', target_kind, 'name', target_name, 'version', target_version),
        'state', CASE WHEN comparison_complete THEN 'ready' ELSE 'partial' END,
        'summary', jsonb_build_object(
            'read_only', true,
            'current_count', current_count,
            'proposed_count', proposed_count,
            'delta_counts', CASE WHEN comparison_complete THEN delta_model -> 'counts' END,
            'counts_exact', comparison_complete,
            'affected_subject_count', CASE WHEN comparison_complete THEN
                COALESCE((delta_model -> 'counts' ->> 'added')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'removed')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'changed')::bigint, 0) END,
            'hypothetical_change_count', jsonb_array_length(change_set),
            'would_be_work', COALESCE((
                SELECT count(*) FROM jsonb_array_elements(proposed_rows) item
                WHERE (item.value -> 'work' ->> 'would_be_work')::boolean), 0)),
        'snapshot', jsonb_build_object(
            'source_relation', source_label,
            'source_frontier', source_frontier,
            'sampled_time', sampled_time,
            'applicability_snapshot', base -> 'evidence' -> 'applicability_snapshot',
            'authoritative_checksum_before', authoritative_checksum_before,
            'authoritative_checksum_after', authoritative_checksum_after,
            'source_checksum_before', source_checksum_before,
            'source_checksum_after', source_checksum_after),
        'evidence', jsonb_build_object(
            'declaration_digest', base -> 'evidence' ->> 'declaration_digest',
            'change_set_digest', change_set_digest,
            'changed_facts', change_set,
            'causal', jsonb_build_object(
                'changed_facts', jsonb_array_length(change_set),
                'support', 'production evaluator evidence',
                'complete', comparison_complete),
            'complete', comparison_complete,
            'evidence_limit', evidence_limit),
        'cost', jsonb_build_object(
            'rows_considered', current_count + proposed_count,
            'hypothetical_rows', jsonb_array_length(change_set),
            'affected_subjects', CASE WHEN comparison_complete THEN
                COALESCE((delta_model -> 'counts' ->> 'added')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'removed')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'changed')::bigint, 0) END,
            'dependency_fan_out', 0,
            'reevaluation', proposed_count,
            'cascade_depth', 0,
            'temporary_storage_bytes', 0,
            'memory_bytes', NULL,
            'elapsed_ms', extract(epoch FROM clock_timestamp() - started_at) * 1000),
        'findings', CASE WHEN comparison_complete THEN
            jsonb_build_array(pgreact_internal.m35_finding(
                'M35_NO_EFFECT', 'INFO', target_name, '<comparison>',
                'hypothetical comparison completed without changing source or pg-react state',
                'Apply the reviewed change separately if you want to change production.'))
            ELSE jsonb_build_array(pgreact_internal.m35_finding(
                'M35_COMPARISON_INCOMPLETE', 'WARNING', target_name, '<comparison>',
                'hypothetical evidence was truncated at the requested limit',
                'Increase evidence_limit or reduce the input and inspect the bounded result.')) END,
        'current', pgreact_internal.m34_raw_rows(current_rows, current_count, evidence_limit) -> 'rows',
        'proposed', pgreact_internal.m34_raw_rows(proposed_rows, proposed_count, evidence_limit) -> 'rows',
        'delta', pgreact_internal.m34_raw_rows(
            delta_rows, jsonb_array_length(delta_rows), evidence_limit) -> 'rows',
        'lifecycle', pgreact_internal.m34_raw_rows(
            lifecycle_rows, jsonb_array_length(lifecycle_rows), evidence_limit) -> 'rows',
        'work', pgreact_internal.m34_raw_rows(
            work_rows, jsonb_array_length(work_rows), evidence_limit) -> 'rows',
        'truncated', NOT comparison_complete)
;
END
$m35$;

CREATE FUNCTION pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    change_set jsonb,
    options jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
    SELECT pgreact_internal.m35_compare($1, $2, $3, $4)
$m35$;

CREATE FUNCTION pgreact.compare_results(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    change_set jsonb,
    options jsonb
)
RETURNS TABLE(
    result_set text,
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
    declaration_digest text,
    change_set_digest text,
    source_checksum_before text,
    source_checksum_after text
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m35$
WITH comparison AS (
    SELECT pgreact.compare($1, $2, $3, $4) AS value
), rows AS (
    SELECT 'current'::text AS result_set, item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'current') item(value)
    UNION ALL
    SELECT 'proposed', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'proposed') item(value)
    UNION ALL
    SELECT 'delta', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'delta') item(value)
    UNION ALL
    SELECT 'lifecycle', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'lifecycle') item(value)
    UNION ALL
    SELECT 'work', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'work') item(value)
)
SELECT result_set,
       comparison.value -> 'target' ->> 'kind',
       comparison.value -> 'target' ->> 'name',
       rows.value ->> 'subject_key',
       rows.value ->> 'result_key',
       rows.value ->> 'state',
       rows.value ->> 'change',
       rows.value -> 'current_value',
       rows.value -> 'proposed_value',
       rows.value -> 'evidence',
       (comparison.value -> 'evidence' ->> 'complete')::boolean,
       (comparison.value -> 'snapshot' ->> 'sampled_time')::timestamptz,
       (comparison.value -> 'snapshot' ->> 'source_frontier')::timestamptz,
       comparison.value -> 'evidence' ->> 'declaration_digest',
       comparison.value -> 'evidence' ->> 'change_set_digest',
       comparison.value -> 'snapshot' ->> 'source_checksum_before',
       comparison.value -> 'snapshot' ->> 'source_checksum_after'
FROM comparison
JOIN rows ON true
$m35$;

REVOKE ALL ON FUNCTION pgreact_internal.m35_finding(text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_require_source(oid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_source_checksum(oid, name) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_check_image(oid, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_apply_changes(oid, name, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_rule_rows(jsonb, name, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_decision_rows(jsonb, name, name, name, name[], integer, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_policy_subject_rows(jsonb, name, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m35_compare(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb) FROM PUBLIC;

DO $m35$
DECLARE role_row record;
BEGIN
    FOR role_row IN
        SELECT role_oid::regrole AS role_name
        FROM pgreact_internal.application_roles
        WHERE role_kind IN ('author', 'operator', 'reader')
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb), '
            'pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb) TO %I',
            role_row.role_name::text);
    END LOOP;
END
$m35$;

COMMENT ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb) IS
    'M35 bounded read-only comparison with ordered hypothetical typed row changes';
COMMENT ON FUNCTION pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb) IS
    'M35 relational current, proposed, delta, lifecycle, and work rows for hypothetical changes';
COMMENT ON EXTENSION pg_react IS
    'M35 hypothetical fact simulation: bounded read-only comparison of typed ordered row changes';
