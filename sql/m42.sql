-- M42 opt-in evidence snapshots over the exact M41 causal-path answer.

CREATE TABLE pgreact_internal.evidence_snapshots (
    snapshot_identity text PRIMARY KEY,
    target_kind text NOT NULL CHECK (target_kind = 'decision_program'),
    target_name text NOT NULL,
    target_version text NOT NULL,
    root_identity text NOT NULL,
    capture_key text NOT NULL,
    subject jsonb NOT NULL,
    owner_oid oid NOT NULL,
    declaration_digest text NOT NULL,
    policy_digest text NOT NULL,
    m41_answer jsonb NOT NULL,
    sampled_time timestamptz,
    captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deletion_eligible_at timestamptz NOT NULL,
    payload_bytes bigint NOT NULL CHECK (payload_bytes > 0),
    source_evidence_read bigint NOT NULL CHECK (source_evidence_read >= 0),
    storage_writes bigint NOT NULL CHECK (storage_writes = 1),
    UNIQUE (target_kind, target_name, target_version, root_identity, capture_key)
);

CREATE INDEX evidence_snapshots_retention_idx
    ON pgreact_internal.evidence_snapshots (deletion_eligible_at, captured_at);

CREATE TABLE pgreact_internal.evidence_snapshot_audits (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snapshot_identity text NOT NULL,
    operation text NOT NULL CHECK (operation IN ('capture', 'delete')),
    outcome text NOT NULL,
    actor_oid oid NOT NULL,
    owner_oid oid NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    details jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (snapshot_identity, operation)
);

ALTER TABLE pgreact_internal.evidence_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgreact_internal.evidence_snapshots FORCE ROW LEVEL SECURITY;
CREATE POLICY evidence_snapshot_access ON pgreact_internal.evidence_snapshots
    USING (pg_catalog.pg_has_role(session_user, owner_oid, 'USAGE')
           OR pgreact_internal.is_operator_admin())
    WITH CHECK (pg_catalog.pg_has_role(session_user, owner_oid, 'USAGE')
                OR pgreact_internal.is_operator_admin());
ALTER TABLE pgreact_internal.evidence_snapshot_audits ENABLE ROW LEVEL SECURITY;
ALTER TABLE pgreact_internal.evidence_snapshot_audits FORCE ROW LEVEL SECURITY;
CREATE POLICY evidence_snapshot_audit_access ON pgreact_internal.evidence_snapshot_audits
    USING (pg_catalog.pg_has_role(session_user, owner_oid, 'USAGE')
           OR pgreact_internal.is_operator_admin())
    WITH CHECK (pg_catalog.pg_has_role(session_user, owner_oid, 'USAGE')
                OR pgreact_internal.is_operator_admin());

INSERT INTO pgreact_internal.retention_families
    (family, relation_name, time_column, classification, lost_capabilities, remediation)
VALUES
    ('evidence_snapshots', 'pgreact_internal.evidence_snapshots', 'captured_at',
     'opt-in retained explanation evidence', ARRAY['historical causal-path detail'],
     'use the names-first snapshot read before deletion or restore a verified backup')
ON CONFLICT (family) DO NOTHING;

