\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m38_reference;
CREATE TABLE m38_reference.candidates (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m38_reference.candidates VALUES
    (10, 100, 1, 'approve'), (20, 200, 1, 'hold');

DO $m38$
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
    replay jsonb;
    compare jsonb;
    hypothetical jsonb;
    self_explained jsonb;
    relational jsonb;
    before_checksum text;
    after_checksum text;
    message text;
BEGIN
    deployed_declaration := pgreact.decision(
        'm38-decision', 'm38_reference.candidates'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-08-27 09:00:00+00');
    candidate_declaration := pgreact.decision(
        'm38-decision', 'm38_reference.candidates'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['candidate_id']::name[], '2026-08-27 09:00:00+00');
    IF (pgreact.deploy(deployed_declaration, jsonb_build_object(
            'preview_digest', (pgreact.preview(deployed_declaration) -> 'summary' ->> 'preview_digest'))) ->> 'state') <> 'deployed' THEN
        RAISE EXCEPTION 'M38 fixture deployment failed';
    END IF;
    PERFORM pgreact.run('2026-08-27 09:00:00+00');
    target := pgreact_api.target('decision_program', 'm38-decision');
    snapshot := jsonb_build_object(
        'relations', jsonb_build_array(jsonb_build_object(
            'relation', 'm38_reference.candidates',
            'schema_fingerprint', pgreact_internal.m36_schema_fingerprint(
                'm38_reference.candidates'::regclass),
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
            'relation', 'm38_reference.candidates', 'operation', 'UPDATE', 'ordinal', 1,
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
        RAISE EXCEPTION 'M38 default and false why_changed outputs differ';
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
        RAISE EXCEPTION 'M38 backtest explanation mismatch: %', explained;
    END IF;
    self_explained := pgreact.backtest(NULL, target, snapshot, steps,
                                       jsonb_build_object('evidence_limit', 10,
                                                          'why_changed', true));
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(self_explained -> 'differences' -> 'rows') item(value)
        WHERE value ? 'why_changed'
    ) THEN
        RAISE EXCEPTION 'M38 added why_changed to an unchanged row';
    END IF;

    replay := pgreact.replay(candidate_declaration, target, snapshot, steps,
                             jsonb_build_object('evidence_limit', 10,
                                                'why_changed', true));
    compare := pgreact.compare(candidate_declaration, target,
                               jsonb_build_object('evidence_limit', 10,
                                                  'why_changed', true));
    hypothetical := pgreact.compare(candidate_declaration, target, '[]'::jsonb,
                                    jsonb_build_object('evidence_limit', 10,
                                                       'why_changed', true));
    IF replay ->> 'contract_version' <> '25'
       OR compare ->> 'contract_version' <> '25'
       OR hypothetical ->> 'contract_version' <> '25'
       OR replay -> 'evidence' -> 'why_changed' ->> 'requested' <> 'true'
       OR compare -> 'evidence' -> 'why_changed' ->> 'requested' <> 'true'
       OR hypothetical -> 'evidence' -> 'why_changed' ->> 'requested' <> 'true'
       OR NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(replay -> 'steps') step(value),
                jsonb_array_elements(step.value -> 'delta') item(value)
           WHERE item.value ->> 'change' <> 'UNCHANGED'
             AND item.value ? 'why_changed'
       ) THEN
        RAISE EXCEPTION 'M38 comparison and replay explanation mismatch';
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
        RAISE EXCEPTION 'M38 relational explanation mismatch: %', relational;
    END IF;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF before_checksum IS DISTINCT FROM after_checksum THEN
        RAISE EXCEPTION 'M38 changed authoritative state';
    END IF;

    BEGIN
        PERFORM pgreact.backtest(candidate_declaration, target, snapshot, steps,
                                 jsonb_build_object('why_changed', 'yes'));
        RAISE EXCEPTION 'M38 invalid why_changed was accepted';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS message = MESSAGE_TEXT;
        IF message <> 'M38_OPTIONS_INVALID: why_changed must be a boolean' THEN
            RAISE EXCEPTION 'M38 option finding mismatch: %', message;
        END IF;
    END;
END
$m38$;
