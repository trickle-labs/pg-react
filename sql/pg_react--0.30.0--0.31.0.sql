-- M34 read-only deployment-impact comparison over the authoritative M33 state.

CREATE OR REPLACE FUNCTION pgreact_internal.m34_finding(
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
AS $m34$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'target', $3,
        'field', $4,
        'message', $5,
        'hint', $6,
        'details', COALESCE($7, '{}'::jsonb))
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_finding_registry()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
    SELECT jsonb_build_object(
        'schema_version', 1,
        'milestone', 'M34',
        'finding_shape', jsonb_build_array(
            'code', 'severity', 'blocking', 'target',
            'field', 'message', 'hint', 'details'),
        'severity', jsonb_build_array('ERROR', 'WARNING', 'INFO'),
        'codes', jsonb_build_array(
            jsonb_build_object('code', 'M34_INVALID_DECLARATION', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_OPTIONS', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_TARGET_NOT_FOUND', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_TARGET_KIND', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_TARGET_NAME', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_TARGET_VERSION', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_UNAUTHORIZED_TARGET', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_UNAUTHORIZED_SOURCE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_RLS_UNSUPPORTED', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_SOURCE_DRIFT', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_PROPOSAL_DUPLICATE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_WRONG_KEY_TYPE', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_RESOURCE_LIMIT', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_SAMPLED_TIME', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_UNSUPPORTED_KIND', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_AUTHORITATIVE_CHANGED', 'severity', 'ERROR'),
            jsonb_build_object('code', 'M34_COMPARISON_INCOMPLETE', 'severity', 'WARNING'),
            jsonb_build_object('code', 'M34_NO_EFFECT', 'severity', 'INFO')))
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_authoritative_checksum()
RETURNS text
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
    SELECT encode(sha256(convert_to(jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton),
        'declarations', COALESCE((
            SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.declaration_id)
            FROM pgreact_internal.api_declarations row_data), '[]'::jsonb),
        'rules', COALESCE((
            SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.rule_version_id)
            FROM pgreact_internal.rule_versions row_data), '[]'::jsonb),
        'matches', COALESCE((
            SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.rule_version_id, row_data.activation_id)
            FROM pgreact_internal.activation_state row_data), '[]'::jsonb),
        'decisions', COALESCE((
            SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.program_id, row_data.subject_key)
            FROM pgreact_internal.decision_subject_state row_data), '[]'::jsonb),
        'work', COALESCE((
            SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.kind, row_data.name, row_data.work_id)
            FROM pgreact.work row_data), '[]'::jsonb),
        'policy_sets', COALESCE((
            SELECT jsonb_agg(to_jsonb(row_data) ORDER BY row_data.policy_set_id, row_data.version)
            FROM pgreact_internal.policy_set_versions row_data), '[]'::jsonb)
    )::text, 'UTF8')), 'hex')
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_require_source(
    source_oid oid,
    source_name text
)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
DECLARE rls_enabled boolean;
BEGIN
    IF source_oid IS NULL THEN
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: source relation % no longer exists', source_name;
    END IF;
    SELECT relrowsecurity INTO rls_enabled
    FROM pg_class
    WHERE oid = source_oid;
    IF rls_enabled THEN
        RAISE EXCEPTION 'M34_RLS_UNSUPPORTED: source relation % uses row-level security', source_name;
    END IF;
    IF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
        RAISE EXCEPTION 'M34_UNAUTHORIZED_SOURCE: caller lacks SELECT on source relation %', source_name;
    END IF;