CREATE FUNCTION pgreact_internal.m42_finding(
    code text, severity text, field_path text, message text, hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE
AS $m42$
    SELECT jsonb_build_object(
        'code', $1, 'severity', $2, 'blocking', $2 = 'ERROR',
        'field', $3, 'message', $4, 'hint', $5,
        'details', COALESCE($6, '{}'::jsonb))
$m42$;

CREATE FUNCTION pgreact_internal.m42_finding_registry()
RETURNS jsonb
LANGUAGE SQL IMMUTABLE
AS $m42$
SELECT jsonb_build_array(
    jsonb_build_object('code', 'M42_OPTIONS_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M42_POLICY_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M42_POLICY_MISSING', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_POLICY_DISABLED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_TARGET_NOT_FOUND', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_TARGET_UNAUTHORIZED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_ROOT_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M42_ROOT_INCOMPLETE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_VERSION_STALE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_CAPTURE_KEY_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M42_CAPTURE_DUPLICATE', 'severity', 'INFO'),
    jsonb_build_object('code', 'M42_STORAGE_FAILURE', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M42_LIMIT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_SNAPSHOT_MISSING', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_SNAPSHOT_DELETED', 'severity', 'INFO'),
    jsonb_build_object('code', 'M42_DELETE_NOT_ELIGIBLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M42_UNAVAILABLE', 'severity', 'WARNING'))
$m42$;

CREATE FUNCTION pgreact_internal.m42_policy_findings(policy jsonb, target_name text)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $m42$
DECLARE findings jsonb := '[]'::jsonb;
    unknown_field text;
    enabled boolean := true;
    retention_text text;
BEGIN
    IF jsonb_typeof(policy) IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_array(pgreact_internal.m42_finding(
            'M42_POLICY_INVALID', 'ERROR', 'spec.evidence_snapshot',
            'evidence_snapshot must be an object',
            'Use {"retention_seconds": number} with an optional enabled boolean.'));
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_object_keys(policy) key
    WHERE key NOT IN ('enabled', 'retention_seconds')
    ORDER BY key LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        findings := findings || jsonb_build_array(pgreact_internal.m42_finding(
            'M42_POLICY_INVALID', 'ERROR', 'spec.evidence_snapshot.' || unknown_field,
            'evidence_snapshot contains an unknown field',
            'Use only enabled and retention_seconds.', jsonb_build_object('field', unknown_field)));
    END IF;
    IF policy ? 'enabled' AND jsonb_typeof(policy -> 'enabled') IS DISTINCT FROM 'boolean' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m42_finding(
            'M42_POLICY_INVALID', 'ERROR', 'spec.evidence_snapshot.enabled',
            'enabled must be boolean', 'Use true to enable capture or false to disable it.'));
    ELSE
        enabled := COALESCE((policy ->> 'enabled')::boolean, true);
    END IF;
    retention_text := policy ->> 'retention_seconds';
    IF enabled AND (NOT policy ? 'retention_seconds'
                    OR jsonb_typeof(policy -> 'retention_seconds') IS DISTINCT FROM 'number'
                    OR retention_text !~ '^[1-9][0-9]*$'
                    OR length(retention_text) > 10
                    OR retention_text::bigint > 3153600000) THEN
        findings := findings || jsonb_build_array(pgreact_internal.m42_finding(
            'M42_POLICY_INVALID', 'ERROR', 'spec.evidence_snapshot.retention_seconds',
            'retention_seconds must be a positive integer no greater than one hundred years',
            'Choose a finite retention period in seconds.',
            jsonb_build_object('target', target_name)));
    END IF;
    RETURN findings;
END
$m42$;

ALTER FUNCTION pgreact_internal.m28_validate(pgreact_api.declaration)
    RENAME TO m28_validate_m41;

CREATE FUNCTION pgreact_internal.m28_validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
DECLARE sanitized pgreact_api.declaration;
    result jsonb;
    policy jsonb;
    policy_findings jsonb := '[]'::jsonb;
BEGIN
    IF declaration IS NOT NULL AND (declaration).kind = 'decision_program' THEN
        policy := (declaration).spec -> 'evidence_snapshot';
        IF (declaration).spec ? 'evidence_snapshot' THEN
            policy_findings := pgreact_internal.m42_policy_findings(policy, (declaration).name);
        END IF;
        sanitized := ROW(
            (declaration).api_version, (declaration).kind, (declaration).name,
            CASE WHEN (declaration).spec IS NULL THEN NULL
                 ELSE (declaration).spec - 'evidence_snapshot' END
        )::pgreact_api.declaration;
    ELSE
        sanitized := declaration;
    END IF;
    result := pgreact_internal.m28_validate_m41(sanitized);
    IF jsonb_array_length(policy_findings) > 0 THEN
        result := jsonb_set(result, '{findings}',
            COALESCE(result -> 'findings', '[]'::jsonb) || policy_findings, true);
    END IF;
    IF declaration IS NOT NULL AND (declaration).kind = 'decision_program'
       AND (declaration).spec ? 'evidence_snapshot'
       AND result -> 'normalized' IS NOT NULL THEN
        result := jsonb_set(result, '{normalized,spec,evidence_snapshot}', policy, true);
    END IF;
    RETURN result;
END
$m42$;

