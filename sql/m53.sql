-- M53 names-first explanation ergonomics over the installed M40-M44 contracts.

CREATE OR REPLACE FUNCTION pgreact_internal.m53_finding(
    code text, severity text, field_path text, message text, hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE
AS $m53$
    SELECT jsonb_build_object(
        'code', $1, 'severity', $2, 'blocking', $2 = 'ERROR',
        'field', $3, 'message', $4, 'hint', $5,
        'details', COALESCE($6, '{}'::jsonb))
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_finding_registry()
RETURNS jsonb
LANGUAGE SQL IMMUTABLE
AS $m53$
SELECT jsonb_build_array(
    jsonb_build_object('code', 'M53_EXPLAIN_QUESTION_CONFLICT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_EXPLANATION_REF_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_EXPLANATION_REF_STALE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M53_WORK_UNAVAILABLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M53_SNAPSHOT_IDENTITY_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_EXPLANATION_SUMMARY_UNSUPPORTED', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_TARGET_UNAVAILABLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M53_STATE_INCOMPLETE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M53_POLICY_KIND', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_API_VERSION', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_NAME', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_VERSION', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_FIELD_UNKNOWN', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_MEMBERS', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_MEMBER_LIMIT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_MEMBER_KIND', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_MEMBER_DUPLICATE', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_MEMBER_DECLARATION', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_SUPPORT_SHAPE', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_SUPPORT_LIMIT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_SUPPORT_KIND', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_SUPPORT_DECLARATION', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_DEPENDENCY_SHAPE', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_DEPENDENCY_LIMIT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_DEPENDENCY_IDENTITY', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_DEPENDENCY_SELF', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_DEPENDENCY_ENDPOINT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_DEPENDENCY_DUPLICATE', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_APPLICABILITY', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_EFFECTIVE_PERIOD', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_PAYLOAD_LIMIT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_DEPENDENCY_CYCLE', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_IMPORT_DOCUMENT', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_IMPORT_DIGEST', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_ADOPTION_REQUIRED', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_ADOPTION_DIGEST', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M53_POLICY_CROSS_PACKAGE', 'severity', 'ERROR'))
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_explain_question(options jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE
AS $m53$
DECLARE
    causal boolean := pgreact_internal.m41_requested(options);
    why_not boolean := pgreact_internal.m40_requested(options);
BEGIN
    IF causal AND why_not THEN RETURN 'conflict';
    ELSIF causal THEN RETURN 'causal_path';
    ELSIF why_not THEN RETURN 'why_not';
    END IF;
    RETURN 'ordinary';
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_explain_dispatch(
    target_name text, subject jsonb, options jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    question text := pgreact_internal.m53_explain_question(options);
BEGIN
    IF question = 'causal_path' THEN
        RETURN pgreact_internal.m41_explain(target_name, subject, options);
    ELSIF question = 'why_not' THEN
        RETURN pgreact_internal.m40_explain(target_name, subject, options);
    ELSIF question = 'conflict' THEN
        RETURN jsonb_build_object(
            'contract_version', 53,
            'operation', 'explain',
            'target', jsonb_build_object(
                'kind', '<unknown>', 'name', COALESCE(target_name, '<unknown>'),
                'version', NULL),
            'state', 'unsupported',
            'request', COALESCE(options, '{}'::jsonb),
            'subject', subject,
            'findings', jsonb_build_array(pgreact_internal.m53_finding(
                'M53_EXPLAIN_QUESTION_CONFLICT', 'ERROR', 'options',
                'why_not and causal_path cannot be requested together',
                'Pass one explanation question per call.')),
            'read_only', true,
            'truncated', false);
    END IF;
    RETURN pgreact_internal.m32_result(pgreact_api.explain_m31(
        pgreact_internal.m32_target(target_name), subject,
        pgreact_internal.m40_strip_options(
            pgreact_internal.m41_strip_options(options))));
END
$m53$;

DO $m53$
BEGIN
    IF to_regprocedure('pgreact.explain(text,jsonb,jsonb)') IS DISTINCT FROM
       'pgreact.explain(text,jsonb,jsonb)'::regprocedure THEN
        RAISE EXCEPTION 'M53_EXPLAIN_IDENTITY: frozen public explain function is missing';
    END IF;
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact.explain(
    name text,
    subject jsonb DEFAULT NULL,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_internal.m53_explain_dispatch($1, $2, $3)
$m53$;

CREATE FUNCTION pgreact.why_not(
    name text, subject jsonb, result_kind text, result_key jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_internal.m53_explain_dispatch(
        $1, $2, jsonb_build_object('why_not', jsonb_build_object(
            'result_kind', $3, 'result_key', $4)))
$m53$;

CREATE FUNCTION pgreact.trace(
    name text, subject jsonb, result_key jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_internal.m53_explain_dispatch(
        $1, $2, jsonb_build_object('causal_path', jsonb_build_object(
            'root_kind', 'decision_result', 'result_key', $3)))
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_work_reference(
    target_name text, work_id text
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    target_count integer;
    target_kind text;
    target_owner oid;
    subject_key bigint;
    generation bigint;
    revision bigint;
    event_kind text;
    consequence_identity text;
BEGIN
    IF work_id IS NULL OR work_id !~ '^-?[0-9]+$' THEN
        RETURN jsonb_build_object('valid', false);
    END IF;
    SELECT count(*) INTO target_count
    FROM (
        SELECT kind, object_name, owner_oid
        FROM pgreact_internal.api_declarations
        WHERE state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name, set.owner_oid
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
    ) targets
    WHERE object_name = target_name;
    IF target_count <> 1 THEN
        RETURN jsonb_build_object('valid', false);
    END IF;
    SELECT kind, owner_oid INTO target_kind, target_owner
    FROM (
        SELECT kind, object_name, owner_oid
        FROM pgreact_internal.api_declarations
        WHERE state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name, set.owner_oid
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
    ) targets
    WHERE object_name = target_name;
    IF NOT pg_has_role(session_user, target_owner, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin()
       AND NOT EXISTS (
           SELECT 1 FROM pgreact_internal.application_roles role_row
           WHERE role_row.role_kind = 'reader'
             AND pg_has_role(session_user, role_row.role_oid, 'member')) THEN
        RETURN jsonb_build_object('valid', false);
    END IF;
    IF target_kind = 'decision_program' THEN
        SELECT work.subject_key, state.generation, state.revision,
               CASE WHEN work.state = 'WINNER' THEN 'WINNER_REVISION'
                    ELSE 'NO_CANDIDATE' END
        INTO subject_key, generation, revision, event_kind
        FROM pgreact_internal.decision_work work
        JOIN pgreact_internal.decision_programs program USING (program_id)
        JOIN pgreact_internal.decision_subject_state state
          USING (program_id, subject_key)
        WHERE program.program_name = target_name
          AND work.subject_key = work_id::bigint;
        IF NOT FOUND THEN RETURN jsonb_build_object('valid', false); END IF;
        RETURN jsonb_build_object(
            'valid', true, 'target_kind', target_kind,
            'subject', to_jsonb(subject_key),
            'root', jsonb_build_object(
                'kind', 'decision_work', 'work_id', work_id,
                'generation', generation, 'revision', revision));
    ELSIF target_kind = 'rule' THEN
        SELECT episode.activation_generation, event.generation,
               event.event_kind, version.consequence_identity,
               activation.semantic_key
        INTO generation, revision, event_kind, consequence_identity, subject_key
        FROM pgreact_internal.agenda episode
        JOIN pgreact_internal.lifecycle_events event ON event.event_id = episode.event_id
        JOIN pgreact_internal.rule_versions version
          ON version.rule_version_id = episode.rule_version_id
        JOIN pgreact_internal.rules rule ON rule.rule_id = episode.rule_id
        JOIN pgreact_internal.activation_state activation
          ON activation.rule_version_id = episode.rule_version_id
         AND activation.activation_id = episode.activation_id
        WHERE rule.rule_name = target_name AND episode.episode_id::text = work_id;
        IF NOT FOUND THEN RETURN jsonb_build_object('valid', false); END IF;
        SELECT activation.revision INTO revision
        FROM pgreact_internal.activation_state activation
        JOIN pgreact_internal.agenda episode
          ON episode.rule_version_id = activation.rule_version_id
         AND episode.activation_id = activation.activation_id
        WHERE episode.episode_id::text = work_id
        ORDER BY activation.revision DESC LIMIT 1;
        RETURN jsonb_build_object(
            'valid', true, 'target_kind', target_kind,
            'subject', to_jsonb(subject_key),
            'root', jsonb_build_object(
                'kind', 'rule_work', 'work_id', work_id,
                'generation', generation, 'revision', revision,
                'event_kind', event_kind,
                'consequence_identity', consequence_identity));
    END IF;
    RETURN jsonb_build_object('valid', false);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('valid', false);
END
$m53$;

CREATE FUNCTION pgreact.trace(name text, work_id text)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
WITH resolved AS (
    SELECT pgreact_internal.m53_work_reference($1, $2) AS value
)
SELECT CASE WHEN value ->> 'valid' = 'true' THEN
    pgreact_internal.m53_explain_dispatch(
        $1, value -> 'subject',
        jsonb_build_object('causal_path', value -> 'root'))
    ELSE jsonb_build_object(
        'contract_version', 53, 'operation', 'trace', 'state', 'unavailable',
        'target', '{}'::jsonb, 'subject', NULL, 'request', '{}',
        'findings', jsonb_build_array(pgreact_internal.m53_finding(
            'M53_WORK_UNAVAILABLE', 'WARNING', NULL,
            'the requested work item is unavailable',
            'Use an authorized public work identity from pgreact.work.')),
        'read_only', true, 'truncated', false)
    END
FROM resolved
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_explanation_ref(answer jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $m53$
DECLARE
    root jsonb := answer -> 'root';
    root_kind text := root ->> 'kind';
    target jsonb := answer -> 'target';
BEGIN
    IF answer IS NULL OR jsonb_typeof(answer) IS DISTINCT FROM 'object'
       OR answer ->> 'contract_version' <> '27'
       OR answer ->> 'operation' <> 'explain'
       OR answer -> 'request' ->> 'causal_path' <> 'true'
       OR jsonb_typeof(target) IS DISTINCT FROM 'object'
       OR target ->> 'kind' IS NULL OR target ->> 'name' IS NULL
       OR target ->> 'version' IS NULL
       OR jsonb_typeof(root) IS DISTINCT FROM 'object'
       OR root_kind NOT IN ('decision_result', 'decision_work', 'rule_work')
       OR (root_kind IN ('decision_result', 'decision_work')
           AND target ->> 'kind' <> 'decision_program')
       OR (root_kind = 'rule_work' AND target ->> 'kind' <> 'rule')
       OR pgreact_internal.m40_subject_key(answer -> 'subject') IS NULL THEN
        RETURN NULL;
    END IF;
    IF root_kind = 'decision_result' THEN
        IF root ->> 'result_key' IS NULL
           OR pgreact_internal.m40_subject_key(root -> 'result_key') IS NULL THEN
            RETURN NULL;
        END IF;
        root := jsonb_build_object('kind', root_kind, 'result_key', root -> 'result_key');
    ELSIF root_kind = 'decision_work' THEN
        IF root ->> 'work_id' IS NULL OR root ->> 'generation' IS NULL
           OR root ->> 'revision' IS NULL THEN RETURN NULL; END IF;
        root := jsonb_build_object('kind', root_kind, 'work_id', root ->> 'work_id',
            'generation', root ->> 'generation', 'revision', root ->> 'revision');
    ELSE
        IF root ->> 'work_id' IS NULL OR root ->> 'generation' IS NULL
           OR root ->> 'revision' IS NULL OR root ->> 'event_kind' IS NULL
           OR root ->> 'consequence_identity' IS NULL THEN RETURN NULL; END IF;
        root := jsonb_build_object('kind', root_kind, 'work_id', root ->> 'work_id',
            'generation', root ->> 'generation', 'revision', root ->> 'revision',
            'event_kind', root ->> 'event_kind',
            'consequence_identity', root ->> 'consequence_identity');
    END IF;
    RETURN jsonb_build_object(
        'ref_version', 1, 'question_kind', 'causal_path',
        'target', jsonb_build_object(
            'kind', target ->> 'kind', 'name', target ->> 'name',
            'version', target ->> 'version'),
        'subject', answer -> 'subject', 'root', root);
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_reference_parts(reference jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $m53$
DECLARE
    target jsonb := reference -> 'target';
    subject jsonb := reference -> 'subject';
    root jsonb := reference -> 'root';
    root_kind text := root ->> 'kind';
BEGIN
    IF reference IS NULL OR octet_length(reference::text) > 65536
       OR jsonb_typeof(reference) IS DISTINCT FROM 'object'
       OR (SELECT count(*) FROM jsonb_object_keys(reference)) <> 5
       OR NOT (reference ?& ARRAY['ref_version', 'question_kind', 'target', 'subject', 'root'])
       OR reference ->> 'ref_version' <> '1'
       OR reference ->> 'question_kind' <> 'causal_path'
       OR jsonb_typeof(target) IS DISTINCT FROM 'object'
       OR (SELECT count(*) FROM jsonb_object_keys(target)) <> 3
       OR target ->> 'kind' IS NULL
       OR target ->> 'kind' NOT IN ('rule', 'decision_program')
       OR target ->> 'name' IS NULL OR target ->> 'version' IS NULL
       OR jsonb_typeof(root) IS DISTINCT FROM 'object'
       OR pgreact_internal.m40_subject_key(subject) IS NULL THEN
        RETURN jsonb_build_object('valid', false);
    END IF;
    IF root_kind = 'decision_result' THEN
        IF target ->> 'kind' <> 'decision_program'
           OR (SELECT count(*) FROM jsonb_object_keys(root)) <> 2
           OR jsonb_typeof(root -> 'result_key') NOT IN ('number', 'string')
           OR root ->> 'result_key' IS NULL
           OR pgreact_internal.m40_subject_key(root -> 'result_key') IS NULL THEN
            RETURN jsonb_build_object('valid', false);
        END IF;
    ELSIF root_kind = 'decision_work' THEN
        IF target ->> 'kind' <> 'decision_program'
           OR (SELECT count(*) FROM jsonb_object_keys(root)) <> 4
           OR root ->> 'work_id' IS NULL OR root ->> 'work_id' !~ '^-?[0-9]+$'
           OR root ->> 'generation' IS NULL OR root ->> 'generation' !~ '^[0-9]+$'
           OR root ->> 'revision' IS NULL OR root ->> 'revision' !~ '^[0-9]+$' THEN
            RETURN jsonb_build_object('valid', false);
        END IF;
    ELSIF root_kind = 'rule_work' THEN
        IF target ->> 'kind' <> 'rule'
           OR (SELECT count(*) FROM jsonb_object_keys(root)) <> 6
           OR root ->> 'work_id' IS NULL OR root ->> 'work_id' !~ '^-?[0-9]+$'
           OR root ->> 'generation' IS NULL OR root ->> 'generation' !~ '^[0-9]+$'
           OR root ->> 'revision' IS NULL OR root ->> 'revision' !~ '^[0-9]+$'
           OR root ->> 'event_kind' NOT IN ('ACTIVATE', 'DEACTIVATE')
           OR root ->> 'consequence_identity' IS NULL THEN
            RETURN jsonb_build_object('valid', false);
        END IF;
    ELSE
        RETURN jsonb_build_object('valid', false);
    END IF;
    RETURN jsonb_build_object('valid', true, 'question_kind', 'causal_path',
        'target', target, 'subject', subject, 'root', root);
END
$m53$;

CREATE FUNCTION pgreact.trace(explanation_ref jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    parts jsonb := pgreact_internal.m53_reference_parts(explanation_ref);
    answer jsonb;
BEGIN
    IF parts ->> 'valid' <> 'true' THEN
        RETURN jsonb_build_object(
            'contract_version', 53, 'operation', 'trace', 'state', 'unsupported',
            'target', '{}'::jsonb, 'subject', NULL,
            'findings', jsonb_build_array(pgreact_internal.m53_finding(
                'M53_EXPLANATION_REF_INVALID', 'ERROR', 'explanation_ref',
                'the explanation reference is invalid',
                'Use the exact public reference returned by a complete trace.')),
            'read_only', true, 'truncated', false);
    END IF;
    answer := pgreact_internal.m53_explain_dispatch(
        parts -> 'target' ->> 'name', parts -> 'subject',
        jsonb_build_object('causal_path', parts -> 'root'));
    IF answer -> 'target' ->> 'version' IS DISTINCT FROM parts -> 'target' ->> 'version' THEN
        RETURN answer || jsonb_build_object(
            'state', 'unavailable',
            'findings', jsonb_build_array(pgreact_internal.m53_finding(
                'M53_EXPLANATION_REF_STALE', 'WARNING', 'target.version',
                'the referenced target version is no longer current',
                'Create a new trace reference from the current target.')));
    END IF;
    RETURN answer;
END
$m53$;

CREATE FUNCTION pgreact.compare(
    proposed pgreact_api.declaration, why_changed boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact.compare(
        $1, pgreact_internal.m32_target(($1).name, ($1).kind),
        CASE WHEN $2 THEN '{"why_changed":true}'::jsonb ELSE '{}'::jsonb END)
$m53$;

CREATE FUNCTION pgreact.semantic_diff(proposed pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_api.semantic_diff(
        $1, pgreact_internal.m32_target(($1).name, ($1).kind))
$m53$;

CREATE FUNCTION pgreact.capture_evidence(
    explanation_ref jsonb, capture_key text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    parts jsonb := pgreact_internal.m53_reference_parts(explanation_ref);
    target pgreact_api.target;
    root jsonb;
BEGIN
    IF parts ->> 'valid' <> 'true'
       OR parts ->> 'question_kind' <> 'causal_path'
       OR parts -> 'root' ->> 'kind' <> 'decision_result' THEN
        RETURN pgreact_internal.m42_result('capture', 'unsupported', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m53_finding(
                'M53_EXPLANATION_REF_INVALID', 'ERROR', 'explanation_ref',
                'capture requires a valid decision-result trace reference',
                'Pass explanation_ref from a complete decision-result trace.')));
    END IF;
    target := pgreact_api.target(
        parts -> 'target' ->> 'kind', parts -> 'target' ->> 'name',
        parts -> 'target' ->> 'version');
    root := jsonb_build_object(
        'root_kind', 'decision_result',
        'result_key', parts -> 'root' -> 'result_key');
    RETURN pgreact_api.capture_evidence_snapshot(
        target, parts -> 'subject', root, capture_key);
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_evidence_by_identity(
    snapshot_identity text, operation text
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    row_data pgreact_internal.evidence_snapshots%ROWTYPE;
    audit_row record;
    tombstone record;
    target pgreact_api.target;
BEGIN
    IF operation NOT IN ('read', 'delete') OR snapshot_identity IS NULL
       OR octet_length(snapshot_identity) > 4096 THEN
        RETURN pgreact_internal.m42_result(operation, 'unsupported', NULL, NULL, '{}',
            jsonb_build_array(pgreact_internal.m53_finding(
                'M53_SNAPSHOT_IDENTITY_INVALID', 'ERROR', 'snapshot_identity',
                'snapshot_identity must be at most 4096 bytes',
                'Pass the exact snapshot_identity returned by capture.')));
    END IF;
    SELECT * INTO row_data
    FROM pgreact_internal.evidence_snapshots
    WHERE evidence_snapshots.snapshot_identity = m53_evidence_by_identity.snapshot_identity;
    IF FOUND THEN
        IF NOT pg_has_role(session_user, row_data.owner_oid, 'USAGE')
           AND NOT pgreact_internal.is_operator_admin() THEN
            RETURN pgreact_internal.m42_result(operation, 'unavailable', NULL, NULL, '{}',
                jsonb_build_array(pgreact_internal.m42_finding(
                    'M42_TARGET_UNAUTHORIZED', 'WARNING', NULL,
                    'the retained evidence is not available to this caller',
                    'Use the declaration owner or configured operator role.')));
        END IF;
        target := pgreact_api.target(row_data.target_kind, row_data.target_name,
                                     row_data.target_version);
        IF operation = 'read' THEN
            RETURN pgreact_api.read_evidence_snapshot(
                target, row_data.root_identity, row_data.capture_key);
        END IF;
        RETURN pgreact_api.delete_evidence_snapshot(
            target, row_data.root_identity, row_data.capture_key);
    END IF;
    SELECT * INTO audit_row
    FROM pgreact_internal.evidence_snapshot_audits
    WHERE evidence_snapshot_audits.snapshot_identity =
              m53_evidence_by_identity.snapshot_identity
      AND operation = 'capture';
    SELECT * INTO tombstone
    FROM pgreact_internal.retention_tombstones
    WHERE family = 'evidence_snapshots'
      AND historical_identity = m53_evidence_by_identity.snapshot_identity;
    IF operation = 'read' AND FOUND AND audit_row IS NOT NULL
       AND (pg_has_role(session_user, audit_row.owner_oid, 'USAGE')
            OR pgreact_internal.is_operator_admin()) THEN
        RETURN pgreact_internal.m42_result('read', 'deleted', snapshot_identity, NULL,
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
    IF operation = 'delete' AND FOUND THEN
        RETURN pgreact_internal.m42_result('delete', 'deleted', snapshot_identity, NULL, '{}',
            jsonb_build_array(pgreact_internal.m42_finding(
                'M42_SNAPSHOT_DELETED', 'INFO', NULL,
                'the snapshot was already deleted',
                'Deletion is idempotent for this identity.')));
    END IF;
    RETURN pgreact_internal.m42_result(operation, 'missing', NULL, NULL, '{}',
        jsonb_build_array(pgreact_internal.m42_finding(
            'M42_SNAPSHOT_MISSING', 'WARNING', NULL,
            'the requested retained evidence is unavailable',
            'Use the exact identity returned by capture.')));
END
$m53$;

CREATE FUNCTION pgreact.read_evidence(snapshot_identity text)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_internal.m53_evidence_by_identity($1, 'read')
$m53$;

CREATE FUNCTION pgreact.delete_evidence(snapshot_identity text)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_internal.m53_evidence_by_identity($1, 'delete')
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_state(state text)
RETURNS text
LANGUAGE SQL IMMUTABLE
AS $m53$
    SELECT CASE
        WHEN $1 IN ('complete', 'ready', 'already_present', 'available', 'deletion_eligible') THEN 'complete'
        WHEN $1 = 'partial' THEN 'partial'
        WHEN $1 IN ('unavailable', 'missing', 'deleted', 'changed') THEN 'unavailable'
        WHEN $1 IN ('unsupported', 'invalid', 'attention') THEN 'unsupported'
        ELSE 'unavailable'
    END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_next_actions(
    findings jsonb, origin_state text, origin text
)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $m53$
DECLARE
    finding jsonb;
    action jsonb;
    actions jsonb := '[]'::jsonb;
    code text;
    field_name text;
    action_name text;
    retryable boolean;
BEGIN
    FOR finding IN
        SELECT value FROM jsonb_array_elements(
            CASE WHEN jsonb_typeof(findings) = 'array' THEN findings ELSE '[]'::jsonb END)
    LOOP
        code := COALESCE(finding ->> 'code', 'M53_STATE_INCOMPLETE');
        field_name := COALESCE(finding ->> 'field', finding ->> 'field_path');
        IF code LIKE '%UNAUTHORIZED%' OR code LIKE '%RLS%' THEN
            action_name := 'grant_access'; retryable := false;
        ELSIF code LIKE '%LIMIT%' OR code LIKE '%PARTIAL%' THEN
            action_name := 'increase_limit'; retryable := true;
            field_name := COALESCE(field_name, 'limit');
        ELSIF code LIKE '%POLICY_MISSING%' OR code LIKE '%UNSUPPORTED%'
              OR code LIKE '%INVALID%' OR code LIKE '%AMBIGUOUS%' THEN
            action_name := 'stop'; retryable := false;
        ELSIF code LIKE '%DELETED%' THEN
            action_name := 'recapture'; retryable := false;
        ELSIF code LIKE '%DRIFT%' OR code LIKE '%SCHEMA%' THEN
            action_name := 'repair_schema'; retryable := false;
        ELSIF code LIKE '%NOT_FOUND%' OR code LIKE '%STALE%' THEN
            action_name := 'refresh_target'; retryable := true;
        ELSE
            action_name := 'retry'; retryable := true;
        END IF;
        action := jsonb_build_object(
            'action', action_name, 'reason_code', code,
            'safe_to_retry', retryable,
            'parameters', CASE WHEN field_name IS NULL THEN '{}'::jsonb
                               ELSE jsonb_build_object('field', field_name) END);
        IF NOT actions @> jsonb_build_array(action) THEN
            actions := actions || jsonb_build_array(action);
        END IF;
        IF jsonb_array_length(actions) >= 16 THEN EXIT; END IF;
    END LOOP;
    IF jsonb_array_length(actions) = 0 AND
       pgreact_internal.m53_state(origin_state) <> 'complete' THEN
        actions := jsonb_build_array(jsonb_build_object(
            'action', CASE WHEN pgreact_internal.m53_state(origin_state) = 'unsupported'
                           THEN 'stop' ELSE 'retry' END,
            'reason_code', 'M53_STATE_INCOMPLETE',
            'safe_to_retry', pgreact_internal.m53_state(origin_state) <> 'unsupported',
            'parameters', '{}'::jsonb));
    END IF;
    RETURN actions;
END
$m53$;

CREATE FUNCTION pgreact.explanation_summary(answer jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $m53$
DECLARE
    contract text := answer ->> 'contract_version';
    origin text;
    question_kind text;
    state text;
    explanation_state text;
    availability_state text := 'current';
    target jsonb := COALESCE(answer -> 'target', '{}'::jsonb);
    subject jsonb := answer -> 'subject';
    reference jsonb;
    evidence_point jsonb := '{}';
    semantic_digest text;
    limits jsonb := COALESCE(answer -> 'limits', '{}'::jsonb);
    findings jsonb := COALESCE(answer -> 'findings', '[]'::jsonb);
    next_actions jsonb;
    children jsonb := '[]'::jsonb;
    item jsonb;
    why jsonb;
    nested jsonb;
    complete boolean := false;
    seen integer := 0;
BEGIN
    IF answer IS NULL OR jsonb_typeof(answer) IS DISTINCT FROM 'object'
       OR contract !~ '^[0-9]+$' THEN
        RETURN jsonb_build_object(
            'contract_version', 53, 'origin', 'unsupported',
            'question_kind', 'unsupported', 'target', '{}'::jsonb,
            'subject', NULL, 'explanation_ref', NULL,
            'availability_state', 'unsupported', 'origin_state', 'unsupported',
            'explanation_state', 'unsupported', 'complete', false,
            'evidence_point', '{}', 'semantic_digest', NULL, 'limits', '{}',
            'findings', jsonb_build_array(pgreact_internal.m53_finding(
                'M53_EXPLANATION_SUMMARY_UNSUPPORTED', 'ERROR', NULL,
                'the supplied result contract is unsupported',
                'Pass an installed Area 2 explanation result.')),
            'next_actions', jsonb_build_array(jsonb_build_object(
                'action', 'stop', 'reason_code', 'M53_EXPLANATION_SUMMARY_UNSUPPORTED',
                'safe_to_retry', false, 'parameters', '{}'::jsonb)));
    END IF;
    IF contract = '14' THEN
        origin := 'current'; question_kind := 'current';
        state := COALESCE(answer ->> 'state', answer ->> 'status', 'complete');
        evidence_point := COALESCE(answer -> 'evidence', '{}');
    ELSIF contract = '26' THEN
        origin := 'why_not'; question_kind := 'why_not';
        state := COALESCE(answer ->> 'state', 'unsupported');
        evidence_point := COALESCE(answer -> 'evidence', '{}');
        limits := COALESCE(answer -> 'limits', '{}');
    ELSIF contract = '27' AND answer ->> 'operation' = 'explain'
          AND answer -> 'request' ->> 'causal_path' = 'true' THEN
        origin := 'causal_path'; question_kind := 'causal_path';
        state := COALESCE(answer ->> 'state', 'unsupported');
        evidence_point := jsonb_build_object(
            'sampled_time', answer -> 'sampled_time',
            'authoritative_frontier', answer -> 'authoritative_frontier',
            'digests', COALESCE(answer -> 'digests', '{}'::jsonb));
        reference := pgreact_internal.m53_explanation_ref(answer);
        semantic_digest := answer -> 'digests' ->> 'semantic';
    ELSIF contract = '25' AND answer ->> 'operation' = 'compare' THEN
        origin := 'why_changed'; question_kind := 'why_changed';
        state := COALESCE(answer ->> 'state', 'unsupported');
        evidence_point := COALESCE(answer -> 'evidence', '{}');
        semantic_digest := answer -> 'evidence' -> 'why_changed' ->> 'explanation_digest';
        limits := jsonb_build_object(
            'evidence_limit', answer -> 'evidence' -> 'why_changed' -> 'evidence_limit');
        FOR item IN
            SELECT value FROM jsonb_array_elements(
                COALESCE(answer -> 'delta', '[]'::jsonb)
                || COALESCE(answer -> 'lifecycle', '[]'::jsonb))
        LOOP
            why := item -> 'why_changed';
            IF jsonb_typeof(why) = 'object' THEN
                seen := seen + 1;
                IF seen <= 256 THEN
                    children := children || jsonb_build_array(jsonb_build_object(
                        'origin', 'why_changed', 'question_kind', 'why_changed',
                        'target', target,
                        'subject', to_jsonb(COALESCE(item ->> 'subject_key', item ->> 'result_key')),
                        'explanation_ref', NULL,
                        'availability_state', CASE WHEN why ->> 'state' = 'complete'
                                                   THEN 'current' ELSE 'unavailable' END,
                        'origin_state', why ->> 'state',
                        'explanation_state', pgreact_internal.m53_state(why ->> 'state'),
                        'complete', why ->> 'state' = 'complete',
                        'evidence_point', COALESCE(why -> 'evidence', '{}'),
                        'semantic_digest', why ->> 'explanation_digest',
                        'limits', '{}', 'findings', '[]'::jsonb,
                        'next_actions', pgreact_internal.m53_next_actions(
                            '[]'::jsonb, why ->> 'state', 'why_changed')));
                END IF;
            END IF;
        END LOOP;
        IF seen > 256 THEN state := 'partial'; END IF;
    ELSIF contract = '28' THEN
        origin := 'retained_causal_path'; question_kind := 'causal_path';
        state := COALESCE(answer ->> 'state', 'unsupported');
        IF state IN ('available', 'deletion_eligible')
           AND jsonb_typeof(answer -> 'snapshot') = 'object' THEN
            nested := answer -> 'snapshot';
            explanation_state := pgreact_internal.m53_state(nested ->> 'state');
            complete := explanation_state = 'complete';
            target := COALESCE(answer -> 'metadata' -> 'target', '{}');
            subject := nested -> 'subject';
            evidence_point := COALESCE(answer -> 'metadata', '{}');
            limits := COALESCE(nested -> 'limits', '{}');
            semantic_digest := nested -> 'digests' ->> 'semantic';
            reference := pgreact_internal.m53_explanation_ref(nested);
            availability_state := 'historical';
        ELSIF state = 'deleted' THEN
            availability_state := 'deleted';
        ELSIF state = 'missing' THEN
            availability_state := 'missing';
        ELSE
            availability_state := 'unavailable';
        END IF;
    ELSIF contract = '43' AND answer ->> 'operation' = 'semantic_diff' THEN
        origin := 'semantic_difference'; question_kind := 'semantic_difference';
        state := COALESCE(answer ->> 'state', 'unsupported');
        evidence_point := jsonb_build_object(
            'proposed_declaration_digest', answer -> 'proposed_declaration_digest',
            'deployed_declaration_digest', answer -> 'deployed_declaration_digest',
            'completeness', COALESCE(answer -> 'completeness', '{}'));
        semantic_digest := answer ->> 'semantic_digest';
        complete := COALESCE((answer -> 'completeness' ->> 'complete')::boolean,
                             state = 'ready');
    ELSE
        RETURN pgreact.explanation_summary(NULL);
    END IF;
    IF explanation_state IS NULL THEN
        explanation_state := pgreact_internal.m53_state(state);
    END IF;
    IF NOT complete THEN complete := explanation_state = 'complete'; END IF;
    next_actions := pgreact_internal.m53_next_actions(findings, state, origin);
    RETURN jsonb_build_object(
        'contract_version', 53, 'origin', origin,
        'question_kind', question_kind, 'target', target, 'subject', subject,
        'explanation_ref', reference, 'availability_state', availability_state,
        'origin_state', state, 'explanation_state', explanation_state,
        'complete', complete, 'evidence_point', evidence_point,
        'semantic_digest', semantic_digest, 'limits', limits,
        'findings', findings, 'next_actions', next_actions)
        || CASE WHEN jsonb_array_length(children) > 0 OR origin = 'why_changed'
                THEN jsonb_build_object('children', children) ELSE '{}'::jsonb END;
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_capability_questions(target_kind text)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE
AS $m53$
SELECT jsonb_build_array(
    jsonb_build_object(
        'question_kind', 'current',
        'supported', $1 IS NULL OR $1 IN ('rule','decision_program','policy_set'),
        'target_kinds', jsonb_build_array('rule','decision_program','policy_set'),
        'result_kinds', '[]'::jsonb, 'root_kinds', '[]'::jsonb,
        'function', 'pgreact.explain',
        'arguments', jsonb_build_array('name','subject'),
        'advanced_option', NULL,
        'default_limits', '{}'::jsonb, 'maximum_limits', '{}'::jsonb,
        'finding', NULL),
    jsonb_build_object(
        'question_kind', 'why_not',
        'supported', $1 IS NULL OR $1 IN ('rule','decision_program','policy_set'),
        'target_kinds', jsonb_build_array('rule','decision_program','policy_set'),
        'result_kinds', jsonb_build_array('rule_match','decision_result','derived_fact','policy_eligibility'),
        'root_kinds', '[]'::jsonb, 'function', 'pgreact.why_not',
        'arguments', jsonb_build_array('name','subject','result_kind','result_key'),
        'advanced_option', 'why_not',
        'default_limits', jsonb_build_object('candidate_limit',1000,'cause_limit',32),
        'maximum_limits', jsonb_build_object('cause_limit',1000), 'finding', NULL),
    jsonb_build_object(
        'question_kind', 'causal_path',
        'supported', $1 IS NULL OR $1 IN ('rule','decision_program'),
        'target_kinds', jsonb_build_array('rule','decision_program'),
        'result_kinds', '[]'::jsonb,
        'root_kinds', CASE WHEN $1 = 'rule' THEN jsonb_build_array('rule_work')
                           WHEN $1 = 'decision_program' THEN jsonb_build_array('decision_result','decision_work')
                           ELSE jsonb_build_array('decision_result','decision_work','rule_work') END,
        'function', 'pgreact.trace',
        'arguments', jsonb_build_array('name','subject','result_key'),
        'advanced_option', 'causal_path',
        'default_limits', jsonb_build_object('node_limit',256,'edge_limit',512,'path_limit',64,'depth_limit',16,'fanout_limit',64,'payload_limit',65536),
        'maximum_limits', jsonb_build_object('node_limit',4096,'edge_limit',8192,'path_limit',1024,'depth_limit',64,'fanout_limit',256,'payload_limit',1048576),
        'finding', NULL),
    jsonb_build_object(
        'question_kind', 'why_changed',
        'supported', $1 IS NULL OR $1 IN ('rule','decision_program','policy_set'),
        'target_kinds', jsonb_build_array('rule','decision_program','policy_set'),
        'result_kinds', '[]'::jsonb, 'root_kinds', '[]'::jsonb,
        'function', 'pgreact.compare',
        'arguments', jsonb_build_array('proposed','why_changed'),
        'advanced_option', 'why_changed',
        'default_limits', jsonb_build_object('evidence_limit',100),
        'maximum_limits', jsonb_build_object('evidence_limit',10000), 'finding', NULL),
    jsonb_build_object(
        'question_kind', 'semantic_difference',
        'supported', $1 IS NULL OR $1 IN ('rule','decision_program','policy_set'),
        'target_kinds', jsonb_build_array('rule','decision_program','policy_set'),
        'result_kinds', '[]'::jsonb, 'root_kinds', '[]'::jsonb,
        'function', 'pgreact.semantic_diff',
        'arguments', jsonb_build_array('proposed'),
        'advanced_option', NULL,
        'default_limits', jsonb_build_object('max_declaration_bytes',65536,'max_fields',128,'max_collection_members',256,'max_differences',128,'max_opaque_records',64,'max_nesting_depth',8,'max_payload_bytes',1048576),
        'maximum_limits', jsonb_build_object('max_declaration_bytes',1048576,'max_fields',1024,'max_collection_members',10000,'max_differences',1024,'max_opaque_records',256,'max_nesting_depth',32,'max_payload_bytes',16777216),
        'finding', NULL),
    jsonb_build_object(
        'question_kind', 'retained_causal_path',
        'supported', $1 IS NULL OR $1 = 'decision_program',
        'target_kinds', jsonb_build_array('decision_program'),
        'result_kinds', jsonb_build_array('decision_result'),
        'root_kinds', jsonb_build_array('decision_result'),
        'function', 'pgreact.capture_evidence / pgreact.read_evidence',
        'arguments', jsonb_build_array('explanation_ref','capture_key','snapshot_identity'),
        'advanced_option', 'evidence_snapshot',
        'default_limits', jsonb_build_object('reference_bytes',65536,'snapshot_identity_bytes',4096),
        'maximum_limits', jsonb_build_object('reference_bytes',65536,'snapshot_identity_bytes',4096),
        'finding', NULL)
)
$m53$;

CREATE FUNCTION pgreact.explanation_capabilities(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    target_count integer;
    target_kind text;
    target_version text;
    target_owner oid;
    target jsonb := '{}'::jsonb;
    questions jsonb;
    item jsonb;
    findings jsonb := '[]'::jsonb;
BEGIN
    IF name IS NULL THEN
        RETURN jsonb_build_object(
            'contract_version', 53, 'operation', 'explanation_capabilities',
            'target', '{}',
            'questions', pgreact_internal.m53_capability_questions(NULL),
            'read_only', true, 'findings', '[]'::jsonb);
    END IF;
    SELECT count(*) INTO target_count
    FROM (
        SELECT kind, object_name, owner_oid
        FROM pgreact_internal.api_declarations WHERE state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name, set.owner_oid
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
    ) targets WHERE object_name = name;
    IF target_count = 1 THEN
        SELECT kind, owner_oid INTO target_kind, target_owner
        FROM (
            SELECT kind, object_name, owner_oid
            FROM pgreact_internal.api_declarations WHERE state = 'DEPLOYED'
            UNION
            SELECT 'policy_set', set.set_name, set.owner_oid
            FROM pgreact_internal.policy_set_versions version
            JOIN pgreact_internal.policy_sets set USING (policy_set_id)
            WHERE version.state = 'DEPLOYED'
        ) targets WHERE object_name = name;
        IF target_kind = 'policy_set' THEN
            SELECT version.version INTO target_version
            FROM pgreact_internal.policy_set_versions version
            JOIN pgreact_internal.policy_sets set USING (policy_set_id)
            WHERE set.set_name = name AND version.state = 'DEPLOYED'
            ORDER BY version.valid_from DESC, version.created_at DESC LIMIT 1;
        ELSE
            target_version := '1';
        END IF;
    END IF;
    IF target_count <> 1
       OR (NOT pg_has_role(session_user, target_owner, 'USAGE')
           AND NOT pgreact_internal.is_operator_admin()
           AND NOT EXISTS (
               SELECT 1 FROM pgreact_internal.application_roles role_row
               WHERE role_row.role_kind = 'reader'
                 AND pg_has_role(session_user, role_row.role_oid, 'member'))) THEN
        findings := jsonb_build_array(pgreact_internal.m53_finding(
            'M53_TARGET_UNAVAILABLE', 'WARNING', NULL,
            'the requested target is unavailable',
            'Check the public target name and your granted access.'));
        questions := pgreact_internal.m53_capability_questions(NULL);
        SELECT COALESCE(jsonb_agg(
            item.value || jsonb_build_object(
                'supported', false, 'finding', findings -> 0)
            ORDER BY item.ordinality), '[]'::jsonb)
        INTO questions
        FROM jsonb_array_elements(questions) WITH ORDINALITY item(value, ordinality);
        RETURN jsonb_build_object(
            'contract_version', 53, 'operation', 'explanation_capabilities',
            'target', '{}', 'questions', questions,
            'read_only', true, 'findings', findings);
    END IF;
    target := jsonb_build_object('kind', target_kind, 'name', name, 'version', target_version);
    questions := pgreact_internal.m53_capability_questions(target_kind);
    RETURN jsonb_build_object(
        'contract_version', 53, 'operation', 'explanation_capabilities',
        'target', target, 'questions', questions, 'read_only', true, 'findings', findings);
END
$m53$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m43;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
BEGIN
    PERFORM pgreact_api.configure_roles_m43(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact.why_not(text,jsonb,text,jsonb), pgreact.trace(text,jsonb,jsonb), pgreact.trace(text,text), pgreact.trace(jsonb), pgreact.compare(pgreact_api.declaration,boolean), pgreact.semantic_diff(pgreact_api.declaration), pgreact.explanation_summary(jsonb), pgreact.explanation_capabilities(text), pgreact.capture_evidence(jsonb,text), pgreact.read_evidence(text), pgreact.delete_evidence(text) TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
END
$m53$;

REVOKE ALL ON FUNCTION pgreact_internal.m53_finding(text,text,text,text,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_explain_question(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_explain_dispatch(text,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_work_reference(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_explanation_ref(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_reference_parts(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_evidence_by_identity(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_state(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_next_actions(jsonb,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m53_capability_questions(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.why_not(text,jsonb,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.trace(text,jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.trace(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.trace(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.compare(pgreact_api.declaration,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.semantic_diff(pgreact_api.declaration) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.explanation_summary(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.explanation_capabilities(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.capture_evidence(jsonb,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.read_evidence(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.delete_evidence(text) FROM PUBLIC;

COMMENT ON FUNCTION pgreact.why_not(text,jsonb,text,jsonb) IS
    'M53 names-first why-not explanation over the installed M40 evaluator';
COMMENT ON FUNCTION pgreact.trace(text,jsonb,jsonb) IS
    'M53 names-first decision-result causal trace over the installed M41 evaluator';
COMMENT ON FUNCTION pgreact.explanation_summary(jsonb) IS
    'M53 immutable common projection over installed Area 2 explanation results';
COMMENT ON FUNCTION pgreact.explanation_capabilities(text) IS
    'M53 bounded read-only explanation capability discovery';

-- M53 complete policy-set packaging over the installed M29-M44 planner/runtime.
ALTER TABLE pgreact_internal.policy_set_versions
    ADD COLUMN IF NOT EXISTS package_format_version integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS package_complete boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS definition_digest text,
    ADD COLUMN IF NOT EXISTS plan_digest text,
    ADD COLUMN IF NOT EXISTS dependency_graph jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS support_declarations jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE pgreact_internal.policy_set_members
    ADD COLUMN IF NOT EXISTS package_owned boolean NOT NULL DEFAULT false;

CREATE UNIQUE INDEX IF NOT EXISTS policy_set_one_owned_member
    ON pgreact_internal.policy_set_members(member_kind, member_name, member_version)
    WHERE package_owned;

CREATE TABLE IF NOT EXISTS pgreact_internal.policy_set_supports (
    policy_set_version_id uuid NOT NULL REFERENCES pgreact_internal.policy_set_versions
        ON DELETE CASCADE,
    ordinal integer NOT NULL CHECK (ordinal > 0),
    support_kind text NOT NULL CHECK (support_kind IN ('shared_condition', 'parameter_family')),
    support_name text NOT NULL,
    support_version text NOT NULL,
    support_declaration jsonb NOT NULL,
    definition_digest text NOT NULL,
    PRIMARY KEY (policy_set_version_id, ordinal),
    UNIQUE (policy_set_version_id, support_kind, support_name, support_version)
);

CREATE TABLE IF NOT EXISTS pgreact_internal.policy_set_dependencies (
    policy_set_version_id uuid NOT NULL REFERENCES pgreact_internal.policy_set_versions
        ON DELETE CASCADE,
    ordinal integer NOT NULL CHECK (ordinal > 0),
    from_kind text NOT NULL,
    from_name text NOT NULL,
    from_version text NOT NULL,
    on_kind text NOT NULL,
    on_name text NOT NULL,
    on_version text NOT NULL,
    PRIMARY KEY (policy_set_version_id, ordinal),
    UNIQUE (policy_set_version_id, from_kind, from_name, from_version,
            on_kind, on_name, on_version)
);

CREATE OR REPLACE FUNCTION pgreact_internal.m53_declaration_json(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT jsonb_build_object(
        'format_version', 1,
        'api_version', (declaration).api_version,
        'kind', (declaration).kind,
        'name', (declaration).name,
        'spec', COALESCE((declaration).spec, '{}'::jsonb))
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_member_json(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT jsonb_build_object(
        'kind', (declaration).kind,
        'name', (declaration).name,
        'version', COALESCE((declaration).spec ->> 'version', '1'),
        'match_keys', CASE (declaration).kind
            WHEN 'rule' THEN jsonb_build_array((declaration).spec ->> 'semantic_key')
            WHEN 'decision_program' THEN jsonb_build_array((declaration).spec ->> 'candidate_key')
            ELSE '[]'::jsonb END,
        'subject_keys', CASE (declaration).kind
            WHEN 'rule' THEN jsonb_build_array((declaration).spec ->> 'semantic_key')
            WHEN 'decision_program' THEN jsonb_build_array((declaration).spec ->> 'subject_key')
            ELSE '[]'::jsonb END,
        'scope_mode', 'POLICY_SET_REQUIRED',
        'declaration', pgreact_internal.m53_declaration_json(declaration))
$m53$;

CREATE FUNCTION pgreact.shared_condition(
    name text, source regclass, key_columns name[],
    maintenance_mode text DEFAULT 'SCHEDULED'
)
RETURNS pgreact_api.declaration
LANGUAGE SQL STABLE
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_api.declaration('shared_condition', $1,
        jsonb_build_object('source', $2::text,
                           'row_type', COALESCE((SELECT c.reltype::regtype::text
                                                FROM pg_class c WHERE c.oid = $2), $2::text),
                           'key', to_jsonb($3),
                           'maintenance_mode', upper($4), 'delegate', true))
$m53$;

CREATE FUNCTION pgreact.parameter_family(
    name text, parameter_relation regclass, parameter_key name,
    parameter_value_columns name[]
)
RETURNS pgreact_api.declaration
LANGUAGE SQL IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_api.declaration('parameter_family', $1,
        jsonb_build_object('parameter_relation', $2::text,
                           'parameter_key', $3::text,
                           'parameter_value_columns', to_jsonb($4),
                           'definition_fingerprint', encode(
                               sha256(convert_to($2::text || ':' || $3::text || ':' ||
                                                COALESCE($4::text, ''), 'UTF8')), 'hex'),
                           'delegate', true))
$m53$;

CREATE FUNCTION pgreact.policy_set(
    name text,
    version text,
    members pgreact_api.declaration[],
    applicability regclass,
    subject_keys name[],
    support pgreact_api.declaration[],
    dependencies jsonb DEFAULT '[]'::jsonb,
    valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL,
    evidence_limit integer DEFAULT 100
)
RETURNS pgreact_api.declaration
LANGUAGE SQL VOLATILE
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_api.declaration('policy_set', $1, jsonb_strip_nulls(jsonb_build_object(
        'version', $2,
        'members', COALESCE((SELECT jsonb_agg(
            pgreact_internal.m53_member_json(item)
            ORDER BY item.kind, item.name, COALESCE(item.spec ->> 'version', '1'))
            FROM unnest($3) item), '[]'::jsonb),
        'support', COALESCE((SELECT jsonb_agg(
            jsonb_build_object(
                'kind', item.kind,
                'name', item.name,
                'version', COALESCE(item.spec ->> 'version', '1'),
                'declaration', pgreact_internal.m53_declaration_json(item))
            ORDER BY item.kind, item.name, COALESCE(item.spec ->> 'version', '1'))
            FROM unnest($6) item), '[]'::jsonb),
        'dependencies', COALESCE($7, '[]'::jsonb),
        'applicability', jsonb_build_object(
            'source_kind', 'relation', 'relation', $4::text,
            'subject_keys', to_jsonb($5)),
        'valid_from', $8, 'valid_to', $9, 'evidence_limit', $10)))
$m53$;

-- Keep legacy positional timestamp literals unambiguous beside the typed package overload.
CREATE FUNCTION pgreact.policy_set(
    name text, version text, members pgreact_api.declaration[],
    applicability regclass, subject_keys name[], valid_from text
)
RETURNS pgreact_api.declaration
LANGUAGE SQL VOLATILE
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact.policy_set($1, $2, $3, $4, $5, $6::timestamptz, NULL, 100)
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_normalize(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT jsonb_build_object(
        'format_version', 1,
        'api_version', (declaration).api_version,
        'kind', (declaration).kind,
        'name', (declaration).name,
        'spec', jsonb_build_object(
            'version', (declaration).spec ->> 'version',
            'members', COALESCE((SELECT jsonb_agg(value ORDER BY
                value ->> 'kind', value ->> 'name', COALESCE(value ->> 'version', '1'))
                FROM jsonb_array_elements(CASE WHEN jsonb_typeof((declaration).spec -> 'members') = 'array'
                    THEN (declaration).spec -> 'members' ELSE '[]'::jsonb END) value), '[]'::jsonb),
            'support', COALESCE((SELECT jsonb_agg(value ORDER BY
                value ->> 'kind', value ->> 'name', COALESCE(value ->> 'version', '1'))
                FROM jsonb_array_elements(CASE WHEN jsonb_typeof((declaration).spec -> 'support') = 'array'
                    THEN (declaration).spec -> 'support' ELSE '[]'::jsonb END) value), '[]'::jsonb),
            'dependencies', COALESCE((SELECT jsonb_agg(value ORDER BY
                value -> 'from' ->> 'kind', value -> 'from' ->> 'name', value -> 'from' ->> 'version',
                value -> 'on' ->> 'kind', value -> 'on' ->> 'name', value -> 'on' ->> 'version')
                FROM jsonb_array_elements(CASE WHEN jsonb_typeof((declaration).spec -> 'dependencies') = 'array'
                    THEN (declaration).spec -> 'dependencies' ELSE '[]'::jsonb END) value), '[]'::jsonb),
            'applicability', COALESCE((declaration).spec -> 'applicability', '{}'::jsonb),
            'valid_from', (declaration).spec ->> 'valid_from',
            'valid_to', (declaration).spec ->> 'valid_to',
            'evidence_limit', COALESCE((declaration).spec -> 'evidence_limit', '100'::jsonb)))
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_id(value jsonb)
RETURNS text
LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT (value ->> 'kind') || ':' || (value ->> 'name') || ':' ||
           COALESCE(value ->> 'version', '1')
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_validate(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    normalized jsonb := pgreact_internal.m53_package_normalize(declaration);
    spec jsonb := COALESCE(normalized -> 'spec', '{}'::jsonb);
    findings jsonb := '[]'::jsonb;
    member jsonb;
    support jsonb;
    dependency jsonb;
    node_id text;
    endpoint text;
    field text;
    member_count integer := 0;
    support_count integer := 0;
    dependency_count integer := 0;
    complete boolean := true;
    valid_from timestamptz;
    valid_to timestamptz;
BEGIN
    IF declaration IS NULL OR (declaration).kind IS DISTINCT FROM 'policy_set' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_KIND', 'ERROR', 'kind',
            'M53 packaging accepts one policy_set declaration',
            'Build the declaration with pgreact.policy_set().'));
        RETURN jsonb_build_object('normalized', normalized, 'findings', findings,
                                  'complete', false);
    END IF;
    IF (declaration).api_version IS DISTINCT FROM '1' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_API_VERSION', 'ERROR', 'api_version',
            'only declaration API version 1 is supported', 'Use API version 1.'));
    END IF;
    IF (declaration).name IS NULL OR (declaration).name !~ '^[A-Za-z_][A-Za-z0-9_.-]*$' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_NAME', 'ERROR', 'name',
            'policy-set name must be a stable public name', 'Use a qualified name.'));
    END IF;
    IF NULLIF(btrim(spec ->> 'version'), '') IS NULL
       OR length(spec ->> 'version') > 64
       OR spec ->> 'version' !~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_VERSION', 'ERROR', 'spec.version',
            'policy-set version must be a stable immutable identifier',
            'Use a value such as 1 or 2026-09.'));
    END IF;
    FOR field IN SELECT key FROM jsonb_object_keys(spec) key LOOP
        IF field NOT IN ('version', 'members', 'support', 'dependencies', 'applicability',
                         'valid_from', 'valid_to', 'evidence_limit') THEN
            findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                'M53_POLICY_FIELD_UNKNOWN', 'ERROR', 'spec.' || field,
                'policy-set declaration contains an unknown field',
                'Remove the field or use the M53 policy-set contract.'));
        END IF;
    END LOOP;
    IF jsonb_typeof(spec -> 'members') IS DISTINCT FROM 'array'
       OR jsonb_array_length(COALESCE(spec -> 'members', '[]'::jsonb)) = 0 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_MEMBERS', 'ERROR', 'spec.members',
            'a complete policy set needs at least one member',
            'Add a rule or decision declaration.'));
    ELSE
        member_count := jsonb_array_length(spec -> 'members');
        IF member_count > 64 THEN
            findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                'M53_POLICY_MEMBER_LIMIT', 'ERROR', 'spec.members',
                'a policy set may contain at most 64 members',
                'Split the policy into smaller sets.'));
        END IF;
        FOR member IN SELECT value FROM jsonb_array_elements(spec -> 'members') value LOOP
            node_id := pgreact_internal.m53_package_id(member);
            IF member ->> 'kind' NOT IN ('rule', 'decision_program')
               OR NULLIF(member ->> 'name', '') IS NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_MEMBER_KIND', 'ERROR', 'spec.members',
                    'members must be named rule or decision_program declarations',
                    'Use a complete typed child declaration.'));
            END IF;
            IF jsonb_typeof(member -> 'declaration') IS DISTINCT FROM 'object'
               OR (member -> 'declaration' ->> 'kind') IS DISTINCT FROM member ->> 'kind'
               OR (member -> 'declaration' ->> 'name') IS DISTINCT FROM member ->> 'name'
               OR jsonb_typeof(member -> 'declaration' -> 'spec') IS DISTINCT FROM 'object' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_MEMBER_DECLARATION', 'ERROR', 'spec.members',
                    'each member needs its complete child declaration',
                    'Use a rule or decision declaration in the member field.'));
            END IF;
            IF (SELECT count(*) FROM jsonb_array_elements(spec -> 'members') value
                WHERE pgreact_internal.m53_package_id(value) = node_id) > 1 THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_MEMBER_DUPLICATE', 'ERROR', 'spec.members',
                    'a member identity appears more than once',
                    'Keep each immutable child identity once.'));
            END IF;
        END LOOP;
    END IF;
    IF jsonb_typeof(spec -> 'support') IS DISTINCT FROM 'array' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_SUPPORT_SHAPE', 'ERROR', 'spec.support',
            'support must be an array', 'Use shared-condition or parameter-family declarations.'));
    ELSE
        support_count := jsonb_array_length(spec -> 'support');
        IF support_count > 64 THEN
            findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                'M53_POLICY_SUPPORT_LIMIT', 'ERROR', 'spec.support',
                'a policy set may contain at most 64 support declarations',
                'Split the support declarations between policy sets.'));
        END IF;
        FOR support IN SELECT value FROM jsonb_array_elements(spec -> 'support') value LOOP
            IF support ->> 'kind' NOT IN ('shared_condition', 'parameter_family')
               OR NULLIF(support ->> 'name', '') IS NULL THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_SUPPORT_KIND', 'ERROR', 'spec.support',
                    'support must be a shared_condition or parameter_family declaration',
                    'Use the typed support constructors.'));
            END IF;
            IF jsonb_typeof(support -> 'declaration') IS DISTINCT FROM 'object'
               OR (support -> 'declaration' ->> 'kind') IS DISTINCT FROM support ->> 'kind'
               OR (support -> 'declaration' ->> 'name') IS DISTINCT FROM support ->> 'name'
               OR jsonb_typeof(support -> 'declaration' -> 'spec') IS DISTINCT FROM 'object' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_SUPPORT_DECLARATION', 'ERROR', 'spec.support',
                    'each support item needs its complete typed declaration',
                    'Use a shared-condition or parameter-family constructor.'));
            END IF;
        END LOOP;
    END IF;
    IF jsonb_typeof(spec -> 'dependencies') IS DISTINCT FROM 'array' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_DEPENDENCY_SHAPE', 'ERROR', 'spec.dependencies',
            'dependencies must be an array', 'Use objects with from and on identities.'));
    ELSE
        dependency_count := jsonb_array_length(spec -> 'dependencies');
        IF dependency_count > 256 THEN
            findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                'M53_POLICY_DEPENDENCY_LIMIT', 'ERROR', 'spec.dependencies',
                'a policy set may contain at most 256 dependency edges',
                'Remove unused edges or split the policy.'));
        END IF;
        FOR dependency IN SELECT value FROM jsonb_array_elements(spec -> 'dependencies') value LOOP
            IF jsonb_typeof(dependency -> 'from') IS DISTINCT FROM 'object'
               OR jsonb_typeof(dependency -> 'on') IS DISTINCT FROM 'object' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_DEPENDENCY_IDENTITY', 'ERROR', 'spec.dependencies',
                    'each dependency needs typed from and on identities',
                    'Use kind, name, and version at both endpoints.'));
                CONTINUE;
            END IF;
            node_id := pgreact_internal.m53_package_id(dependency -> 'from');
            endpoint := pgreact_internal.m53_package_id(dependency -> 'on');
            IF node_id = endpoint THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_DEPENDENCY_SELF', 'ERROR', 'spec.dependencies',
                    'a dependency cannot point to itself', 'Remove the self-edge.'));
            END IF;
            IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
                               CASE WHEN jsonb_typeof(spec -> 'members') = 'array'
                               THEN spec -> 'members' ELSE '[]'::jsonb END) value
                           WHERE pgreact_internal.m53_package_id(value) = node_id)
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
                                   CASE WHEN jsonb_typeof(spec -> 'support') = 'array'
                                   THEN spec -> 'support' ELSE '[]'::jsonb END) value
                               WHERE pgreact_internal.m53_package_id(value) = node_id) THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_DEPENDENCY_ENDPOINT', 'ERROR', 'spec.dependencies',
                    'dependency endpoints must be declared in this policy set',
                    'Add both endpoint declarations or remove the edge.'));
            END IF;
            IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
                               CASE WHEN jsonb_typeof(spec -> 'members') = 'array'
                               THEN spec -> 'members' ELSE '[]'::jsonb END) value
                           WHERE pgreact_internal.m53_package_id(value) = endpoint)
               AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
                                   CASE WHEN jsonb_typeof(spec -> 'support') = 'array'
                                   THEN spec -> 'support' ELSE '[]'::jsonb END) value
                               WHERE pgreact_internal.m53_package_id(value) = endpoint) THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_DEPENDENCY_ENDPOINT', 'ERROR', 'spec.dependencies',
                    'dependency endpoints must be declared in this policy set',
                    'Add both endpoint declarations or remove the edge.'));
            END IF;
            IF (SELECT count(*) FROM jsonb_array_elements(spec -> 'dependencies') value
                WHERE value -> 'from' = dependency -> 'from'
                  AND value -> 'on' = dependency -> 'on') > 1 THEN
                findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                    'M53_POLICY_DEPENDENCY_DUPLICATE', 'ERROR', 'spec.dependencies',
                    'a dependency edge appears more than once', 'Keep each edge once.'));
            END IF;
        END LOOP;
    END IF;
    IF jsonb_typeof(spec -> 'applicability') IS DISTINCT FROM 'object'
       OR NULLIF(spec -> 'applicability' ->> 'relation', '') IS NULL
       OR to_regclass(spec -> 'applicability' ->> 'relation') IS NULL THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_APPLICABILITY', 'ERROR', 'spec.applicability',
            'applicability must name an existing relation',
            'Create the relation before previewing the policy set.'));
    END IF;
    BEGIN
        valid_from := (spec ->> 'valid_from')::timestamptz;
        valid_to := NULLIF(spec ->> 'valid_to', '')::timestamptz;
        IF valid_to IS NOT NULL AND valid_to <= valid_from THEN
            findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
                'M53_POLICY_EFFECTIVE_PERIOD', 'ERROR', 'spec.valid_to',
                'valid_to must be after valid_from', 'Use a non-overlapping effective period.'));
        END IF;
    EXCEPTION WHEN OTHERS THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_EFFECTIVE_PERIOD', 'ERROR', 'spec.valid_from',
            'effective timestamps must be valid timestamptz values',
            'Use RFC3339 timestamps.'));
    END;
    IF octet_length(normalized::text) > 1048576 THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_PAYLOAD_LIMIT', 'ERROR', 'spec',
            'the canonical policy declaration may not exceed 1 MiB',
            'Remove unused declarations or split the policy set.'));
    END IF;
    IF jsonb_typeof(spec -> 'dependencies') = 'array' AND EXISTS (
        WITH RECURSIVE edges AS (
            SELECT pgreact_internal.m53_package_id(value -> 'from') AS from_id,
                   pgreact_internal.m53_package_id(value -> 'on') AS on_id
            FROM jsonb_array_elements(spec -> 'dependencies') value
        ), walk(start_id, current_id, path) AS (
            SELECT from_id, on_id, ARRAY[from_id, on_id] FROM edges
            UNION ALL
            SELECT walk.start_id, edges.on_id, walk.path || edges.on_id
            FROM walk JOIN edges ON edges.from_id = walk.current_id
            WHERE edges.on_id = walk.start_id OR NOT edges.on_id = ANY(walk.path)
        ) SELECT 1 FROM walk WHERE current_id = start_id
    ) THEN
        findings := findings || jsonb_build_array(pgreact_internal.m53_finding(
            'M53_POLICY_DEPENDENCY_CYCLE', 'ERROR', 'spec.dependencies',
            'dependency edges must form an acyclic graph',
            'Remove one edge from the cycle.'));
    END IF;
    complete := complete AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(findings) value
        WHERE value ->> 'severity' = 'ERROR');
    RETURN jsonb_build_object('normalized', normalized, 'findings', findings,
        'complete', complete, 'member_count', member_count,
        'support_count', support_count, 'dependency_count', dependency_count);
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_validate_result(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE checked jsonb := pgreact_internal.m53_package_validate(declaration);
BEGIN
    RETURN jsonb_build_object(
        'contract_version', 53, 'operation', 'validate',
        'state', CASE WHEN (checked ->> 'complete')::boolean
                      THEN 'valid' ELSE 'attention' END,
        'target', jsonb_build_object('kind', (declaration).kind,
                                     'name', (declaration).name,
                                     'version', checked -> 'normalized' -> 'spec' -> 'version'),
        'complete', checked -> 'complete',
        'normalized_declaration', checked -> 'normalized',
        'limits', jsonb_build_object(
            'members', checked -> 'member_count',
            'support', checked -> 'support_count',
            'dependencies', checked -> 'dependency_count'),
        'findings', checked -> 'findings', 'read_only', true, 'truncated', false);
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_digest(normalized jsonb)
RETURNS text
LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT encode(sha256(convert_to($1::text, 'UTF8')), 'hex')
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_semantic_diff(
    declaration pgreact_api.declaration,
    target pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    checked jsonb := pgreact_internal.m53_package_validate(declaration);
    proposed jsonb := checked -> 'normalized';
    current_package jsonb;
    node jsonb;
    other jsonb;
    differences jsonb := '[]'::jsonb;
    deployed_digest text;
    target_version text;
    state text := 'complete';
BEGIN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(checked -> 'findings') value
               WHERE value ->> 'severity' = 'ERROR') THEN
        RETURN jsonb_build_object(
            'contract_version', 53, 'operation', 'semantic_diff', 'state', 'unsupported',
            'target', NULL, 'proposed_declaration_digest', NULL,
            'deployed_declaration_digest', NULL, 'differences', '[]'::jsonb,
            'opaque', '[]'::jsonb, 'completeness', jsonb_build_object('complete', false),
            'limits', jsonb_build_object('reached', '[]'::jsonb),
            'findings', checked -> 'findings', 'read_only', true, 'truncated', false);
    END IF;
    target_version := COALESCE(($2).version, proposed -> 'spec' ->> 'version');
    SELECT version.normalized,
           COALESCE(version.definition_digest, encode(version.declaration_digest, 'hex'))
    INTO current_package, deployed_digest
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = ($2).name AND version.state = 'DEPLOYED'
      AND version.version = target_version
    ORDER BY version.created_at DESC LIMIT 1;
    IF current_package IS NULL THEN
        RETURN jsonb_build_object(
            'contract_version', 53, 'operation', 'semantic_diff', 'state', 'unavailable',
            'target', NULL, 'proposed_declaration_digest',
            pgreact_internal.m53_package_digest(proposed),
            'deployed_declaration_digest', NULL, 'differences', '[]'::jsonb,
            'opaque', '[]'::jsonb, 'completeness', jsonb_build_object('complete', false),
            'limits', jsonb_build_object('reached', '[]'::jsonb),
            'findings', jsonb_build_array(pgreact_internal.m53_finding(
                'M53_TARGET_UNAVAILABLE', 'WARNING', 'target',
                'the deployed policy-set version is unavailable',
                'Use the exact deployed policy-set name and version.')),
            'read_only', true, 'truncated', false);
    END IF;
    FOR node IN
        SELECT value FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(proposed -> 'spec' -> 'members') = 'array'
            THEN proposed -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
        UNION ALL
        SELECT value FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(proposed -> 'spec' -> 'support') = 'array'
            THEN proposed -> 'spec' -> 'support' ELSE '[]'::jsonb END) value
    LOOP
        SELECT value INTO other
        FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(current_package -> 'spec' -> 'members') = 'array'
            THEN current_package -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
        WHERE pgreact_internal.m53_package_id(value) = pgreact_internal.m53_package_id(node)
        UNION ALL
        SELECT value
        FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(current_package -> 'spec' -> 'support') = 'array'
            THEN current_package -> 'spec' -> 'support' ELSE '[]'::jsonb END) value
        WHERE pgreact_internal.m53_package_id(value) = pgreact_internal.m53_package_id(node)
        LIMIT 1;
        differences := differences || jsonb_build_array(jsonb_build_object(
            'kind', node ->> 'kind', 'name', node ->> 'name',
            'version', COALESCE(node ->> 'version', '1'),
            'change_kind', CASE WHEN other IS NULL THEN 'added'
                                WHEN other = node THEN 'unchanged' ELSE 'changed' END,
            'before', other, 'after', node));
    END LOOP;
    FOR node IN
        SELECT value FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(current_package -> 'spec' -> 'members') = 'array'
            THEN current_package -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
        UNION ALL
        SELECT value FROM jsonb_array_elements(CASE
            WHEN jsonb_typeof(current_package -> 'spec' -> 'support') = 'array'
            THEN current_package -> 'spec' -> 'support' ELSE '[]'::jsonb END) value
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(proposed -> 'spec' -> 'members') = 'array'
                THEN proposed -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
            WHERE pgreact_internal.m53_package_id(value) = pgreact_internal.m53_package_id(node)
            UNION ALL
            SELECT 1
            FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(proposed -> 'spec' -> 'support') = 'array'
                THEN proposed -> 'spec' -> 'support' ELSE '[]'::jsonb END) value
            WHERE pgreact_internal.m53_package_id(value) = pgreact_internal.m53_package_id(node)) THEN
            differences := differences || jsonb_build_array(jsonb_build_object(
                'kind', node ->> 'kind', 'name', node ->> 'name',
                'version', COALESCE(node ->> 'version', '1'),
                'change_kind', 'removed', 'before', node, 'after', NULL));
        END IF;
    END LOOP;
    IF proposed -> 'spec' -> 'applicability' IS DISTINCT FROM current_package -> 'spec' -> 'applicability'
       OR proposed -> 'spec' -> 'dependencies' IS DISTINCT FROM current_package -> 'spec' -> 'dependencies' THEN
        differences := differences || jsonb_build_array(jsonb_build_object(
            'kind', 'policy_set', 'name', ($1).name, 'version', target_version,
            'change_kind', 'changed', 'before', jsonb_build_object(
                'applicability', current_package -> 'spec' -> 'applicability',
                'dependencies', current_package -> 'spec' -> 'dependencies'),
            'after', jsonb_build_object(
                'applicability', proposed -> 'spec' -> 'applicability',
                'dependencies', proposed -> 'spec' -> 'dependencies')));
    END IF;
    RETURN jsonb_build_object(
        'contract_version', 53, 'operation', 'semantic_diff', 'state', state,
        'target', jsonb_build_object('kind', 'policy_set', 'name', ($2).name,
                                     'version', target_version),
        'proposed_declaration_digest', pgreact_internal.m53_package_digest(proposed),
        'deployed_declaration_digest', deployed_digest, 'differences', differences,
        'opaque', '[]'::jsonb, 'completeness', jsonb_build_object('complete', true),
        'limits', jsonb_build_object('reached', '[]'::jsonb),
        'findings', checked -> 'findings', 'semantic_digest',
        pgreact_internal.m53_package_digest(jsonb_build_object(
            'target', jsonb_build_object('kind', 'policy_set', 'name', ($2).name,
                                          'version', target_version),
            'differences', differences)), 'read_only', true, 'truncated', false);
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_compare(
    declaration pgreact_api.declaration,
    target pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_internal.m53_package_semantic_diff($1, $2, $3)
        || jsonb_build_object('operation', 'compare', 'package', true)
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    checked jsonb := pgreact_internal.m53_package_validate(declaration);
    package_normalized jsonb := checked -> 'normalized';
    findings jsonb := checked -> 'findings';
    actions jsonb := '[]'::jsonb;
    node jsonb;
    node_kind text;
    node_name text;
    node_version text;
    current_state text := 'absent';
    current_digest text;
    source_fingerprint text;
    child_digests jsonb := '{}'::jsonb;
    definition_digest text := pgreact_internal.m53_package_digest(package_normalized);
    plan_digest text;
BEGIN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(findings) value
               WHERE value ->> 'severity' = 'ERROR') THEN
        RETURN jsonb_build_object(
            'contract_version', 53, 'operation', 'preview',
            'target', jsonb_build_object('kind', 'policy_set', 'name', (declaration).name),
            'state', 'attention', 'summary', jsonb_build_object(
                'read_only', true, 'definition_digest', definition_digest,
                'action_plan', actions, 'plan_digest', NULL,
            'blockers', findings), 'findings', findings,
            'evidence', jsonb_build_object('normalized_declaration', package_normalized),
            'truncated', false);
    END IF;
    SELECT version.state, version.definition_digest
    INTO current_state, current_digest
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (declaration).name
      AND version.version = package_normalized -> 'spec' ->> 'version'
    ORDER BY version.created_at DESC LIMIT 1;
    source_fingerprint := pgreact_internal.m30_relation_fingerprint(
        to_regclass(package_normalized -> 'spec' -> 'applicability' ->> 'relation'),
        ARRAY(SELECT value::name FROM jsonb_array_elements_text(
            COALESCE(package_normalized -> 'spec' -> 'applicability' -> 'subject_keys', '[]'::jsonb)) value),
        NULL);
    SELECT COALESCE(jsonb_object_agg(
               (member_node ->> 'kind') || ':' || (member_node ->> 'name') || ':' || COALESCE(member_node ->> 'version', '1'),
               encode(row_data.declaration_digest, 'hex')
               ORDER BY (member_node ->> 'kind'), (member_node ->> 'name')), '{}'::jsonb)
    INTO child_digests
    FROM jsonb_array_elements(package_normalized -> 'spec' -> 'members') member_node
    JOIN pgreact_internal.api_declarations row_data
      ON row_data.kind = member_node ->> 'kind' AND row_data.object_name = member_node ->> 'name'
     AND row_data.state = 'DEPLOYED';
    FOR node IN
        WITH RECURSIVE package_nodes AS (
            SELECT value, pgreact_internal.m53_package_id(value) AS node_id
            FROM jsonb_array_elements(package_normalized -> 'spec' -> 'members') value
            UNION ALL
            SELECT value, pgreact_internal.m53_package_id(value) AS node_id
            FROM jsonb_array_elements(package_normalized -> 'spec' -> 'support') value
        ), edges AS (
            SELECT pgreact_internal.m53_package_id(value -> 'from') AS from_id,
                   pgreact_internal.m53_package_id(value -> 'on') AS on_id
            FROM jsonb_array_elements(package_normalized -> 'spec' -> 'dependencies') value
        ), walk(node_id, depth) AS (
            SELECT package_nodes.node_id, 0
            FROM package_nodes
            WHERE NOT EXISTS (SELECT 1 FROM edges WHERE edges.from_id = package_nodes.node_id)
            UNION ALL
            SELECT edges.from_id, walk.depth + 1
            FROM walk JOIN edges ON edges.on_id = walk.node_id
        ), ranks AS (
            SELECT node_id, max(depth) AS depth FROM walk GROUP BY node_id
        )
        SELECT package_nodes.value
        FROM package_nodes JOIN ranks USING (node_id)
        ORDER BY ranks.depth, package_nodes.value ->> 'kind', package_nodes.value ->> 'name',
                 COALESCE(package_nodes.value ->> 'version', '1')
    LOOP
        node_kind := node ->> 'kind';
        node_name := node ->> 'name';
        node_version := COALESCE(node ->> 'version', '1');
        IF EXISTS (SELECT 1 FROM pgreact_internal.api_declarations row_data
                   WHERE row_data.kind = node_kind AND row_data.object_name = node_name
                     AND row_data.state = 'DEPLOYED') THEN
            actions := actions || jsonb_build_array(jsonb_build_object(
                'action', CASE WHEN EXISTS (
                    SELECT 1
                    FROM pgreact_internal.policy_set_members member
                    JOIN pgreact_internal.policy_set_versions version
                      USING (policy_set_version_id)
                    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                    WHERE set.set_name = (declaration).name
                      AND version.version = package_normalized -> 'spec' ->> 'version'
                      AND version.state = 'DEPLOYED'
                      AND member.member_kind = node_kind
                      AND member.member_name = node_name
                      AND member.member_version = node_version)
                    THEN 'KEEP' ELSE 'ADOPT' END,
                'kind', node_kind, 'name', node_name, 'version', node_version));
        ELSIF EXISTS (SELECT 1 FROM pgreact_internal.policy_set_supports support
                      JOIN pgreact_internal.policy_set_versions version
                        USING (policy_set_version_id)
                      JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                      WHERE set.set_name = (declaration).name
                        AND version.version = package_normalized -> 'spec' ->> 'version'
                        AND version.state = 'DEPLOYED'
                        AND support.support_kind = node_kind
                        AND support.support_name = node_name
                        AND support.support_version = node_version) THEN
            actions := actions || jsonb_build_array(jsonb_build_object(
                'action', 'KEEP', 'kind', node_kind, 'name', node_name, 'version', node_version));
        ELSE
            actions := actions || jsonb_build_array(jsonb_build_object(
                'action', 'ADD', 'kind', node_kind, 'name', node_name, 'version', node_version));
        END IF;
    END LOOP;
    IF current_state = 'DEPLOYED' THEN
        FOR node IN
            SELECT value
            FROM (
                SELECT jsonb_build_object('kind', member.member_kind, 'name', member.member_name,
                                          'version', member.member_version) AS value
                FROM pgreact_internal.policy_set_members member
                JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
                JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                WHERE set.set_name = (declaration).name
                  AND version.version = package_normalized -> 'spec' ->> 'version'
                  AND version.state = 'DEPLOYED'
                EXCEPT
                SELECT jsonb_build_object('kind', value ->> 'kind', 'name', value ->> 'name',
                                          'version', COALESCE(value ->> 'version', '1'))
                FROM jsonb_array_elements(package_normalized -> 'spec' -> 'members') value
                UNION ALL
                SELECT jsonb_build_object('kind', support.support_kind, 'name', support.support_name,
                                          'version', support.support_version)
                FROM pgreact_internal.policy_set_supports support
                JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
                JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                WHERE set.set_name = (declaration).name
                  AND version.version = package_normalized -> 'spec' ->> 'version'
                  AND version.state = 'DEPLOYED'
                EXCEPT
                SELECT jsonb_build_object('kind', value ->> 'kind', 'name', value ->> 'name',
                                          'version', COALESCE(value ->> 'version', '1'))
                FROM jsonb_array_elements(package_normalized -> 'spec' -> 'support') value
            ) nodes
            ORDER BY value ->> 'kind', value ->> 'name', value ->> 'version'
        LOOP
            actions := actions || jsonb_build_array(jsonb_build_object(
                'action', 'REMOVE', 'kind', node ->> 'kind', 'name', node ->> 'name',
                'version', COALESCE(node ->> 'version', '1')));
        END LOOP;
    END IF;
    actions := actions || jsonb_build_array(jsonb_build_object(
        'action', CASE WHEN current_state = 'DEPLOYED' THEN 'REPLACE' ELSE 'ADD' END,
        'kind', 'policy_set', 'name', (declaration).name,
        'version', package_normalized -> 'spec' ->> 'version'));
    plan_digest := pgreact_internal.m53_package_digest(jsonb_build_object(
        'definition_digest', definition_digest, 'current_state', COALESCE(current_state, 'absent'),
        'current_digest', current_digest, 'source_fingerprint', source_fingerprint,
        'child_digests', child_digests, 'action_plan', actions));
    RETURN jsonb_build_object(
        'contract_version', 53, 'operation', 'preview',
        'target', jsonb_build_object('kind', 'policy_set', 'name', (declaration).name,
                                     'version', package_normalized -> 'spec' ->> 'version'),
        'state', 'ready', 'summary', jsonb_build_object(
             'read_only', true, 'definition_digest', definition_digest,
             'plan_digest', plan_digest, 'current_state', COALESCE(current_state, 'absent'),
             'current_definition_digest', current_digest, 'action_plan', actions,
             'blockers', '[]'::jsonb, 'source_fingerprint', source_fingerprint,
             'child_digests', child_digests), 'findings', findings,
        'evidence', jsonb_build_object('normalized_declaration', package_normalized),
        'truncated', false);
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_runtime_declaration(
    normalized jsonb
)
RETURNS pgreact_api.declaration
LANGUAGE SQL IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_api.declaration('policy_set', normalized ->> 'name',
        (
          ((normalized -> 'spec') || jsonb_build_object(
            'members', COALESCE((SELECT jsonb_agg(value - 'declaration' ORDER BY
                value ->> 'kind', value ->> 'name', COALESCE(value ->> 'version', '1'))
                FROM jsonb_array_elements(normalized -> 'spec' -> 'members') value), '[]'::jsonb)))
          - 'format_version' - 'support' - 'dependencies'
        ))
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE
    checked jsonb := pgreact_internal.m53_package_validate(declaration);
    package_normalized jsonb := checked -> 'normalized';
    findings jsonb := checked -> 'findings';
    runtime_declaration pgreact_api.declaration;
    result jsonb;
    preview jsonb;
    version_id uuid;
    package_definition_digest text;
    package_plan_digest text;
    node jsonb;
    child pgreact_api.declaration;
    existing_child pgreact_internal.api_declarations%ROWTYPE;
    child_exists boolean;
    support jsonb;
    dependency jsonb;
    ordinal integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(findings) value
               WHERE value ->> 'severity' = 'ERROR') THEN
        RETURN pgreact_internal.m53_package_preview(declaration, preconditions);
    END IF;
    preview := pgreact_internal.m53_package_preview(declaration, preconditions);
    package_plan_digest := preview -> 'summary' ->> 'plan_digest';
    IF preconditions ? 'plan_digest'
       AND preconditions ->> 'plan_digest' IS DISTINCT FROM package_plan_digest THEN
        RAISE EXCEPTION 'M53_STALE_PREVIEW: package preview is stale';
    END IF;
    FOR node IN SELECT value FROM jsonb_array_elements(package_normalized -> 'spec' -> 'members') value LOOP
        IF jsonb_typeof(node -> 'declaration') = 'object' THEN
            child := pgreact_api.declaration(
                node -> 'declaration' ->> 'kind', node -> 'declaration' ->> 'name',
                node -> 'declaration' -> 'spec');
            SELECT * INTO existing_child
            FROM pgreact_internal.api_declarations row_data
            WHERE row_data.kind = node ->> 'kind'
              AND row_data.object_name = node ->> 'name'
              AND row_data.state = 'DEPLOYED';
            child_exists := FOUND;
            IF EXISTS (SELECT 1 FROM pgreact_internal.policy_set_members member
                       JOIN pgreact_internal.policy_set_versions version
                         USING (policy_set_version_id)
                       JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                       WHERE set.set_name <> (declaration).name
                         AND version.state = 'DEPLOYED' AND member.package_owned
                         AND member.member_kind = node ->> 'kind'
                         AND member.member_name = node ->> 'name'
                         AND member.member_version = COALESCE(node ->> 'version', '1')) THEN
                RAISE EXCEPTION 'M53_POLICY_CROSS_PACKAGE: child is owned by another package';
            END IF;
            IF child_exists
               AND NOT EXISTS (SELECT 1 FROM pgreact_internal.policy_set_members member
                               JOIN pgreact_internal.policy_set_versions version
                                 USING (policy_set_version_id)
                               JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                               WHERE set.set_name = (declaration).name
                                 AND version.version = package_normalized -> 'spec' ->> 'version'
                                 AND version.state = 'DEPLOYED'
                                 AND member.member_kind = node ->> 'kind'
                                 AND member.member_name = node ->> 'name'
                                 AND member.member_version = COALESCE(node ->> 'version', '1'))
               AND NOT COALESCE(preconditions -> 'adopt', '[]'::jsonb) @>
                   jsonb_build_array(jsonb_build_object(
                       'kind', node ->> 'kind', 'name', node ->> 'name',
                       'version', COALESCE(node ->> 'version', '1'))) THEN
                RAISE EXCEPTION 'M53_POLICY_ADOPTION_REQUIRED: declare the existing child in preconditions.adopt';
            END IF;
            IF (child).kind IN ('rule', 'decision_program') THEN
                IF child_exists THEN
                    IF existing_child.declaration_digest IS DISTINCT FROM sha256(convert_to(
                        pgreact_internal.m28_normalize(child)::text, 'UTF8')) THEN
                        RAISE EXCEPTION 'M53_POLICY_ADOPTION_DIGEST: existing child digest does not match';
                    END IF;
                ELSE
                    PERFORM pgreact_api.deploy_m31(child, '{}'::jsonb);
                END IF;
            END IF;
        END IF;
    END LOOP;
    runtime_declaration := pgreact_internal.m53_package_runtime_declaration(package_normalized);
    result := pgreact_api.deploy_m31(runtime_declaration, COALESCE(preconditions, '{}'::jsonb) - 'plan_digest');
    SELECT version.policy_set_version_id INTO version_id
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = (declaration).name
      AND version.version = package_normalized -> 'spec' ->> 'version'
    ORDER BY version.created_at DESC LIMIT 1;
    IF version_id IS NULL THEN
        RAISE EXCEPTION 'M53_DEPLOYMENT_MISSING: installed policy planner did not create a version';
    END IF;
    package_definition_digest := pgreact_internal.m53_package_digest(package_normalized);
    UPDATE pgreact_internal.policy_set_versions
    SET package_format_version = 1, package_complete = COALESCE((checked ->> 'complete')::boolean, false),
        definition_digest = package_definition_digest, plan_digest = package_plan_digest,
        dependency_graph = package_normalized -> 'spec' -> 'dependencies',
        support_declarations = package_normalized -> 'spec' -> 'support',
        normalized = package_normalized,
        declaration_digest = decode(package_definition_digest, 'hex')
    WHERE policy_set_version_id = version_id;
    DELETE FROM pgreact_internal.policy_set_supports WHERE policy_set_version_id = version_id;
    UPDATE pgreact_internal.policy_set_members member
    SET package_owned = true
    WHERE member.policy_set_version_id = version_id;
    FOR support IN SELECT value FROM jsonb_array_elements(package_normalized -> 'spec' -> 'support') value LOOP
        ordinal := ordinal + 1;
        INSERT INTO pgreact_internal.policy_set_supports(
            policy_set_version_id, ordinal, support_kind, support_name, support_version,
            support_declaration, definition_digest)
        VALUES (version_id, ordinal, support ->> 'kind', support ->> 'name',
                COALESCE(support ->> 'version', '1'), support -> 'declaration',
                pgreact_internal.m53_package_digest(support -> 'declaration'));
    END LOOP;
    DELETE FROM pgreact_internal.policy_set_dependencies WHERE policy_set_version_id = version_id;
    ordinal := 0;
    FOR dependency IN SELECT value FROM jsonb_array_elements(package_normalized -> 'spec' -> 'dependencies') value LOOP
        ordinal := ordinal + 1;
        INSERT INTO pgreact_internal.policy_set_dependencies(
            policy_set_version_id, ordinal, from_kind, from_name, from_version,
            on_kind, on_name, on_version)
        VALUES (version_id, ordinal, dependency -> 'from' ->> 'kind',
                dependency -> 'from' ->> 'name', COALESCE(dependency -> 'from' ->> 'version', '1'),
                dependency -> 'on' ->> 'kind', dependency -> 'on' ->> 'name',
                COALESCE(dependency -> 'on' ->> 'version', '1'));
    END LOOP;
    RETURN result || jsonb_build_object(
        'contract_version', 53, 'operation', 'deploy',
        'package', jsonb_build_object(
            'complete', checked -> 'complete', 'definition_digest', package_definition_digest,
            'plan_digest', package_plan_digest, 'member_count', checked -> 'member_count',
            'support_count', checked -> 'support_count',
            'dependency_count', checked -> 'dependency_count'),
        'findings', findings);
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_status(target pgreact_api.target)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT pgreact_internal.m32_result(pgreact_api.status_m31($1, '{}'::jsonb))
        || jsonb_build_object('contract_version', 53,
            'package', COALESCE((SELECT jsonb_build_object(
                'complete', version.package_complete,
                'format_version', version.package_format_version,
                'definition_digest', version.definition_digest,
                'plan_digest', version.plan_digest,
                'dependencies', version.dependency_graph,
                'supports', version.support_declarations)
                FROM pgreact_internal.policy_set_versions version
                JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                WHERE set.set_name = ($1).name
                  AND (($1).version IS NULL OR version.version = ($1).version)
                ORDER BY version.valid_from DESC, version.created_at DESC LIMIT 1), '{}'::jsonb))