END
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_raw_rows(
    rows jsonb,
    total_count bigint,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m34$
    SELECT jsonb_build_object(
        'rows', COALESCE((
            SELECT jsonb_agg(item.value ORDER BY item.ordinality)
            FROM jsonb_array_elements($1) WITH ORDINALITY item(value, ordinality)
            WHERE item.ordinality <= $3), '[]'::jsonb),
        'rows_considered', $2,
        'truncated', $2 > $3)
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_rule_rows(
    source_oid oid,
    key_column name,
    source_label text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
DECLARE total_count bigint;
    null_count bigint;
    duplicate_count bigint;
    rows jsonb;
    key_type regtype;
BEGIN
    SELECT a.atttypid::regtype INTO key_type
    FROM pg_attribute a
    WHERE a.attrelid = source_oid
      AND a.attname = key_column
      AND a.attnum > 0
      AND NOT a.attisdropped;
    IF key_type IS DISTINCT FROM 'bigint'::regtype THEN
        RAISE EXCEPTION 'M34_WRONG_KEY_TYPE: rule key % must be bigint', key_column;
    END IF;
    EXECUTE format('SELECT count(*) FROM %s', source_oid::regclass) INTO total_count;
    EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NULL', source_oid::regclass, key_column)
        INTO null_count;
    IF null_count > 0 THEN
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: rule source % contains null keys', source_oid::regclass;
    END IF;
    EXECUTE format(
        'SELECT count(*) FROM (
             SELECT %1$I FROM %2$s GROUP BY %1$I HAVING count(*) > 1
         ) duplicates', key_column, source_oid::regclass)
        INTO duplicate_count;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M34_PROPOSAL_DUPLICATE: rule source % contains duplicate keys',
            source_oid::regclass;
    END IF;
    EXECUTE format(
        'SELECT COALESCE(jsonb_agg(jsonb_build_object(
             ''subject_key'', s.%1$I::text,
             ''result_key'', s.%1$I::text,
             ''state'', ''MATCH'',
             ''value'', to_jsonb(s),
             ''work'', jsonb_build_object(''would_be_work'', true),
             ''evidence'', jsonb_build_object(
                 ''source'', $2, ''complete'', true))
             ORDER BY s.%1$I), ''[]''::jsonb)
         FROM (
             SELECT * FROM %2$s
             ORDER BY %1$I
             LIMIT ($1 + 1)
         ) s', key_column, source_oid::regclass)
        INTO rows
        USING evidence_limit, source_label;
    RETURN jsonb_build_object(
        'rows', rows,
        'rows_considered', total_count,
        'truncated', total_count > evidence_limit);
END
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_current_rule_rows(
    target_name text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
    SELECT jsonb_build_object(
        'rows', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'subject_key', match_row.semantic_key::text,
                       'result_key', match_row.semantic_key::text,
                       'state', CASE WHEN match_row.active THEN 'MATCH' ELSE 'INACTIVE' END,
                       'value', match_row.bindings - '__pgt_row_id',
                       'work', jsonb_build_object(
                           'would_be_work', match_row.active),
                       'evidence', jsonb_build_object(
                           'source', 'pgreact.matches',
                           'generation', match_row.generation,
                           'revision', match_row.revision,
                           'complete', true))
                   ORDER BY match_row.semantic_key)
            FROM (
                SELECT *
                FROM pgreact.matches
                WHERE name = $1 AND active
                ORDER BY semantic_key
                LIMIT ($2 + 1)
            ) match_row), '[]'::jsonb),
        'rows_considered', (
            SELECT count(*) FROM pgreact.matches
            WHERE name = $1 AND active),
        'truncated', (
            SELECT count(*) > $2 FROM pgreact.matches
            WHERE name = $1 AND active))
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_decision_rows(
    source_oid oid,
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
AS $m34$
DECLARE total_count bigint;
    null_count bigint;
    duplicate_count bigint;
    over_limit_count bigint;
    rows jsonb;
BEGIN
    EXECUTE format(
        'SELECT count(*) FROM %1$s
         WHERE %2$I IS NULL OR %3$I IS NULL OR %4$I IS NULL',
        source_oid::regclass, subject_column, candidate_column, priority_column)
        INTO null_count;
    IF null_count > 0 THEN
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: decision source % contains null identities or priorities',
            source_oid::regclass;
    END IF;
    EXECUTE format(
        'SELECT count(*) FROM (
             SELECT %1$I, %2$I FROM %3$s
             GROUP BY %1$I, %2$I HAVING count(*) > 1
         ) duplicates', subject_column, candidate_column, source_oid::regclass)
        INTO duplicate_count;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M34_PROPOSAL_DUPLICATE: decision source % contains duplicate candidates',
            source_oid::regclass;
    END IF;
    EXECUTE format(
        'SELECT count(*) FROM (
             SELECT %1$I FROM %2$s
             GROUP BY %1$I HAVING count(*) > $1
         ) over_limit', subject_column, source_oid::regclass)
        INTO over_limit_count
        USING max_candidates;
    IF over_limit_count > 0 THEN
        RAISE EXCEPTION 'M34_RESOURCE_LIMIT: decision source % exceeds max_candidates',
            source_oid::regclass;
    END IF;
    EXECUTE format('SELECT count(DISTINCT %1$I) FROM %2$s', subject_column, source_oid::regclass)
        INTO total_count;
    EXECUTE format(
        'WITH source AS (
             SELECT s.%1$I::bigint AS subject_key,
                    s.%2$I::bigint AS candidate_key,
                    s.%3$I::bigint AS priority,
                    to_jsonb(s) AS row_data
             FROM %4$s s
         ), ranked AS (
             SELECT source.*,
                    min(priority) OVER (PARTITION BY subject_key) AS best_priority
             FROM source
         ), grouped AS (
             SELECT subject_key,
                    min(priority) AS best_priority,
                    count(*) AS candidate_count,
                    count(*) FILTER (WHERE priority = best_priority) AS top_count,
                    min(candidate_key) FILTER (WHERE priority = best_priority) AS winner_candidate,
                    (array_agg(row_data ORDER BY candidate_key)
                        FILTER (WHERE priority = best_priority))[1] AS winner_row,
                    jsonb_agg(jsonb_build_object(
                        ''candidate'', candidate_key::text,
                        ''priority'', priority,
                        ''value'', row_data)
                        ORDER BY candidate_key) AS competitors
             FROM ranked
             GROUP BY subject_key
         ), limited AS (
             SELECT *
             FROM grouped
             ORDER BY subject_key
             LIMIT ($1 + 1)
         )
         SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    ''subject_key'', subject_key::text,
                    ''result_key'', CASE WHEN top_count = 1
                                         THEN winner_candidate::text ELSE NULL END,
                    ''state'', CASE WHEN top_count = 1
                                    THEN ''WINNER'' ELSE ''AMBIGUOUS'' END,
                    ''value'', jsonb_build_object(
                        ''candidate'', CASE WHEN top_count = 1
                                            THEN winner_candidate ELSE NULL END,
                        ''priority'', best_priority,
                        ''result'', CASE WHEN top_count = 1
                                         THEN pgreact_internal.decision_result(
                                             winner_row, $3) ELSE NULL END),
                    ''work'', jsonb_build_object(
                        ''would_be_work'', top_count = 1),
                    ''evidence'', jsonb_build_object(
                        ''source'', $2,
                        ''candidate_count'', candidate_count,
                        ''competitors'', competitors,
                        ''complete'', true))
                ORDER BY subject_key), ''[]''::jsonb)
         FROM limited', subject_column, candidate_column, priority_column, source_oid::regclass)
        INTO rows
        USING evidence_limit, source_label, result_columns;
    RETURN jsonb_build_object(
        'rows', rows,
        'rows_considered', total_count,
        'truncated', total_count > evidence_limit);
