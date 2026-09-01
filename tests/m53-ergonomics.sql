\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $m53$
DECLARE
    ordinary jsonb;
    ordinary_repeat jsonb;
    causal jsonb;
    causal_repeat jsonb;
    conflict jsonb;
    summary jsonb;
    expected_summary jsonb;
BEGIN
    IF to_regprocedure('pgreact.explain(text,jsonb,jsonb)') IS NULL THEN
        RAISE EXCEPTION 'M53 baseline explain identity is missing';
    END IF;

    ordinary := pgreact.explain('m41-routing', '10'::jsonb);
    ordinary_repeat := pgreact.explain('m41-routing', '10'::jsonb);
    IF ordinary ->> 'contract_version' <> '14'
       OR ordinary ->> 'operation' <> 'explain'
       OR ordinary ->> 'side_effect_free' <> 'true'
       OR ordinary IS DISTINCT FROM ordinary_repeat THEN
        RAISE EXCEPTION 'M53 ordinary baseline mismatch: %, %', ordinary, ordinary_repeat;
    END IF;

    causal := pgreact.explain(
        'm41-routing', '10'::jsonb,
        '{"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'::jsonb);
    causal_repeat := pgreact.explain(
        'm41-routing', '10'::jsonb,
        '{"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'::jsonb);
    IF causal ->> 'contract_version' <> '27'
       OR causal ->> 'state' <> 'complete'
       OR causal -> 'root' ->> 'kind' <> 'decision_result'
       OR causal -> 'nodes' IS DISTINCT FROM causal_repeat -> 'nodes'
       OR causal -> 'edges' IS DISTINCT FROM causal_repeat -> 'edges'
       OR causal -> 'paths' IS DISTINCT FROM causal_repeat -> 'paths'
       OR causal -> 'digests' ->> 'semantic' IS DISTINCT FROM causal_repeat -> 'digests' ->> 'semantic' THEN
        RAISE EXCEPTION 'M53 causal baseline mismatch: %, %', causal, causal_repeat;
    END IF;

    IF to_regprocedure('pgreact.why_not(text,jsonb,text,jsonb)') IS NULL THEN
        RETURN;
    END IF;
    conflict := pgreact.explain(
        'm41-routing', '10'::jsonb,
        '{"why_not":{"result_kind":"decision_result","result_key":"1000"},"causal_path":{"root_kind":"decision_result","result_key":"1000"}}'::jsonb);
    IF conflict ->> 'contract_version' <> '53'
       OR conflict ->> 'state' <> 'unsupported'
       OR conflict -> 'findings' -> 0 ->> 'code' <> 'M53_EXPLAIN_QUESTION_CONFLICT' THEN
        RAISE EXCEPTION 'M53 conflict mismatch: %', conflict;
    END IF;
    summary := pgreact.explanation_summary(causal);
    expected_summary := jsonb_build_object(
        'contract_version', 53, 'origin', 'causal_path',
        'question_kind', 'causal_path', 'target', causal -> 'target',
        'subject', causal -> 'subject',
        'explanation_ref', jsonb_build_object(
            'ref_version', 1, 'question_kind', 'causal_path',
            'target', causal -> 'target', 'subject', causal -> 'subject',
            'root', jsonb_build_object(
                'kind', 'decision_result',
                'result_key', causal -> 'root' -> 'result_key')),
        'availability_state', 'current', 'origin_state', 'complete',
        'explanation_state', 'complete', 'complete', true,
        'evidence_point', jsonb_build_object(
            'sampled_time', causal -> 'sampled_time',
            'authoritative_frontier', causal -> 'authoritative_frontier',
            'digests', causal -> 'digests'),
        'semantic_digest', causal -> 'digests' ->> 'semantic',
        'limits', causal -> 'limits', 'findings', causal -> 'findings',
        'next_actions', '[]'::jsonb);
    IF summary IS DISTINCT FROM expected_summary THEN
        RAISE EXCEPTION 'M53 summary mismatch: %', summary;
    END IF;
END
$m53$;