$m53$;

CREATE VIEW pgreact.policy_set_contents AS
SELECT set.set_name AS name, version.version, 'member'::text AS role,
       member.member_kind AS kind, member.member_name AS object_name,
       member.member_version AS object_version,
       version.definition_digest, version.state
FROM pgreact_internal.policy_set_versions version
JOIN pgreact_internal.policy_sets set USING (policy_set_id)
JOIN pgreact_internal.policy_set_members member USING (policy_set_version_id)
WHERE pg_has_role(session_user, set.owner_oid, 'USAGE')
   OR pgreact_internal.is_operator_admin()
   OR EXISTS (SELECT 1 FROM pgreact_internal.application_roles role_row
              WHERE role_row.role_kind = 'reader'
                AND pg_has_role(session_user, role_row.role_oid, 'member'))
UNION ALL
SELECT set.set_name, version.version, 'support', support.support_kind,
       support.support_name, support.support_version,
       support.definition_digest, version.state
FROM pgreact_internal.policy_set_versions version
JOIN pgreact_internal.policy_sets set USING (policy_set_id)
JOIN pgreact_internal.policy_set_supports support USING (policy_set_version_id)
WHERE pg_has_role(session_user, set.owner_oid, 'USAGE')
   OR pgreact_internal.is_operator_admin()
   OR EXISTS (SELECT 1 FROM pgreact_internal.application_roles role_row
              WHERE role_row.role_kind = 'reader'
                AND pg_has_role(session_user, role_row.role_oid, 'member'));

