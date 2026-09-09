-- pg-react 0.43.2 correctness patch over the M54 public workflow.

CREATE OR REPLACE FUNCTION pgreact_internal.m54_relation_identity(source_oid oid)
RETURNS text
LANGUAGE SQL STABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT format('%I.%I', namespace.nspname, relation.relname)
    FROM pg_catalog.pg_class relation
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE relation.oid = $1
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_decision_result(
    row_data jsonb, columns name[]
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE STRICT SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    column_name name;
    result jsonb := '{}'::jsonb;
BEGIN
    FOREACH column_name IN ARRAY columns LOOP
        result := result || jsonb_build_object(column_name::text,
                                               row_data -> column_name::text);
    END LOOP;
    RETURN result;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_read_rule_model(
    source_schema name, source_relation name, key_column name,
    source_label text, work_enabled boolean, evidence_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    total_count bigint;
    null_count bigint;
    duplicate_count bigint;
    rows jsonb;
BEGIN
    EXECUTE format('SELECT count(*) FROM %I.%I', source_schema, source_relation)
        INTO total_count;
    EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I IS NULL',
                   source_schema, source_relation, key_column) INTO null_count;
    IF null_count > 0 THEN
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: rule source % contains null keys', source_label;
    END IF;
    EXECUTE format('SELECT count(*) FROM (SELECT %I FROM %I.%I GROUP BY %I HAVING count(*) > 1) duplicates',
                   key_column, source_schema, source_relation, key_column)
        INTO duplicate_count;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M34_PROPOSAL_DUPLICATE: rule source % contains duplicate keys', source_label;
    END IF;
    EXECUTE format($query$
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'subject_key', s.%1$I::text, 'result_key', s.%1$I::text,
            'state', 'MATCH', 'value', to_jsonb(s),
            'work', jsonb_build_object('would_be_work', $2),
            'evidence', jsonb_build_object('source', $3, 'complete', true))
            ORDER BY s.%1$I), '[]'::jsonb)
        FROM (SELECT * FROM %2$I.%3$I ORDER BY %1$I LIMIT ($1 + 1)) s
    $query$, key_column, source_schema, source_relation)
    INTO rows USING evidence_limit, work_enabled, source_label;
    RETURN jsonb_build_object('rows', rows, 'rows_considered', total_count,
                              'truncated', total_count > evidence_limit);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_read_decision_model(
    source_schema name, source_relation name, subject_column name,
    candidate_column name, priority_column name, result_columns name[],
    max_candidates integer, source_label text, evidence_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    total_count bigint;
    null_count bigint;
    duplicate_count bigint;
    over_limit_count bigint;
    rows jsonb;
BEGIN
    EXECUTE format('SELECT count(*) FROM %1$I.%2$I WHERE %3$I IS NULL OR %4$I IS NULL OR %5$I IS NULL',
        source_schema, source_relation, subject_column, candidate_column, priority_column)
        INTO null_count;
    IF null_count > 0 THEN
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: decision source % contains null identities or priorities', source_label;
    END IF;
    EXECUTE format('SELECT count(*) FROM (SELECT %1$I, %2$I FROM %3$I.%4$I GROUP BY %1$I, %2$I HAVING count(*) > 1) duplicates',
        subject_column, candidate_column, source_schema, source_relation)
        INTO duplicate_count;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M34_PROPOSAL_DUPLICATE: decision source % contains duplicate candidates', source_label;
    END IF;
    EXECUTE format('SELECT count(*) FROM (SELECT %1$I FROM %2$I.%3$I GROUP BY %1$I HAVING count(*) > $1) over_limit',
        subject_column, source_schema, source_relation)
        INTO over_limit_count USING max_candidates;
    IF over_limit_count > 0 THEN
        RAISE EXCEPTION 'M34_RESOURCE_LIMIT: decision source % exceeds max_candidates', source_label;
    END IF;
    EXECUTE format('SELECT count(DISTINCT %1$I) FROM %2$I.%3$I',
        subject_column, source_schema, source_relation) INTO total_count;
    EXECUTE format($query$
        WITH source AS (
            SELECT s.%1$I::bigint AS subject_key, s.%2$I::bigint AS candidate_key,
                   s.%3$I::bigint AS priority, to_jsonb(s) AS row_data
            FROM %4$I.%5$I s
        ), ranked AS (
            SELECT source.*, min(priority) OVER (PARTITION BY subject_key) AS best_priority
            FROM source
        ), grouped AS (
            SELECT subject_key, min(priority) AS best_priority, count(*) AS candidate_count,
                   count(*) FILTER (WHERE priority = best_priority) AS top_count,
                   min(candidate_key) FILTER (WHERE priority = best_priority) AS winner_candidate,
                   (array_agg(row_data ORDER BY candidate_key)
                       FILTER (WHERE priority = best_priority))[1] AS winner_row,
                   jsonb_agg(jsonb_build_object('candidate', candidate_key::text,
                       'priority', priority, 'value', row_data) ORDER BY candidate_key) AS competitors
            FROM ranked GROUP BY subject_key
        ), limited AS (
            SELECT * FROM grouped ORDER BY subject_key LIMIT ($1 + 1)
        )
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'subject_key', subject_key::text,
            'result_key', CASE WHEN top_count = 1 THEN winner_candidate::text ELSE NULL END,
            'state', CASE WHEN top_count = 1 THEN 'WINNER' ELSE 'AMBIGUOUS' END,
            'value', jsonb_build_object('candidate', CASE WHEN top_count = 1 THEN winner_candidate ELSE NULL END,
                'priority', best_priority,
                'result', CASE WHEN top_count = 1
                    THEN pgreact_internal.m54_decision_result(winner_row, $3) ELSE NULL END),
            'work', jsonb_build_object('would_be_work', top_count = 1),
            'evidence', jsonb_build_object('source', $2,
                'candidate_count', candidate_count, 'competitors', competitors, 'complete', true))
            ORDER BY subject_key), '[]'::jsonb)
        FROM limited
    $query$, subject_column, candidate_column, priority_column,
             source_schema, source_relation)
    INTO rows USING evidence_limit, source_label, result_columns;
    RETURN jsonb_build_object('rows', rows, 'rows_considered', total_count,
                              'truncated', total_count > evidence_limit);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    target_kind text := (deployed).kind;
    target_name text := (deployed).name;
    target_version text := (deployed).version;
    validation jsonb;
    current_validation jsonb;
    current_document jsonb;
    current_normalized jsonb;
    proposed_normalized jsonb;
    current_model jsonb;
    proposed_model jsonb;
    delta_model jsonb;
    current_rows jsonb;
    proposed_rows jsonb;
    delta_rows jsonb;
    lifecycle_rows jsonb;
    work_rows jsonb;
    evidence_limit integer := 100;
    sampled_time timestamptz;
    source_frontier timestamptz;
    before_checksum text;
    after_checksum text;
    comparison_complete boolean;
    source_oid oid;
    source_schema name;
    source_relation name;
    key_column name;
    subject_column name;
    candidate_column name;
    priority_column name;
    result_columns name[];
    max_candidates integer;
    relation_name text;
    current_decl pgreact_api.declaration;
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M34_OPTIONS: options must be a JSON object';
    END IF;
    IF options ? 'evidence_limit' THEN
        IF jsonb_typeof(options -> 'evidence_limit') IS DISTINCT FROM 'number'
           OR (options ->> 'evidence_limit')::integer < 1
           OR (options ->> 'evidence_limit')::integer > 1000 THEN
            RAISE EXCEPTION 'M34_RESOURCE_LIMIT: evidence_limit must be between 1 and 1000';
        END IF;
        evidence_limit := (options ->> 'evidence_limit')::integer;
    END IF;
    IF options ? 'sampled_time' THEN
        IF jsonb_typeof(options -> 'sampled_time') IS DISTINCT FROM 'string' THEN
            RAISE EXCEPTION 'M34_OPTIONS: sampled_time must be an RFC3339 timestamp string';
        END IF;
        sampled_time := (options ->> 'sampled_time')::timestamptz;
    END IF;
    SELECT frontier INTO source_frontier
    FROM pgreact_internal.clock_frontier
    WHERE singleton;
    sampled_time := COALESCE(sampled_time, source_frontier);
    IF sampled_time IS DISTINCT FROM source_frontier THEN
        RAISE EXCEPTION 'M34_SAMPLED_TIME: comparison must use the current authoritative frontier %',
            source_frontier;
    END IF;
    IF proposed IS NULL OR target_kind IS NULL OR target_name IS NULL THEN
        RAISE EXCEPTION 'M34_INVALID_DECLARATION: proposed declaration and target are required';
    END IF;
    IF (proposed).kind IS DISTINCT FROM target_kind THEN
        RAISE EXCEPTION 'M34_TARGET_KIND: proposed and deployed kinds must match';
    END IF;
    IF (proposed).name IS DISTINCT FROM target_name THEN
        RAISE EXCEPTION 'M34_TARGET_NAME: proposed declaration name must match deployed target name';
    END IF;
    IF target_kind = 'policy_set' THEN
        RETURN pgreact.compare_m43(proposed, deployed, options);
    END IF;
    validation := pgreact.validate(proposed);
    IF validation ->> 'state' = 'attention' THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(validation -> 'findings') item
                   WHERE item ->> 'code' = 'M54_RLS_UNSUPPORTED') THEN
            RAISE EXCEPTION 'M34_RLS_UNSUPPORTED: source relation uses row-level security';
        END IF;
        RETURN jsonb_build_object('contract_version', 21, 'operation', 'compare',
            'target', jsonb_build_object('kind', target_kind, 'name', target_name,
                                         'version', target_version), 'state', 'attention',
            'summary', jsonb_build_object('read_only', true),
            'findings', validation -> 'findings', 'current', '[]'::jsonb,
            'proposed', '[]'::jsonb, 'delta', '[]'::jsonb,
            'lifecycle', '[]'::jsonb, 'work', '[]'::jsonb, 'truncated', false);
    END IF;
    proposed_normalized := validation -> 'evidence' -> 'normalized_declaration';
    current_document := pgreact.export(target_name, target_kind, target_version);
    IF current_document IS NULL THEN
        RAISE EXCEPTION 'M34_TARGET_NOT_FOUND: deployed % % was not found', target_kind, target_name;
    END IF;
    current_normalized := jsonb_build_object(
        'api_version', COALESCE(current_document ->> 'api_version', '1'),
        'kind', current_document ->> 'kind', 'name', current_document ->> 'name',
        'spec', current_document -> 'spec');
    current_decl := pgreact_api.declaration(target_kind, target_name,
                                            current_normalized -> 'spec');
    current_validation := pgreact.validate(current_decl);
    IF current_validation ->> 'state' = 'attention' THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(current_validation -> 'findings') item
                   WHERE item ->> 'code' = 'M54_RLS_UNSUPPORTED') THEN
            RAISE EXCEPTION 'M34_RLS_UNSUPPORTED: source relation uses row-level security';
        END IF;
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: deployed source is no longer supported';
    END IF;
    IF target_kind NOT IN ('rule', 'decision_program') THEN
        RETURN pgreact.compare_m43(proposed, deployed, options);
    END IF;
    before_checksum := pgreact_internal.m34_authoritative_checksum();
    IF target_kind = 'rule' THEN
        relation_name := proposed_normalized -> 'spec' ->> 'condition';
        source_oid := to_regclass(relation_name);
        SELECT n.nspname, c.relname INTO source_schema, source_relation
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = source_oid;
        key_column := (proposed_normalized -> 'spec' ->> 'semantic_key')::name;
        proposed_model := pgreact_internal.m54_read_rule_model(
            source_schema, source_relation, key_column, relation_name,
            (proposed_normalized -> 'spec' ->> 'kind') = 'COMMAND', evidence_limit);
        relation_name := current_normalized -> 'spec' ->> 'condition';
        source_oid := to_regclass(relation_name);
        SELECT n.nspname, c.relname INTO source_schema, source_relation
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = source_oid;
        key_column := (current_normalized -> 'spec' ->> 'semantic_key')::name;
        current_model := pgreact_internal.m54_read_rule_model(
            source_schema, source_relation, key_column, relation_name,
            (current_normalized -> 'spec' ->> 'kind') = 'COMMAND', evidence_limit);
    ELSE
        relation_name := proposed_normalized -> 'spec' ->> 'candidate_relation';
        source_oid := to_regclass(relation_name);
        SELECT n.nspname, c.relname INTO source_schema, source_relation
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = source_oid;
        subject_column := (proposed_normalized -> 'spec' ->> 'subject_key')::name;
        candidate_column := (proposed_normalized -> 'spec' ->> 'candidate_key')::name;
        priority_column := (proposed_normalized -> 'spec' ->> 'priority')::name;
        SELECT array_agg(value::name ORDER BY ordinal)
        INTO result_columns
        FROM jsonb_array_elements_text(proposed_normalized -> 'spec' -> 'results')
             WITH ORDINALITY item(value, ordinal);
        max_candidates := COALESCE((proposed_normalized -> 'spec' ->> 'max_candidates')::integer, 1000);
        proposed_model := pgreact_internal.m54_read_decision_model(
            source_schema, source_relation, subject_column, candidate_column, priority_column,
            result_columns, max_candidates, relation_name, evidence_limit);
        relation_name := current_normalized -> 'spec' ->> 'candidate_relation';
        source_oid := to_regclass(relation_name);
        SELECT n.nspname, c.relname INTO source_schema, source_relation
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.oid = source_oid;
        subject_column := (current_normalized -> 'spec' ->> 'subject_key')::name;
        candidate_column := (current_normalized -> 'spec' ->> 'candidate_key')::name;
        priority_column := (current_normalized -> 'spec' ->> 'priority')::name;
        SELECT array_agg(value::name ORDER BY ordinal)
        INTO result_columns
        FROM jsonb_array_elements_text(current_normalized -> 'spec' -> 'results')
             WITH ORDINALITY item(value, ordinal);
        max_candidates := COALESCE((current_normalized -> 'spec' ->> 'max_candidates')::integer, 1000);
        current_model := pgreact_internal.m54_read_decision_model(
            source_schema, source_relation, subject_column, candidate_column, priority_column,
            result_columns, max_candidates, relation_name, evidence_limit);
    END IF;
    current_rows := current_model -> 'rows';
    proposed_rows := proposed_model -> 'rows';
    delta_model := pgreact_internal.m34_delta(current_rows, proposed_rows);
    delta_rows := delta_model -> 'rows';
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value ->> 'subject_key'), '[]'::jsonb)
    INTO lifecycle_rows
    FROM jsonb_array_elements(delta_rows) item(value)
    WHERE item.value ->> 'change' <> 'UNCHANGED';
    IF current_normalized IS NOT DISTINCT FROM proposed_normalized THEN
        work_rows := '[]'::jsonb;
    ELSE
        SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value ->> 'subject_key'), '[]'::jsonb)
        INTO work_rows
        FROM jsonb_array_elements(proposed_rows) item(value)
        WHERE (item.value -> 'work' ->> 'would_be_work')::boolean;
    END IF;
    comparison_complete := NOT COALESCE((current_model ->> 'truncated')::boolean, false)
        AND NOT COALESCE((proposed_model ->> 'truncated')::boolean, false)
        AND jsonb_array_length(delta_rows) <= evidence_limit;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF before_checksum IS DISTINCT FROM after_checksum THEN
        RAISE EXCEPTION 'M34_AUTHORITATIVE_CHANGED: authoritative state changed during comparison';
    END IF;
    RETURN jsonb_build_object(
        'contract_version', 21, 'operation', 'compare',
        'target', jsonb_build_object('kind', target_kind, 'name', target_name, 'version', target_version),
        'state', CASE WHEN comparison_complete THEN 'ready' ELSE 'partial' END,
        'summary', jsonb_build_object('read_only', true,
            'current_count', (current_model ->> 'rows_considered')::bigint,
            'proposed_count', (proposed_model ->> 'rows_considered')::bigint,
            'delta_counts', CASE WHEN comparison_complete THEN delta_model -> 'counts' ELSE NULL END,
            'counts_exact', comparison_complete,
            'affected_subject_count', CASE WHEN comparison_complete THEN
                COALESCE((delta_model -> 'counts' ->> 'added')::bigint, 0) +
                COALESCE((delta_model -> 'counts' ->> 'removed')::bigint, 0) +
                COALESCE((delta_model -> 'counts' ->> 'changed')::bigint, 0) ELSE NULL END,
            'would_be_work', jsonb_array_length(work_rows)),
        'evidence', jsonb_build_object('sampled_time', sampled_time,
            'source_frontier', sampled_time,
            'declaration_digest', encode(sha256(convert_to(proposed_normalized::text, 'UTF8')), 'hex'),
            'authoritative_checksum_before', before_checksum,
            'authoritative_checksum_after', after_checksum, 'complete', comparison_complete,
            'evidence_limit', evidence_limit),
        'cost', jsonb_build_object('rows_considered',
            (current_model ->> 'rows_considered')::bigint + (proposed_model ->> 'rows_considered')::bigint,
            'affected_subjects', CASE WHEN comparison_complete THEN
                COALESCE((delta_model -> 'counts' ->> 'added')::bigint, 0) +
                COALESCE((delta_model -> 'counts' ->> 'removed')::bigint, 0) +
                COALESCE((delta_model -> 'counts' ->> 'changed')::bigint, 0) ELSE NULL END,
            'dependency_fan_out', 0, 'reevaluation', 0, 'cascade_depth', 0,
            'would_be_work', jsonb_array_length(work_rows), 'elapsed_ms', 0,
            'memory_bytes', NULL, 'temporary_storage_bytes', 0),
        'findings', CASE WHEN comparison_complete THEN jsonb_build_array(pgreact_internal.m34_finding(
            'M34_NO_EFFECT', 'INFO', target_name, '<comparison>',
            'comparison completed without changing authoritative state',
            'No deployment or run is required to inspect this result.')) ELSE
            jsonb_build_array(pgreact_internal.m34_finding(
            'M34_COMPARISON_INCOMPLETE', 'WARNING', target_name, '<comparison>',
            'evidence was truncated at the requested limit',
            'Increase evidence_limit or inspect the relational result stream.')) END,
        'current', pgreact_internal.m34_raw_rows(current_rows,
            (current_model ->> 'rows_considered')::bigint, evidence_limit) -> 'rows',
        'proposed', pgreact_internal.m34_raw_rows(proposed_rows,
            (proposed_model ->> 'rows_considered')::bigint, evidence_limit) -> 'rows',
        'delta', pgreact_internal.m34_raw_rows(delta_rows,
            jsonb_array_length(delta_rows), evidence_limit) -> 'rows',
        'lifecycle', pgreact_internal.m34_raw_rows(lifecycle_rows,
            jsonb_array_length(lifecycle_rows), evidence_limit) -> 'rows',
        'work', pgreact_internal.m34_raw_rows(work_rows,
            jsonb_array_length(work_rows), evidence_limit) -> 'rows',
        'truncated', NOT comparison_complete);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_check_preconditions(
    preconditions jsonb,
    current_found boolean,
    current_state text,
    current_digest text,
    preview jsonb
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    field text;
    expected text;
    allow_create boolean;
BEGIN
    IF preconditions IS NULL OR jsonb_typeof(preconditions) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M54_PRECONDITIONS: preconditions must be a JSON object';
    END IF;
    FOR field IN SELECT key FROM jsonb_object_keys(preconditions) key LOOP
        IF field NOT IN ('allow_create', 'expected_current_digest', 'preview_digest',
                         'plan_digest', 'old_work', 'old_work_policy', 'adopt') THEN
            RAISE EXCEPTION 'M54_PRECONDITION_FIELD: unsupported precondition %', field;
        END IF;
    END LOOP;
    IF preconditions ? 'allow_create' THEN
        IF jsonb_typeof(preconditions -> 'allow_create') IS DISTINCT FROM 'boolean' THEN
            RAISE EXCEPTION 'M54_PRECONDITION_FIELD: allow_create must be boolean';
        END IF;
        allow_create := (preconditions ->> 'allow_create')::boolean;
        IF allow_create AND current_found AND upper(current_state) = 'DEPLOYED' THEN
            RAISE EXCEPTION 'M28_EXISTS: target already exists';
        END IF;
    END IF;
    IF preconditions ? 'expected_current_digest' THEN
        IF jsonb_typeof(preconditions -> 'expected_current_digest') IS DISTINCT FROM 'string'
           OR preconditions ->> 'expected_current_digest' !~ '^[0-9a-f]{64}$' THEN
            RAISE EXCEPTION 'M54_PRECONDITION_FIELD: expected_current_digest must be a 64-character lowercase hex digest';
        END IF;
        expected := preconditions ->> 'expected_current_digest';
        IF current_found AND upper(current_state) = 'DEPLOYED'
           AND expected IS DISTINCT FROM current_digest THEN
            RAISE EXCEPTION 'M28_REPLACE_STALE'
                USING HINT = 'Preview the current target and use its exact digest as expected_current_digest.';
        ELSIF NOT current_found OR upper(current_state) <> 'DEPLOYED' THEN
            RAISE EXCEPTION 'M28_REPLACE_STALE'
                USING HINT = 'The expected target is not currently deployed.';
        END IF;
    ELSIF preconditions ? 'allow_create'
          AND (preconditions ->> 'allow_create')::boolean = false
          AND current_found AND upper(current_state) = 'DEPLOYED' THEN
        RAISE EXCEPTION 'M28_REPLACE_STALE'
            USING HINT = 'Preview the current target and use its exact digest as expected_current_digest.';
    END IF;
    FOREACH field IN ARRAY ARRAY['preview_digest', 'plan_digest'] LOOP
        IF preconditions ? field THEN
            IF jsonb_typeof(preconditions -> field) IS DISTINCT FROM 'string'
               OR preconditions ->> field !~ '^[0-9a-f]{64}$' THEN
                RAISE EXCEPTION 'M54_PRECONDITION_FIELD: % must be a 64-character lowercase hex digest', field;
            END IF;
            expected := preconditions ->> field;
            IF expected IS DISTINCT FROM preview -> 'summary' ->> field
               AND NOT (field = 'preview_digest'
                        AND expected = preview -> 'summary' ->> 'legacy_preview_digest') THEN
                RAISE EXCEPTION 'M54_REVIEW_TOKEN_STALE: reviewed preview is stale';
            END IF;
        END IF;
    END LOOP;
    IF preconditions ? 'old_work' AND preconditions ? 'old_work_policy'
       AND preconditions ->> 'old_work' IS DISTINCT FROM preconditions ->> 'old_work_policy' THEN
        RAISE EXCEPTION 'M54_PRECONDITION_FIELD: old_work and old_work_policy disagree';
    END IF;
    IF preconditions ? 'old_work'
       AND jsonb_typeof(preconditions -> 'old_work') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'M54_PRECONDITION_FIELD: old_work must be a string';
    END IF;
    IF preconditions ? 'old_work_policy'
       AND jsonb_typeof(preconditions -> 'old_work_policy') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'M54_PRECONDITION_FIELD: old_work_policy must be a string';
    END IF;
    IF preconditions ? 'adopt'
       AND jsonb_typeof(preconditions -> 'adopt') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'M54_PRECONDITION_FIELD: adopt must be an array';
    END IF;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb,
    token_payload jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    canonical pgreact_api.declaration := pgreact_internal.m54_canonicalize_declaration(declaration);
    preview jsonb;
    validation jsonb;
    normalized_decl jsonb;
    current_row pgreact_internal.api_declarations%ROWTYPE;
    current_found boolean;
    owner_id oid := (SELECT oid FROM pg_roles WHERE rolname = session_user);
    action text;
    old_work text;
    old_work_required boolean;
    condition_oid regclass;
    candidate_oid regclass;
    result_columns name[];
    live_source text;
    new_delegated_id uuid;
    effective_preconditions jsonb := COALESCE(preconditions, '{}'::jsonb);
BEGIN
    validation := pgreact_internal.m54_validate(canonical);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(validation -> 'findings', '[]'::jsonb)) item
               WHERE item ->> 'severity' = 'ERROR') THEN
        RAISE EXCEPTION 'M54_VALIDATION: %', validation -> 'findings';
    END IF;
    IF token_payload IS NOT NULL THEN
        IF token_payload ->> 'operation' IS DISTINCT FROM 'preview'
           OR token_payload ->> 'digest_kind' IS NULL
           OR jsonb_typeof(token_payload -> 'target') IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_UNSUPPORTED: review token shape is not supported';
        END IF;
        IF token_payload -> 'target' ->> 'kind' IS DISTINCT FROM (canonical).kind
           OR token_payload -> 'target' ->> 'name' IS DISTINCT FROM (canonical).name THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_MISMATCH: token target does not match declaration';
        END IF;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended(
        (canonical).kind || ':' || (canonical).name, 5788046901200000));
    SELECT * INTO current_row
    FROM pgreact_internal.api_declarations row_data
    WHERE row_data.kind = (canonical).kind
      AND row_data.object_name = (canonical).name
    FOR UPDATE;
    current_found := FOUND;
    preview := pgreact_internal.m54_preview(canonical, effective_preconditions);
    IF token_payload IS NOT NULL THEN
        IF token_payload ->> 'contract_version' IS DISTINCT FROM preview ->> 'contract_version' THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_MISMATCH: token contract does not match';
        END IF;
        IF token_payload ->> 'proposed_declaration_digest' IS DISTINCT FROM
           preview -> 'summary' ->> 'proposed_declaration_digest' THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_MISMATCH: token declaration digest does not match';
        END IF;
        IF token_payload ->> 'digest_kind' NOT IN ('plan_digest', 'preview_digest')
           OR token_payload ->> 'digest' IS DISTINCT FROM
              preview -> 'summary' ->> (token_payload ->> 'digest_kind') THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_STALE: reviewed preview is stale';
        END IF;
        effective_preconditions := effective_preconditions || jsonb_build_object(
            token_payload ->> 'digest_kind', token_payload ->> 'digest');
    END IF;
    PERFORM pgreact_internal.m54_check_preconditions(
        effective_preconditions, current_found, current_row.state,
        CASE WHEN current_found THEN encode(current_row.declaration_digest, 'hex') ELSE NULL END,
        preview);
    IF preview ->> 'state' <> 'ready' THEN
        RAISE EXCEPTION 'M54_VALIDATION: preview contains blocking findings';
    END IF;
    normalized_decl := preview -> 'evidence' -> 'normalized_declaration';
    action := preview -> 'summary' ->> 'action';
    old_work_required := COALESCE((preview -> 'summary' ->> 'old_work_policy_required')::boolean, false);
    old_work := COALESCE(effective_preconditions ->> 'old_work',
                         effective_preconditions ->> 'old_work_policy');
    IF current_found AND current_row.owner_oid <> owner_id
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M54_OWNER: only the declaration owner or operator may deploy this target';
    END IF;
    IF pgreact_internal.m54_is_package(canonical) THEN
        RETURN pgreact_internal.m54_package_deploy(canonical, effective_preconditions);
    END IF;
    IF normalized_decl IS NOT NULL THEN
        live_source := pgreact_internal.m54_source_fingerprint(normalized_decl);
        IF live_source IS DISTINCT FROM preview -> 'summary' ->> 'source_fingerprint' THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_STALE: source or executable dependency changed during deployment';
        END IF;
    END IF;
    IF current_found AND current_row.state = 'DEPLOYED' AND EXISTS (
        SELECT 1 FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED' AND member.package_owned
          AND member.member_kind = current_row.kind
          AND member.member_name = current_row.object_name) THEN
        RAISE EXCEPTION 'M54_PACKAGE_OWNED: replace the complete policy set';
    END IF;
    IF old_work_required AND old_work IS NULL THEN
        RAISE EXCEPTION 'M54_OLD_WORK_REQUIRED: choose DRAIN_OLD or CANCEL_OLD explicitly';
    END IF;
    IF old_work IS NOT NULL AND old_work NOT IN ('DRAIN_OLD', 'CANCEL_OLD') THEN
        RAISE EXCEPTION 'M54_OLD_WORK_POLICY: choose DRAIN_OLD or CANCEL_OLD';
    END IF;
    IF action = 'KEEP' THEN
        RETURN preview || jsonb_build_object('operation', 'deploy', 'state', 'deployed',
            'summary', preview -> 'summary' || jsonb_build_object(
                'read_only', false, 'reviewed', token_payload IS NOT NULL,
                'old_work_policy', old_work));
    END IF;
    IF action = 'REPLACE' AND current_found AND current_row.state = 'DEPLOYED' THEN
        IF (canonical).kind = 'rule' THEN
            condition_oid := to_regclass(normalized_decl -> 'spec' ->> 'condition');
            SELECT pgreact_internal.replace_pack_rule(
                current_row.delegated_id, (canonical).name, condition_oid,
                ARRAY[(normalized_decl -> 'spec' ->> 'semantic_key')::name],
                normalized_decl -> 'spec' ->> 'kind',
                (normalized_decl -> 'spec' ->> 'on_activate')::regprocedure,
                (normalized_decl -> 'spec' ->> 'on_deactivate')::regprocedure,
                (normalized_decl -> 'spec' ->> 'on_change')::regprocedure,
                normalized_decl -> 'spec' ->> 'bootstrap_policy',
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'change_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'salience')::integer, 0),
                COALESCE(normalized_decl -> 'spec' ->> 'agenda_group', 'default'),
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'conflict_key_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'max_attempts')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((normalized_decl -> 'spec' ->> 'max_backoff_seconds')::integer, 60),
                COALESCE(old_work, 'DRAIN_OLD')) INTO new_delegated_id;
            current_row.delegated_id := new_delegated_id;
        ELSIF (canonical).kind = 'decision_program' THEN
            candidate_oid := to_regclass(normalized_decl -> 'spec' ->> 'candidate_relation');
            result_columns := ARRAY(SELECT value::name FROM jsonb_array_elements_text(
                normalized_decl -> 'spec' -> 'results') value);
            SELECT pgreact_internal.m54_replace_decision(
                current_row.delegated_id, (canonical).name, candidate_oid,
                (normalized_decl -> 'spec' ->> 'subject_key')::name,
                (normalized_decl -> 'spec' ->> 'candidate_key')::name,
                (normalized_decl -> 'spec' ->> 'priority')::name, result_columns,
                COALESCE((normalized_decl -> 'spec' ->> 'valid_from')::timestamptz, clock_timestamp()),
                NULLIF(normalized_decl -> 'spec' ->> 'valid_to', '')::timestamptz,
                COALESCE((normalized_decl -> 'spec' ->> 'max_candidates')::integer, 1000))
            INTO new_delegated_id;
            current_row.delegated_id := new_delegated_id;
        ELSE
            RAISE EXCEPTION 'M54_KIND: ordinary replacement supports rule and decision_program';
        END IF;
    ELSE
        IF (canonical).kind = 'rule' THEN
            condition_oid := to_regclass(normalized_decl -> 'spec' ->> 'condition');
            new_delegated_id := pgreact_api.author_rule(
                (canonical).name, condition_oid,
                (normalized_decl -> 'spec' ->> 'semantic_key')::name,
                normalized_decl -> 'spec' ->> 'kind', normalized_decl -> 'spec' ->> 'on_activate',
                normalized_decl -> 'spec' ->> 'on_deactivate', normalized_decl -> 'spec' ->> 'on_change',
                normalized_decl -> 'spec' ->> 'bootstrap_policy',
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'change_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'salience')::integer, 0),
                COALESCE(normalized_decl -> 'spec' ->> 'agenda_group', 'default'),
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'conflict_key_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'max_attempts')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((normalized_decl -> 'spec' ->> 'max_backoff_seconds')::integer, 60));
            current_row.delegated_id := new_delegated_id;
        ELSIF (canonical).kind = 'decision_program' THEN
            candidate_oid := to_regclass(normalized_decl -> 'spec' ->> 'candidate_relation');
            result_columns := ARRAY(SELECT value::name FROM jsonb_array_elements_text(
                normalized_decl -> 'spec' -> 'results') value);
            new_delegated_id := pgreact_api.author_decision_program(
                (canonical).name, candidate_oid,
                (normalized_decl -> 'spec' ->> 'subject_key')::name,
                (normalized_decl -> 'spec' ->> 'candidate_key')::name,
                (normalized_decl -> 'spec' ->> 'priority')::name, result_columns,
                COALESCE((normalized_decl -> 'spec' ->> 'valid_from')::timestamptz, clock_timestamp()),
                NULLIF(normalized_decl -> 'spec' ->> 'valid_to', '')::timestamptz,
                COALESCE((normalized_decl -> 'spec' ->> 'max_candidates')::integer, 1000));
            current_row.delegated_id := new_delegated_id;
        ELSE
            RETURN pgreact.deploy_m53(canonical, effective_preconditions);
        END IF;
    END IF;
    IF current_found THEN
        UPDATE pgreact_internal.api_declarations
        SET api_version = (canonical).api_version, spec = (canonical).spec,
            normalized = normalized_decl,
            declaration_digest = decode(preview -> 'summary' ->> 'proposed_declaration_digest', 'hex'),
            delegated_id = current_row.delegated_id, owner_oid = owner_id, state = 'DEPLOYED',
            last_preview_digest = decode(preview -> 'summary' ->> 'source_fingerprint', 'hex'),
            deployed_at = clock_timestamp(), removed_at = NULL
        WHERE declaration_id = current_row.declaration_id;
    ELSE
        INSERT INTO pgreact_internal.api_declarations(
            api_version, kind, object_name, spec, normalized, declaration_digest,
            delegated_id, owner_oid, state, last_preview_digest, deployed_at)
        VALUES ((canonical).api_version, (canonical).kind, (canonical).name,
            (canonical).spec, normalized_decl,
            decode(preview -> 'summary' ->> 'proposed_declaration_digest', 'hex'),
            current_row.delegated_id, owner_id, 'DEPLOYED',
            decode(preview -> 'summary' ->> 'source_fingerprint', 'hex'), clock_timestamp());
    END IF;
    RETURN preview || jsonb_build_object('operation', 'deploy', 'state', 'deployed',
        'summary', preview -> 'summary' || jsonb_build_object(
            'read_only', false, 'delegated_id', current_row.delegated_id,
            'reviewed', token_payload IS NOT NULL, 'old_work_policy', old_work));
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    canonical pgreact_api.declaration := pgreact_internal.m54_canonicalize_declaration(declaration);
    base jsonb;
    normalized_decl jsonb;
    current_row pgreact_internal.api_declarations%ROWTYPE;
    current_found boolean;
    current_state text := 'absent';
    current_digest text;
    current_source text;
    source_fingerprint text;
    proposed_digest text;
    action text;
    work_state text := 'NOT_APPLICABLE';
    old_work_required boolean := false;
    old_kind text;
    plan_digest text;
    extra jsonb := '[]'::jsonb;
    filtered jsonb := '[]'::jsonb;
    item jsonb;
    source_name text;
    source_oid oid;
BEGIN
    IF pgreact_internal.m54_is_package(canonical) THEN
        RETURN pgreact_internal.m54_package_preview(canonical, options);
    END IF;
    base := pgreact.preview_m53(canonical, options);
    source_name := (canonical).spec ->> CASE WHEN (canonical).kind = 'rule'
                                             THEN 'condition' ELSE 'candidate_relation' END;
    BEGIN
        source_oid := to_regclass(source_name);
    EXCEPTION WHEN OTHERS THEN
        source_oid := NULL;
    END;
    FOR item IN SELECT value FROM jsonb_array_elements(COALESCE(base -> 'findings', '[]'::jsonb)) value LOOP
        IF (COALESCE(item ->> 'code', '') = 'M28_RELATION_NAME'
            OR item -> 'details' ->> 'source_code' = 'M28_RELATION_NAME')
           AND item ->> 'field' IN ('spec.condition', 'spec.candidate_relation')
           AND source_oid IS NOT NULL THEN
            CONTINUE;
        END IF;
        filtered := filtered || jsonb_build_array(item);
    END LOOP;
    base := base || jsonb_build_object(
        'state', CASE WHEN EXISTS (
            SELECT 1 FROM jsonb_array_elements(filtered) value
            WHERE value ->> 'severity' = 'ERROR') THEN 'attention' ELSE 'ready' END,
        'findings', filtered);
    normalized_decl := base -> 'evidence' -> 'normalized_declaration';
    BEGIN
        extra := pgreact_internal.m54_rule_findings(canonical);
    EXCEPTION WHEN OTHERS THEN
        extra := '[]'::jsonb;
    END;
    IF base ->> 'state' = 'attention' THEN
        RETURN base || jsonb_build_object('findings',
            COALESCE(base -> 'findings', '[]'::jsonb) || extra);
    END IF;
    SELECT * INTO current_row
    FROM pgreact_internal.api_declarations row_data
    WHERE row_data.kind = (canonical).kind
      AND row_data.object_name = (canonical).name;
    current_found := FOUND;
    IF current_found THEN
        current_state := lower(current_row.state);
        current_digest := encode(current_row.declaration_digest, 'hex');
        current_source := pgreact_internal.m54_source_fingerprint(current_row.normalized);
        work_state := pgreact_internal.m54_current_work(canonical, current_row);
        old_kind := CASE WHEN current_row.kind = 'rule'
                         THEN COALESCE(current_row.normalized -> 'spec' ->> 'kind', 'CONSTRAINT')
                         ELSE current_row.kind END;
    END IF;
    source_fingerprint := pgreact_internal.m54_source_fingerprint(normalized_decl);
    proposed_digest := encode(sha256(convert_to(normalized_decl::text, 'UTF8')), 'hex');
    action := CASE WHEN NOT current_found OR current_state <> 'deployed' THEN 'ADD'
                   WHEN current_digest = proposed_digest AND current_source = source_fingerprint
                   THEN 'KEEP' ELSE 'REPLACE' END;
    old_work_required := action = 'REPLACE'
        AND old_kind = 'COMMAND'
        AND work_state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    plan_digest := encode(sha256(convert_to(jsonb_build_object(
        'kind', (canonical).kind, 'name', (canonical).name,
        'normalized', normalized_decl, 'action', action,
        'current_state', current_state, 'current_digest', current_digest,
        'source_fingerprint', source_fingerprint, 'current_source_fingerprint', current_source,
        'work_state', work_state, 'old_work_required', old_work_required)::text, 'UTF8')), 'hex');
    RETURN base || jsonb_build_object(
        'state', CASE WHEN jsonb_array_length(extra) > 0 OR base ->> 'state' = 'attention'
                      THEN 'attention' ELSE 'ready' END,
        'summary', COALESCE(base -> 'summary', '{}'::jsonb) || jsonb_build_object(
            'action', action,
            'deployment', CASE action WHEN 'ADD' THEN 'create' WHEN 'KEEP' THEN 'keep'
                                      ELSE 'replacement' END,
            'current_state', current_state, 'current_declaration_digest', current_digest,
            'proposed_declaration_digest', proposed_digest,
            'source_fingerprint', source_fingerprint,
            'current_source_fingerprint', current_source,
            'work_state', work_state, 'current_effect_kind', old_kind,
            'old_work_policy_required', old_work_required, 'old_work_policy', NULL,
            'plan_digest', plan_digest,
            'legacy_preview_digest', base -> 'summary' ->> 'preview_digest',
            'blockers', CASE WHEN jsonb_array_length(extra) > 0 THEN extra
                             ELSE COALESCE(base -> 'summary' -> 'blockers', '[]'::jsonb) END),
        'findings', COALESCE(base -> 'findings', '[]'::jsonb) || extra);
END
$m54$;

-- ponytail: bounded Kahn scans are O(V*(V+E)) at the published 64/256
-- limits; use a heap only if those limits grow.
CREATE OR REPLACE FUNCTION pgreact_internal.m54_package_graph_order(package_normalized jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    remaining text[];
    ordered text[] := ARRAY[]::text[];
    ready text[];
    node_id text;
    ordered_nodes jsonb;
BEGIN
    SELECT COALESCE(array_agg(nodes.node_id ORDER BY nodes.node_id), ARRAY[]::text[])
    INTO remaining
    FROM (
        SELECT DISTINCT pgreact_internal.m53_package_id(value) AS node_id
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(package_normalized -> 'spec' -> 'members') = 'array'
                                      THEN package_normalized -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
        UNION
        SELECT DISTINCT pgreact_internal.m53_package_id(value) AS node_id
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(package_normalized -> 'spec' -> 'support') = 'array'
                                      THEN package_normalized -> 'spec' -> 'support' ELSE '[]'::jsonb END) value
    ) nodes;
    WHILE cardinality(remaining) > 0 LOOP
        SELECT COALESCE(array_agg(ids.node_id ORDER BY ids.node_id), ARRAY[]::text[])
        INTO ready
        FROM unnest(remaining) ids(node_id)
        WHERE NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(package_normalized -> 'spec' -> 'dependencies') = 'array'
                THEN package_normalized -> 'spec' -> 'dependencies' ELSE '[]'::jsonb END) edge
            WHERE pgreact_internal.m53_package_id(edge -> 'from') = ids.node_id
              AND pgreact_internal.m53_package_id(edge -> 'on') = ANY(remaining));
        IF cardinality(ready) = 0 THEN
            RETURN NULL;
        END IF;
        ordered := ordered || ready;
        remaining := ARRAY(
            SELECT id FROM unnest(remaining) id WHERE NOT id = ANY(ready));
    END LOOP;
    SELECT COALESCE(jsonb_agg(value ORDER BY array_position(ordered,
                                  pgreact_internal.m53_package_id(value))), '[]'::jsonb)
    INTO ordered_nodes
    FROM (
        SELECT value
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(package_normalized -> 'spec' -> 'members') = 'array'
                                      THEN package_normalized -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
        UNION ALL
        SELECT value
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof(package_normalized -> 'spec' -> 'support') = 'array'
                                      THEN package_normalized -> 'spec' -> 'support' ELSE '[]'::jsonb END) value
    ) nodes;
    RETURN ordered_nodes;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_package_has_cycle(spec jsonb)
