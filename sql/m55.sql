-- M55 / pg-react 0.44.0: target-scoped comparison provenance and one-pass
-- rule-source validation. Historical installation files remain immutable.

CREATE OR REPLACE FUNCTION pgreact_internal.m55_source_checksum(
    normalized jsonb
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m55$
DECLARE source_name text;
    source_oid oid;
    key_column name;
BEGIN
    source_name := CASE normalized ->> 'kind'
        WHEN 'rule' THEN normalized -> 'spec' ->> 'condition'
        WHEN 'decision_program' THEN normalized -> 'spec' ->> 'candidate_relation'
        WHEN 'policy_set' THEN normalized -> 'spec' -> 'applicability' ->> 'relation'
    END;
    key_column := CASE normalized ->> 'kind'
        WHEN 'rule' THEN (normalized -> 'spec' ->> 'semantic_key')::name
        WHEN 'decision_program' THEN (normalized -> 'spec' ->> 'candidate_key')::name
        WHEN 'policy_set' THEN
            (normalized -> 'spec' -> 'applicability' -> 'subject_keys' ->> 0)::name
    END;
    source_oid := to_regclass(source_name);
    IF source_oid IS NULL OR key_column IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN pgreact_internal.m35_source_checksum(source_oid, key_column);
END
$m55$;

CREATE OR REPLACE FUNCTION pgreact_internal.m55_target_provenance(
    target_kind text,
    target_name text,
    target_version text,
    proposed_normalized jsonb
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m55$
DECLARE current_normalized jsonb;
    current_version text;
    source_oid oid;
    key_column name;
    source_checksum text;
    runtime_rows jsonb;
BEGIN
    IF target_kind = 'policy_set' THEN
        SELECT version_row.normalized, version_row.version,
               version_row.applicability_source_oid, version_row.subject_key
        INTO current_normalized, current_version, source_oid, key_column
        FROM pgreact_internal.policy_set_versions version_row
        JOIN pgreact_internal.policy_sets set_row
          USING (policy_set_id)
        WHERE set_row.set_name = target_name
          AND version_row.state = 'DEPLOYED'
          AND (target_version IS NULL OR version_row.version = target_version)
        ORDER BY version_row.valid_from DESC, version_row.created_at DESC
        LIMIT 1;
    ELSE
        SELECT row_data.normalized
        INTO current_normalized
        FROM pgreact_internal.api_declarations row_data
        WHERE row_data.kind = target_kind
          AND row_data.object_name = target_name
          AND row_data.state = 'DEPLOYED';
        current_version := COALESCE(target_version, '1');
        IF target_kind = 'rule' THEN
            SELECT version_row.source_view_oid, version_row.key_column
            INTO source_oid, key_column
            FROM pgreact_internal.rule_versions version_row
            JOIN pgreact_internal.rules rule_row USING (rule_id)
            WHERE rule_row.rule_name = target_name
              AND version_row.state <> 'REMOVED'
            ORDER BY version_row.created_at DESC
            LIMIT 1;
        ELSIF target_kind = 'decision_program' THEN
            SELECT to_regclass(decision_row.candidate_relation),
                   decision_row.candidate_key_column
            INTO source_oid, key_column
            FROM pgreact.decisions decision_row
            WHERE decision_row.program_name = target_name
            ORDER BY decision_row.version_no DESC
            LIMIT 1;
        END IF;
    END IF;
    IF current_normalized IS NULL THEN
        RETURN NULL;
    END IF;
    IF source_oid IS NOT NULL AND key_column IS NOT NULL THEN
        source_checksum := pgreact_internal.m35_source_checksum(source_oid, key_column);
    END IF;
    IF target_kind = 'rule' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.activation_id), '[]'::jsonb)
        INTO runtime_rows
        FROM pgreact.matches row_data
        WHERE row_data.name = target_name;
    ELSIF target_kind = 'decision_program' THEN
        SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.subject_key), '[]'::jsonb)
        INTO runtime_rows
        FROM pgreact.decision_winners row_data
        WHERE row_data.program_name = target_name;
    ELSE
        SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.subject_identity), '[]'::jsonb)
        INTO runtime_rows
        FROM pgreact.policy_set_eligible_subjects row_data
        WHERE row_data.set_name = target_name
          AND row_data.version = current_version;
    END IF;
    RETURN encode(sha256(convert_to(jsonb_build_object(
        'frontier', (SELECT frontier FROM pgreact_internal.clock_frontier WHERE singleton),
        'target', jsonb_build_object(
            'kind', target_kind, 'name', target_name, 'version', current_version,
            'normalized', current_normalized),
        'source_checksum', source_checksum,
        'proposed_source_checksum', pgreact_internal.m55_source_checksum(proposed_normalized),
        'runtime', runtime_rows)::text, 'UTF8')), 'hex');