CREATE VIEW pgreact.policy_set_dependencies AS
SELECT set.set_name AS name, version.version,
       dependency.ordinal, dependency.from_kind, dependency.from_name,
       dependency.from_version, dependency.on_kind, dependency.on_name,
       dependency.on_version, version.definition_digest, version.state
FROM pgreact_internal.policy_set_versions version
JOIN pgreact_internal.policy_sets set USING (policy_set_id)
JOIN pgreact_internal.policy_set_dependencies dependency USING (policy_set_version_id)
WHERE pg_has_role(session_user, set.owner_oid, 'USAGE')
   OR pgreact_internal.is_operator_admin()
   OR EXISTS (SELECT 1 FROM pgreact_internal.application_roles role_row
              WHERE role_row.role_kind = 'reader'
                AND pg_has_role(session_user, role_row.role_oid, 'member'));

CREATE OR REPLACE FUNCTION pgreact.validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN ($1).kind = 'policy_set'
        AND (($1).spec ? 'support' OR ($1).spec ? 'dependencies' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(($1).spec -> 'members') = 'array'
                THEN ($1).spec -> 'members' ELSE '[]'::jsonb END) value
            WHERE jsonb_typeof(value -> 'declaration') = 'object'))
        THEN pgreact_internal.m53_package_validate_result($1)
        ELSE pgreact_internal.m32_result(pgreact_api.validate_m31($1)) END