CREATE FUNCTION pgreact_internal.m42_result(
    operation text, state text, snapshot_identity text, answer jsonb,
    metadata jsonb, findings jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE
AS $m42$
    SELECT jsonb_build_object(
        'contract_version', 28,
        'operation', $1,
        'state', $2,
        'snapshot_identity', $3,
        'snapshot', $4,
        'metadata', COALESCE($5, '{}'::jsonb),
        'findings', COALESCE($6, '[]'::jsonb),
        'read_only', $1 = 'read',
        'truncated', false)
$m42$;

CREATE FUNCTION pgreact_internal.m42_identity(
    target_kind text, target_name text, target_version text,
    root_identity text, capture_key text
)
RETURNS text
LANGUAGE SQL IMMUTABLE STRICT
AS $m42$
    SELECT format('evidence_snapshot:%s:%s:%s:%s:%s',
        $1, $2, $3, $4, $5)
$m42$;

CREATE FUNCTION pgreact_internal.m42_snapshot_metadata(row_data pgreact_internal.evidence_snapshots)
RETURNS jsonb
LANGUAGE SQL STABLE
AS $m42$
    SELECT jsonb_build_object(
        'target', jsonb_build_object('kind', $1.target_kind, 'name', $1.target_name,
                                     'version', $1.target_version),
        'root_identity', $1.root_identity,
        'capture_key', $1.capture_key,
        'subject', $1.subject,
        'declaration_digest', $1.declaration_digest,
        'policy_digest', $1.policy_digest,
        'sampled_time', $1.sampled_time,
        'captured_at', $1.captured_at,
        'deletion_eligible_at', $1.deletion_eligible_at,
        'owner', pg_get_userbyid($1.owner_oid),
        'cost', jsonb_build_object(
            'source_evidence_read', $1.source_evidence_read,
            'payload_bytes', $1.payload_bytes,
            'storage_writes', $1.storage_writes))
$m42$;

CREATE FUNCTION pgreact_api.capture_evidence_snapshot(
    target pgreact_api.target,
    subject jsonb,
    root jsonb,
    capture_key text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
DECLARE subject_key bigint;
    result_key bigint;
    root_identity text;
    computed_identity text;
    existing pgreact_internal.evidence_snapshots%ROWTYPE;
    tombstone record;
    declaration_row pgreact_internal.api_declarations%ROWTYPE;
    answer jsonb;
    policy jsonb;
    policy_findings jsonb;
    declaration_digest text;
    policy_digest text;
    captured_at timestamptz := clock_timestamp();
    deletion_eligible_at timestamptz;
    payload_bytes bigint;
    source_reads bigint;
BEGIN
    IF target IS NULL OR (target).kind IS DISTINCT FROM 'decision_program'
       OR (target).name IS NULL OR (target).version IS NULL
       OR (target).version !~ '^[1-9][0-9]*$'
       OR jsonb_typeof(root) IS DISTINCT FROM 'object'
       OR root ->> 'root_kind' IS DISTINCT FROM 'decision_result'
       OR root ->> 'result_key' !~ '^-?[0-9]+$'
       OR (SELECT count(*) FROM jsonb_object_keys(root)) <> 2 THEN
        RETURN pgreact_internal.m42_result('capture', 'unsupported', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_ROOT_INVALID', 'ERROR', 'root',
                'capture accepts one decision_result root and a numeric version',
                'Pass target kind decision_program, its version, and {root_kind, result_key}.')));
    END IF;
    IF capture_key IS NULL OR capture_key !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$' THEN
        RETURN pgreact_internal.m42_result('capture', 'unsupported', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_CAPTURE_KEY_INVALID', 'ERROR', 'capture_key',
                'capture_key must be 1 to 128 safe characters',
                'Use letters, digits, dot, underscore, colon, or hyphen.')));
    END IF;
    subject_key := pgreact_internal.m40_subject_key(subject);
    IF subject_key IS NULL THEN
        RETURN pgreact_internal.m42_result('capture', 'unsupported', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_ROOT_INVALID', 'ERROR', 'subject',
                'subject must contain one bigint business key',
                'Pass a JSON number or {"key": number}.')));
    END IF;
    result_key := (root ->> 'result_key')::bigint;
    root_identity := format('decision_result:%s@%s:subject=%s:candidate=%s',
        (target).name, (target).version, subject_key, result_key);
    computed_identity := pgreact_internal.m42_identity(
        (target).kind, (target).name, (target).version, root_identity, capture_key);

    SELECT * INTO existing
    FROM pgreact_internal.evidence_snapshots
    WHERE evidence_snapshots.snapshot_identity = computed_identity
    FOR UPDATE;
    IF FOUND THEN
        IF NOT pg_has_role(session_user, existing.owner_oid, 'USAGE')
           AND NOT pgreact_internal.is_operator_admin() THEN
            RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
                jsonb_build_array(pgreact_internal.m42_finding(
                    'M42_TARGET_UNAUTHORIZED', 'WARNING', NULL,
                    'the retained evidence is not available to this caller',
                    'Use the declaration owner or configured operator role.')));
        END IF;
        RETURN pgreact_internal.m42_result(
            'capture', CASE WHEN existing.deletion_eligible_at <= clock_timestamp()
                            THEN 'deletion_eligible' ELSE 'available' END,
            existing.snapshot_identity, existing.m41_answer,
            pgreact_internal.m42_snapshot_metadata(existing),
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_CAPTURE_DUPLICATE', 'INFO', 'capture_key',
                'the capture identity already exists; the retained answer was returned',
                'Reuse the same identity to retry safely.')));
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.retention_tombstones
               WHERE family = 'evidence_snapshots'
                 AND historical_identity = computed_identity) THEN
        RETURN pgreact_internal.m42_result('capture', 'deleted', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_SNAPSHOT_DELETED', 'INFO', NULL,
                'this capture identity was deleted and cannot be recreated',
                'Use a new capture_key for a new historical record.')));
    END IF;

    SELECT * INTO declaration_row
    FROM pgreact_internal.api_declarations
    WHERE kind = 'decision_program' AND object_name = (target).name AND state = 'DEPLOYED';
    IF NOT FOUND THEN
        RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_TARGET_NOT_FOUND', 'WARNING', 'target',
                'no deployed canonical decision program has this name',
                'Deploy a decision_program declaration before capturing evidence.')));
    END IF;
    IF NOT pg_has_role(session_user, declaration_row.owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_TARGET_UNAUTHORIZED', 'WARNING', NULL,
                'the decision program is not available to this caller',
                'Use the declaration owner or configured operator role.')));
    END IF;
    policy := declaration_row.normalized -> 'spec' -> 'evidence_snapshot';
    IF policy IS NULL THEN
        RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_POLICY_MISSING', 'WARNING', 'spec.evidence_snapshot',
                'evidence snapshots are disabled because the declaration did not opt in',
                'Deploy the decision program with a finite evidence_snapshot retention_seconds policy.')));
    END IF;
    policy_findings := pgreact_internal.m42_policy_findings(policy, (target).name);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(policy_findings) f WHERE f ->> 'severity' = 'ERROR') THEN
        RETURN pgreact_internal.m42_result('capture', 'unsupported', NULL, NULL, '{}', policy_findings);
    END IF;
    IF COALESCE((policy ->> 'enabled')::boolean, true) = false THEN
        RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_POLICY_DISABLED', 'WARNING', 'spec.evidence_snapshot.enabled',
                'evidence snapshots are disabled by this declaration',
                'Set enabled to true or omit it.')));
    END IF;

    answer := pgreact_internal.m41_explain(
        (target).name, subject, jsonb_build_object('causal_path', root));
    IF answer ->> 'state' <> 'complete' THEN
        RETURN pgreact_internal.m42_result('capture',
            CASE WHEN answer ->> 'state' = 'partial' THEN 'partial' ELSE 'unavailable' END,
            NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_ROOT_INCOMPLETE', 'WARNING', 'root',
                'only a complete current M41 causal path can be retained',
                'Resolve the M41 finding and retry while the evidence is current.',
                jsonb_build_object('m41_state', answer ->> 'state'))));
    END IF;
    IF answer -> 'target' ->> 'version' IS DISTINCT FROM (target).version
       OR answer -> 'root' ->> 'identity' IS DISTINCT FROM root_identity THEN
        RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_VERSION_STALE', 'WARNING', 'target.version',
                'the requested M41 path does not match the requested public version',
                'Retry with the version and root identity returned by M41.')));
    END IF;
    declaration_digest := encode(declaration_row.declaration_digest, 'hex');
    policy_digest := encode(sha256(convert_to(policy::text, 'UTF8')), 'hex');
    captured_at := clock_timestamp();
    deletion_eligible_at := captured_at +
        interval '1 second' * (policy ->> 'retention_seconds')::bigint;
    payload_bytes := pg_column_size(answer);
    source_reads := COALESCE((answer -> 'cost' ->> 'boundary_checks')::bigint, 0);
    INSERT INTO pgreact_internal.evidence_snapshots(
        snapshot_identity, target_kind, target_name, target_version, root_identity,
        capture_key, subject, owner_oid, declaration_digest, policy_digest, m41_answer,
        sampled_time, captured_at, deletion_eligible_at, payload_bytes,
        source_evidence_read, storage_writes)
    VALUES (computed_identity, (target).kind, (target).name, (target).version, root_identity,
            capture_key, subject, declaration_row.owner_oid, declaration_digest, policy_digest,
            answer, (answer ->> 'sampled_time')::timestamptz, captured_at,
            deletion_eligible_at, payload_bytes, source_reads, 1)
    ON CONFLICT (snapshot_identity) DO NOTHING;
    SELECT * INTO existing
    FROM pgreact_internal.evidence_snapshots
    WHERE evidence_snapshots.snapshot_identity = computed_identity;
    IF existing.snapshot_identity IS DISTINCT FROM computed_identity THEN
        RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_STORAGE_FAILURE', 'ERROR', NULL,
                'the retained evidence could not be read after capture',
                'Retry the capture after resolving storage pressure.')));
    END IF;
    INSERT INTO pgreact_internal.evidence_snapshot_audits(
        snapshot_identity, operation, outcome, actor_oid, owner_oid, details)
    VALUES (computed_identity, 'capture', 'captured', session_user::regrole::oid,
            existing.owner_oid, jsonb_build_object('payload_bytes', payload_bytes))
    ON CONFLICT (snapshot_identity, operation) DO NOTHING;
    RETURN pgreact_internal.m42_result('capture', 'available', computed_identity,
        existing.m41_answer, pgreact_internal.m42_snapshot_metadata(existing), '[]');
