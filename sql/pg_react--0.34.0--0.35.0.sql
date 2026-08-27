-- M38 bounded why-changed evidence over the M34-M37 result contracts.

CREATE OR REPLACE FUNCTION pgreact_internal.m38_finding(
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
AS $m38$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'target', $3,
        'field', $4,
        'message', $5,
        'hint', $6,
        'details', COALESCE($7, '{}'::jsonb))
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_finding_registry()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m38$
SELECT jsonb_build_array(
    jsonb_build_object('code', 'M38_OPTIONS_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M38_UNKNOWN_FIELD', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M38_EVIDENCE_UNAVAILABLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M38_EVIDENCE_PARTIAL', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M38_EVIDENCE_UNSUPPORTED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M38_EVIDENCE_AMBIGUOUS', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M38_EVIDENCE_CYCLIC', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M38_EVIDENCE_LIMIT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M38_NO_EFFECT', 'severity', 'INFO'))
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_requested(options jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $m38$
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object'
       OR NOT options ? 'why_changed' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(options -> 'why_changed') IS DISTINCT FROM 'boolean' THEN
        RAISE EXCEPTION 'M38_OPTIONS_INVALID: why_changed must be a boolean';
    END IF;
    RETURN (options ->> 'why_changed')::boolean;
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_strip_options(options jsonb)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m38$
    SELECT CASE WHEN jsonb_typeof($1) = 'object' THEN $1 - 'why_changed' ELSE $1 END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_cause_kind(path text)
RETURNS text
LANGUAGE SQL
IMMUTABLE
STRICT
AS $m38$
    SELECT CASE
        WHEN lower($1) LIKE '%work%' THEN 'would_be_work'
        WHEN lower($1) LIKE '%winner%' THEN 'decision_winner'
        WHEN lower($1) LIKE '%candidate%' OR lower($1) LIKE '%competitor%' THEN 'decision_candidate'
        WHEN lower($1) LIKE '%applicability%' OR lower($1) LIKE '%subject%' THEN 'applicability'
        WHEN lower($1) LIKE '%parameter%' THEN 'parameter'
        WHEN lower($1) LIKE '%threshold%' OR lower($1) LIKE '%aggregate%' THEN 'threshold'
        WHEN lower($1) LIKE '%deadline%' OR lower($1) LIKE '%window%' OR lower($1) LIKE '%effective%' THEN 'deadline'
        WHEN lower($1) LIKE '%support%' OR lower($1) LIKE '%provenance%' THEN 'positive_support'
        WHEN lower($1) LIKE '%derived%' THEN 'derived_fact'
        WHEN lower($1) LIKE '%revision%' OR lower($1) LIKE '%generation%' OR lower($1) LIKE '%state%' THEN 'lifecycle_revision'
        ELSE 'source_fact'
    END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_causes(
    baseline jsonb,
    candidate jsonb,
    baseline_evidence jsonb,
    candidate_evidence jsonb,
    baseline_work jsonb,
    candidate_work jsonb,
    change_kind text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    field_name text;
    before_value jsonb;
    after_value jsonb;
    causes jsonb := '[]'::jsonb;
    path text;
BEGIN
    IF jsonb_typeof(baseline) = 'object' AND jsonb_typeof(candidate) = 'object' THEN
        FOR field_name IN
            SELECT key
            FROM (
                SELECT jsonb_object_keys(baseline) AS key
                UNION
                SELECT jsonb_object_keys(candidate) AS key
            ) fields
            ORDER BY key
        LOOP
            before_value := baseline -> field_name;
            after_value := candidate -> field_name;
            IF before_value IS DISTINCT FROM after_value THEN
                path := 'value.' || field_name;
                causes := causes || jsonb_build_array(jsonb_build_object(
                    'kind', pgreact_internal.m38_cause_kind(path),
                    'direction', CASE
                        WHEN before_value IS NULL THEN 'added'
                        WHEN after_value IS NULL THEN 'removed'
                        ELSE 'changed' END,
                    'path', path,
                    'before', before_value,
                    'after', after_value,
                    'public_evidence', jsonb_build_object(
                        'baseline', COALESCE(baseline_evidence, '{}'::jsonb),
                        'candidate', COALESCE(candidate_evidence, '{}'::jsonb))));
            END IF;
        END LOOP;
    ELSIF baseline IS DISTINCT FROM candidate THEN
        causes := causes || jsonb_build_array(jsonb_build_object(
            'kind', 'source_fact',
            'direction', CASE
                WHEN baseline IS NULL THEN 'added'
                WHEN candidate IS NULL THEN 'removed'
                ELSE 'changed' END,
            'path', 'value',
            'before', baseline,
            'after', candidate,
            'public_evidence', jsonb_build_object(
                'baseline', COALESCE(baseline_evidence, '{}'::jsonb),
                'candidate', COALESCE(candidate_evidence, '{}'::jsonb))));
    END IF;
    IF baseline_work IS DISTINCT FROM candidate_work THEN
        causes := causes || jsonb_build_array(jsonb_build_object(
            'kind', 'would_be_work',
            'direction', CASE
                WHEN baseline_work IS NULL THEN 'added'
                WHEN candidate_work IS NULL THEN 'removed'
                ELSE 'changed' END,
            'path', 'work',
            'before', baseline_work,
            'after', candidate_work,
            'public_evidence', jsonb_build_object(
                'baseline', COALESCE(baseline_evidence, '{}'::jsonb),
                'candidate', COALESCE(candidate_evidence, '{}'::jsonb))));
    END IF;
    IF jsonb_array_length(causes) = 0 AND change_kind <> 'UNCHANGED' THEN
        causes := jsonb_build_array(jsonb_build_object(
            'kind', 'lifecycle_revision',
            'direction', 'changed',
            'path', 'state',
            'before', baseline,
            'after', candidate,
            'public_evidence', jsonb_build_object(
                'baseline', COALESCE(baseline_evidence, '{}'::jsonb),
                'candidate', COALESCE(candidate_evidence, '{}'::jsonb))));
    END IF;
    RETURN causes;
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_explain_row(
    operation text,
    result_set text,
    ordinal text,
    subject_key text,
    result_key text,
    change_kind text,
    baseline_side text,
    candidate_side text,
    baseline jsonb,
    candidate jsonb,
    baseline_work jsonb,
    candidate_work jsonb,
    baseline_evidence jsonb,
    candidate_evidence jsonb,
    comparison_point jsonb,
    origin_state text,
    originating_result_digest text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    causes jsonb;
    semantic jsonb;
    state text;
    started_at timestamptz := clock_timestamp();
BEGIN
    IF change_kind = 'UNCHANGED' THEN
        RETURN NULL;
    END IF;
    causes := pgreact_internal.m38_causes(
        baseline, candidate, baseline_evidence, candidate_evidence,
        baseline_work, candidate_work, change_kind);
    state := CASE
        WHEN baseline_evidence IS NULL AND candidate_evidence IS NULL THEN 'unavailable'
        WHEN origin_state IS DISTINCT FROM 'ready' THEN 'partial'
        ELSE 'complete'
    END;
    semantic := jsonb_build_object(
        'version', 1,
        'state', state,
        'originating_operation', operation,
        'side_pair', jsonb_build_object(
            'baseline', baseline_side, 'candidate', candidate_side),
        'result', jsonb_build_object(
            'result_set', result_set,
            'ordinal', ordinal,
            'subject_key', subject_key,
            'result_key', result_key,
            'change', change_kind),
        'comparison_point', comparison_point,
        'causes', causes,
        'evidence', jsonb_build_object(
            'baseline', COALESCE(baseline_evidence, '{}'::jsonb),
            'candidate', COALESCE(candidate_evidence, '{}'::jsonb),
            'path_is_public', true,
            'causes_exact', state = 'complete'),
        'originating_result_digest', originating_result_digest,
        'cost', jsonb_build_object(
            'cause_discovery', jsonb_array_length(causes),
            'evidence_expansion', jsonb_array_length(causes),
            'path_depth', CASE WHEN jsonb_array_length(causes) > 0 THEN 1 ELSE 0 END,
            'returned_nodes', jsonb_array_length(causes)));
    RETURN semantic || jsonb_build_object(
        'explanation_digest', encode(sha256(convert_to(semantic::text, 'UTF8')), 'hex'),
        'cost', semantic -> 'cost' || jsonb_build_object(
            'elapsed_ms', extract(epoch FROM clock_timestamp() - started_at) * 1000));
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_annotate_rows(
    rows jsonb,
    operation text,
    baseline_side text,
    candidate_side text,
    result_set_name text,
    context jsonb,
    row_mode text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    row_item jsonb;
    annotated jsonb;
    why jsonb;
    output_rows jsonb := '[]'::jsonb;
    change_kind text;
    baseline_value jsonb;
    candidate_value jsonb;
    baseline_work jsonb;
    candidate_work jsonb;
    baseline_evidence jsonb;
    candidate_evidence jsonb;
    ordinal text;
    point jsonb;
    digest text;
BEGIN
    digest := encode(sha256(convert_to(context::text, 'UTF8')), 'hex');
    FOR row_item IN SELECT value FROM jsonb_array_elements(COALESCE(rows, '[]'::jsonb)) item(value)
    LOOP
        change_kind := row_item ->> 'change';
        IF change_kind IS NULL OR change_kind = 'UNCHANGED' THEN
            output_rows := output_rows || jsonb_build_array(row_item);
            CONTINUE;
        END IF;
        IF row_mode = 'backtest' THEN
            baseline_value := row_item -> 'baseline' -> 'value';
            candidate_value := row_item -> 'candidate' -> 'value';
            baseline_work := row_item -> 'baseline' -> 'work';
            candidate_work := row_item -> 'candidate' -> 'work';
            baseline_evidence := row_item -> 'baseline' -> 'evidence';
            candidate_evidence := row_item -> 'candidate' -> 'evidence';
        ELSE
            baseline_value := row_item -> 'current_value';
            candidate_value := row_item -> 'proposed_value';
            baseline_work := row_item -> 'current_work';
            candidate_work := row_item -> 'proposed_work';
            baseline_evidence := row_item -> 'evidence' -> 'current';
            candidate_evidence := row_item -> 'evidence' -> 'proposed';
        END IF;
        ordinal := COALESCE(
            row_item ->> 'ordinal',
            context ->> 'ordinal',
            context -> 'step' ->> 'ordinal');
        point := jsonb_build_object(
            'result_set', result_set_name,
            'ordinal', ordinal,
            'sampled_time', COALESCE(
                context ->> 'sampled_time',
                context -> 'evidence' ->> 'sampled_time',
                context -> 'snapshot' ->> 'sampled_time',
                context -> 'step' ->> 'sampled_time'),
            'source_frontier', COALESCE(
                context ->> 'source_frontier',
                context -> 'evidence' ->> 'source_frontier',
                context -> 'snapshot' ->> 'source_frontier',
                context -> 'step' ->> 'source_frontier'),
            'event_time_watermark', COALESCE(
                context ->> 'event_time_watermark',
                context -> 'step' ->> 'event_time_watermark'));
        why := pgreact_internal.m38_explain_row(
            operation, result_set_name, ordinal,
            row_item ->> 'subject_key',
            COALESCE(row_item ->> 'result_key', row_item ->> 'subject_key'),
            change_kind, baseline_side, candidate_side,
            baseline_value, candidate_value,
            baseline_work, candidate_work,
            baseline_evidence, candidate_evidence,
            point, context ->> 'state', digest);
        annotated := row_item || jsonb_build_object(
            'why_changed', why,
            'evidence', COALESCE(row_item -> 'evidence', '{}'::jsonb)
                || jsonb_build_object('why_changed', why));
        IF row_mode = 'backtest' THEN
            annotated := annotated || jsonb_build_object(
                'baseline', COALESCE(row_item -> 'baseline', '{}'::jsonb)
                    || jsonb_build_object('evidence',
                        COALESCE(row_item -> 'baseline' -> 'evidence', '{}'::jsonb)
                            || jsonb_build_object('why_changed', why)),
                'candidate', COALESCE(row_item -> 'candidate', '{}'::jsonb)
                    || jsonb_build_object('evidence',
                        COALESCE(row_item -> 'candidate' -> 'evidence', '{}'::jsonb)
                            || jsonb_build_object('why_changed', why)));
        END IF;
        output_rows := output_rows || jsonb_build_array(annotated);
    END LOOP;
    RETURN output_rows;
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_metadata(
    rows jsonb,
    complete boolean,
    evidence_limit integer,
    originating_result_digest text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    semantic jsonb;
    row_count bigint;
    cause_count bigint;
    started_at timestamptz := clock_timestamp();
BEGIN
    SELECT count(*), COALESCE(sum(jsonb_array_length(value -> 'why_changed' -> 'causes')), 0)
    INTO row_count, cause_count
    FROM jsonb_array_elements(COALESCE(rows, '[]'::jsonb)) item(value)
    WHERE value ? 'why_changed';
    semantic := jsonb_build_object(
        'requested', true,
        'state', CASE WHEN complete THEN 'complete' ELSE 'partial' END,
        'causes_exact', complete,
        'rows_explained', row_count,
        'causes_returned', cause_count,
        'evidence_limit', evidence_limit,
        'originating_result_digest', originating_result_digest,
        'cost', jsonb_build_object(
            'cause_discovery', row_count,
            'evidence_expansion', cause_count,
            'path_depth', CASE WHEN cause_count > 0 THEN 1 ELSE 0 END,
            'returned_nodes', cause_count));
    RETURN semantic || jsonb_build_object(
        'explanation_digest', encode(sha256(convert_to(semantic::text, 'UTF8')), 'hex'),
        'cost', semantic -> 'cost' || jsonb_build_object(
            'elapsed_ms', extract(epoch FROM clock_timestamp() - started_at) * 1000));
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_finish(
    result jsonb,
    explained_rows jsonb,
    operation text,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    digest text := encode(sha256(convert_to(result::text, 'UTF8')), 'hex');
    metadata jsonb;
    complete boolean := result ->> 'state' = 'ready';
BEGIN
    metadata := pgreact_internal.m38_metadata(
        explained_rows, complete, evidence_limit, digest);
    RETURN result || jsonb_build_object(
        'contract_version', 25,
        'evidence', COALESCE(result -> 'evidence', '{}'::jsonb)
            || jsonb_build_object('why_changed', metadata),
        'findings', COALESCE(result -> 'findings', '[]'::jsonb)
            || jsonb_build_array(pgreact_internal.m38_finding(
                CASE WHEN complete THEN 'M38_NO_EFFECT' ELSE 'M38_EVIDENCE_PARTIAL' END,
                CASE WHEN complete THEN 'INFO' ELSE 'WARNING' END,
                COALESCE(result -> 'target' ->> 'name', '<comparison>'),
                '<why_changed>',
                CASE WHEN complete
                    THEN 'why-changed evidence completed without changing authoritative state'
                    ELSE 'why-changed evidence is bounded and incomplete'
                END,
                'Increase the evidence limit or use the originating result to inspect the bound.')));
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_annotate_compare(
    result jsonb,
    operation text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    delta jsonb;
    lifecycle jsonb;
    explained jsonb;
    evidence_limit integer := COALESCE((result -> 'evidence' ->> 'evidence_limit')::integer, 100);
BEGIN
    delta := pgreact_internal.m38_annotate_rows(
        result -> 'delta', operation, 'current', 'proposed', 'delta', result, 'comparison');
    lifecycle := pgreact_internal.m38_annotate_rows(
        result -> 'lifecycle', operation, 'current', 'proposed', 'lifecycle', result, 'comparison');
    explained := COALESCE(delta, '[]'::jsonb) || COALESCE(lifecycle, '[]'::jsonb);
    result := result || jsonb_build_object('delta', delta, 'lifecycle', lifecycle);
    RETURN pgreact_internal.m38_finish(result, explained, operation, evidence_limit);
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_annotate_replay(result jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    step_item jsonb;
    step_output jsonb;
    delta jsonb;
    lifecycle jsonb;
    steps jsonb := '[]'::jsonb;
    explained jsonb := '[]'::jsonb;
    evidence_limit integer := COALESCE((result -> 'evidence' ->> 'evidence_limit')::integer, 100);
BEGIN
    FOR step_item IN SELECT value FROM jsonb_array_elements(COALESCE(result -> 'steps', '[]'::jsonb)) item(value)
    LOOP
        step_output := result || jsonb_build_object('step', step_item);
        delta := pgreact_internal.m38_annotate_rows(
            step_item -> 'delta', 'replay', 'previous', 'current',
            'delta', step_output, 'comparison');
        lifecycle := pgreact_internal.m38_annotate_rows(
            step_item -> 'lifecycle', 'replay', 'previous', 'current',
            'lifecycle', step_output, 'comparison');
        step_item := step_item || jsonb_build_object('delta', delta, 'lifecycle', lifecycle);
        steps := steps || jsonb_build_array(step_item);
        explained := explained || COALESCE(delta, '[]'::jsonb) || COALESCE(lifecycle, '[]'::jsonb);
    END LOOP;
    result := result || jsonb_build_object('steps', steps);
    RETURN pgreact_internal.m38_finish(result, explained, 'replay', evidence_limit);
END
$m38$;

CREATE OR REPLACE FUNCTION pgreact_internal.m38_annotate_backtest(result jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
DECLARE
    rows jsonb;
    differences jsonb;
    evidence_limit integer := COALESCE((result -> 'evidence' ->> 'evidence_limit')::integer, 100);
BEGIN
    rows := pgreact_internal.m38_annotate_rows(
        result -> 'differences' -> 'rows', 'backtest',
        'baseline', 'candidate', 'difference', result, 'backtest');
    differences := COALESCE(result -> 'differences', '{}'::jsonb)
        || jsonb_build_object('rows', rows);
    result := result || jsonb_build_object('differences', differences);
    RETURN pgreact_internal.m38_finish(result, rows, 'backtest', evidence_limit);
END
$m38$;

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
AS $m38$
    SELECT CASE WHEN pgreact_internal.m38_requested($3)
        THEN pgreact_internal.m38_annotate_compare(
            pgreact_internal.m34_compare($1, $2, pgreact_internal.m38_strip_options($3)),
            'compare')
        ELSE pgreact_internal.m34_compare($1, $2, pgreact_internal.m38_strip_options($3))
    END
$m38$;

CREATE OR REPLACE FUNCTION pgreact.compare(
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
AS $m38$
    SELECT CASE WHEN pgreact_internal.m38_requested($4)
        THEN pgreact_internal.m38_annotate_compare(
            pgreact_internal.m35_compare($1, $2, $3, pgreact_internal.m38_strip_options($4)),
            'compare')
        ELSE pgreact_internal.m35_compare($1, $2, $3, pgreact_internal.m38_strip_options($4))
    END
$m38$;

CREATE OR REPLACE FUNCTION pgreact.replay(
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
AS $m38$
    SELECT CASE WHEN pgreact_internal.m38_requested($5)
        THEN pgreact_internal.m38_annotate_replay(
            pgreact_internal.m36_replay($1, $2, $3, $4, pgreact_internal.m38_strip_options($5)))
        ELSE pgreact_internal.m36_replay($1, $2, $3, $4, pgreact_internal.m38_strip_options($5))
    END
$m38$;

CREATE OR REPLACE FUNCTION pgreact.backtest(
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
AS $m38$
    SELECT CASE WHEN pgreact_internal.m38_requested($5)
        THEN pgreact_internal.m38_annotate_backtest(
            pgreact_internal.m37_backtest($1, $2, $3, $4, pgreact_internal.m38_strip_options($5)))
        ELSE pgreact_internal.m37_backtest($1, $2, $3, $4, pgreact_internal.m38_strip_options($5))
    END
$m38$;

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
AS $m38$
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
$m38$;

CREATE OR REPLACE FUNCTION pgreact.compare_results(
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
AS $m38$
WITH comparison AS (
    SELECT pgreact.compare($1, $2, $3, $4) AS value
), rows AS (
    SELECT 'current'::text AS result_set, item.value FROM comparison, jsonb_array_elements(comparison.value -> 'current') item(value)
    UNION ALL SELECT 'proposed', item.value FROM comparison, jsonb_array_elements(comparison.value -> 'proposed') item(value)
    UNION ALL SELECT 'delta', item.value FROM comparison, jsonb_array_elements(comparison.value -> 'delta') item(value)
    UNION ALL SELECT 'lifecycle', item.value FROM comparison, jsonb_array_elements(comparison.value -> 'lifecycle') item(value)
    UNION ALL SELECT 'work', item.value FROM comparison, jsonb_array_elements(comparison.value -> 'work') item(value)
)
SELECT result_set,
       comparison.value -> 'target' ->> 'kind', comparison.value -> 'target' ->> 'name',
       rows.value ->> 'subject_key', rows.value ->> 'result_key', rows.value ->> 'state',
       rows.value ->> 'change', rows.value -> 'current_value', rows.value -> 'proposed_value',
       rows.value -> 'evidence', (comparison.value -> 'evidence' ->> 'complete')::boolean,
       (comparison.value -> 'snapshot' ->> 'sampled_time')::timestamptz,
       (comparison.value -> 'snapshot' ->> 'source_frontier')::timestamptz,
       comparison.value -> 'evidence' ->> 'declaration_digest',
       comparison.value -> 'evidence' ->> 'change_set_digest',
       comparison.value -> 'snapshot' ->> 'source_checksum_before',
       comparison.value -> 'snapshot' ->> 'source_checksum_after'
FROM comparison
JOIN rows ON true
$m38$;

CREATE OR REPLACE FUNCTION pgreact.replay_results(
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
AS $m38$
WITH replay AS (
    SELECT pgreact.replay($1, $2, $3, $4, $5) AS value
), envelopes AS (
    SELECT value -> 'initial' AS envelope FROM replay
    UNION ALL SELECT item.value FROM replay, jsonb_array_elements(value -> 'steps') item(value)
    UNION ALL SELECT value -> 'final' FROM replay
), rows AS (
    SELECT envelope, envelope ->> 'result_set' AS result_set,
           (envelope ->> 'ordinal')::bigint AS step_ordinal, item.value
    FROM envelopes, jsonb_array_elements(envelope -> 'rows') item(value)
    UNION ALL
    SELECT envelope, 'delta', (envelope ->> 'ordinal')::bigint, item.value
    FROM envelopes, jsonb_array_elements(envelope -> 'delta') item(value)
    WHERE envelope ->> 'result_set' = 'step'
)
SELECT result_set, step_ordinal,
       replay.value -> 'target' ->> 'kind', replay.value -> 'target' ->> 'name',
       rows.value ->> 'subject_key', rows.value ->> 'result_key', rows.value ->> 'state',
       rows.value ->> 'change', rows.value -> 'current_value', rows.value -> 'proposed_value',
       rows.value -> 'evidence', (rows.envelope ->> 'complete')::boolean,
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
$m38$;

CREATE OR REPLACE FUNCTION pgreact.backtest_results(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    initial_snapshot jsonb,
    replay_steps jsonb,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
    side text,
    result_set text,
    step_ordinal bigint,
    kind text,
    name text,
    subject_key text,
    result_key text,
    state text,
    change text,
    baseline_value jsonb,
    candidate_value jsonb,
    baseline_work jsonb,
    candidate_work jsonb,
    baseline_evidence jsonb,
    candidate_evidence jsonb,
    complete boolean,
    sampled_time timestamptz,
    source_frontier timestamptz,
    event_time_watermark timestamptz,
    baseline_declaration_digest text,
    candidate_declaration_digest text,
    snapshot_digest text,
    replay_digest text,
    comparison_digest text
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m38$
WITH backtest AS (
    SELECT pgreact.backtest($1, $2, $3, $4, $5) AS value
), sides AS (
    SELECT 'baseline'::text AS side, value, value -> 'baseline' AS replay FROM backtest
    UNION ALL SELECT 'candidate', value, value -> 'candidate' FROM backtest
), envelopes AS (
    SELECT side, value, replay, replay -> 'initial' AS envelope FROM sides
    UNION ALL SELECT sides.side, sides.value, sides.replay, item.value
    FROM sides, jsonb_array_elements(COALESCE(replay -> 'steps', '[]'::jsonb)) item(value)
    UNION ALL SELECT side, sides.value, replay, replay -> 'final' FROM sides
), side_rows AS (
    SELECT side, envelopes.value, envelope, false AS is_delta, item.value AS row_data,
           envelope ->> 'result_set' AS result_set, (envelope ->> 'ordinal')::bigint AS ordinal
    FROM envelopes, jsonb_array_elements(COALESCE(envelope -> 'rows', '[]'::jsonb)) item(value)
    UNION ALL
    SELECT side, envelopes.value, envelope, true, item.value, 'delta',
           (envelope ->> 'ordinal')::bigint
    FROM envelopes, jsonb_array_elements(COALESCE(envelope -> 'delta', '[]'::jsonb)) item(value)
    WHERE envelope ->> 'result_set' = 'step'
), result_rows AS (
    SELECT side, result_set, ordinal,
           value -> 'target' ->> 'kind' AS kind, value -> 'target' ->> 'name' AS name,
           row_data ->> 'subject_key' AS subject_key,
           COALESCE(row_data ->> 'result_key', row_data ->> 'subject_key') AS result_key,
           row_data ->> 'state' AS state,
           CASE WHEN is_delta THEN row_data ->> 'change' END AS change,
           CASE WHEN side = 'baseline' THEN CASE WHEN is_delta THEN row_data -> 'current_value' ELSE row_data -> 'value' END END AS baseline_value,
           CASE WHEN side = 'candidate' THEN CASE WHEN is_delta THEN row_data -> 'proposed_value' ELSE row_data -> 'value' END END AS candidate_value,
           CASE WHEN side = 'baseline' THEN row_data -> 'work' END AS baseline_work,
           CASE WHEN side = 'candidate' THEN row_data -> 'work' END AS candidate_work,
           CASE WHEN side = 'baseline' THEN row_data -> 'evidence' END AS baseline_evidence,
           CASE WHEN side = 'candidate' THEN row_data -> 'evidence' END AS candidate_evidence,
           (envelope ->> 'complete')::boolean AS complete,
           (envelope ->> 'sampled_time')::timestamptz AS sampled_time,
           (envelope ->> 'source_frontier')::timestamptz AS source_frontier,
           (envelope ->> 'event_time_watermark')::timestamptz AS event_time_watermark,
           value -> 'evidence' ->> 'baseline_declaration_digest' AS baseline_declaration_digest,
           value -> 'evidence' ->> 'candidate_declaration_digest' AS candidate_declaration_digest,
           value -> 'evidence' ->> 'snapshot_digest' AS snapshot_digest,
           value -> 'evidence' ->> 'replay_digest' AS replay_digest,
           value -> 'evidence' ->> 'comparison_digest' AS comparison_digest
    FROM side_rows
), difference_rows AS (
    SELECT 'difference'::text AS side, item.value ->> 'result_set' AS result_set,
           (item.value ->> 'ordinal')::bigint AS ordinal,
           backtest.value -> 'target' ->> 'kind' AS kind,
           backtest.value -> 'target' ->> 'name' AS name,
           item.value ->> 'subject_key' AS subject_key,
           item.value ->> 'result_key' AS result_key,
           item.value ->> 'state' AS state,
           item.value ->> 'change' AS change,
           item.value -> 'baseline' -> 'value' AS baseline_value,
           item.value -> 'candidate' -> 'value' AS candidate_value,
           item.value -> 'baseline' -> 'work' AS baseline_work,
           item.value -> 'candidate' -> 'work' AS candidate_work,
           item.value -> 'baseline' -> 'evidence' AS baseline_evidence,
           item.value -> 'candidate' -> 'evidence' AS candidate_evidence,
           (backtest.value ->> 'state') = 'ready' AS complete,
           NULL::timestamptz AS sampled_time, NULL::timestamptz AS source_frontier,
           NULL::timestamptz AS event_time_watermark,
           backtest.value -> 'evidence' ->> 'baseline_declaration_digest' AS baseline_declaration_digest,
           backtest.value -> 'evidence' ->> 'candidate_declaration_digest' AS candidate_declaration_digest,
           backtest.value -> 'evidence' ->> 'snapshot_digest' AS snapshot_digest,
           backtest.value -> 'evidence' ->> 'replay_digest' AS replay_digest,
           backtest.value -> 'evidence' ->> 'comparison_digest' AS comparison_digest
    FROM backtest, jsonb_array_elements(COALESCE(backtest.value -> 'differences' -> 'rows', '[]'::jsonb)) item(value)
)
SELECT * FROM result_rows
UNION ALL
SELECT * FROM difference_rows
$m38$;

REVOKE ALL ON FUNCTION pgreact_internal.m38_finding(text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_requested(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_strip_options(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_cause_kind(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_causes(jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_explain_row(text, text, text, text, text, text, text, text, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, jsonb, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_annotate_rows(jsonb, text, text, text, text, jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_metadata(jsonb, boolean, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_finish(jsonb, jsonb, text, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_annotate_compare(jsonb, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_annotate_replay(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m38_annotate_backtest(jsonb) FROM PUBLIC;

COMMENT ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb) IS
    'M38 bounded read-only comparison with optional why-changed evidence';
COMMENT ON FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb) IS
    'M38 bounded read-only hypothetical comparison with optional why-changed evidence';
COMMENT ON FUNCTION pgreact.replay(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) IS
    'M38 bounded read-only historical replay with optional why-changed evidence';
COMMENT ON FUNCTION pgreact.backtest(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) IS
    'M38 bounded read-only comparative backtest with optional why-changed evidence';
COMMENT ON EXTENSION pg_react IS
    'M38 why-changed comparison: bounded read-only causal evidence over existing result contracts';
