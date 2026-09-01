\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $m44$
DECLARE
    ordinary jsonb;
    why_not jsonb;
    causal jsonb;
    causal_repeat jsonb;
    comparison jsonb;
    declaration pgreact_api.declaration;
    preview jsonb;
    target pgreact_api.target;
    captured jsonb;
    reread jsonb;
BEGIN
    IF to_regprocedure('pgreact.explain(text,jsonb,jsonb)') IS NULL
       OR to_regprocedure('pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)') IS NULL
       OR to_regprocedure('pgreact_api.read_evidence_snapshot(pgreact_api.target,text,text)') IS NULL THEN
        RAISE EXCEPTION 'M44 qualified function inventory is incomplete';
    END IF;

    ordinary := pgreact.explain('m41-routing', '10'::jsonb);
    IF ordinary ->> 'contract_version' <> '14'
       OR ordinary ->> 'operation' <> 'explain'
       OR ordinary ->> 'side_effect_free' <> 'true'
       OR ordinary -> 'target' ->> 'name' <> 'm41-routing'
       OR ordinary -> 'current' IS NULL THEN
        RAISE EXCEPTION 'M44 ordinary explanation mismatch: %', ordinary;
    END IF;

    why_not := pgreact.explain(
        'm40-review', '20'::jsonb,
        '{"why_not":{"result_kind":"rule_match","result_key":"20"}}'::jsonb);
    IF why_not ->> 'contract_version' <> '26'
       OR why_not ->> 'state' <> 'complete'
       OR why_not -> 'expected' ->> 'result_key' <> '20'
       OR why_not -> 'limits' IS NULL
       OR why_not -> 'findings' IS NULL THEN
        RAISE EXCEPTION 'M44 why-not explanation mismatch: %', why_not;
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
       OR causal -> 'root' ->> 'result_key' <> '1000'
       OR causal -> 'completeness' ->> 'paths_exact' <> 'true'
       OR causal -> 'limits' IS NULL
       OR causal -> 'digests' ->> 'semantic' IS NULL
       OR causal -> 'cost' IS NULL
       OR causal ->> 'read_only' <> 'true'
       OR causal -> 'digests' ->> 'semantic' IS DISTINCT FROM causal_repeat -> 'digests' ->> 'semantic'
       OR causal -> 'nodes' IS DISTINCT FROM causal_repeat -> 'nodes'
       OR causal -> 'edges' IS DISTINCT FROM causal_repeat -> 'edges'
       OR causal -> 'paths' IS DISTINCT FROM causal_repeat -> 'paths' THEN
        RAISE EXCEPTION 'M44 causal explanation mismatch: %, %', causal, causal_repeat;
    END IF;

    declaration := pgreact_api.declaration('decision_program', 'm44-snapshot-routing', jsonb_build_object(
        'candidate_relation', 'm42_reference.routes',
        'subject_key', 'subject_id',
        'candidate_key', 'candidate_id',
        'priority', 'priority',
        'results', jsonb_build_array('result'),
        'valid_from', '2026-01-01 00:00:00+00',
        'evidence_snapshot', jsonb_build_object('retention_seconds', 3600)));
    preview := pgreact_api.preview(declaration);
    IF (pgreact_api.deploy(declaration, jsonb_build_object(
            'preview_digest', preview -> 'summary' ->> 'preview_digest')) ->> 'state') <> 'deployed' THEN
        RAISE EXCEPTION 'M44 snapshot fixture deployment failed';
    END IF;
    target := pgreact_api.target('decision_program', 'm44-snapshot-routing', '1');
    captured := pgreact_api.capture_evidence_snapshot(
        target, '10'::jsonb,
        '{"root_kind":"decision_result","result_key":"1000"}'::jsonb,
        'm44-review');
    IF captured ->> 'contract_version' <> '28'
       OR captured ->> 'state' <> 'available'
       OR captured -> 'snapshot' ->> 'contract_version' <> '27'
       OR captured -> 'snapshot' ->> 'state' <> 'complete'
       OR captured -> 'metadata' ->> 'root_identity' IS NULL
       OR captured -> 'metadata' -> 'cost' ->> 'storage_writes' <> '1' THEN
        RAISE EXCEPTION 'M44 retained explanation mismatch: %', captured;
    END IF;
    reread := pgreact_api.read_evidence_snapshot(
        target, captured -> 'metadata' ->> 'root_identity', 'm44-review');
    IF reread ->> 'state' <> 'available'
       OR reread -> 'snapshot' IS DISTINCT FROM captured -> 'snapshot'
       OR reread -> 'metadata' ->> 'root_identity' <> captured -> 'metadata' ->> 'root_identity'
       OR reread ->> 'read_only' <> 'true' THEN
        RAISE EXCEPTION 'M44 retained reread mismatch: %', reread;
    END IF;

    declaration := pgreact_api.declaration('rule', 'm43-payment-review', jsonb_build_object(
        'condition', 'm43_reference.payments',
        'semantic_key', 'payment_id',
        'kind', 'CONSTRAINT',
        'salience', 30));
    comparison := pgreact.compare(
        declaration,
        pgreact_api.target('rule', 'm43-payment-review', '1'),
        '{"why_changed":true}'::jsonb);
    IF comparison ->> 'contract_version' <> '25'
       OR comparison -> 'evidence' -> 'why_changed' ->> 'requested' <> 'true'
       OR comparison -> 'evidence' -> 'why_changed' ->> 'explanation_digest' IS NULL
       OR comparison -> 'findings' IS NULL THEN
        RAISE EXCEPTION 'M44 current comparison mismatch: %', comparison;
    END IF;
END
$m44$;