RETURNS boolean
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_internal.m54_package_graph_order(
        jsonb_build_object('spec', $1)) IS NULL
$m54$;

-- Replace the two path-enumerating M53 walks without changing the published
-- M53 result shape or historical artifacts.
DO $m54$
DECLARE
    definition text;
    patched text;
BEGIN
    SELECT pg_get_functiondef(
        'pgreact_internal.m53_package_validate(pgreact_api.declaration)'::regprocedure)
    INTO definition;
    patched := regexp_replace(definition,
        E'(?s)    IF jsonb_typeof\\(spec -> ''dependencies''\\) = ''array'' AND EXISTS \\(.*?    END IF;\\n    complete :=',
        $replacement$
    IF pgreact_internal.m54_package_has_cycle(spec) THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_DEPENDENCY_CYCLE', 'ERROR', 'spec.dependencies',
            'dependency edges must form an acyclic graph',
            'Remove one edge from the cycle.'));
    END IF;
    complete :=$replacement$, 1);
    IF patched = definition THEN
        RAISE EXCEPTION 'M54 could not patch the package validation walk';
    END IF;
    EXECUTE patched;

    SELECT pg_get_functiondef(
        'pgreact_internal.m53_package_preview(pgreact_api.declaration,jsonb)'::regprocedure)
    INTO definition;
    patched := regexp_replace(definition,
        E'(?s)    FOR node IN\\s+WITH RECURSIVE package_nodes AS \\(.*?\\s+LOOP',
        $replacement$
    FOR node IN
        SELECT value FROM jsonb_array_elements(
            pgreact_internal.m54_package_graph_order(package_normalized)) value
    LOOP$replacement$, 1);
    IF patched = definition THEN
        RAISE EXCEPTION 'M54 could not patch the package preview walk';
    END IF;
    EXECUTE patched;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_package_preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    result jsonb := pgreact_internal.m53_package_preview(declaration, options);
    normalized jsonb := result -> 'evidence' -> 'normalized_declaration';
    actions jsonb := COALESCE(result -> 'summary' -> 'action_plan', '[]'::jsonb);
    findings jsonb := COALESCE(result -> 'findings', '[]'::jsonb);
    blockers jsonb := '[]'::jsonb;
    action_row jsonb;
    member jsonb;
    child pgreact_api.declaration;
    current_digest text;
    proposed_digest text;