END
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_current_decision_rows(
    target_name text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
    SELECT jsonb_build_object(
        'rows', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'subject_key', winner.subject_key::text,
                       'result_key', winner.winner_candidate::text,
                       'state', winner.state,
                       'value', jsonb_build_object(
                           'candidate', winner.winner_candidate,
                           'priority', winner.winner_priority,
                           'result', winner.winner_result,
                           'claimable', winner.claimable),
                       'work', jsonb_build_object(
                           'would_be_work', winner.claimable),
                       'evidence', jsonb_build_object(
                           'source', 'pgreact.decision_winners',
                           'competitors', winner.competitors,
                           'competitors_truncated', winner.competitors_truncated,
                           'complete', NOT winner.competitors_truncated))
                   ORDER BY winner.subject_key)
            FROM (
                SELECT *
                FROM pgreact.decision_winners
                WHERE program_name = $1
                ORDER BY subject_key
                LIMIT ($2 + 1)
            ) winner), '[]'::jsonb),
        'rows_considered', (
            SELECT count(*) FROM pgreact.decision_winners
            WHERE program_name = $1),
        'truncated', (
            SELECT count(*) > $2 FROM pgreact.decision_winners
            WHERE program_name = $1))
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_policy_rows(
    current_normalized jsonb,
    proposed_normalized jsonb,
    current_set_name text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
DECLARE current_members jsonb;
    current_subjects jsonb;
    proposed_members jsonb;
    proposed_subjects jsonb;
    current_rows jsonb;
    proposed_rows jsonb;
    current_count bigint;
    proposed_count bigint;
    current_member_count bigint;
    proposed_member_count bigint;
    current_subject_count bigint;
    proposed_subject_count bigint;
    source_oid oid;
    key_names name[];
    key_types text[];
    values_expression text;
    complete_expression text;
BEGIN
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'subject_key', 'member:' || (item.value ->> 'kind') || ':' ||
                              (item.value ->> 'name') || ':' || (item.value ->> 'version'),
               'result_key', 'member:' || (item.value ->> 'kind') || ':' ||
                             (item.value ->> 'name') || ':' || (item.value ->> 'version'),
               'state', 'MEMBER',
               'value', item.value,
               'work', jsonb_build_object('would_be_work', false),
               'evidence', jsonb_build_object('source', 'pgreact.policy_set_members',
                                              'complete', true))
               ORDER BY item.value ->> 'kind', item.value ->> 'name', item.value ->> 'version'),
           '[]'::jsonb)
    INTO current_members
    FROM (
        SELECT item.value
        FROM jsonb_array_elements(
                 COALESCE(current_normalized -> 'spec' -> 'members', '[]'::jsonb))
             WITH ORDINALITY item(value, ordinal)
        WHERE item.ordinal <= evidence_limit + 1
    ) item;
    current_member_count := jsonb_array_length(
        COALESCE(current_normalized -> 'spec' -> 'members', '[]'::jsonb));
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'subject_key', 'subject:' || row_data.subject_identity,
               'result_key', 'subject:' || row_data.subject_identity,
               'state', 'ELIGIBLE',
               'value', row_data.subject_values,
               'work', jsonb_build_object('would_be_work', false),
               'evidence', jsonb_build_object(
                   'source', 'pgreact.policy_set_eligible_subjects',
                   'complete', true))
               ORDER BY row_data.subject_identity), '[]'::jsonb)
    INTO current_subjects
    FROM (
        SELECT row_data.*
        FROM pgreact.policy_set_eligible_subjects row_data
        WHERE row_data.set_name = current_set_name
          AND row_data.version = current_normalized -> 'spec' ->> 'version'
        ORDER BY row_data.subject_identity
        LIMIT (evidence_limit + 1)
    ) row_data;
    SELECT count(*) INTO current_subject_count
    FROM pgreact.policy_set_eligible_subjects row_data
    WHERE row_data.set_name = current_set_name
      AND row_data.version = current_normalized -> 'spec' ->> 'version';

    proposed_members := COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'subject_key', 'member:' || (item.value ->> 'kind') || ':' ||
                                  (item.value ->> 'name') || ':' || (item.value ->> 'version'),
                   'result_key', 'member:' || (item.value ->> 'kind') || ':' ||
                                 (item.value ->> 'name') || ':' || (item.value ->> 'version'),
                   'state', 'MEMBER',
                   'value', item.value,
                   'work', jsonb_build_object('would_be_work', false),
                   'evidence', jsonb_build_object('source', 'proposed declaration',
                                                  'complete', true))
                   ORDER BY item.value ->> 'kind', item.value ->> 'name', item.value ->> 'version')
        FROM (
            SELECT item.value
            FROM jsonb_array_elements(
                     COALESCE(proposed_normalized -> 'spec' -> 'members', '[]'::jsonb))
                 WITH ORDINALITY item(value, ordinal)
            WHERE item.ordinal <= evidence_limit + 1
        ) item), '[]'::jsonb);
    proposed_member_count := jsonb_array_length(
        COALESCE(proposed_normalized -> 'spec' -> 'members', '[]'::jsonb));

    IF proposed_normalized -> 'spec' -> 'applicability' ->> 'source_kind'
       IS DISTINCT FROM 'relation' THEN
        RAISE EXCEPTION 'M34_UNSUPPORTED_KIND: M34 requires a relational applicability source';
    END IF;
    source_oid := to_regclass(proposed_normalized -> 'spec' -> 'applicability' ->> 'relation');
    PERFORM pgreact_internal.m34_require_source(
        source_oid, proposed_normalized -> 'spec' -> 'applicability' ->> 'relation');
    SELECT array_agg(value::name ORDER BY ordinal),
           array_agg(a.atttypid::regtype::text ORDER BY ordinal)
    INTO key_names, key_types
    FROM jsonb_array_elements_text(
             proposed_normalized -> 'spec' -> 'applicability' -> 'subject_keys')
         WITH ORDINALITY requested(value, ordinal)
    JOIN pg_attribute a
      ON a.attrelid = source_oid
     AND a.attname = requested.value::name
     AND a.attnum > 0
     AND NOT a.attisdropped;
    IF cardinality(key_names) IS DISTINCT FROM
       jsonb_array_length(proposed_normalized -> 'spec' -> 'applicability' -> 'subject_keys') THEN
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: applicability key column is missing';
    END IF;
    SELECT string_agg(format('to_jsonb(s.%I)', key_name), ', ' ORDER BY ordinal),
           string_agg(format('s.%I IS NOT NULL', key_name), ' AND ' ORDER BY ordinal)
    INTO values_expression, complete_expression
    FROM unnest(key_names) WITH ORDINALITY requested(key_name, ordinal);
    values_expression := 'jsonb_build_array(' || values_expression || ')';
    EXECUTE format(
        'SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    ''subject_key'', ''subject:'' ||
                        encode(pgreact_internal.m30_key_identity($1, x.subject_values), ''hex''),
                    ''result_key'', ''subject:'' ||
                        encode(pgreact_internal.m30_key_identity($1, x.subject_values), ''hex''),
                    ''state'', ''ELIGIBLE'',
                    ''value'', x.subject_values,
                    ''work'', jsonb_build_object(''would_be_work'', false),
                    ''evidence'', jsonb_build_object(
                        ''source'', $2, ''complete'', true))
                ORDER BY x.subject_values::text), ''[]''::jsonb)
         FROM (
             SELECT distinct_values.subject_values
             FROM (
                 SELECT DISTINCT %1$s AS subject_values
                 FROM %2$s s
                 WHERE %3$s
             ) distinct_values
             ORDER BY distinct_values.subject_values::text
             LIMIT ($3 + 1)
         ) x', values_expression, source_oid::regclass, complete_expression)
        INTO proposed_subjects
        USING key_types,
              proposed_normalized -> 'spec' -> 'applicability' ->> 'relation',
              evidence_limit;
    EXECUTE format(
        'SELECT count(*) FROM (
             SELECT DISTINCT %1$s AS subject_values
             FROM %2$s s
             WHERE %3$s
         ) distinct_values', values_expression, source_oid::regclass, complete_expression)
        INTO proposed_subject_count;

    current_rows := current_members || current_subjects;
    proposed_rows := proposed_members || proposed_subjects;
    current_count := current_member_count + current_subject_count;
    proposed_count := proposed_member_count + proposed_subject_count;
    RETURN jsonb_build_object(
        'current', jsonb_build_object(
            'rows', current_rows,
            'rows_considered', current_count,
            'truncated', current_count > evidence_limit),
        'proposed', jsonb_build_object(
            'rows', proposed_rows,
            'rows_considered', proposed_count,
            'truncated', proposed_count > evidence_limit));