EXCEPTION WHEN OTHERS THEN
    RETURN pgreact_internal.m42_result('capture', 'unavailable', NULL, NULL, '{}',
        jsonb_build_array(pgreact_internal.m42_finding(
            'M42_STORAGE_FAILURE', 'ERROR', NULL,
            'the evidence snapshot was not retained',
            'Retry after resolving the reported PostgreSQL storage error.',
            jsonb_build_object('sqlstate', SQLSTATE))));
END
$m42$;

CREATE FUNCTION pgreact_api.read_evidence_snapshot(
    target pgreact_api.target,
    root_identity text,
    capture_key text
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
DECLARE computed_identity text;
    row_data pgreact_internal.evidence_snapshots%ROWTYPE;
    audit_row record;
    tombstone record;
BEGIN
    IF target IS NULL OR (target).kind IS DISTINCT FROM 'decision_program'
       OR (target).name IS NULL OR (target).version IS NULL
       OR root_identity IS NULL OR length(root_identity) > 2048
       OR capture_key IS NULL OR capture_key !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$' THEN
        RETURN pgreact_internal.m42_result('read', 'unsupported', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_OPTIONS_INVALID', 'ERROR', NULL,
                'target, root_identity, and capture_key are required',
                'Use the exact values returned by a successful capture.')));
    END IF;
    computed_identity := pgreact_internal.m42_identity(
        (target).kind, (target).name, (target).version, root_identity, capture_key);
    SELECT * INTO row_data FROM pgreact_internal.evidence_snapshots
    WHERE evidence_snapshots.snapshot_identity = computed_identity;
    IF FOUND THEN
        IF NOT pg_has_role(session_user, row_data.owner_oid, 'USAGE')
           AND NOT pgreact_internal.is_operator_admin() THEN
            RETURN pgreact_internal.m42_result('read', 'unavailable', NULL, NULL, '{}',
                jsonb_build_array(pgreact_internal.m42_finding(
                    'M42_TARGET_UNAUTHORIZED', 'WARNING', NULL,
                    'the retained evidence is not available to this caller',
                    'Use the declaration owner or configured operator role.')));
        END IF;
        RETURN pgreact_internal.m42_result(
            'read', CASE WHEN row_data.deletion_eligible_at <= clock_timestamp()
                         THEN 'deletion_eligible' ELSE 'available' END,
            row_data.snapshot_identity, row_data.m41_answer,
            pgreact_internal.m42_snapshot_metadata(row_data), '[]');
    END IF;
    SELECT * INTO audit_row FROM pgreact_internal.evidence_snapshot_audits
    WHERE evidence_snapshot_audits.snapshot_identity = computed_identity AND operation = 'capture';
    SELECT * INTO tombstone FROM pgreact_internal.retention_tombstones
    WHERE family = 'evidence_snapshots' AND historical_identity = computed_identity;
    IF FOUND AND audit_row IS NOT NULL
       AND (pg_has_role(session_user, audit_row.owner_oid, 'USAGE')
            OR pgreact_internal.is_operator_admin()) THEN
        RETURN pgreact_internal.m42_result('read', 'deleted', computed_identity, NULL,
            jsonb_build_object('tombstone', jsonb_build_object(
                'historical_identity', tombstone.historical_identity,
                'outcome', tombstone.outcome,
                'detail_digest', encode(tombstone.detail_digest, 'hex'),
                'policy_version', tombstone.policy_version,
                'pruned_at', tombstone.pruned_at)),
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_SNAPSHOT_DELETED', 'INFO', NULL,
                'the retained evidence was deleted',
                'Use a new capture_key for a new historical record.')));
    END IF;
    RETURN pgreact_internal.m42_result('read', 'missing', NULL, NULL, '{}',
        jsonb_build_array(pgreact_internal.m42_finding(
            'M42_SNAPSHOT_MISSING', 'WARNING', NULL,
            'the requested retained evidence is unavailable',
            'Use the exact identity returned by capture or restore a verified backup.')));