END
$m55$;

CREATE OR REPLACE FUNCTION pgreact_internal.m55_full_authoritative_checksum()
RETURNS text
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m55$
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
$m55$;

CREATE OR REPLACE FUNCTION pgreact_internal.m34_authoritative_checksum()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m55$
DECLARE context jsonb;
BEGIN
    context := NULLIF(current_setting('pgreact.compare_target', true), '')::jsonb;
    IF jsonb_typeof(context) = 'object' THEN
        RETURN pgreact_internal.m55_target_provenance(
            context ->> 'kind', context ->> 'name', context ->> 'version',
            context -> 'proposed');
    END IF;
    RETURN pgreact_internal.m55_full_authoritative_checksum();
END
$m55$;

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
AS $m55$
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
    EXECUTE format(
        'WITH source AS MATERIALIZED (SELECT * FROM %2$s),
              metrics AS (
                  SELECT count(*) AS total_count,
                         count(*) FILTER (WHERE %1$I IS NULL) AS null_count
                  FROM source
              ),
              duplicates AS (
                  SELECT count(*) AS duplicate_count
                  FROM (
                      SELECT %1$I FROM source
                      GROUP BY %1$I HAVING count(*) > 1
                  ) duplicate_rows
              ),
              limited AS (
                  SELECT * FROM source
                  ORDER BY %1$I
                  LIMIT ($1 + 1)
              )
         SELECT metrics.total_count, metrics.null_count, duplicates.duplicate_count,
                COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        ''subject_key'', s.%1$I::text,
                        ''result_key'', s.%1$I::text,
                        ''state'', ''MATCH'',
                        ''value'', to_jsonb(s),
                        ''work'', jsonb_build_object(''would_be_work'', true),
                        ''evidence'', jsonb_build_object(
                            ''source'', $2, ''complete'', true))
                        ORDER BY s.%1$I)
                    FROM limited s), ''[]''::jsonb)
         FROM metrics, duplicates',
        key_column, source_oid::regclass)
    INTO total_count, null_count, duplicate_count, rows
    USING evidence_limit, source_label;
    IF null_count > 0 THEN
        RAISE EXCEPTION 'M34_SOURCE_DRIFT: rule source % contains null keys', source_oid::regclass;
    END IF;
    IF duplicate_count > 0 THEN
        RAISE EXCEPTION 'M34_PROPOSAL_DUPLICATE: rule source % contains duplicate keys',
            source_oid::regclass;
    END IF;
    RETURN jsonb_build_object(
        'rows', rows,
        'rows_considered', total_count,
        'truncated', total_count > evidence_limit);
END
$m55$;

