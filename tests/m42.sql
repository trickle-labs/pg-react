\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m42_reference;
CREATE TABLE m42_reference.routes (
    subject_id bigint NOT NULL,
    candidate_id bigint PRIMARY KEY,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m42_reference.routes VALUES
    (10, 1000, 1, 'manual'), (10, 1001, 2, 'automatic');

DO $m42$
DECLARE declaration pgreact_api.declaration;
    preview jsonb;
    deployed jsonb;
    captured jsonb;
    reread jsonb;
    deleted jsonb;
    missing jsonb;
    retention_preview jsonb;
    retention_status jsonb;
    retention_metrics jsonb;
    retention_audit jsonb;
    retention_detail jsonb;
    target pgreact_api.target;
    root jsonb := '{"root_kind":"decision_result","result_key":"1000"}'::jsonb;
    root_identity text;
    capture_key text := 'm42-first-capture';
    original_answer jsonb;
BEGIN
    declaration := pgreact_api.declaration('decision_program', 'm42-routing', jsonb_build_object(
        'candidate_relation', 'm42_reference.routes',
        'subject_key', 'subject_id',
        'candidate_key', 'candidate_id',
        'priority', 'priority',
        'results', jsonb_build_array('result'),
        'valid_from', '2026-01-01 00:00:00+00',
        'evidence_snapshot', jsonb_build_object('retention_seconds', 1)));
    preview := pgreact_api.preview(declaration);
    deployed := pgreact_api.deploy(declaration, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed'
       OR deployed -> 'evidence' -> 'normalized_declaration' -> 'spec' ->> 'evidence_snapshot'
          <> '{"retention_seconds": 1}' THEN
        RAISE EXCEPTION 'M42 declaration policy was not normalized: %', deployed;
    END IF;
    target := pgreact_api.target('decision_program', 'm42-routing', '1');
    captured := pgreact_api.capture_evidence_snapshot(target, '10'::jsonb, root, capture_key);
    IF captured ->> 'contract_version' <> '28'
       OR captured ->> 'state' <> 'available'
       OR captured ->> 'snapshot_identity' IS NULL
       OR captured -> 'snapshot' ->> 'contract_version' <> '27'
       OR captured -> 'snapshot' ->> 'state' <> 'complete'
       OR captured -> 'snapshot' -> 'root' ->> 'identity' IS NULL
       OR captured -> 'metadata' ->> 'deletion_eligible_at' IS NULL
       OR captured -> 'metadata' -> 'cost' ->> 'storage_writes' <> '1' THEN
        RAISE EXCEPTION 'M42 capture mismatch: %', captured;
    END IF;
    original_answer := captured -> 'snapshot';
    root_identity := captured -> 'metadata' ->> 'root_identity';

    captured := pgreact_api.capture_evidence_snapshot(target, '10'::jsonb, root, capture_key);
    IF captured ->> 'state' NOT IN ('available', 'deletion_eligible')
       OR captured -> 'snapshot' IS DISTINCT FROM original_answer
       OR captured -> 'findings' -> 0 ->> 'code' <> 'M42_CAPTURE_DUPLICATE' THEN
        RAISE EXCEPTION 'M42 duplicate capture mismatch: %', captured;
    END IF;

    retention_preview := pgreact_api.retention_preview(
        clock_timestamp() - interval '1 hour', 10000);
    retention_status := pgreact_api.retention_status();
    retention_metrics := pgreact_api.retention_metrics();
    retention_audit := pgreact_api.retention_audit(100);
    retention_detail := pgreact_api.retention_detail('evidence_snapshots', captured ->> 'snapshot_identity');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(retention_preview -> 'families') f
                   WHERE f ->> 'family' = 'evidence_snapshots')
       OR NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
               WHERE oid = 'pgreact_internal.evidence_snapshots'::regclass)
       OR NOT (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class
               WHERE oid = 'pgreact_internal.evidence_snapshot_audits'::regclass)
       OR retention_status -> 'backlog' IS NULL
       OR retention_metrics -> 'eligible_bytes' IS NULL
       OR retention_audit -> 'snapshot_audits' IS NULL
       OR retention_detail ->> 'retained' <> 'true' THEN
        RAISE EXCEPTION 'M42 retention integration mismatch: %, %, %, %, %',
            retention_preview, retention_status, retention_metrics,
            retention_audit, retention_detail;
    END IF;

    PERFORM pg_sleep(2);
    reread := pgreact_api.read_evidence_snapshot(target, root_identity, capture_key);
    IF reread ->> 'state' <> 'deletion_eligible'
       OR reread -> 'snapshot' IS DISTINCT FROM original_answer
       OR reread -> 'metadata' ->> 'root_identity' <> root_identity
       OR reread ->> 'read_only' <> 'true' THEN
        RAISE EXCEPTION 'M42 historical read mismatch: %', reread;
    END IF;

    deleted := pgreact_api.delete_evidence_snapshot(target, root_identity, capture_key);
    IF deleted ->> 'state' <> 'deleted'
       OR deleted -> 'findings' -> 0 ->> 'code' <> 'M42_SNAPSHOT_DELETED' THEN
        RAISE EXCEPTION 'M42 delete mismatch: %', deleted;
    END IF;
    reread := pgreact_api.read_evidence_snapshot(target, root_identity, capture_key);
    IF reread ->> 'state' <> 'deleted'
       OR reread -> 'metadata' -> 'tombstone' ->> 'historical_identity'
          <> deleted ->> 'snapshot_identity' THEN
        RAISE EXCEPTION 'M42 tombstone read mismatch: %', reread;
    END IF;
    missing := pgreact_api.read_evidence_snapshot(
        target, root_identity, 'm42-never-captured');
    IF missing ->> 'state' <> 'missing'
       OR missing ->> 'snapshot' IS NOT NULL
       OR missing -> 'findings' -> 0 ->> 'code' <> 'M42_SNAPSHOT_MISSING' THEN
        RAISE EXCEPTION 'M42 missing read mismatch: %', missing;
    END IF;
    IF (SELECT count(*) FROM pgreact_internal.evidence_snapshot_audits
        WHERE snapshot_identity = deleted ->> 'snapshot_identity') <> 2 THEN
        RAISE EXCEPTION 'M42 capture/delete audit rows are incomplete';
    END IF;
END
$m42$;

DO $m42$
DECLARE declaration pgreact_api.declaration;
    result jsonb;
BEGIN
    declaration := pgreact_api.declaration('decision_program', 'm42-no-opt-in', jsonb_build_object(
        'candidate_relation', 'm42_reference.routes',
        'subject_key', 'subject_id', 'candidate_key', 'candidate_id',
        'priority', 'priority', 'results', jsonb_build_array('result'),
        'valid_from', '2026-01-01 00:00:00+00'));
    PERFORM pgreact_api.deploy(declaration);
    result := pgreact_api.capture_evidence_snapshot(
        pgreact_api.target('decision_program', 'm42-no-opt-in', '1'),
        '10'::jsonb, '{"root_kind":"decision_result","result_key":"1000"}'::jsonb,
        'm42-disabled');
    IF result ->> 'state' <> 'unavailable'
       OR result -> 'findings' -> 0 ->> 'code' <> 'M42_POLICY_MISSING'
       OR EXISTS (SELECT 1 FROM pgreact_internal.evidence_snapshots
                  WHERE target_name = 'm42-no-opt-in') THEN
        RAISE EXCEPTION 'M42 opt-in default mismatch: %', result;
    END IF;
END
$m42$;