END
$m42$;

CREATE FUNCTION pgreact_api.delete_evidence_snapshot(
    target pgreact_api.target,
    root_identity text,
    capture_key text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
DECLARE computed_identity text;
    row_data pgreact_internal.evidence_snapshots%ROWTYPE;
    batch_id uuid := gen_random_uuid();
    policy_version bigint;
BEGIN
    IF target IS NULL OR (target).kind IS DISTINCT FROM 'decision_program'
       OR (target).name IS NULL OR (target).version IS NULL
       OR root_identity IS NULL OR length(root_identity) > 2048
       OR capture_key IS NULL OR capture_key !~ '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$' THEN
        RETURN pgreact_internal.m42_result('delete', 'unsupported', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_OPTIONS_INVALID', 'ERROR', NULL,
                'target, root_identity, and capture_key are required',
                'Use the exact values returned by a successful capture.')));
    END IF;
    computed_identity := pgreact_internal.m42_identity(
        (target).kind, (target).name, (target).version, root_identity, capture_key);
    PERFORM pg_advisory_xact_lock(hashtextextended(computed_identity, 420042));
    SELECT * INTO row_data FROM pgreact_internal.evidence_snapshots
    WHERE evidence_snapshots.snapshot_identity = computed_identity
    FOR UPDATE;
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM pgreact_internal.retention_tombstones
                   WHERE family = 'evidence_snapshots'
                     AND historical_identity = computed_identity) THEN
            RETURN pgreact_internal.m42_result('delete', 'deleted', computed_identity, NULL, '{}',
                jsonb_build_array(pgreact_internal.m42_finding(
                    'M42_SNAPSHOT_DELETED', 'INFO', NULL,
                    'the snapshot was already deleted',
                    'Deletion is idempotent for this identity.')));
        END IF;
        RETURN pgreact_internal.m42_result('delete', 'missing', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_SNAPSHOT_MISSING', 'WARNING', NULL,
                'the requested retained evidence is unavailable',
                'Use the exact identity returned by capture.')));
    END IF;
    IF NOT pg_has_role(session_user, row_data.owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RETURN pgreact_internal.m42_result('delete', 'unavailable', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_TARGET_UNAUTHORIZED', 'WARNING', NULL,
                'the retained evidence is not available to this caller',
                'Use the declaration owner or configured operator role.')));
    END IF;
    IF row_data.deletion_eligible_at > clock_timestamp() THEN
        RETURN pgreact_internal.m42_result('delete', 'available', row_data.snapshot_identity,
            row_data.m41_answer, pgreact_internal.m42_snapshot_metadata(row_data),
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_DELETE_NOT_ELIGIBLE', 'WARNING', 'deletion_eligible_at',
                'the snapshot cannot be deleted before its eligibility time',
                'Retry after deletion_eligible_at.')));
    END IF;
    SELECT rp.policy_version INTO policy_version
    FROM pgreact_internal.retention_policies AS rp WHERE rp.singleton;
    INSERT INTO pgreact_internal.retention_batches(
        batch_id, policy_version, requested_cutoff, effective_cutoff, state,
        family_counts, finished_at)
    VALUES (batch_id, policy_version, clock_timestamp() - interval '1 microsecond',
            clock_timestamp(), 'COMPLETED', '{"evidence_snapshots": 1}'::jsonb, clock_timestamp());
    PERFORM pgreact_internal.retention_record_tombstone(
        'evidence_snapshots', row_data.snapshot_identity, 'evidence_snapshot',
        to_jsonb(row_data), policy_version, batch_id);
    DELETE FROM pgreact_internal.evidence_snapshots
        WHERE evidence_snapshots.snapshot_identity = computed_identity;
    INSERT INTO pgreact_internal.evidence_snapshot_audits(
        snapshot_identity, operation, outcome, actor_oid, owner_oid, details)
    VALUES (computed_identity, 'delete', 'deleted', session_user::regrole::oid,
            row_data.owner_oid, jsonb_build_object('batch_id', batch_id))
    ON CONFLICT (snapshot_identity, operation) DO NOTHING;
    RETURN pgreact_internal.m42_result('delete', 'deleted', computed_identity, NULL,
        jsonb_build_object('batch_id', batch_id),
        jsonb_build_array(pgreact_internal.m42_finding(
            'M42_SNAPSHOT_DELETED', 'INFO', NULL,
            'the retained evidence was deleted',
            'Reads now return the stable tombstone.')));