END
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_delta(
    current_rows jsonb,
    proposed_rows jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m34$
WITH current_values AS (
    SELECT value ->> 'subject_key' AS subject_key, value
    FROM jsonb_array_elements($1) item(value)
), proposed_values AS (
    SELECT value ->> 'subject_key' AS subject_key, value
    FROM jsonb_array_elements($2) item(value)
), changes AS (
    SELECT COALESCE(current_values.subject_key, proposed_values.subject_key) AS subject_key,
           current_values.value AS current_value,
           proposed_values.value AS proposed_value,
           CASE
               WHEN current_values.value IS NULL THEN 'ADDED'
               WHEN proposed_values.value IS NULL THEN 'REMOVED'
               WHEN current_values.value ->> 'state' IS NOT DISTINCT FROM
                    proposed_values.value ->> 'state'
                AND current_values.value -> 'value' IS NOT DISTINCT FROM
                    proposed_values.value -> 'value' THEN 'UNCHANGED'
               ELSE 'CHANGED'
           END AS change
    FROM current_values
    FULL JOIN proposed_values USING (subject_key)
)
SELECT jsonb_build_object(
    'rows', COALESCE(jsonb_agg(jsonb_build_object(
        'subject_key', subject_key,
        'result_key', subject_key,
        'change', change,
        'state', COALESCE(proposed_value ->> 'state', current_value ->> 'state'),
        'current_value', current_value -> 'value',
        'proposed_value', proposed_value -> 'value',
        'work', COALESCE(proposed_value -> 'work', current_value -> 'work'),
        'evidence', jsonb_build_object(
            'current', current_value -> 'evidence',
            'proposed', proposed_value -> 'evidence',
            'complete', true))
        ORDER BY subject_key), '[]'::jsonb),
    'counts', jsonb_build_object(
        'added', count(*) FILTER (WHERE change = 'ADDED'),
        'removed', count(*) FILTER (WHERE change = 'REMOVED'),
        'changed', count(*) FILTER (WHERE change = 'CHANGED'),
        'unchanged', count(*) FILTER (WHERE change = 'UNCHANGED')))
FROM changes
$m34$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
DECLARE validation jsonb;
    proposed_normalized jsonb;
    current_normalized jsonb;
    current_owner oid;
    current_checksum text;
    after_checksum text;
    current_model jsonb;
    proposed_model jsonb;
    delta_model jsonb;
    current_rows jsonb;
    proposed_rows jsonb;
    delta_rows jsonb;
    lifecycle_rows jsonb;
    work_rows jsonb;
    current_count bigint;
    proposed_count bigint;
    missing_count bigint := 0;
    evidence_limit integer := 100;
    sampled_time timestamptz;
    source_frontier timestamptz;
    started_at timestamptz := clock_timestamp();
    comparison_complete boolean;
    target_kind text := (deployed).kind;
    target_name text := (deployed).name;
    target_version text := (deployed).version;
    source_oid oid;
    key_column name;
    subject_column name;
    candidate_column name;
    priority_column name;
    result_columns name[];
    max_candidates integer;
    relation_name text;
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
    IF options ? 'sampled_time'
       AND jsonb_typeof(options -> 'sampled_time') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'M34_OPTIONS: sampled_time must be an RFC3339 timestamp string';
    END IF;
    SELECT frontier INTO source_frontier
    FROM pgreact_internal.clock_frontier
    WHERE singleton;
    sampled_time := COALESCE(
        NULLIF(options ->> 'sampled_time', '')::timestamptz,
        source_frontier);
    IF sampled_time IS DISTINCT FROM source_frontier THEN
        RAISE EXCEPTION 'M34_SAMPLED_TIME: comparison must use the current authoritative frontier %',
            source_frontier;
    END IF;
    IF proposed IS NULL THEN
        RAISE EXCEPTION 'M34_INVALID_DECLARATION: proposed declaration is required';
    END IF;
    IF target_kind IS NULL OR target_name IS NULL THEN
        RAISE EXCEPTION 'M34_TARGET_NOT_FOUND: deployed target kind and name are required';
    END IF;
    IF (proposed).kind IS DISTINCT FROM target_kind THEN
        RAISE EXCEPTION 'M34_TARGET_KIND: proposed and deployed kinds must match';
    END IF;
    IF (proposed).name IS DISTINCT FROM target_name THEN
        RAISE EXCEPTION 'M34_TARGET_NAME: proposed declaration name must match deployed target name';
    END IF;
    validation := pgreact.validate(proposed);
    IF validation ->> 'state' = 'attention' THEN
        RETURN jsonb_build_object(
            'contract_version', 21,
            'operation', 'compare',
            'target', jsonb_build_object(
                'kind', target_kind, 'name', target_name, 'version', target_version),
            'state', 'attention',
            'summary', jsonb_build_object('read_only', true),
            'findings', validation -> 'findings',
            'current', '[]'::jsonb,
            'proposed', '[]'::jsonb,
            'delta', '[]'::jsonb,
            'lifecycle', '[]'::jsonb,
            'work', '[]'::jsonb,
            'truncated', false);
    END IF;
    proposed_normalized := COALESCE(
        validation -> 'evidence' -> 'normalized_declaration',
        pgreact_internal.m28_normalize(proposed));

    IF target_kind = 'policy_set' THEN
        SELECT version.normalized, set.owner_oid
        INTO current_normalized, current_owner
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = target_name
          AND version.state = 'DEPLOYED'
          AND version.valid_from <= source_frontier
          AND (version.valid_to IS NULL OR source_frontier < version.valid_to)
          AND (target_version IS NULL OR version.version = target_version)
        ORDER BY version.valid_from DESC, version.created_at DESC
        LIMIT 1;
    ELSE
        SELECT row_data.normalized, row_data.owner_oid
        INTO current_normalized, current_owner
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = target_kind
          AND row_data.object_name = target_name
          AND row_data.state = 'DEPLOYED';
        IF current_normalized IS NULL THEN
            RAISE EXCEPTION 'M34_TARGET_NOT_FOUND: deployed % % was not found',
                target_kind, target_name;
        END IF;
        IF target_version IS NOT NULL AND target_version <> '1' THEN
            RAISE EXCEPTION 'M34_TARGET_VERSION: only the deployed declaration version 1 is supported';
        END IF;
    END IF;
    IF current_normalized IS NULL THEN
        RAISE EXCEPTION 'M34_TARGET_NOT_FOUND: deployed % % was not found',
            target_kind, target_name;
    END IF;
    IF NOT pg_has_role(session_user, current_owner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin()
       AND NOT EXISTS (
           SELECT 1
           FROM pgreact_internal.application_roles role_row
           WHERE role_row.role_kind = 'reader'
             AND pg_has_role(session_user, role_row.role_oid, 'member')) THEN
        RAISE EXCEPTION 'M34_UNAUTHORIZED_TARGET: caller is not allowed to inspect %', target_name;
    END IF;
    current_checksum := pgreact_internal.m34_authoritative_checksum();

    IF target_kind = 'rule' THEN
        relation_name := proposed_normalized -> 'spec' ->> 'condition';
        source_oid := to_regclass(relation_name);
        PERFORM pgreact_internal.m34_require_source(source_oid, relation_name);
        key_column := (proposed_normalized -> 'spec' ->> 'semantic_key')::name;
        proposed_model := pgreact_internal.m34_rule_rows(
            source_oid, key_column, relation_name, evidence_limit);
        SELECT row_data.source_view_oid, row_data.key_column
        INTO source_oid, key_column
        FROM pgreact_internal.rule_versions row_data
        JOIN pgreact_internal.rules rule USING (rule_id)
        WHERE rule.rule_name = target_name
          AND row_data.state <> 'REMOVED'
        ORDER BY row_data.created_at DESC
        LIMIT 1;
        PERFORM pgreact_internal.m34_require_source(source_oid, source_oid::regclass::text);
        current_model := pgreact_internal.m34_current_rule_rows(target_name, evidence_limit);
    ELSIF target_kind = 'decision_program' THEN
        relation_name := proposed_normalized -> 'spec' ->> 'candidate_relation';
        source_oid := to_regclass(relation_name);
        PERFORM pgreact_internal.m34_require_source(source_oid, relation_name);
        subject_column := (proposed_normalized -> 'spec' ->> 'subject_key')::name;
        candidate_column := (proposed_normalized -> 'spec' ->> 'candidate_key')::name;
        priority_column := (proposed_normalized -> 'spec' ->> 'priority')::name;
        SELECT array_agg(value::name ORDER BY ordinal)
        INTO result_columns
        FROM jsonb_array_elements_text(proposed_normalized -> 'spec' -> 'results')
             WITH ORDINALITY item(value, ordinal);
        max_candidates := COALESCE(
            (proposed_normalized -> 'spec' ->> 'max_candidates')::integer, 1000);
        proposed_model := pgreact_internal.m34_decision_rows(
            source_oid, subject_column, candidate_column, priority_column,
            result_columns, max_candidates, relation_name, evidence_limit);
        SELECT version.candidate_relation_oid
        INTO source_oid
        FROM pgreact_internal.decision_program_versions version
        JOIN pgreact_internal.decision_programs program USING (program_id)
        WHERE program.program_name = target_name
          AND version.state = 'DEPLOYED'
        ORDER BY version.valid_from DESC, version.version_no DESC
        LIMIT 1;
        PERFORM pgreact_internal.m34_require_source(source_oid, source_oid::regclass::text);
        current_model := pgreact_internal.m34_current_decision_rows(target_name, evidence_limit);
        SELECT count(*) INTO missing_count
        FROM jsonb_array_elements(current_model -> 'rows') current_row
        WHERE NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(proposed_model -> 'rows') proposed_row
            WHERE proposed_row.value ->> 'subject_key' =
                  current_row.value ->> 'subject_key');
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
                               'candidate', NULL,
                               'priority', NULL,
                               'result', NULL,
                               'claimable', false),
                           'work', jsonb_build_object('would_be_work', false),
                           'evidence', jsonb_build_object(
                               'source', 'pgreact.decision_winners',
                               'complete', true))
                FROM jsonb_array_elements(current_model -> 'rows') current_row
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM jsonb_array_elements(proposed_model -> 'rows') proposed_row
                    WHERE proposed_row.value ->> 'subject_key' =
                          current_row.value ->> 'subject_key')
            ) rows;
            proposed_model := jsonb_build_object(
                'rows', proposed_rows,
                'rows_considered',
                    (proposed_model ->> 'rows_considered')::bigint + missing_count,
                'truncated',
                    COALESCE((proposed_model ->> 'truncated')::boolean, false)
                    OR ((
                        proposed_model ->> 'rows_considered')::bigint + missing_count
                        > evidence_limit));
        END IF;
    ELSIF target_kind = 'policy_set' THEN
        proposed_model := pgreact_internal.m34_policy_rows(
            current_normalized, proposed_normalized, target_name, evidence_limit) -> 'proposed';
        current_model := pgreact_internal.m34_policy_rows(
            current_normalized, proposed_normalized, target_name, evidence_limit) -> 'current';
    ELSE
        RAISE EXCEPTION 'M34_UNSUPPORTED_KIND: comparison does not approximate %', target_kind;
    END IF;

    current_rows := current_model -> 'rows';
    proposed_rows := proposed_model -> 'rows';
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
    comparison_complete := NOT COALESCE((current_model ->> 'truncated')::boolean, false)
        AND NOT COALESCE((proposed_model ->> 'truncated')::boolean, false)
        AND jsonb_array_length(delta_rows) <= evidence_limit;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF current_checksum IS DISTINCT FROM after_checksum THEN
        RAISE EXCEPTION 'M34_AUTHORITATIVE_CHANGED: authoritative state changed during comparison';
    END IF;
    current_count := (current_model ->> 'rows_considered')::bigint;
    proposed_count := (proposed_model ->> 'rows_considered')::bigint;
    RETURN jsonb_build_object(
        'contract_version', 21,
        'operation', 'compare',
        'target', jsonb_build_object(
            'kind', target_kind, 'name', target_name, 'version', target_version),
        'state', CASE WHEN comparison_complete THEN 'ready' ELSE 'partial' END,
        'summary', jsonb_build_object(
            'read_only', true,
            'current_count', current_count,
            'proposed_count', proposed_count,
            'delta_counts', CASE WHEN comparison_complete
                THEN delta_model -> 'counts' ELSE NULL END,
            'counts_exact', comparison_complete,
            'affected_subject_count', CASE WHEN comparison_complete THEN
                COALESCE((delta_model -> 'counts' ->> 'added')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'removed')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'changed')::bigint, 0)
                ELSE NULL END,
            'would_be_work', COALESCE((
                SELECT count(*)
                FROM jsonb_array_elements(proposed_rows) item
                WHERE (item.value -> 'work' ->> 'would_be_work')::boolean), 0)),
        'evidence', jsonb_build_object(
            'sampled_time', sampled_time,
            'source_frontier', source_frontier,
            'applicability_snapshot', CASE WHEN target_kind = 'policy_set'
                THEN proposed_normalized -> 'spec' -> 'applicability' ELSE NULL END,
            'declaration_digest', encode(
                sha256(convert_to(proposed_normalized::text, 'UTF8')), 'hex'),
            'authoritative_checksum_before', current_checksum,
            'authoritative_checksum_after', after_checksum,
            'complete', comparison_complete,
            'evidence_limit', evidence_limit),
        'cost', jsonb_build_object(
            'rows_considered', current_count + proposed_count,
            'affected_subjects', CASE WHEN comparison_complete THEN
                COALESCE((delta_model -> 'counts' ->> 'added')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'removed')::bigint, 0)
                + COALESCE((delta_model -> 'counts' ->> 'changed')::bigint, 0)
                ELSE NULL END,
            'dependency_fan_out', 0,
            'reevaluation', 0,
            'cascade_depth', 0,
            'would_be_work', COALESCE((
                SELECT count(*)
                FROM jsonb_array_elements(proposed_rows) item
                WHERE (item.value -> 'work' ->> 'would_be_work')::boolean), 0),
            'elapsed_ms', extract(epoch FROM clock_timestamp() - started_at) * 1000,
            'memory_bytes', NULL,
            'temporary_storage_bytes', 0),
        'findings', CASE WHEN comparison_complete THEN
            jsonb_build_array(pgreact_internal.m34_finding(
                'M34_NO_EFFECT', 'INFO', target_name, '<comparison>',
                'comparison completed without changing authoritative state',
                'No deployment or run is required to inspect this result.'))
            ELSE jsonb_build_array(pgreact_internal.m34_finding(
                'M34_COMPARISON_INCOMPLETE', 'WARNING', target_name, '<comparison>',
                'evidence was truncated at the requested limit',
                'Increase evidence_limit or inspect the relational result stream.'))
            END,
        'current', pgreact_internal.m34_raw_rows(
            current_rows, current_count, evidence_limit) -> 'rows',
        'proposed', pgreact_internal.m34_raw_rows(
            proposed_rows, proposed_count, evidence_limit) -> 'rows',
        'delta', pgreact_internal.m34_raw_rows(
            delta_rows,
            jsonb_array_length(delta_rows),
            evidence_limit) -> 'rows',
        'lifecycle', pgreact_internal.m34_raw_rows(
            lifecycle_rows,
            jsonb_array_length(lifecycle_rows),
            evidence_limit) -> 'rows',
        'work', pgreact_internal.m34_raw_rows(
            work_rows,
            jsonb_array_length(work_rows),
            evidence_limit) -> 'rows',
        'truncated', NOT comparison_complete);
