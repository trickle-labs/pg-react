-- M37 comparative backtesting over the M36 read-only replay evaluator.

CREATE OR REPLACE FUNCTION pgreact_internal.m37_finding(
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
AS $m37$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'target', $3,
        'field', $4,
        'message', $5,
        'hint', $6,
        'details', COALESCE($7, '{}'::jsonb))
$m37$;

CREATE OR REPLACE FUNCTION pgreact_internal.m37_finding_registry()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m37$
SELECT jsonb_build_array(
    jsonb_build_object('code', 'M37_OPTIONS_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M37_UNKNOWN_FIELD', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M37_INCOMPATIBLE_TARGET', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M37_SHARED_INPUT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M37_AUTHORITATIVE_CHANGED', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M37_COMPARISON_INCOMPLETE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M37_NO_EFFECT', 'severity', 'INFO'))
$m37$;

CREATE OR REPLACE FUNCTION pgreact_internal.m37_differences(
    baseline jsonb,
    candidate jsonb,
    evidence_limit integer
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m37$
WITH sides AS (
    SELECT 'baseline'::text AS side, $1 AS replay
    UNION ALL
    SELECT 'candidate'::text, $2
), envelopes AS (
    SELECT side, replay -> 'initial' AS envelope
    FROM sides
    UNION ALL
    SELECT side, item.value
    FROM sides
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(replay -> 'steps', '[]'::jsonb)) item(value)
    UNION ALL
    SELECT side, replay -> 'final'
    FROM sides
), side_rows AS (
    SELECT side,
           envelope ->> 'result_set' AS result_set,
           (envelope ->> 'ordinal')::bigint AS ordinal,
           item.value ->> 'subject_key' AS subject_key,
           COALESCE(item.value ->> 'result_key', item.value ->> 'subject_key') AS result_key,
           item.value AS value
    FROM envelopes
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(envelope -> 'rows', '[]'::jsonb)) item(value)
    UNION ALL
    SELECT side,
           'delta',
           (envelope ->> 'ordinal')::bigint,
           item.value ->> 'subject_key',
           COALESCE(item.value ->> 'result_key', item.value ->> 'subject_key'),
           item.value
    FROM envelopes
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(envelope -> 'delta', '[]'::jsonb)) item(value)
    WHERE envelope ->> 'result_set' = 'step'
), baseline_rows AS (
    SELECT * FROM side_rows WHERE side = 'baseline'
), candidate_rows AS (
    SELECT * FROM side_rows WHERE side = 'candidate'
), changes AS (
    SELECT COALESCE(baseline_rows.result_set, candidate_rows.result_set) AS result_set,
           COALESCE(baseline_rows.ordinal, candidate_rows.ordinal) AS ordinal,
           COALESCE(baseline_rows.subject_key, candidate_rows.subject_key) AS subject_key,
           COALESCE(baseline_rows.result_key, candidate_rows.result_key) AS result_key,
           baseline_rows.value AS baseline_value,
           candidate_rows.value AS candidate_value,
           CASE
               WHEN baseline_rows.value IS NULL THEN 'ADDED'
               WHEN candidate_rows.value IS NULL THEN 'REMOVED'
               WHEN baseline_rows.value ->> 'state' IS NOT DISTINCT FROM
                    candidate_rows.value ->> 'state'
                AND COALESCE(baseline_rows.value -> 'value',
                    jsonb_build_object('current_value', baseline_rows.value -> 'current_value',
                                       'proposed_value', baseline_rows.value -> 'proposed_value'))
                    IS NOT DISTINCT FROM COALESCE(candidate_rows.value -> 'value',
                    jsonb_build_object('current_value', candidate_rows.value -> 'current_value',
                                       'proposed_value', candidate_rows.value -> 'proposed_value'))
                AND baseline_rows.value -> 'work' IS NOT DISTINCT FROM
                    candidate_rows.value -> 'work' THEN 'UNCHANGED'
               ELSE 'CHANGED'
           END AS change
    FROM baseline_rows
    FULL JOIN candidate_rows
      ON baseline_rows.result_set = candidate_rows.result_set
     AND baseline_rows.ordinal = candidate_rows.ordinal
     AND baseline_rows.subject_key = candidate_rows.subject_key
     AND baseline_rows.result_key = candidate_rows.result_key
), limited AS (
    SELECT *
    FROM changes
    ORDER BY result_set, ordinal, subject_key, result_key
    LIMIT $3
)
SELECT jsonb_build_object(
    'rows', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
                   'result_set', result_set,
                   'ordinal', ordinal,
                   'subject_key', subject_key,
                   'result_key', result_key,
                   'change', change,
                   'state', COALESCE(candidate_value ->> 'state', baseline_value ->> 'state'),
                   'baseline', jsonb_build_object(
                       'state', baseline_value ->> 'state',
                       'value', COALESCE(baseline_value -> 'value',
                           jsonb_build_object('current_value', baseline_value -> 'current_value',
                                              'proposed_value', baseline_value -> 'proposed_value')),
                       'work', baseline_value -> 'work',
                       'evidence', baseline_value -> 'evidence'),
                   'candidate', jsonb_build_object(
                       'state', candidate_value ->> 'state',
                       'value', COALESCE(candidate_value -> 'value',
                           jsonb_build_object('current_value', candidate_value -> 'current_value',
                                              'proposed_value', candidate_value -> 'proposed_value')),
                       'work', candidate_value -> 'work',
                       'evidence', candidate_value -> 'evidence'),
                   'evidence', jsonb_build_object(
                       'baseline', baseline_value -> 'evidence',
                       'candidate', candidate_value -> 'evidence',
                       'complete', true))
                   ORDER BY result_set, ordinal, subject_key, result_key)
        FROM limited), '[]'::jsonb),
    'counts', (SELECT jsonb_build_object(
        'added', count(*) FILTER (WHERE change = 'ADDED'),
        'removed', count(*) FILTER (WHERE change = 'REMOVED'),
        'changed', count(*) FILTER (WHERE change = 'CHANGED'),
        'unchanged', count(*) FILTER (WHERE change = 'UNCHANGED'))
        FROM changes),
    'rows_considered', (SELECT count(*) FROM changes),
    'affected_subjects', (SELECT count(DISTINCT subject_key)
                          FILTER (WHERE change <> 'UNCHANGED')
                          FROM changes),
    'truncated', (SELECT count(*) > $3 FROM changes))