END
$m42$;

ALTER FUNCTION pgreact_internal.retention_preview_data(timestamptz, integer)
    RENAME TO retention_preview_data_m21;

CREATE FUNCTION pgreact_internal.retention_preview_data(
    target_cutoff timestamptz, target_batch_size integer)
RETURNS TABLE(
    family text, relation_name text, eligible_rows bigint, eligible_bytes bigint,
    protected_rows bigint, protected_bytes bigint, blocking_reasons jsonb,
    lost_capabilities text[], remediation text, has_more boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
DECLARE candidate_rows bigint; candidate_bytes bigint; rows_ok bigint; bytes_ok bigint;
BEGIN
    RETURN QUERY SELECT base.family, base.relation_name, base.eligible_rows, base.eligible_bytes,
        base.protected_rows, base.protected_bytes, base.blocking_reasons,
        base.lost_capabilities, base.remediation, base.has_more
    FROM pgreact_internal.retention_preview_data_m21(target_cutoff, target_batch_size) base
    WHERE base.family <> 'evidence_snapshots';
    SELECT count(*), COALESCE(sum(pg_column_size(s)), 0)
    INTO candidate_rows, candidate_bytes
    FROM pgreact_internal.evidence_snapshots s WHERE s.captured_at < target_cutoff;
    SELECT count(*), COALESCE(sum(pg_column_size(s)), 0)
    INTO rows_ok, bytes_ok
    FROM pgreact_internal.evidence_snapshots s
    WHERE s.captured_at < target_cutoff AND s.deletion_eligible_at <= clock_timestamp();
    RETURN QUERY SELECT 'evidence_snapshots', 'pgreact_internal.evidence_snapshots',
        rows_ok, bytes_ok, candidate_rows - rows_ok, candidate_bytes - bytes_ok,
        jsonb_build_object('deletion_eligibility', candidate_rows - rows_ok),
        ARRAY['historical causal-path detail']::text[],
        'use the names-first snapshot read before deletion or restore a verified backup',
        rows_ok > target_batch_size;
END
$m42$;

ALTER FUNCTION pgreact_internal.retention_apply_family(text, timestamptz, integer, bigint, uuid)
    RENAME TO retention_apply_family_m21;

CREATE FUNCTION pgreact_internal.retention_apply_family(
    target_family text, target_cutoff timestamptz, target_batch_size integer,
    target_policy_version bigint, target_batch_id uuid)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
DECLARE item record; removed bigint := 0;
BEGIN
    IF target_family <> 'evidence_snapshots' THEN
        RETURN pgreact_internal.retention_apply_family_m21(
            target_family, target_cutoff, target_batch_size,
            target_policy_version, target_batch_id);
    END IF;
    FOR item IN SELECT * FROM pgreact_internal.evidence_snapshots s
        WHERE s.captured_at < target_cutoff AND s.deletion_eligible_at <= clock_timestamp()
        ORDER BY s.captured_at, s.snapshot_identity LIMIT target_batch_size LOOP
        PERFORM pgreact_internal.retention_record_tombstone(
            target_family, item.snapshot_identity, 'evidence_snapshot',
            to_jsonb(item), target_policy_version, target_batch_id);
        DELETE FROM pgreact_internal.evidence_snapshots
        WHERE snapshot_identity = item.snapshot_identity;
        removed := removed + 1;
    END LOOP;
    RETURN removed;
END
$m42$;

ALTER FUNCTION pgreact_api.retention_apply(timestamptz, integer)
    RENAME TO retention_apply_m21;

CREATE FUNCTION pgreact_api.retention_apply(requested_cutoff timestamptz, batch_size integer DEFAULT 1000)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
DECLARE policy_row record; effective_cutoff timestamptz; new_batch_id uuid;
    family_name text; removed bigint; total_removed bigint := 0; counts jsonb := '{}'::jsonb;
    preview jsonb; remaining bigint; batch_state text;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'M21_RETENTION_FORBIDDEN: operator role required'; END IF;
    IF requested_cutoff >= clock_timestamp() THEN RAISE EXCEPTION 'M21_RETENTION_CUTOFF: cutoff must be in the past'; END IF;
    IF batch_size NOT BETWEEN 1 AND 10000 THEN RAISE EXCEPTION 'M21_RETENTION_BATCH_SIZE: must be between 1 and 10000'; END IF;
    PERFORM pg_advisory_xact_lock(5788046901200021);
    SELECT * INTO STRICT policy_row FROM pgreact_internal.retention_policies WHERE singleton;
    IF NOT policy_row.enabled THEN RAISE EXCEPTION 'M21_RETENTION_DISABLED: enable a policy before apply'; END IF;
    effective_cutoff := greatest(requested_cutoff, clock_timestamp() - GREATEST(
        policy_row.full_detail_horizon, policy_row.minimum_audit_horizon,
        policy_row.replay_horizon, policy_row.rollback_horizon,
        policy_row.deduplication_horizon, policy_row.explanation_horizon,
        policy_row.reconciliation_horizon, policy_row.recovery_horizon));
    preview := pgreact_api.retention_preview(requested_cutoff, batch_size);
    IF (preview #>> '{totals,eligible_rows}')::bigint = 0 THEN
        RETURN preview || jsonb_build_object('outcome','NOOP','batch_id',NULL);
    END IF;
    new_batch_id := gen_random_uuid();
    INSERT INTO pgreact_internal.retention_batches(
        batch_id, policy_version, requested_cutoff, effective_cutoff, state, protected_reasons)
    VALUES (new_batch_id, policy_row.policy_version, requested_cutoff, effective_cutoff, 'RUNNING',
        COALESCE((SELECT jsonb_object_agg(item.value ->> 'family', item.value -> 'blocking_reasons')
                  FROM jsonb_array_elements(preview -> 'families') item), '{}'::jsonb));
    BEGIN
        FOREACH family_name IN ARRAY ARRAY[
            'evidence_snapshots','runtime_events','executions','derived_support_inputs',
            'negative_dependency_evidence','aggregate_dependency_evidence','derived_supports',
            'derived_repair_diagnostics','derived_reconciliations',
            'derivation_program_repair_diagnostics','derivation_program_iterations',
            'derivation_program_runs','window_corrections','window_diagnostics','window_audits',
            'clock_history','reconciliation_audit','metadata_rebuild_audits','agenda',
            'lifecycle_events'] LOOP
            removed := pgreact_internal.retention_apply_family(
                family_name, effective_cutoff, batch_size, policy_row.policy_version, new_batch_id);
            total_removed := total_removed + removed;
            counts := counts || jsonb_build_object(family_name, removed);
        END LOOP;
        SELECT COALESCE(sum(eligible_rows),0) INTO remaining
        FROM pgreact_internal.retention_preview_data(effective_cutoff, batch_size);
        batch_state := CASE WHEN remaining = 0 THEN 'COMPLETED' ELSE 'PARTIAL' END;
        UPDATE pgreact_internal.retention_batches SET state = batch_state,
            family_counts = counts, finished_at = clock_timestamp()
        WHERE retention_batches.batch_id = new_batch_id;
        RETURN preview || jsonb_build_object('outcome', lower(batch_state), 'batch_id', new_batch_id,
            'removed_rows', total_removed, 'family_counts', counts,
            'remaining_eligible_rows', remaining);
    EXCEPTION WHEN OTHERS THEN
        UPDATE pgreact_internal.retention_batches SET state = 'FAILED', family_counts = counts,
            finished_at = clock_timestamp(), error = jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM)
        WHERE retention_batches.batch_id = new_batch_id;
        RETURN jsonb_build_object('contract_version', 9, 'outcome', 'failed',
            'batch_id', new_batch_id, 'family_counts', counts,
            'error', jsonb_build_object('sqlstate', SQLSTATE, 'message', SQLERRM));
    END;
END
$m42$;

ALTER FUNCTION pgreact_api.retention_detail(text, text)
    RENAME TO retention_detail_m21;

CREATE FUNCTION pgreact_api.retention_detail(target_family text, target_identity text)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
    SELECT CASE
        WHEN $1 = 'evidence_snapshots' AND EXISTS (
            SELECT 1 FROM pgreact_internal.evidence_snapshots
            WHERE snapshot_identity = $2)
        THEN jsonb_build_object('contract_version', 9, 'retained', true,
            'family', $1, 'historical_identity', $2)
        WHEN $1 = 'evidence_snapshots' AND EXISTS (
            SELECT 1 FROM pgreact_internal.retention_tombstones
            WHERE family = $1 AND historical_identity = $2)
        THEN jsonb_build_object('contract_version', 9, 'retained', false,
            'diagnostic', jsonb_build_object('code', 'M21_HISTORY_NOT_RETAINED',
                'message', 'requested historical detail is outside retained coverage',
                'family', $1, 'historical_identity', $2))
        WHEN $1 = 'evidence_snapshots'
        THEN jsonb_build_object('contract_version', 9, 'retained', false,
            'diagnostic', jsonb_build_object('code', 'M42_SNAPSHOT_MISSING',
                'message', 'the requested evidence snapshot is unavailable'))
        ELSE pgreact_api.retention_detail_m21($1, $2)
    END
$m42$;

ALTER FUNCTION pgreact_api.retention_audit(integer)
    RENAME TO retention_audit_m21;

CREATE FUNCTION pgreact_api.retention_audit(limit_count integer DEFAULT 100)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
    SELECT pgreact_api.retention_audit_m21($1)
        || jsonb_build_object('snapshot_audits', COALESCE((
            SELECT jsonb_agg(to_jsonb(a) ORDER BY a.occurred_at DESC)
            FROM (SELECT * FROM pgreact_internal.evidence_snapshot_audits
                  ORDER BY occurred_at DESC LIMIT $1) a), '[]'::jsonb))
$m42$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m41;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m42$
BEGIN
    PERFORM pgreact_api.configure_roles_m41(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.capture_evidence_snapshot(pgreact_api.target,jsonb,jsonb,text), pgreact_api.read_evidence_snapshot(pgreact_api.target,text,text), pgreact_api.delete_evidence_snapshot(pgreact_api.target,text,text) TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
END
$m42$;

REVOKE ALL ON TABLE pgreact_internal.evidence_snapshots,
    pgreact_internal.evidence_snapshot_audits FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m42_finding(text,text,text,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m42_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m42_policy_findings(jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m42_result(text,text,text,jsonb,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m42_identity(text,text,text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m42_snapshot_metadata(pgreact_internal.evidence_snapshots) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.capture_evidence_snapshot(pgreact_api.target,jsonb,jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.read_evidence_snapshot(pgreact_api.target,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.delete_evidence_snapshot(pgreact_api.target,text,text) FROM PUBLIC;

COMMENT ON FUNCTION pgreact_api.capture_evidence_snapshot(pgreact_api.target,jsonb,jsonb,text) IS
    'M42 atomic capture of one complete historical M41 decision-result path';
COMMENT ON FUNCTION pgreact_api.read_evidence_snapshot(pgreact_api.target,text,text) IS
    'M42 names-first read of a retained historical M41 decision-result path';
COMMENT ON FUNCTION pgreact_api.delete_evidence_snapshot(pgreact_api.target,text,text) IS
    'M42 bounded owner or operator deletion after the declared eligibility time';
COMMENT ON EXTENSION pg_react IS
    'M42 opt-in evidence snapshots over the exact bounded M41 causal-path answer';