BEGIN
    result := result || jsonb_build_object(
        'summary', result -> 'summary' || jsonb_build_object(
            'proposed_declaration_digest', result -> 'summary' ->> 'definition_digest'));
    FOR action_row IN SELECT value FROM jsonb_array_elements(actions) value LOOP
        CONTINUE WHEN action_row ->> 'kind' NOT IN ('rule', 'decision_program');
        CONTINUE WHEN action_row ->> 'action' NOT IN ('KEEP', 'ADOPT');
        SELECT value INTO member
        FROM jsonb_array_elements(COALESCE(normalized -> 'spec' -> 'members', '[]'::jsonb)) value
        WHERE value ->> 'kind' = action_row ->> 'kind'
          AND value ->> 'name' = action_row ->> 'name'
          AND COALESCE(value ->> 'version', '1') = COALESCE(action_row ->> 'version', '1')
        LIMIT 1;
        CONTINUE WHEN member IS NULL OR jsonb_typeof(member -> 'declaration') <> 'object';
        child := pgreact_internal.m54_canonicalize_declaration(pgreact_api.declaration(
            member -> 'declaration' ->> 'kind', member -> 'declaration' ->> 'name',
            member -> 'declaration' -> 'spec'));
        proposed_digest := encode(sha256(convert_to(
            pgreact_internal.m28_normalize(child)::text, 'UTF8')), 'hex');
        SELECT encode(row_data.declaration_digest, 'hex') INTO current_digest
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = action_row ->> 'kind'
          AND row_data.object_name = action_row ->> 'name'
          AND row_data.state = 'DEPLOYED';
        IF current_digest IS NOT NULL AND current_digest IS DISTINCT FROM proposed_digest THEN
            blockers := blockers || jsonb_build_array(pgreact_internal.m54_finding(
                'M54_PACKAGE_CHILD_CHANGE', 'ERROR', 'spec.members',
                'package preview cannot KEEP or ADOPT a changed child declaration',
                'Publish a new child version or replace the complete package.',
                jsonb_build_object('kind', action_row ->> 'kind', 'name', action_row ->> 'name',
                    'version', COALESCE(action_row ->> 'version', '1'),
                    'before_digest', current_digest, 'after_digest', proposed_digest)));
        END IF;
    END LOOP;
    IF jsonb_array_length(blockers) = 0 THEN
        RETURN result;
    END IF;
    actions := COALESCE((SELECT jsonb_agg(
        CASE WHEN item.value ->> 'kind' IN ('rule', 'decision_program')
                  AND item.value ->> 'action' IN ('KEEP', 'ADOPT')
             THEN item.value || jsonb_build_object('action', 'BLOCKED')
             ELSE item.value END ORDER BY item.ordinality)
        FROM jsonb_array_elements(actions) WITH ORDINALITY item(value, ordinality)), '[]'::jsonb);
    RETURN result || jsonb_build_object(
        'state', 'attention',
        'summary', result -> 'summary' || jsonb_build_object(
            'action_plan', actions,
            'blockers', COALESCE(result -> 'summary' -> 'blockers', '[]'::jsonb) || blockers),
        'findings', findings || blockers);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_package_deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE preview jsonb := pgreact_internal.m54_package_preview(declaration, preconditions);
