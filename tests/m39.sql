\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m39_reference;
CREATE TABLE m39_reference.candidates (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m39_reference.candidates VALUES
    (10, 100, 1, 'approve'), (20, 200, 1, 'hold');

DO $m39$
DECLARE
    deployed_declaration pgreact_api.declaration;
    candidate_declaration pgreact_api.declaration;
    target pgreact_api.target;
    snapshot jsonb;
    steps jsonb;
    legacy jsonb;
    explicit_false jsonb;
    legacy_semantic jsonb;
    explicit_false_semantic jsonb;
    explained jsonb;
    repeated_explained jsonb;
    same_policy jsonb;
    limited jsonb;
    replay jsonb;
    compare jsonb;
    hypothetical jsonb;
    self_explained jsonb;
    relational jsonb;
    compare_canonical jsonb;
    hypothetical_canonical jsonb;
    compare_row_count bigint;
    replay_row_count bigint;
    backtest_row_count bigint;
    before_checksum text;
    after_checksum text;
    oracle_winner_count bigint;
    message text;
BEGIN
    deployed_declaration := pgreact.decision(
        'm39-decision', 'm39_reference.candidates'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-08-27 09:00:00+00');
    candidate_declaration := pgreact.decision(
        'm39-decision', 'm39_reference.candidates'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['candidate_id']::name[], '2026-08-27 09:00:00+00');
    IF (pgreact.deploy(deployed_declaration, jsonb_build_object(
            'preview_digest', (pgreact.preview(deployed_declaration) -> 'summary' ->> 'preview_digest'))) ->> 'state') <> 'deployed' THEN
        RAISE EXCEPTION 'M39 fixture deployment failed';
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:00+00');
    target := pgreact_api.target('decision_program', 'm39-decision');
    snapshot := jsonb_build_object(
        'relations', jsonb_build_array(jsonb_build_object(
            'relation', 'm39_reference.candidates',
            'schema_fingerprint', pgreact_internal.m36_schema_fingerprint(
                'm39_reference.candidates'::regclass),
            'rows', jsonb_build_array(
                jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                   'priority', 1, 'result', 'approve'),
                jsonb_build_object('subject_id', 20, 'candidate_id', 200,
                                   'priority', 1, 'result', 'hold')))),
        'source_frontier', '2026-08-27 09:00:00+00',
        'sampled_time', '2026-08-27 09:00:00+00',
        'event_time_watermark', '2026-08-27 09:00:00+00');
    SELECT count(*) INTO oracle_winner_count
    FROM pgreact.decision_winners
    WHERE program_name = 'm39-decision';
    IF oracle_winner_count <> 2
       OR NOT EXISTS (
           SELECT 1 FROM pgreact.decision_winners
           WHERE program_name = 'm39-decision'
             AND subject_key = 10
             AND state = 'WINNER'
             AND winner_candidate = 100
             AND winner_result = jsonb_build_object('result', 'approve')
       )
       OR NOT EXISTS (
           SELECT 1 FROM pgreact.decision_winners
           WHERE program_name = 'm39-decision'
             AND subject_key = 20
             AND state = 'WINNER'
             AND winner_candidate = 200
             AND winner_result = jsonb_build_object('result', 'hold')
       ) THEN
        RAISE EXCEPTION 'M39 production oracle mismatch: %', oracle_winner_count;
    END IF;
    steps := jsonb_build_array(jsonb_build_object(
        'ordinal', 1,
        'source_frontier', '2026-08-27 09:00:01+00',
        'sampled_time', '2026-08-27 09:00:01+00',
        'event_time_watermark', '2026-08-27 09:00:01+00',
        'change_set', jsonb_build_array(jsonb_build_object(
            'relation', 'm39_reference.candidates', 'operation', 'UPDATE', 'ordinal', 1,
            'key', jsonb_build_object('candidate_id', 100),
            'before', jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                         'priority', 1, 'result', 'approve'),
            'after', jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                        'priority', 0, 'result', 'approve'))),
        'final', true));

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    legacy := pgreact.backtest(candidate_declaration, target, snapshot, steps,
                               jsonb_build_object('evidence_limit', 10));
    explicit_false := pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                       jsonb_build_object('evidence_limit', 10,
                                                          'why_changed', false));
    legacy_semantic := legacy;
    explicit_false_semantic := explicit_false;
    legacy_semantic := jsonb_set(legacy_semantic, '{cost,baseline,elapsed_ms}', 'null'::jsonb);
    explicit_false_semantic := jsonb_set(explicit_false_semantic, '{cost,baseline,elapsed_ms}', 'null'::jsonb);
    legacy_semantic := jsonb_set(legacy_semantic, '{cost,candidate,elapsed_ms}', 'null'::jsonb);
    explicit_false_semantic := jsonb_set(explicit_false_semantic, '{cost,candidate,elapsed_ms}', 'null'::jsonb);
    legacy_semantic := jsonb_set(legacy_semantic, '{cost,comparison,elapsed_ms}', 'null'::jsonb);
    explicit_false_semantic := jsonb_set(explicit_false_semantic, '{cost,comparison,elapsed_ms}', 'null'::jsonb);
    legacy_semantic := jsonb_set(legacy_semantic, '{baseline,cost,elapsed_ms}', 'null'::jsonb);
    explicit_false_semantic := jsonb_set(explicit_false_semantic, '{baseline,cost,elapsed_ms}', 'null'::jsonb);
    legacy_semantic := jsonb_set(legacy_semantic, '{candidate,cost,elapsed_ms}', 'null'::jsonb);
    explicit_false_semantic := jsonb_set(explicit_false_semantic, '{candidate,cost,elapsed_ms}', 'null'::jsonb);
    IF legacy_semantic IS DISTINCT FROM explicit_false_semantic THEN
        RAISE EXCEPTION 'M39 default and false why_changed outputs differ';
    END IF;

    compare := pgreact.compare(candidate_declaration, target,
                               jsonb_build_object('evidence_limit', 10,
                                                  'why_changed', true));
    hypothetical := pgreact.compare(candidate_declaration, target, '[]'::jsonb,
                                    jsonb_build_object('evidence_limit', 10,
                                                       'why_changed', true));
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'subject_key', value ->> 'subject_key',
               'result_key', value ->> 'result_key',
               'state', value ->> 'state',
               'change', value ->> 'change',
               'current_value', value -> 'current_value'
           ) ORDER BY value ->> 'subject_key'), '[]'::jsonb)
    INTO compare_canonical
    FROM jsonb_array_elements(compare -> 'delta') item(value);
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'subject_key', value ->> 'subject_key',
               'result_key', value ->> 'result_key',
               'state', value ->> 'state',
               'change', value ->> 'change',
               'current_value', value -> 'current_value'
           ) ORDER BY value ->> 'subject_key'), '[]'::jsonb)
    INTO hypothetical_canonical
    FROM jsonb_array_elements(hypothetical -> 'delta') item(value);
    IF compare_canonical IS DISTINCT FROM hypothetical_canonical THEN
        RAISE EXCEPTION 'M39 current and empty-change comparison outputs differ';
    END IF;

    explained := pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                  jsonb_build_object('evidence_limit', 10,
                                                     'why_changed', true));
    IF explained ->> 'contract_version' <> '25'
       OR explained ->> 'state' <> 'ready'
       OR explained -> 'evidence' -> 'why_changed' ->> 'state' <> 'complete'
       OR explained -> 'evidence' -> 'why_changed' ->> 'explanation_digest' IS NULL
       OR jsonb_array_length(explained -> 'differences' -> 'rows') <> 8
       OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(explained -> 'differences' -> 'rows') item(value)
           WHERE value ->> 'change' <> 'UNCHANGED'
             AND (value -> 'why_changed' ->> 'originating_operation') <> 'backtest'
       )
       OR EXISTS (
           SELECT 1
           FROM jsonb_array_elements(explained -> 'differences' -> 'rows') item(value)
           WHERE value ->> 'change' <> 'UNCHANGED'
             AND (value -> 'why_changed' -> 'side_pair') IS DISTINCT FROM
                 jsonb_build_object('baseline', 'baseline', 'candidate', 'candidate')
       )
       OR NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(explained -> 'differences' -> 'rows') item(value)
           WHERE value ->> 'change' = 'CHANGED'
             AND value ? 'why_changed'
             AND value -> 'why_changed' ->> 'state' = 'complete'
             AND jsonb_array_length(value -> 'why_changed' -> 'causes') > 0
             AND (value -> 'why_changed' -> 'causes' -> 0 ->> 'path') IS NOT NULL
       ) THEN
        RAISE EXCEPTION 'M39 backtest explanation mismatch: %', explained;
    END IF;
    repeated_explained := pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                           jsonb_build_object('evidence_limit', 10,
                                                              'why_changed', true));
    IF explained -> 'evidence' ->> 'comparison_digest' IS DISTINCT FROM
       repeated_explained -> 'evidence' ->> 'comparison_digest'
       OR explained -> 'evidence' ->> 'replay_digest' IS DISTINCT FROM
          repeated_explained -> 'evidence' ->> 'replay_digest'
       OR explained -> 'differences' -> 'counts' IS DISTINCT FROM
          repeated_explained -> 'differences' -> 'counts' THEN
        RAISE EXCEPTION 'M39 repeated backtest semantic output differs';
    END IF;
    same_policy := pgreact.backtest(NULL, target, snapshot, steps,
                                    jsonb_build_object('evidence_limit', 10));
    IF same_policy ->> 'state' <> 'ready'
       OR same_policy -> 'summary' -> 'difference_counts' IS DISTINCT FROM
          jsonb_build_object('added', 0, 'removed', 0, 'changed', 0, 'unchanged', 8)
       OR jsonb_array_length(same_policy -> 'differences' -> 'rows') <> 8 THEN
        RAISE EXCEPTION 'M39 same-policy backtest invented a difference: %', same_policy;
    END IF;
    limited := pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                jsonb_build_object('evidence_limit', 1));
    IF limited ->> 'state' <> 'partial'
       OR (limited -> 'summary' ->> 'counts_exact')::boolean
       OR (limited -> 'evidence' ->> 'complete')::boolean
       OR (limited -> 'evidence' ->> 'evidence_limit')::integer <> 1 THEN
        RAISE EXCEPTION 'M39 partial bound mismatch: %', limited;
    END IF;
    self_explained := pgreact.backtest(NULL, target, snapshot, steps,
                                       jsonb_build_object('evidence_limit', 10,
                                                          'why_changed', true));
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(self_explained -> 'differences' -> 'rows') item(value)
        WHERE value ? 'why_changed'
    ) THEN
        RAISE EXCEPTION 'M39 added why_changed to an unchanged row';
    END IF;

    replay := pgreact.replay(candidate_declaration, target, snapshot, steps,
                             jsonb_build_object('evidence_limit', 10,
                                                'why_changed', true));
    IF replay ->> 'contract_version' <> '25'
       OR replay -> 'evidence' -> 'why_changed' ->> 'requested' <> 'true'
       OR replay -> 'final' -> 'rows' IS DISTINCT FROM
          explained -> 'candidate' -> 'final' -> 'rows'
       OR NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(replay -> 'steps') step(value),
                jsonb_array_elements(step.value -> 'delta') item(value)
           WHERE item.value ->> 'change' <> 'UNCHANGED'
             AND item.value ? 'why_changed'
       ) THEN
        RAISE EXCEPTION 'M39 comparison and replay explanation mismatch';
    END IF;

    SELECT count(*) INTO compare_row_count
    FROM pgreact.compare_results(candidate_declaration, target,
                                 jsonb_build_object('evidence_limit', 10,
                                                    'why_changed', true));
    SELECT count(*) INTO replay_row_count
    FROM pgreact.replay_results(candidate_declaration, target, snapshot, steps,
                                jsonb_build_object('evidence_limit', 10,
                                                   'why_changed', true));
    IF compare_row_count <> jsonb_array_length(compare -> 'current')
                         + jsonb_array_length(compare -> 'proposed')
                         + jsonb_array_length(compare -> 'delta')
                         + jsonb_array_length(compare -> 'lifecycle')
                         + jsonb_array_length(compare -> 'work')
       OR replay_row_count <> jsonb_array_length(replay -> 'initial' -> 'rows')
                           + jsonb_array_length(replay -> 'steps' -> 0 -> 'rows')
                           + jsonb_array_length(replay -> 'steps' -> 0 -> 'delta')
                           + jsonb_array_length(replay -> 'final' -> 'rows') THEN
        RAISE EXCEPTION 'M39 JSON and relational row counts differ';
    END IF;

    SELECT jsonb_agg(to_jsonb(value) ORDER BY value.result_key)
    INTO relational
    FROM pgreact.backtest_results(
        candidate_declaration, target, snapshot, steps,
        jsonb_build_object('evidence_limit', 10, 'why_changed', true)) value
    WHERE value.side = 'difference';
    IF relational IS NULL OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(relational) item(value)
        WHERE value ->> 'change' <> 'UNCHANGED'
          AND NOT (value -> 'baseline_evidence' ? 'why_changed')
    ) THEN
        RAISE EXCEPTION 'M39 relational explanation mismatch: %', relational;
    END IF;
    SELECT count(*) INTO backtest_row_count
    FROM pgreact.backtest_results(
        candidate_declaration, target, snapshot, steps,
        jsonb_build_object('evidence_limit', 10, 'why_changed', true));
    IF backtest_row_count = 0 THEN
        RAISE EXCEPTION 'M39 relational backtest result was empty';
    END IF;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF before_checksum IS DISTINCT FROM after_checksum THEN
        RAISE EXCEPTION 'M39 changed authoritative state';
    END IF;

    BEGIN
        PERFORM pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                 jsonb_build_object('why_changed', 'yes'));
        RAISE EXCEPTION 'M39 invalid why_changed was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        IF message <> 'M38_OPTIONS_INVALID: why_changed must be a boolean' THEN
            RAISE EXCEPTION 'M39 option finding mismatch: %', message;
        END IF;
    END;
END
$m39$;