$m37$;

CREATE OR REPLACE FUNCTION pgreact_internal.m37_backtest(
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
AS $m37$
DECLARE
    target_kind text := (deployed).kind;
    target_name text := (deployed).name;
    baseline jsonb;
    candidate jsonb;
    differences jsonb;
    options_object jsonb := COALESCE(options, '{}'::jsonb);
    unknown_field text;
    evidence_limit integer := 100;
    complete boolean;
    comparison_digest text;
    started_at timestamptz := clock_timestamp();
BEGIN
    IF deployed IS NULL OR target_kind IS NULL OR target_name IS NULL THEN
        RAISE EXCEPTION 'M37_INCOMPATIBLE_TARGET: deployed target kind and name are required';
    END IF;
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M37_OPTIONS_INVALID: options must be a JSON object';
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_object_keys(options) AS key
    WHERE key NOT IN ('evidence_limit', 'max_steps', 'max_changes',
                      'max_snapshot_rows', 'max_total_changes')
    ORDER BY key
    LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        RAISE EXCEPTION 'M37_UNKNOWN_FIELD: option % is not supported', unknown_field;
    END IF;
    IF proposed IS NOT NULL
       AND ((proposed).kind IS DISTINCT FROM target_kind
            OR (proposed).name IS DISTINCT FROM target_name) THEN
        RAISE EXCEPTION 'M37_INCOMPATIBLE_TARGET: candidate and baseline targets must match';
    END IF;
    IF options ? 'evidence_limit' THEN
        evidence_limit := (options ->> 'evidence_limit')::integer;
    END IF;

    baseline := pgreact_internal.m36_replay(
        NULL::pgreact_api.declaration, deployed, initial_snapshot, replay_steps, options);
    candidate := pgreact_internal.m36_replay(
        proposed, deployed, initial_snapshot, replay_steps, options);

    IF baseline -> 'evidence' ->> 'snapshot_digest' IS DISTINCT FROM
       candidate -> 'evidence' ->> 'snapshot_digest'
       OR baseline -> 'evidence' ->> 'replay_digest' IS DISTINCT FROM
          candidate -> 'evidence' ->> 'replay_digest'
       OR baseline -> 'snapshot' ->> 'source_schema_fingerprint_before' IS DISTINCT FROM
          candidate -> 'snapshot' ->> 'source_schema_fingerprint_before'
       OR baseline -> 'snapshot' ->> 'authoritative_checksum_before' IS DISTINCT FROM
          candidate -> 'snapshot' ->> 'authoritative_checksum_before'
       OR baseline -> 'snapshot' ->> 'authoritative_checksum_after' IS DISTINCT FROM
          candidate -> 'snapshot' ->> 'authoritative_checksum_after' THEN
        RAISE EXCEPTION 'M37_SHARED_INPUT: baseline and candidate did not use one shared frozen history';
    END IF;
    IF baseline -> 'snapshot' ->> 'authoritative_checksum_before' IS DISTINCT FROM
       baseline -> 'snapshot' ->> 'authoritative_checksum_after'
       OR candidate -> 'snapshot' ->> 'authoritative_checksum_before' IS DISTINCT FROM
          candidate -> 'snapshot' ->> 'authoritative_checksum_after' THEN
        RAISE EXCEPTION 'M37_AUTHORITATIVE_CHANGED: authoritative state changed during backtest';
    END IF;

    differences := pgreact_internal.m37_differences(baseline, candidate, evidence_limit);
    complete := baseline ->> 'state' = 'ready'
        AND candidate ->> 'state' = 'ready'
        AND NOT (differences ->> 'truncated')::boolean;
    comparison_digest := encode(sha256(convert_to(
        COALESCE(baseline -> 'evidence' ->> 'declaration_digest', '') || E'\n' ||
        COALESCE(candidate -> 'evidence' ->> 'declaration_digest', '') || E'\n' ||
        COALESCE(baseline -> 'evidence' ->> 'snapshot_digest', '') || E'\n' ||
        COALESCE(baseline -> 'evidence' ->> 'replay_digest', '') || E'\n' ||
        (differences -> 'counts')::text, 'UTF8')), 'hex');

    RETURN jsonb_build_object(
        'contract_version', 24,
        'operation', 'backtest',
        'simulation', 'comparative_backtesting',
        'target', baseline -> 'target',
        'state', CASE WHEN complete THEN 'ready' ELSE 'partial' END,
        'summary', jsonb_build_object(
            'read_only', true,
            'initial_row_count', (baseline -> 'summary' ->> 'initial_row_count')::bigint,
            'replay_step_count', (baseline -> 'summary' ->> 'replay_step_count')::integer,
            'replay_change_count', (baseline -> 'summary' ->> 'replay_change_count')::bigint,
            'baseline_final_row_count', (baseline -> 'summary' ->> 'final_row_count')::bigint,
            'candidate_final_row_count', (candidate -> 'summary' ->> 'final_row_count')::bigint,
            'difference_counts', differences -> 'counts',
            'counts_exact', complete,
            'affected_subject_count', CASE WHEN complete
                THEN (differences ->> 'affected_subjects')::bigint END),
        'shared_input', jsonb_build_object(
            'snapshot_digest', baseline -> 'evidence' ->> 'snapshot_digest',
            'replay_digest', baseline -> 'evidence' ->> 'replay_digest',
            'starting_source_frontier', baseline -> 'snapshot' ->> 'starting_source_frontier',
            'ending_source_frontier', baseline -> 'snapshot' ->> 'ending_source_frontier',
            'starting_sampled_time', baseline -> 'snapshot' ->> 'starting_sampled_time',
            'ending_sampled_time', baseline -> 'snapshot' ->> 'ending_sampled_time',
            'starting_event_time_watermark', baseline -> 'snapshot' ->> 'starting_event_time_watermark',
            'ending_event_time_watermark', baseline -> 'snapshot' ->> 'ending_event_time_watermark'),
        'evidence', jsonb_build_object(
            'baseline_declaration_digest', baseline -> 'evidence' ->> 'declaration_digest',
            'candidate_declaration_digest', candidate -> 'evidence' ->> 'declaration_digest',
            'snapshot_digest', baseline -> 'evidence' ->> 'snapshot_digest',
            'replay_digest', baseline -> 'evidence' ->> 'replay_digest',
            'comparison_digest', comparison_digest,
            'changed_subjects', differences -> 'rows',
            'complete', complete,
            'evidence_limit', evidence_limit),
        'cost', jsonb_build_object(
            'baseline', baseline -> 'cost',
            'candidate', candidate -> 'cost',
            'comparison', jsonb_build_object(
                'aligned_rows', differences -> 'rows_considered',
                'changed_rows', (differences -> 'counts' ->> 'added')::bigint
                    + (differences -> 'counts' ->> 'removed')::bigint
                    + (differences -> 'counts' ->> 'changed')::bigint,
                'affected_subjects', differences -> 'affected_subjects',
                'evidence_rows', jsonb_array_length(differences -> 'rows'),
                'counts_exact', complete,
                'elapsed_ms', extract(epoch FROM clock_timestamp() - started_at) * 1000)),
        'findings', CASE WHEN complete THEN
            jsonb_build_array(pgreact_internal.m37_finding(
                'M37_NO_EFFECT', 'INFO', target_name, '<backtest>',
                'comparative backtest completed without changing source or pg-react state',
                'Apply reviewed production changes separately if you want to change data.'))
            ELSE jsonb_build_array(pgreact_internal.m37_finding(
                'M37_COMPARISON_INCOMPLETE', 'WARNING', target_name, '<backtest>',
                'comparative evidence was truncated at the requested limit',
                'Increase evidence_limit or reduce the supplied snapshot.')) END,
        'baseline', baseline,
        'candidate', candidate,
        'differences', differences)
    ;
END
$m37$;

CREATE FUNCTION pgreact.backtest(
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
AS $m37$
    SELECT pgreact_internal.m37_backtest($1, $2, $3, $4, $5)
$m37$;

CREATE FUNCTION pgreact.backtest_results(
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
AS $m37$
WITH backtest AS (
    SELECT pgreact_internal.m37_backtest($1, $2, $3, $4, $5) AS value
), sides AS (
    SELECT 'baseline'::text AS side, value, value -> 'baseline' AS replay
    FROM backtest
    UNION ALL
    SELECT 'candidate'::text, value, value -> 'candidate'
    FROM backtest
), envelopes AS (
    SELECT side, value, replay, replay -> 'initial' AS envelope
    FROM sides
    UNION ALL
    SELECT sides.side, sides.value, sides.replay, item.value
    FROM sides
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(replay -> 'steps', '[]'::jsonb)) item(value)
    UNION ALL
    SELECT side, sides.value, replay, replay -> 'final'
    FROM sides
), side_rows AS (
    SELECT side, envelopes.value, envelope, false AS is_delta, item.value AS row_data,
           envelope ->> 'result_set' AS result_set,
           (envelope ->> 'ordinal')::bigint AS ordinal
    FROM envelopes
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(envelope -> 'rows', '[]'::jsonb)) item(value)
    UNION ALL
    SELECT side, envelopes.value, envelope, true, item.value, 'delta',
           (envelope ->> 'ordinal')::bigint
    FROM envelopes
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(envelope -> 'delta', '[]'::jsonb)) item(value)
    WHERE envelope ->> 'result_set' = 'step'
), result_rows AS (
    SELECT side,
           result_set,
           ordinal,
           value -> 'target' ->> 'kind' AS kind,
           value -> 'target' ->> 'name' AS name,
           row_data ->> 'subject_key' AS subject_key,
           COALESCE(row_data ->> 'result_key', row_data ->> 'subject_key') AS result_key,
           row_data ->> 'state' AS state,
           CASE WHEN is_delta THEN row_data ->> 'change' END AS change,
           CASE WHEN side = 'baseline' THEN
               CASE WHEN is_delta THEN row_data -> 'current_value' ELSE row_data -> 'value' END END AS baseline_value,
           CASE WHEN side = 'candidate' THEN
               CASE WHEN is_delta THEN row_data -> 'proposed_value' ELSE row_data -> 'value' END END AS candidate_value,
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
    SELECT 'difference'::text AS side,
           item.value ->> 'result_set' AS result_set,
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
           NULL::timestamptz AS sampled_time,
           NULL::timestamptz AS source_frontier,
           NULL::timestamptz AS event_time_watermark,
           backtest.value -> 'evidence' ->> 'baseline_declaration_digest' AS baseline_declaration_digest,
           backtest.value -> 'evidence' ->> 'candidate_declaration_digest' AS candidate_declaration_digest,
           backtest.value -> 'evidence' ->> 'snapshot_digest' AS snapshot_digest,
           backtest.value -> 'evidence' ->> 'replay_digest' AS replay_digest,
           backtest.value -> 'evidence' ->> 'comparison_digest' AS comparison_digest
    FROM backtest
    CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(backtest.value -> 'differences' -> 'rows', '[]'::jsonb)) item(value)
)
SELECT * FROM result_rows
UNION ALL
SELECT * FROM difference_rows
$m37$;

REVOKE ALL ON FUNCTION pgreact_internal.m37_finding(text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m37_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m37_differences(jsonb, jsonb, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m37_backtest(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.backtest(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.backtest_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) FROM PUBLIC;

DO $m37$
DECLARE
    role_row record;
BEGIN
    FOR role_row IN
        SELECT role_oid::regrole AS role_name
        FROM pgreact_internal.application_roles
        WHERE role_kind IN ('author', 'operator', 'reader')
    LOOP
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION pgreact.backtest(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb), '
            'pgreact.backtest_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) TO %I',
            role_row.role_name::text);
    END LOOP;
END
$m37$;

COMMENT ON FUNCTION pgreact.backtest(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) IS
    'M37 bounded read-only comparative backtest of two policy versions over one supplied history';
COMMENT ON FUNCTION pgreact.backtest_results(pgreact_api.declaration, pgreact_api.target, jsonb, jsonb, jsonb) IS
    'M37 relational baseline, candidate, delta, and difference rows for comparative backtesting';
COMMENT ON EXTENSION pg_react IS
    'M37 comparative backtesting: bounded read-only comparison of two policy versions over supplied history';
