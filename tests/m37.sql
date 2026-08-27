\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m37_reference;
CREATE TABLE m37_reference.candidates (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m37_reference.candidates VALUES
    (10, 100, 1, 'approve'), (20, 200, 1, 'hold');

DO $m37$
DECLARE
    deployed_declaration pgreact_api.declaration;
    candidate_declaration pgreact_api.declaration;
    deployed jsonb;
    target pgreact_api.target;
    snapshot jsonb;
    steps jsonb;
    backtest jsonb;
    self_backtest jsonb;
    partial_backtest jsonb;
    relational jsonb;
    before_checksum text;
    after_checksum text;
    message text;
BEGIN
    deployed_declaration := pgreact.decision(
        'm37-decision', 'm37_reference.candidates'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-08-27 09:00:00+00');
    candidate_declaration := pgreact.decision(
        'm37-decision', 'm37_reference.candidates'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['candidate_id']::name[], '2026-08-27 09:00:00+00');
    deployed := pgreact.deploy(deployed_declaration, jsonb_build_object(
        'preview_digest', (pgreact.preview(deployed_declaration) -> 'summary' ->> 'preview_digest')));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M37 fixture deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:00+00');
    target := pgreact_api.target('decision_program', 'm37-decision');
    snapshot := jsonb_build_object(
        'relations', jsonb_build_array(jsonb_build_object(
            'relation', 'm37_reference.candidates',
            'schema_fingerprint', pgreact_internal.m36_schema_fingerprint(
                'm37_reference.candidates'::regclass),
            'rows', jsonb_build_array(
                jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                   'priority', 1, 'result', 'approve'),
                jsonb_build_object('subject_id', 20, 'candidate_id', 200,
                                   'priority', 1, 'result', 'hold')))),
        'source_frontier', '2026-08-27 09:00:00+00',
        'sampled_time', '2026-08-27 09:00:00+00',
        'event_time_watermark', '2026-08-27 09:00:00+00');
    steps := jsonb_build_array(jsonb_build_object(
        'ordinal', 1,
        'source_frontier', '2026-08-27 09:00:01+00',
        'sampled_time', '2026-08-27 09:00:01+00',
        'event_time_watermark', '2026-08-27 09:00:01+00',
        'change_set', jsonb_build_array(jsonb_build_object(
            'relation', 'm37_reference.candidates', 'operation', 'UPDATE', 'ordinal', 1,
            'key', jsonb_build_object('candidate_id', 100),
            'before', jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                         'priority', 1, 'result', 'approve'),
            'after', jsonb_build_object('subject_id', 10, 'candidate_id', 100,
                                        'priority', 0, 'result', 'approve'))),
        'final', true));

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    backtest := pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                 jsonb_build_object('evidence_limit', 10));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF backtest ->> 'contract_version' <> '24'
       OR backtest ->> 'simulation' <> 'comparative_backtesting'
       OR backtest ->> 'state' <> 'ready'
       OR backtest -> 'summary' IS DISTINCT FROM jsonb_build_object(
           'read_only', true,
           'initial_row_count', 2,
           'replay_step_count', 1,
           'replay_change_count', 1,
           'baseline_final_row_count', 2,
           'candidate_final_row_count', 2,
           'difference_counts', jsonb_build_object(
               'added', 0, 'removed', 0, 'changed', 8, 'unchanged', 0),
           'counts_exact', true,
           'affected_subject_count', 2)
       OR backtest -> 'evidence' ->> 'baseline_declaration_digest' IS NULL
       OR backtest -> 'evidence' ->> 'candidate_declaration_digest' IS NULL
       OR backtest -> 'evidence' ->> 'baseline_declaration_digest' =
          backtest -> 'evidence' ->> 'candidate_declaration_digest'
       OR backtest -> 'evidence' ->> 'snapshot_digest' IS NULL
       OR backtest -> 'evidence' ->> 'replay_digest' IS NULL
       OR jsonb_array_length(backtest -> 'differences' -> 'rows') <> 8
       OR after_checksum IS DISTINCT FROM before_checksum
       OR (backtest -> 'findings' -> 0 ->> 'code') <> 'M37_NO_EFFECT' THEN
        RAISE EXCEPTION 'M37 changed-policy output mismatch: %', backtest;
    END IF;

    SELECT jsonb_build_object(
               'rows', jsonb_agg(jsonb_build_object(
                   'side', side, 'result_set', result_set, 'ordinal', step_ordinal,
                   'subject_key', subject_key, 'result_key', result_key,
                   'state', state, 'change', change)
                   ORDER BY CASE side WHEN 'baseline' THEN 1 WHEN 'candidate' THEN 2 ELSE 3 END,
                            step_ordinal, result_set, subject_key, result_key),
               'side_counts', (SELECT jsonb_object_agg(side, row_count ORDER BY side)
                               FROM (
                                   SELECT side, count(*) AS row_count
                                   FROM pgreact.backtest_results(
                                       candidate_declaration, target, snapshot, steps,
                                       jsonb_build_object('evidence_limit', 10))
                                   GROUP BY side
                               ) counts))
    INTO relational
    FROM pgreact.backtest_results(
        candidate_declaration, target, snapshot, steps,
        jsonb_build_object('evidence_limit', 10));
    IF relational -> 'side_counts' IS DISTINCT FROM
       jsonb_build_object('baseline', 8, 'candidate', 8, 'difference', 8)
       OR jsonb_array_length(relational -> 'rows') <> 24
       OR NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(relational -> 'rows') item(value)
           WHERE value ->> 'side' = 'difference'
             AND value ->> 'result_set' = 'delta'
             AND value ->> 'change' = 'CHANGED') THEN
        RAISE EXCEPTION 'M37 relational output mismatch: %', relational;
    END IF;

    self_backtest := pgreact.backtest(NULL, target, snapshot, steps,
                                      jsonb_build_object('evidence_limit', 10));
    IF self_backtest ->> 'state' <> 'ready'
       OR self_backtest -> 'summary' -> 'difference_counts' IS DISTINCT FROM
          jsonb_build_object('added', 0, 'removed', 0, 'changed', 0, 'unchanged', 8)
       OR self_backtest -> 'evidence' ->> 'baseline_declaration_digest' IS DISTINCT FROM
          self_backtest -> 'evidence' ->> 'candidate_declaration_digest' THEN
        RAISE EXCEPTION 'M37 null-candidate output mismatch: %', self_backtest;
    END IF;

    partial_backtest := pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                         jsonb_build_object('evidence_limit', 1));
    IF partial_backtest ->> 'state' <> 'partial'
       OR (partial_backtest -> 'summary' ->> 'counts_exact')::boolean
       OR (partial_backtest -> 'summary' ->> 'affected_subject_count') IS NOT NULL
       OR (partial_backtest -> 'findings' -> 0 ->> 'code') <> 'M37_COMPARISON_INCOMPLETE' THEN
        RAISE EXCEPTION 'M37 bounded output mismatch: %', partial_backtest;
    END IF;

    BEGIN
        PERFORM pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                 jsonb_build_object('unknown', true));
        RAISE EXCEPTION 'M37 unknown option was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        IF message <> 'M37_UNKNOWN_FIELD: option unknown is not supported' THEN
            RAISE EXCEPTION 'M37 unknown option finding mismatch: %', message;
        END IF;
    END;
END
$m37$;