BEGIN
    IF preview ->> 'state' <> 'ready' THEN
        RAISE EXCEPTION 'M54_PACKAGE_CHILD_CHANGE: package preview contains blocking child changes';
    END IF;
    RETURN pgreact.deploy_m53(declaration, preconditions);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_function_identity(function_oid oid)
RETURNS text
LANGUAGE SQL STABLE STRICT SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT format('%I.%I(%s)', namespace.nspname, procedure.proname,
                  COALESCE((SELECT string_agg(pg_catalog.format_type(argument_oid, NULL), ','
                                              ORDER BY ordinal)
                            FROM unnest(procedure.proargtypes::oid[]) WITH ORDINALITY
                                arguments(argument_oid, ordinal)), ''))
    FROM pg_catalog.pg_proc procedure
    JOIN pg_catalog.pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE procedure.oid = $1
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_canonicalize_declaration(
    declaration pgreact_api.declaration
)
RETURNS pgreact_api.declaration
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    result_spec jsonb := COALESCE((declaration).spec, '{}'::jsonb);
    field text;
    relation_oid oid;
    function_oid oid;
    item jsonb;
    child pgreact_api.declaration;
    canonical_items jsonb := '[]'::jsonb;
BEGIN
    IF declaration IS NULL THEN
        RETURN NULL;
    END IF;
    FOREACH field IN ARRAY ARRAY[
        'condition', 'candidate_relation', 'parameter_relation',
        'population_relation', 'candidate_catalog'
    ] LOOP
        IF result_spec ? field THEN
            BEGIN
                relation_oid := to_regclass(result_spec ->> field);
                IF relation_oid IS NOT NULL THEN
                    result_spec := jsonb_set(result_spec, ARRAY[field],
                        to_jsonb(pgreact_internal.m54_relation_identity(relation_oid)), true);
                END IF;
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END IF;
    END LOOP;
    IF jsonb_typeof(result_spec -> 'applicability') = 'object'
       AND result_spec -> 'applicability' ? 'relation' THEN
        BEGIN
            relation_oid := to_regclass(result_spec -> 'applicability' ->> 'relation');
            IF relation_oid IS NOT NULL THEN
                result_spec := jsonb_set(result_spec, '{applicability,relation}',
                    to_jsonb(pgreact_internal.m54_relation_identity(relation_oid)), true);
            END IF;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END IF;
    FOREACH field IN ARRAY ARRAY['on_activate', 'on_deactivate', 'on_change'] LOOP
        IF result_spec ? field THEN
            BEGIN
                function_oid := to_regprocedure(result_spec ->> field);
                IF function_oid IS NOT NULL THEN
                    result_spec := jsonb_set(result_spec, ARRAY[field],
                        to_jsonb(pgreact_internal.m54_function_identity(function_oid)), true);
                END IF;
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END IF;
    END LOOP;
    IF (declaration).kind = 'policy_set' THEN
        IF jsonb_typeof(result_spec -> 'members') = 'array' THEN
            FOR item IN SELECT value FROM jsonb_array_elements(result_spec -> 'members') value LOOP
                IF jsonb_typeof(item -> 'declaration') = 'object' THEN
                    child := pgreact_api.declaration(
                        item -> 'declaration' ->> 'kind',
                        item -> 'declaration' ->> 'name',
                        item -> 'declaration' -> 'spec');
                    child := pgreact_internal.m54_canonicalize_declaration(child);
                    item := jsonb_set(item, '{declaration}', jsonb_build_object(
                        'api_version', (child).api_version,
                        'kind', (child).kind, 'name', (child).name,
                        'spec', (child).spec), true);
                END IF;
                canonical_items := canonical_items || jsonb_build_array(item);
            END LOOP;
            result_spec := jsonb_set(result_spec, '{members}', canonical_items, true);
        END IF;
        canonical_items := '[]'::jsonb;
        IF jsonb_typeof(result_spec -> 'support') = 'array' THEN
            FOR item IN SELECT value FROM jsonb_array_elements(result_spec -> 'support') value LOOP
                IF jsonb_typeof(item -> 'declaration') = 'object' THEN
                    child := pgreact_api.declaration(
                        item -> 'declaration' ->> 'kind',
                        item -> 'declaration' ->> 'name',
                        item -> 'declaration' -> 'spec');
                    child := pgreact_internal.m54_canonicalize_declaration(child);
                    item := jsonb_set(item, '{declaration}', jsonb_build_object(
                        'api_version', (child).api_version,
                        'kind', (child).kind, 'name', (child).name,
                        'spec', (child).spec), true);
                END IF;
                canonical_items := canonical_items || jsonb_build_array(item);
            END LOOP;
            result_spec := jsonb_set(result_spec, '{support}', canonical_items, true);
        END IF;
    END IF;
    RETURN ROW((declaration).api_version, (declaration).kind, (declaration).name,
               result_spec)::pgreact_api.declaration;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact.rule(
    name text, condition regclass, semantic_key name,
    kind text DEFAULT 'CONSTRAINT', on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL, on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT', change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0, agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL, max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1, backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS pgreact_api.declaration
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_api.declaration(
        'rule', $1,
        jsonb_strip_nulls(jsonb_build_object(
            'condition', (SELECT format('%I.%I', namespace.nspname, relation.relname)
                         FROM pg_catalog.pg_class relation
                         JOIN pg_catalog.pg_namespace namespace
                           ON namespace.oid = relation.relnamespace
                         WHERE relation.oid = $2),
            'semantic_key', $3::text, 'kind', $4,
            'on_activate', (SELECT pgreact_internal.m54_function_identity($5)),
            'on_deactivate', (SELECT pgreact_internal.m54_function_identity($6)),
            'on_change', (SELECT pgreact_internal.m54_function_identity($7)),
            'bootstrap_policy', $8, 'change_columns', to_jsonb($9),
            'salience', $10, 'agenda_group', $11,
            'conflict_key_columns', to_jsonb($12), 'max_attempts', $13,
            'initial_backoff_seconds', $14, 'backoff_multiplier', $15,
            'max_backoff_seconds', $16, 'delegate', true)))
$m54$;

CREATE OR REPLACE FUNCTION pgreact.decision(
    name text, candidate_relation regclass, subject_key name, candidate_key name,
    priority name, results name[], valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL, max_candidates integer DEFAULT 1000
)
RETURNS pgreact_api.declaration
LANGUAGE SQL STABLE
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_api.declaration(
        'decision_program', $1,
        jsonb_strip_nulls(jsonb_build_object(
            'candidate_relation', (SELECT format('%I.%I', namespace.nspname, relation.relname)
                                   FROM pg_catalog.pg_class relation
                                   JOIN pg_catalog.pg_namespace namespace
                                     ON namespace.oid = relation.relnamespace
                                   WHERE relation.oid = $2),
            'subject_key', $3::text, 'candidate_key', $4::text,
            'priority', $5::text, 'results', to_jsonb($6),
            'valid_from', $7, 'valid_to', $8, 'max_candidates', $9,
            'delegate', true)))
$m54$;

CREATE OR REPLACE FUNCTION pgreact.shared_condition(
    name text, source regclass, key_columns name[],
    maintenance_mode text DEFAULT 'SCHEDULED'
)
RETURNS pgreact_api.declaration
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_api.declaration('shared_condition', $1,
        jsonb_build_object(
            'source', pgreact_internal.m54_relation_identity($2),
            'row_type', (SELECT c.reltype::regtype::text FROM pg_class c WHERE c.oid = $2),
            'key', to_jsonb($3), 'maintenance_mode', upper($4), 'delegate', true))
$m54$;

CREATE OR REPLACE FUNCTION pgreact.parameter_family(
    name text, parameter_relation regclass, parameter_key name,
    parameter_value_columns name[]
)
RETURNS pgreact_api.declaration
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_api.declaration('parameter_family', $1,
        jsonb_build_object(
            'parameter_relation', pgreact_internal.m54_relation_identity($2),
            'parameter_key', $3::text,
            'parameter_value_columns', to_jsonb($4),
            'definition_fingerprint', encode(sha256(convert_to(
                pgreact_internal.m54_relation_identity($2) || ':' || $3::text || ':' ||
                COALESCE($4::text, ''), 'UTF8')), 'hex'), 'delegate', true))
$m54$;

CREATE OR REPLACE FUNCTION pgreact.policy_set(
    name text, version text, members pgreact_api.declaration[], applicability regclass,
    subject_keys name[], support pgreact_api.declaration[], dependencies jsonb DEFAULT '[]'::jsonb,
    valid_from timestamptz DEFAULT clock_timestamp(), valid_to timestamptz DEFAULT NULL,
    evidence_limit integer DEFAULT 100
)
RETURNS pgreact_api.declaration
LANGUAGE SQL VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_api.declaration('policy_set', $1, jsonb_strip_nulls(jsonb_build_object(
        'version', $2,
        'members', COALESCE((SELECT jsonb_agg(
            jsonb_build_object('kind', item.kind, 'name', item.name,
                'version', COALESCE(item.spec ->> 'version', '1'),
                'match_keys', CASE item.kind
                    WHEN 'rule' THEN jsonb_build_array(item.spec ->> 'semantic_key')
                    WHEN 'decision_program' THEN jsonb_build_array(item.spec ->> 'candidate_key')
                    ELSE '[]'::jsonb END,
                'subject_keys', CASE item.kind
                    WHEN 'rule' THEN jsonb_build_array(item.spec ->> 'semantic_key')
                    WHEN 'decision_program' THEN jsonb_build_array(item.spec ->> 'subject_key')
                    ELSE '[]'::jsonb END,
                'scope_mode', 'POLICY_SET_REQUIRED',
                'declaration', jsonb_build_object('api_version', (item).api_version,
                    'kind', (item).kind, 'name', (item).name, 'spec', (item).spec))
            ORDER BY item.kind, item.name, COALESCE(item.spec ->> 'version', '1'))
            FROM unnest($3) item), '[]'::jsonb),
        'support', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'kind', item.kind, 'name', item.name,
                'version', COALESCE(item.spec ->> 'version', '1'),
                'declaration', jsonb_build_object('api_version', (item).api_version,
                    'kind', (item).kind, 'name', (item).name, 'spec', (item).spec))
            ORDER BY item.kind, item.name, COALESCE(item.spec ->> 'version', '1'))
            FROM unnest($6) item), '[]'::jsonb),
        'dependencies', COALESCE($7, '[]'::jsonb),
        'applicability', jsonb_build_object('source_kind', 'relation',
            'relation', pgreact_internal.m54_relation_identity($4),
            'subject_keys', to_jsonb($5)),
        'valid_from', $8, 'valid_to', $9, 'evidence_limit', $10)))
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_dependency_signature(source_oid oid)
RETURNS text
LANGUAGE SQL STABLE STRICT SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
WITH RECURSIVE dependencies(kind, object_oid) AS (
    SELECT 'r'::text, $1
    UNION
    SELECT CASE WHEN dependency.refclassid = 'pg_class'::regclass THEN 'r' ELSE 'f' END,
           dependency.refobjid
    FROM dependencies parent
    LEFT JOIN pg_catalog.pg_rewrite rewrite
      ON parent.kind = 'r' AND rewrite.ev_class = parent.object_oid
     AND rewrite.rulename = '_RETURN'
    JOIN pg_catalog.pg_depend dependency
      ON true
     AND dependency.refclassid IN ('pg_class'::regclass, 'pg_proc'::regclass)
     AND ((parent.kind = 'r' AND dependency.classid = 'pg_rewrite'::regclass
           AND dependency.objid = rewrite.oid)
          OR (parent.kind = 'f' AND dependency.classid = 'pg_proc'::regclass
              AND dependency.objid = parent.object_oid))
), rendered AS (
    SELECT dependencies.kind, dependencies.object_oid,
           CASE WHEN dependencies.kind = 'r' THEN
               'relation:' || pgreact_internal.m54_relation_identity(dependencies.object_oid) || ':' ||
               COALESCE(pg_get_viewdef(dependencies.object_oid, true), '') || ':' ||
               encode(pgreact_internal.source_row_signature(dependencies.object_oid), 'hex') || ':' ||
               COALESCE((SELECT relowner::text || ':' || relrowsecurity::text || ':' ||
                                relforcerowsecurity::text || ':' || COALESCE(reloptions::text, '')
                         FROM pg_class WHERE oid = dependencies.object_oid), '')
           ELSE
               'function:' || pgreact_internal.m54_function_identity(dependencies.object_oid) || ':' ||
               COALESCE(pg_get_functiondef(dependencies.object_oid), '') || ':' ||
               COALESCE((SELECT proowner::text || ':' || prosecdef::text || ':' || provolatile::text
                         FROM pg_proc WHERE oid = dependencies.object_oid), '')
           END AS value
    FROM dependencies
)
SELECT COALESCE(string_agg(value, E'\n' ORDER BY kind, object_oid), '') FROM rendered
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_require_source(
    source_oid oid, source_name text
)
RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
BEGIN
    IF source_oid IS NULL THEN
        RAISE EXCEPTION 'M54_SOURCE_DRIFT: source relation % no longer exists', source_name;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = source_oid) THEN
        RAISE EXCEPTION 'M54_SOURCE_DRIFT: source relation % no longer exists', source_name;
    END IF;
    IF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
        RAISE EXCEPTION 'M54_UNAUTHORIZED_SOURCE: caller lacks SELECT on source relation %', source_name;
    END IF;
    IF EXISTS (
        WITH RECURSIVE dependencies(kind, object_oid) AS (
            SELECT 'r'::text, source_oid
            UNION
            SELECT CASE WHEN dependency.refclassid = 'pg_class'::regclass THEN 'r' ELSE 'f' END,
                   dependency.refobjid
            FROM dependencies parent
            LEFT JOIN pg_rewrite rewrite
              ON parent.kind = 'r' AND rewrite.ev_class = parent.object_oid
             AND rewrite.rulename = '_RETURN'
            JOIN pg_depend dependency
              ON true
             AND dependency.refclassid IN ('pg_class'::regclass, 'pg_proc'::regclass)
             AND ((parent.kind = 'r' AND dependency.classid = 'pg_rewrite'::regclass
                   AND dependency.objid = rewrite.oid)
                  OR (parent.kind = 'f' AND dependency.classid = 'pg_proc'::regclass
                      AND dependency.objid = parent.object_oid))
        )
        SELECT 1 FROM dependencies
        JOIN pg_class relation ON dependencies.kind = 'r' AND relation.oid = dependencies.object_oid
        WHERE relation.relrowsecurity
    ) THEN
        RAISE EXCEPTION 'M54_RLS_UNSUPPORTED: source relation % or a transitive dependency uses row-level security', source_name;
    END IF;
    IF EXISTS (
        WITH RECURSIVE dependencies(kind, object_oid) AS (
            SELECT 'r'::text, source_oid
            UNION
            SELECT CASE WHEN dependency.refclassid = 'pg_class'::regclass THEN 'r' ELSE 'f' END,
                   dependency.refobjid
            FROM dependencies parent
            LEFT JOIN pg_rewrite rewrite
              ON parent.kind = 'r' AND rewrite.ev_class = parent.object_oid
             AND rewrite.rulename = '_RETURN'
            JOIN pg_depend dependency
              ON true
             AND dependency.refclassid IN ('pg_class'::regclass, 'pg_proc'::regclass)
             AND ((parent.kind = 'r' AND dependency.classid = 'pg_rewrite'::regclass
                   AND dependency.objid = rewrite.oid)
                  OR (parent.kind = 'f' AND dependency.classid = 'pg_proc'::regclass
                      AND dependency.objid = parent.object_oid))
        )
        SELECT 1 FROM dependencies
        JOIN pg_proc procedure ON dependencies.kind = 'f' AND procedure.oid = dependencies.object_oid
        WHERE procedure.prosecdef
    ) THEN
        RAISE EXCEPTION 'M54_SOURCE_FUNCTION_UNSUPPORTED: source relation % depends on a SECURITY DEFINER function', source_name;
    END IF;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_source_fingerprint(normalized jsonb)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    field text;
    identity text;
    object_oid oid;
    function_oid oid;
    parts text := 'm54-source-fingerprint-v2';