END
$m34$;

CREATE OR REPLACE FUNCTION pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
    SELECT pgreact_internal.m34_compare($1, $2, $3)
$m34$;

CREATE OR REPLACE FUNCTION pgreact.compare_results(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
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
    declaration_digest text
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m34$
WITH comparison AS (
    SELECT pgreact.compare($1, $2, $3) AS value
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
       (comparison.value -> 'evidence' ->> 'sampled_time')::timestamptz,
       (comparison.value -> 'evidence' ->> 'source_frontier')::timestamptz,
       comparison.value -> 'evidence' ->> 'declaration_digest'
FROM comparison
JOIN rows ON true
$m34$;

REVOKE ALL ON FUNCTION pgreact_internal.m34_finding(text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_authoritative_checksum() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_require_source(oid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_raw_rows(jsonb, bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_rule_rows(oid, name, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_current_rule_rows(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_decision_rows(oid, name, name, name, name[], integer, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_current_decision_rows(text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_policy_rows(jsonb, jsonb, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_delta(jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m34_compare(pgreact_api.declaration, pgreact_api.target, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb) FROM PUBLIC;

DO $m34$
DECLARE role_row record;
BEGIN
    FOR role_row IN
        SELECT role_oid::regrole AS role_name
        FROM pgreact_internal.application_roles
        WHERE role_kind IN ('author', 'operator', 'reader')
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb), '
            'pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb) TO %I',
            role_row.role_name::text);
    END LOOP;
END
$m34$;

COMMENT ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb) IS
    'M34 bounded read-only comparison of a proposed declaration with one deployed target';
COMMENT ON FUNCTION pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb) IS
    'M34 relational current, proposed, and delta rows for a read-only comparison';
COMMENT ON EXTENSION pg_react IS
    'M34 deployment-impact simulation: bounded read-only comparison over current authoritative state';