$m53$;

CREATE OR REPLACE FUNCTION pgreact.preview(
    declaration pgreact_api.declaration, options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN ($1).kind = 'policy_set'
        AND (($1).spec ? 'support' OR ($1).spec ? 'dependencies' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(($1).spec -> 'members') = 'array'
                THEN ($1).spec -> 'members' ELSE '[]'::jsonb END) value
            WHERE jsonb_typeof(value -> 'declaration') = 'object'))
        THEN pgreact_internal.m53_package_preview($1, $2)
        ELSE pgreact_internal.m32_preview($1, $2) END
$m53$;

CREATE OR REPLACE FUNCTION pgreact.deploy(
    declaration pgreact_api.declaration, preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN ($1).kind = 'policy_set'
        AND (($1).spec ? 'support' OR ($1).spec ? 'dependencies' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(($1).spec -> 'members') = 'array'
                THEN ($1).spec -> 'members' ELSE '[]'::jsonb END) value
            WHERE jsonb_typeof(value -> 'declaration') = 'object'))
        THEN pgreact_internal.m53_package_deploy($1, $2)
        ELSE pgreact_internal.m32_result(pgreact_api.deploy_m31($1, $2)) END
$m53$;

CREATE OR REPLACE FUNCTION pgreact.status(
    name text, options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM pgreact_internal.policy_sets set
        JOIN pgreact_internal.policy_set_versions version USING (policy_set_id)
        WHERE set.set_name = $1 AND version.state = 'DEPLOYED'
          AND version.package_format_version = 1)
        THEN pgreact_internal.m53_package_status(pgreact_internal.m32_target($1))
        ELSE pgreact_internal.m32_result(pgreact_api.status_m31(
            pgreact_internal.m32_target($1), $2)) END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_remove(
    name text, preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE target pgreact_api.target := pgreact_internal.m32_target(name, 'policy_set', NULL);
    result jsonb;
    child record;
BEGIN
    result := pgreact_api.remove_m31(target, preconditions);
    FOR child IN
        SELECT member.member_kind, member.member_name, member.member_version
        FROM pgreact_internal.policy_set_members member
        JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = name AND version.state = 'REMOVED' AND member.package_owned
        ORDER BY member.member_kind DESC, member.member_name DESC, member.member_version DESC
    LOOP
        PERFORM pgreact_api.remove_m31(
            pgreact_api.target(child.member_kind, child.member_name, child.member_version),
            '{}'::jsonb);
    END LOOP;
    UPDATE pgreact_internal.policy_set_members member
    SET package_owned = false
    FROM pgreact_internal.policy_set_versions version, pgreact_internal.policy_sets set
    WHERE member.policy_set_version_id = version.policy_set_version_id
      AND version.policy_set_id = set.policy_set_id AND set.set_name = name;
    DELETE FROM pgreact_internal.policy_set_supports support
    USING pgreact_internal.policy_set_versions version, pgreact_internal.policy_sets set
    WHERE support.policy_set_version_id = version.policy_set_version_id
      AND version.policy_set_id = set.policy_set_id AND set.set_name = name;
    DELETE FROM pgreact_internal.policy_set_dependencies dependency
    USING pgreact_internal.policy_set_versions version, pgreact_internal.policy_sets set
    WHERE dependency.policy_set_version_id = version.policy_set_version_id
      AND version.policy_set_id = set.policy_set_id AND set.set_name = name;
    RETURN result || jsonb_build_object('contract_version', 53, 'operation', 'remove');
END
$m53$;

CREATE OR REPLACE FUNCTION pgreact.remove(
    name text, preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN EXISTS (
        SELECT 1 FROM pgreact_internal.policy_sets set
        JOIN pgreact_internal.policy_set_versions version USING (policy_set_id)
        WHERE set.set_name = $1 AND version.state = 'DEPLOYED'
          AND version.package_format_version = 1)
        THEN pgreact_internal.m53_package_remove($1, $2)
        ELSE pgreact_internal.m32_remove(pgreact_internal.m32_target($1), $2) END
$m53$;

ALTER FUNCTION pgreact.export(text, text, text) RENAME TO export_m32;

CREATE FUNCTION pgreact.export(
    name text, kind text DEFAULT NULL, version text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN COALESCE($2, 'policy_set') = 'policy_set'
        AND EXISTS (SELECT 1 FROM pgreact_internal.policy_sets set
                    JOIN pgreact_internal.policy_set_versions version_row USING (policy_set_id)
                    WHERE set.set_name = $1 AND version_row.state = 'DEPLOYED'
                      AND version_row.package_format_version = 1
                      AND ($3 IS NULL OR version_row.version = $3))
        THEN (SELECT jsonb_build_object(
            'format_version', 1, 'api_version', '1', 'kind', 'policy_set', 'name', set.set_name,
            'spec', version_row.normalized -> 'spec',
            'definition_digest', COALESCE(version_row.definition_digest,
                encode(version_row.declaration_digest, 'hex')),
            'digest', COALESCE(version_row.definition_digest,
                encode(version_row.declaration_digest, 'hex')))
            FROM pgreact_internal.policy_sets set
            JOIN pgreact_internal.policy_set_versions version_row USING (policy_set_id)
            WHERE set.set_name = $1 AND version_row.state = 'DEPLOYED'
              AND version_row.package_format_version = 1
              AND ($3 IS NULL OR version_row.version = $3)
            ORDER BY version_row.valid_from DESC, version_row.created_at DESC LIMIT 1)
        ELSE pgreact.export_m32($1, $2, $3) END
$m53$;

ALTER FUNCTION pgreact.import(jsonb, jsonb) RENAME TO import_m32;

CREATE FUNCTION pgreact.import(
    document jsonb, preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
DECLARE declaration pgreact_api.declaration;
    expected_digest text;
    actual_digest text;
BEGIN
    IF jsonb_typeof(document) IS DISTINCT FROM 'object'
       OR document ->> 'kind' IS NULL OR document ->> 'name' IS NULL
       OR jsonb_typeof(document -> 'spec') IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M53_IMPORT_DOCUMENT: export must contain kind, name, and object spec';
    END IF;
    expected_digest := COALESCE(document ->> 'definition_digest', document ->> 'digest');
    IF document ->> 'kind' = 'policy_set'
       AND (document -> 'spec' ? 'support' OR document -> 'spec' ? 'dependencies' OR EXISTS (
           SELECT 1 FROM jsonb_array_elements(CASE
               WHEN jsonb_typeof(document -> 'spec' -> 'members') = 'array'
               THEN document -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
           WHERE jsonb_typeof(value -> 'declaration') = 'object')) THEN
        actual_digest := pgreact_internal.m53_package_digest(
            pgreact_internal.m53_package_normalize(
                pgreact_api.declaration(document ->> 'kind', document ->> 'name', document -> 'spec')));
    ELSE
        actual_digest := encode(sha256(convert_to(jsonb_build_object(
            'api_version', COALESCE(document ->> 'api_version', '1'),
            'kind', document ->> 'kind', 'name', document ->> 'name',
            'spec', document -> 'spec')::text, 'UTF8')), 'hex');
    END IF;
    IF expected_digest IS NOT NULL AND expected_digest <> actual_digest THEN
        RAISE EXCEPTION 'M53_IMPORT_DIGEST: canonical package digest does not match document';
    END IF;
    declaration := pgreact_api.declaration(document ->> 'kind', document ->> 'name', document -> 'spec');
    IF document ->> 'kind' = 'policy_set'
       AND NOT (document -> 'spec' ? 'support' OR document -> 'spec' ? 'dependencies' OR EXISTS (
           SELECT 1 FROM jsonb_array_elements(CASE
               WHEN jsonb_typeof(document -> 'spec' -> 'members') = 'array'
               THEN document -> 'spec' -> 'members' ELSE '[]'::jsonb END) value
           WHERE jsonb_typeof(value -> 'declaration') = 'object')) THEN
        RETURN pgreact.import_m32(document, preconditions);
    END IF;
    RETURN pgreact.deploy(declaration, preconditions);
END
$m53$;

ALTER FUNCTION pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb)
    RENAME TO compare_m43;

CREATE FUNCTION pgreact.compare(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN ($1).kind = 'policy_set' AND ($2).kind = 'policy_set'
        AND (($1).spec ? 'support' OR ($1).spec ? 'dependencies' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(($1).spec -> 'members') = 'array'
                THEN ($1).spec -> 'members' ELSE '[]'::jsonb END) value
            WHERE jsonb_typeof(value -> 'declaration') = 'object') OR EXISTS (
            SELECT 1
            FROM pgreact_internal.policy_sets set
            JOIN pgreact_internal.policy_set_versions version USING (policy_set_id)
            WHERE set.set_name = ($2).name AND version.state = 'DEPLOYED'
              AND version.package_format_version = 1))
        THEN pgreact_internal.m53_package_compare($1, $2, $3)
        ELSE pgreact.compare_m43($1, $2, $3) END
$m53$;

ALTER FUNCTION pgreact_api.semantic_diff(
    pgreact_api.declaration, pgreact_api.target, jsonb)
    RENAME TO semantic_diff_m43;

CREATE FUNCTION pgreact_api.semantic_diff(
    proposed pgreact_api.declaration,
    deployed pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN ($1).kind = 'policy_set' AND ($2).kind = 'policy_set'
        AND (($1).spec ? 'support' OR ($1).spec ? 'dependencies' OR EXISTS (
            SELECT 1 FROM jsonb_array_elements(CASE
                WHEN jsonb_typeof(($1).spec -> 'members') = 'array'
                THEN ($1).spec -> 'members' ELSE '[]'::jsonb END) value
            WHERE jsonb_typeof(value -> 'declaration') = 'object') OR EXISTS (
            SELECT 1
            FROM pgreact_internal.policy_sets set
            JOIN pgreact_internal.policy_set_versions version USING (policy_set_id)
            WHERE set.set_name = ($2).name AND version.state = 'DEPLOYED'
              AND version.package_format_version = 1))
        THEN pgreact_internal.m53_package_semantic_diff($1, $2, $3)
        ELSE pgreact_api.semantic_diff_m43($1, $2, $3) END
$m53$;

CREATE OR REPLACE FUNCTION pgreact_internal.m53_package_doctor(target pgreact_api.target)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT jsonb_build_object(
        'contract_version', 53, 'operation', 'doctor',
        'state', CASE WHEN status -> 'package' ->> 'complete' = 'true'
                      THEN 'ready' ELSE 'attention' END,
        'target', status -> 'target', 'package', status -> 'package',
        'diagnostics', status -> 'findings', 'read_only', true, 'truncated', false)
    FROM (SELECT pgreact_internal.m53_package_status($1) AS status) current_status
$m53$;

ALTER FUNCTION pgreact.doctor(text, jsonb) RENAME TO doctor_m32;

CREATE FUNCTION pgreact.doctor(
    name text,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
    SELECT CASE WHEN EXISTS (
        SELECT 1
        FROM pgreact_internal.policy_sets set
        JOIN pgreact_internal.policy_set_versions version USING (policy_set_id)
        WHERE set.set_name = $1 AND version.state = 'DEPLOYED'
          AND version.package_format_version = 1)
        THEN pgreact_internal.m53_package_doctor(
            pgreact_internal.m32_target($1, 'policy_set', NULL))
        ELSE pgreact.doctor_m32($1, $2) END
$m53$;

REVOKE ALL ON FUNCTION pgreact.shared_condition(text,regclass,name[],text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.parameter_family(text,regclass,name,name[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.policy_set(text,text,pgreact_api.declaration[],regclass,name[],pgreact_api.declaration[],jsonb,timestamptz,timestamptz,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.policy_set(text,text,pgreact_api.declaration[],regclass,name[],text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.validate(pgreact_api.declaration) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.preview(pgreact_api.declaration,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.deploy(pgreact_api.declaration,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.status(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.remove(text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.export(text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.import(jsonb,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.semantic_diff(pgreact_api.declaration,pgreact_api.target,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.doctor(text,jsonb) FROM PUBLIC;

COMMENT ON VIEW pgreact.policy_set_contents IS
    'M53 canonical packaged member and support declarations';
COMMENT ON VIEW pgreact.policy_set_dependencies IS
    'M53 canonical typed dependency edges for complete policy sets';

CREATE OR REPLACE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m53$
BEGIN
    PERFORM pgreact_api.configure_roles_m43(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format(
        'GRANT EXECUTE ON FUNCTION pgreact.shared_condition(text,regclass,name[],text), pgreact.parameter_family(text,regclass,name,name[]), pgreact.policy_set(text,text,pgreact_api.declaration[],regclass,name[],pgreact_api.declaration[],jsonb,timestamptz,timestamptz,integer) TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
    EXECUTE format(
        'GRANT SELECT ON pgreact.policy_set_contents, pgreact.policy_set_dependencies TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
END
$m53$;