BEGIN
    IF normalized IS NULL THEN
        RETURN NULL;
    END IF;
    FOREACH field IN ARRAY ARRAY[
        'condition', 'candidate_relation', 'population_relation',
        'candidate_catalog', 'parameter_relation'
    ] LOOP
        identity := normalized -> 'spec' ->> field;
        IF identity IS NULL THEN
            CONTINUE;
        END IF;
        object_oid := to_regclass(identity);
        IF object_oid IS NULL THEN
            parts := parts || '|' || field || '=missing:' || identity;
        ELSE
            PERFORM pgreact_internal.m54_require_source(object_oid, identity);
            parts := parts || '|' || field || '=' ||
                pgreact_internal.m54_relation_identity(object_oid) || ':' ||
                pgreact_internal.m54_dependency_signature(object_oid);
        END IF;
    END LOOP;
    FOREACH field IN ARRAY ARRAY['on_activate', 'on_deactivate', 'on_change'] LOOP
        identity := normalized -> 'spec' ->> field;
        IF identity IS NULL THEN
            CONTINUE;
        END IF;
        function_oid := to_regprocedure(identity);
        IF function_oid IS NULL THEN
            parts := parts || '|' || field || '=missing:' || identity;
        ELSE
            parts := parts || '|' || field || '=' ||
                pgreact_internal.m54_function_identity(function_oid) || ':' ||
                pg_get_functiondef(function_oid) || ':' ||
                COALESCE((SELECT proowner::text || ':' || prosecdef::text || ':' || provolatile::text
                          FROM pg_proc WHERE oid = function_oid), '');
        END IF;
    END LOOP;
    RETURN encode(sha256(convert_to(parts, 'UTF8')), 'hex');
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_validate(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    canonical pgreact_api.declaration := pgreact_internal.m54_canonicalize_declaration(declaration);
    result jsonb := pgreact.validate_m53(canonical);
    findings jsonb := COALESCE(result -> 'findings', '[]'::jsonb);
    extra jsonb := '[]'::jsonb;
    source_name text;
    source_oid oid;
    field text;
    item jsonb;
    filtered jsonb := '[]'::jsonb;
    source_error text;
BEGIN
    BEGIN
        extra := pgreact_internal.m54_rule_findings(canonical);
    EXCEPTION WHEN OTHERS THEN
        extra := '[]'::jsonb;
    END;
    FOR item IN SELECT value FROM jsonb_array_elements(findings) value LOOP
        IF (COALESCE(item ->> 'code', '') = 'M28_RELATION_NAME'
            OR item -> 'details' ->> 'source_code' = 'M28_RELATION_NAME')
           AND item ->> 'field' IN ('spec.condition', 'spec.candidate_relation') THEN
            field := split_part(item ->> 'field', '.', 2);
            source_name := (canonical).spec ->> field;
            BEGIN
                source_oid := to_regclass(source_name);
            EXCEPTION WHEN OTHERS THEN
                source_oid := NULL;
            END;
            CONTINUE WHEN source_oid IS NOT NULL;
        END IF;
        filtered := filtered || jsonb_build_array(item);
    END LOOP;
    findings := filtered || extra;
    IF (canonical).kind IN ('rule', 'decision_program') THEN
        field := CASE WHEN (canonical).kind = 'rule' THEN 'condition' ELSE 'candidate_relation' END;
        source_name := (canonical).spec ->> field;
        BEGIN
            source_oid := to_regclass(source_name);
        EXCEPTION WHEN OTHERS THEN
            source_oid := NULL;
        END;
        IF source_oid IS NOT NULL THEN
            BEGIN
                PERFORM pgreact_internal.m54_require_source(source_oid, source_name);
            EXCEPTION WHEN OTHERS THEN
                source_error := SQLERRM;
                findings := findings || jsonb_build_array(pgreact_internal.m54_finding(
                    split_part(source_error, ':', 1), 'ERROR', 'spec.' || field,
                    source_error, 'Use a caller-readable source without transitive RLS or SECURITY DEFINER dependencies.'));
            END;
        END IF;
    END IF;
    RETURN result
        || jsonb_build_object(
            'state', CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(findings) value
                WHERE value ->> 'severity' = 'ERROR')
                THEN 'attention' ELSE 'ready' END,
            'findings', findings,
            'evidence', COALESCE(result -> 'evidence', '{}'::jsonb)
                || jsonb_build_object('normalized_declaration', jsonb_build_object(
                    'api_version', (canonical).api_version,
                    'kind', (canonical).kind,
                    'name', (canonical).name,
                    'spec', (canonical).spec)));
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact.compare_results(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
    result_set text, kind text, name text, subject_key text, result_key text,
    state text, delta text, current_value jsonb, proposed_value jsonb,
    evidence jsonb, complete boolean, sampled_time timestamptz,
    source_frontier timestamptz, declaration_digest text
)
LANGUAGE SQL STABLE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $m54$
WITH comparison AS (
    SELECT pgreact.compare($1, $2, $3) AS value
), rows AS (
    SELECT 'current'::text AS result_set, item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'current') item(value)
    UNION ALL SELECT 'proposed', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'proposed') item(value)
    UNION ALL SELECT 'delta', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'delta') item(value)
    UNION ALL SELECT 'lifecycle', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'lifecycle') item(value)
    UNION ALL SELECT 'work', item.value
    FROM comparison, jsonb_array_elements(comparison.value -> 'work') item(value)
)
SELECT result_set, comparison.value -> 'target' ->> 'kind',
       comparison.value -> 'target' ->> 'name', rows.value ->> 'subject_key',
       rows.value ->> 'result_key', rows.value ->> 'state', rows.value ->> 'change',
       rows.value -> 'current_value', rows.value -> 'proposed_value',
       rows.value -> 'evidence', (comparison.value -> 'evidence' ->> 'complete')::boolean,
       (comparison.value -> 'evidence' ->> 'sampled_time')::timestamptz,
       (comparison.value -> 'evidence' ->> 'source_frontier')::timestamptz,
       comparison.value -> 'evidence' ->> 'declaration_digest'