CREATE OR REPLACE FUNCTION pgreact_internal.m55_mark_compare_result(
    result jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m55$
    SELECT CASE WHEN $1 ? 'evidence' OR $1 ? 'snapshot' THEN
        $1 || jsonb_build_object(
            'contract_version', 55,
            'evidence', CASE WHEN jsonb_typeof($1 -> 'evidence') = 'object' THEN
                ($1 -> 'evidence') || jsonb_build_object(
                    'provenance', jsonb_build_object(
                        'contract_version', 1,
                        'scope', 'target',
                        'before', COALESCE(
                            $1 -> 'evidence' ->> 'authoritative_checksum_before',
                            $1 -> 'snapshot' ->> 'authoritative_checksum_before'),
                        'after', COALESCE(
                            $1 -> 'evidence' ->> 'authoritative_checksum_after',
                            $1 -> 'snapshot' ->> 'authoritative_checksum_after')))
                ELSE $1 -> 'evidence' END,
            'snapshot', CASE WHEN jsonb_typeof($1 -> 'snapshot') = 'object' THEN
                ($1 -> 'snapshot') || jsonb_build_object(
                    'provenance', jsonb_build_object(
                        'contract_version', 1,
                        'scope', 'target',
                        'before', COALESCE(
                            $1 -> 'snapshot' ->> 'authoritative_checksum_before',
                            $1 -> 'evidence' ->> 'authoritative_checksum_before'),
                        'after', COALESCE(
                            $1 -> 'snapshot' ->> 'authoritative_checksum_after',
                            $1 -> 'evidence' ->> 'authoritative_checksum_after')))
                ELSE $1 -> 'snapshot' END)
        ELSE $1 END
$m55$;

CREATE OR REPLACE FUNCTION pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m55$
DECLARE previous_context text := current_setting('pgreact.compare_target', true);
    result jsonb;
BEGIN
    PERFORM set_config('pgreact.compare_target', jsonb_build_object(
        'kind', (deployed).kind, 'name', (deployed).name, 'version', (deployed).version,
        'proposed', pgreact_internal.m28_normalize(proposed))::text, true);
    BEGIN
        result := CASE WHEN pgreact_internal.m38_requested(options)
            THEN pgreact_internal.m38_annotate_compare(
                pgreact_internal.m34_compare(
                    proposed, deployed, pgreact_internal.m38_strip_options(options)),
                'compare')
            ELSE pgreact_internal.m34_compare(
                proposed, deployed, pgreact_internal.m38_strip_options(options))
        END;
        result := pgreact_internal.m55_mark_compare_result(result);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('pgreact.compare_target', COALESCE(previous_context, ''), true);
        RAISE;
    END;
    PERFORM set_config('pgreact.compare_target', COALESCE(previous_context, ''), true);
    RETURN result;
END
$m55$;

CREATE OR REPLACE FUNCTION pgreact.compare(
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
AS $m55$
DECLARE previous_context text := current_setting('pgreact.compare_target', true);
    result jsonb;
BEGIN
    PERFORM set_config('pgreact.compare_target', jsonb_build_object(
        'kind', (deployed).kind, 'name', (deployed).name, 'version', (deployed).version,
        'proposed', pgreact_internal.m28_normalize(proposed))::text, true);
    BEGIN
        result := CASE WHEN pgreact_internal.m38_requested(options)
            THEN pgreact_internal.m38_annotate_compare(
                pgreact_internal.m35_compare(
                    proposed, deployed, change_set,
                    pgreact_internal.m38_strip_options(options)),
                'compare')
            ELSE pgreact_internal.m35_compare(
                proposed, deployed, change_set,
                pgreact_internal.m38_strip_options(options))
        END;
        result := pgreact_internal.m55_mark_compare_result(result);
    EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('pgreact.compare_target', COALESCE(previous_context, ''), true);
        RAISE;
    END;
    PERFORM set_config('pgreact.compare_target', COALESCE(previous_context, ''), true);
    RETURN result;
END
$m55$;

COMMENT ON FUNCTION pgreact_internal.m55_target_provenance(text, text, text, jsonb) IS
    'M55 target-scoped provenance for comparison; unrelated runtime history is excluded';
COMMENT ON FUNCTION pgreact_internal.m34_rule_rows(oid, name, text, integer) IS
    'M55 one-pass rule-source validation and bounded evidence collection';
COMMENT ON FUNCTION pgreact_internal.m55_mark_compare_result(jsonb) IS
    'M55 additive comparison evidence contract with target-scoped provenance';
COMMENT ON EXTENSION pg_react IS
    '0.44.0 measured comparison provenance and SQL maintenance release';