FROM comparison JOIN rows ON true
$m54$;

DO $m54$
DECLARE
    old_roles oid[];
BEGIN
    IF to_regprocedure('pgreact_api.configure_roles(regrole,regrole,regrole,regrole,regrole)') IS NOT NULL
       AND to_regprocedure('pgreact_api.configure_roles_m53(regrole,regrole,regrole,regrole,regrole)') IS NULL THEN
        ALTER FUNCTION pgreact_api.configure_roles(regrole,regrole,regrole,regrole,regrole)
            RENAME TO configure_roles_m53;
    END IF;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_sync_grants(old_roles oid[] DEFAULT ARRAY[]::oid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    author_oid oid;
    operator_oid oid;
    reader_oid oid;
    role_oid oid;
BEGIN
    SELECT role_oid INTO author_oid FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid INTO operator_oid FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid INTO reader_oid FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    FOREACH role_oid IN ARRAY COALESCE(old_roles, ARRAY[]::oid[]) LOOP
        CONTINUE WHEN role_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE oid = role_oid);
        EXECUTE format('REVOKE ALL ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) FROM %I', role_oid::regrole::text);
    END LOOP;
    IF author_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.validate(pgreact_api.declaration), pgreact.preview(pgreact_api.declaration,jsonb), pgreact.deploy(pgreact_api.declaration,jsonb), pgreact.export(text,text,text) TO %I', author_oid::regrole::text);
    END IF;
    IF reader_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.validate(pgreact_api.declaration), pgreact.export(text,text,text) TO %I', reader_oid::regrole::text);
    END IF;
    IF operator_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) TO %I', operator_oid::regrole::text);
    END IF;
    FOREACH role_oid IN ARRAY ARRAY[author_oid, operator_oid, reader_oid] LOOP
        CONTINUE WHEN role_oid IS NULL;
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact.compare_results(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact_internal.m54_read_rule_model(name,name,name,text,boolean,integer), pgreact_internal.m54_read_decision_model(name,name,name,name,name,name[],integer,text,integer), pgreact_internal.m54_decision_result(jsonb,name[]) TO %I', role_oid::regrole::text);
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_internal.m34_authoritative_checksum(), pgreact_internal.m34_delta(jsonb,jsonb), pgreact_internal.m34_raw_rows(jsonb,bigint,integer), pgreact_internal.m34_finding(text,text,text,text,text,text,jsonb) TO %I', role_oid::regrole::text);
    END LOOP;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    caller_oid oid := (SELECT oid FROM pg_roles WHERE rolname = session_user);
    extension_owner oid;
    old_roles oid[];
BEGIN
    SELECT extowner INTO STRICT extension_owner FROM pg_extension WHERE extname = 'pg_react';
    IF caller_oid <> extension_owner
       AND NOT COALESCE((SELECT rolsuper FROM pg_roles WHERE oid = caller_oid), false)
       AND NOT (to_regrole('pgreact_admin') IS NOT NULL
                AND pg_has_role(session_user, 'pgreact_admin', 'member')) THEN
        RAISE EXCEPTION 'M13_ROLE_ADMIN: only the extension owner or pgreact_admin may configure roles';
    END IF;
    IF cardinality(ARRAY[author_role::oid, operator_role::oid, worker_role::oid, reader_role::oid])
       <> (SELECT count(DISTINCT role_oid) FROM unnest(ARRAY[
           author_role::oid, operator_role::oid, worker_role::oid, reader_role::oid]) role_oid) THEN
        RAISE EXCEPTION 'M13_ROLE_DISTINCT: author, operator, worker, and reader roles must be distinct';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('pgreact:configure_roles', 5788046901200000));
    SELECT COALESCE(array_agg(role_oid ORDER BY role_kind), ARRAY[]::oid[])
    INTO old_roles FROM pgreact_internal.application_roles;
    DELETE FROM pgreact_internal.application_roles;
    PERFORM pgreact_api.configure_roles_m53(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    PERFORM pgreact_internal.m54_sync_grants(old_roles);
END
$m54$;

REVOKE ALL ON FUNCTION pgreact_api.configure_roles(regrole,regrole,regrole,regrole,regrole) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_relation_identity(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_function_identity(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_canonicalize_declaration(pgreact_api.declaration) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_dependency_signature(oid) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_require_source(oid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_source_fingerprint(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_validate(pgreact_api.declaration) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_preview(pgreact_api.declaration,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_deploy(pgreact_api.declaration,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_package_graph_order(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_package_has_cycle(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_package_preview(pgreact_api.declaration,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_package_deploy(pgreact_api.declaration,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m54_sync_grants(oid[]) FROM PUBLIC;

DO $m54$
DECLARE author_role oid;
    operator_role oid;
    reader_role oid;
BEGIN
    SELECT role_oid INTO author_role FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid INTO operator_role FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid INTO reader_role FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    IF author_role IS NOT NULL OR operator_role IS NOT NULL OR reader_role IS NOT NULL THEN
        PERFORM pgreact_internal.m54_sync_grants();
    END IF;
END
$m54$;

COMMENT ON EXTENSION pg_react IS
    '0.43.2 correctness hardening for roles, canonical identities, reviewed dependencies, comparison, and packages';
