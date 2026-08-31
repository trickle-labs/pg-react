-- M40 bounded why-not evidence over the installed current-state adapters.

CREATE OR REPLACE FUNCTION pgreact_internal.m40_finding(
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
AS $m40$
    SELECT jsonb_build_object(
        'code', $1,
        'severity', $2,
        'blocking', $2 = 'ERROR',
        'target', $3,
        'field', $4,
        'message', $5,
        'hint', $6,
        'details', COALESCE($7, '{}'::jsonb))
$m40$;

CREATE OR REPLACE FUNCTION pgreact_internal.m40_finding_registry()
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m40$
SELECT jsonb_build_array(
    jsonb_build_object('code', 'M40_OPTIONS_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M40_EXPECTED_RESULT_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M40_SUBJECT_INVALID', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M40_TARGET_NOT_FOUND', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M40_TARGET_AMBIGUOUS', 'severity', 'ERROR'),
    jsonb_build_object('code', 'M40_UNSUPPORTED_TARGET', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_UNSUPPORTED_RESULT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_DERIVED_FACT_MISSING', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_UNAUTHORIZED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_RLS_REJECTED', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_SCHEMA_DRIFT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_STALE_FRONTIER', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_EVIDENCE_UNAVAILABLE', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_EVIDENCE_PARTIAL', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_RESOURCE_LIMIT', 'severity', 'WARNING'),
    jsonb_build_object('code', 'M40_NO_EFFECT', 'severity', 'INFO'))
$m40$;

CREATE OR REPLACE FUNCTION pgreact_internal.m40_requested(options jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $m40$
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object'
       OR NOT options ? 'why_not' THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(options -> 'why_not') = 'boolean'
       AND (options ->> 'why_not')::boolean = false THEN
        RETURN false;
    END IF;
    RETURN true;
END
$m40$;

CREATE OR REPLACE FUNCTION pgreact_internal.m40_strip_options(options jsonb)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m40$
    SELECT CASE WHEN jsonb_typeof($1) = 'object' THEN $1 - 'why_not' ELSE $1 END
$m40$;

CREATE OR REPLACE FUNCTION pgreact_internal.m40_subject_key(subject jsonb)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
AS $m40$
DECLARE value_text text;
BEGIN
    IF subject IS NULL THEN
        RETURN NULL;
    ELSIF jsonb_typeof(subject) = 'object' THEN
        value_text := COALESCE(subject ->> 'key', subject ->> 'subject');
    ELSIF jsonb_typeof(subject) IN ('number', 'string') THEN
        value_text := subject #>> '{}';
    ELSE
        RETURN NULL;
    END IF;
    IF value_text IS NULL OR value_text !~ '^-?[0-9]+$' THEN
        RETURN NULL;
    END IF;
    BEGIN
        RETURN value_text::bigint;
    EXCEPTION WHEN numeric_value_out_of_range THEN
        RETURN NULL;
    END;
END
$m40$;

CREATE OR REPLACE FUNCTION pgreact_internal.m40_cost(
    started_at timestamptz,
    candidate_discovery bigint,
    support_checks bigint,
    evidence_expansion bigint,
    path_depth bigint,
    returned_causes bigint
)
RETURNS jsonb
LANGUAGE SQL
VOLATILE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m40$
    SELECT jsonb_build_object(
        'candidate_discovery', $2,
        'support_checks', $3,
        'evidence_expansion', $4,
        'path_depth', $5,
        'returned_causes', $6,
        'elapsed_ms', extract(epoch FROM clock_timestamp() - $1) * 1000)
$m40$;

CREATE OR REPLACE FUNCTION pgreact_internal.m40_result(
    target_kind text,
    target_name text,
    target_version text,
    state text,
    subject jsonb,
    expected jsonb,
    sampled_time timestamptz,
    authoritative_frontier timestamptz,
    observed jsonb,
    causes jsonb,
    findings jsonb,
    limits jsonb,
    cost jsonb
)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
AS $m40$
    SELECT jsonb_build_object(
        'contract_version', 26,
        'operation', 'explain',
        'target', jsonb_build_object(
            'kind', COALESCE($1, '<unknown>'),
            'name', COALESCE($2, '<unknown>'),
            'version', $3),
        'state', $4,
        'request', jsonb_build_object(
            'why_not', true,
            'expected_result', COALESCE($6, '{}'::jsonb)),
        'subject', $5,
        'sampled_time', $7,
        'authoritative_frontier', $8,
        'observed', COALESCE($9, '{}'::jsonb),
        'causes', COALESCE($10, '[]'::jsonb),
        'completeness', jsonb_build_object(
            'state', $4,
            'causes_exact', $4 IN ('complete', 'already_present'),
            'public_evidence', true),
        'limits', COALESCE($12, '{}'::jsonb),
        'cost', COALESCE($13, '{}'::jsonb),
        'evidence', jsonb_build_object(
            'sampled_time', $7,
            'source_frontier', $8,
            'causes_exact', $4 IN ('complete', 'already_present'),
            'path_is_public', true),
        'findings', COALESCE($11, '[]'::jsonb),
        'diagnostics', '[]'::jsonb,
        'truncated', false)
$m40$;

CREATE OR REPLACE FUNCTION pgreact_internal.m40_explain(
    target_name text,
    subject jsonb,
    options jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m40$
DECLARE
    started_at timestamptz := clock_timestamp();
    sampled_time timestamptz := statement_timestamp();
    authoritative_frontier timestamptz;
    target_count bigint;
    target_kind text;
    target_version text;
    expected_input jsonb;
    expected_payload jsonb;
    expected jsonb;
    expected_kind text;
    expected_key text;
    expected_key_numeric bigint;
    expected_value jsonb;
    cause_limit integer := 32;
    limit_text text;
    subject_key bigint;
    subject_identity text;
    source_oid oid;
    relation_kind "char";
    rls_enabled boolean;
    source_name text;
    source_row jsonb;
    source_count bigint := 0;
    match_row jsonb;
    decision_row record;
    derived_row record;
    derived_fact jsonb;
    derived_support_count bigint := 0;
    candidate_row jsonb;
    candidate_count bigint := 0;
    candidate_priority bigint;
    winner_row jsonb;
    winner_state text;
    winner_candidate bigint;
    winner_priority bigint;
    policy_row pgreact_internal.policy_set_versions%ROWTYPE;
    scope_row record;
    source_complete boolean := true;
    causes jsonb := '[]'::jsonb;
    findings jsonb := '[]'::jsonb;
    observed jsonb := '{}'::jsonb;
    limits jsonb;
    state text;
BEGIN
    SELECT frontier INTO authoritative_frontier
    FROM pgreact_internal.clock_frontier
    WHERE singleton;

    IF jsonb_typeof(options) IS DISTINCT FROM 'object'
       OR jsonb_typeof(options -> 'why_not') IS DISTINCT FROM 'object' THEN
        RETURN pgreact_internal.m40_result(
            NULL, target_name, NULL, 'unsupported', subject, '{}', sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_OPTIONS_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                    'options.why_not',
                    'why_not must be an object containing one expected result',
                    'Pass why_not => {result_kind, result_key}.' )),
            jsonb_build_object('cause_limit', cause_limit),
            pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;

    expected_input := options -> 'why_not';
    expected_payload := COALESCE(expected_input -> 'expected_result',
                                 expected_input -> 'expected', expected_input);
    expected_kind := COALESCE(expected_payload ->> 'result_kind',
                              expected_payload ->> 'kind');
    expected_key := COALESCE(expected_payload ->> 'result_key',
                              expected_payload ->> 'key', expected_payload ->> 'identity');
    expected_value := expected_payload -> 'value';
    limit_text := expected_input ->> 'cause_limit';
    IF limit_text IS NOT NULL THEN
        IF limit_text !~ '^[1-9][0-9]*$' THEN
            RETURN pgreact_internal.m40_result(
                NULL, target_name, NULL, 'unsupported', subject, '{}', sampled_time,
                authoritative_frontier, '{}', '[]', jsonb_build_array(
                    pgreact_internal.m40_finding(
                        'M40_OPTIONS_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                        'options.why_not.cause_limit',
                        'cause_limit must be a positive integer',
                        'Use a value between 1 and 1000.' )),
                jsonb_build_object('cause_limit', cause_limit),
                pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
        END IF;
        IF length(limit_text) > 4 THEN
            RETURN pgreact_internal.m40_result(
                NULL, target_name, NULL, 'unsupported', subject, '{}', sampled_time,
                authoritative_frontier, '{}', '[]', jsonb_build_array(
                    pgreact_internal.m40_finding(
                        'M40_OPTIONS_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                        'options.why_not.cause_limit',
                        'cause_limit exceeds the supported bound',
                        'Use a value between 1 and 1000.' )),
                jsonb_build_object('cause_limit', cause_limit),
                pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
        END IF;
        cause_limit := limit_text::integer;
        IF cause_limit > 1000 THEN
            RETURN pgreact_internal.m40_result(
                NULL, target_name, NULL, 'unsupported', subject, '{}', sampled_time,
                authoritative_frontier, '{}', '[]', jsonb_build_array(
                    pgreact_internal.m40_finding(
                        'M40_OPTIONS_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                        'options.why_not.cause_limit',
                        'cause_limit exceeds the supported bound',
                        'Use a value between 1 and 1000.' )),
                jsonb_build_object('cause_limit', cause_limit),
                pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
        END IF;
    END IF;
    limits := jsonb_build_object(
        'candidate_limit', 1000,
        'cause_limit', cause_limit,
        'path_depth_limit', 1,
        'evidence_limit', cause_limit);

    IF jsonb_typeof(expected_payload) IS DISTINCT FROM 'object'
       OR expected_kind IS NULL OR expected_key IS NULL OR expected_key = '' THEN
        RETURN pgreact_internal.m40_result(
            NULL, target_name, NULL, 'unsupported', subject, '{}', sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_EXPECTED_RESULT_INVALID', 'ERROR', COALESCE(target_name, '<unknown>'),
                    'options.why_not.expected_result',
                    'one public result kind and result key are required',
                    'Use result_kind and result_key in the why_not object.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    expected := jsonb_build_object('kind', expected_kind, 'key', expected_key)
        || CASE WHEN expected_value IS NULL THEN '{}'::jsonb
                ELSE jsonb_build_object('value', expected_value) END;

    SELECT count(*) INTO target_count
    FROM (
        SELECT declaration.kind, declaration.object_name
        FROM pgreact_internal.api_declarations declaration
        WHERE declaration.state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
        UNION
        SELECT 'derived_relation', relation.relation_name
        FROM pgreact_internal.derived_relations relation
        JOIN pgreact_internal.derived_relation_versions version USING (relation_id)
        WHERE version.state = 'ACTIVE'
    ) targets
    WHERE object_name = target_name;
    IF target_count = 0 THEN
        RETURN pgreact_internal.m40_result(
            NULL, target_name, NULL, 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_TARGET_NOT_FOUND', 'ERROR', COALESCE(target_name, '<unknown>'),
                    'target', 'no deployed target with this public name exists',
                    'Use the stable name of one deployed rule, decision program, or policy set.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    ELSIF target_count > 1 THEN
        RETURN pgreact_internal.m40_result(
            NULL, target_name, NULL, 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_TARGET_AMBIGUOUS', 'ERROR', target_name, 'target',
                    'more than one deployed target has this public name',
                    'Pass a unique public target name.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    SELECT kind, object_name INTO target_kind, target_name
    FROM (
        SELECT declaration.kind, declaration.object_name
        FROM pgreact_internal.api_declarations declaration
        WHERE declaration.state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
        UNION
        SELECT 'derived_relation', relation.relation_name
        FROM pgreact_internal.derived_relations relation
        JOIN pgreact_internal.derived_relation_versions version USING (relation_id)
        WHERE version.state = 'ACTIVE'
    ) targets
    WHERE object_name = target_name
    LIMIT 1;

    IF target_kind NOT IN ('rule', 'decision_program', 'policy_set', 'derived_relation') THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_UNSUPPORTED_TARGET', 'WARNING', target_name, 'target.kind',
                    'this target kind has no bounded M40 adapter',
                    'Use a deployed rule, decision program, policy set, or derived relation.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;

    subject_key := pgreact_internal.m40_subject_key(subject);
    subject_identity := CASE WHEN jsonb_typeof(subject) = 'object'
                             THEN subject::text ELSE subject #>> '{}' END;
    IF target_kind IN ('rule', 'decision_program', 'derived_relation') AND subject_key IS NULL THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_SUBJECT_INVALID', 'ERROR', target_name, 'subject',
                    'this adapter requires one bigint business key',
                    'Pass a JSON number or {"key": number}.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;

    IF target_kind = 'rule' AND expected_kind <> 'rule_match' THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, '1', 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_UNSUPPORTED_RESULT', 'WARNING', target_name, 'expected_result.kind',
                    'rules accept the public rule_match result kind',
                    'Use result_kind => rule_match and the semantic key as result_key.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    IF target_kind = 'decision_program' AND expected_kind <> 'decision_result' THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_UNSUPPORTED_RESULT', 'WARNING', target_name, 'expected_result.kind',
                    'decision programs accept the public decision_result result kind',
                    'Use result_kind => decision_result and the candidate key as result_key.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    IF target_kind = 'policy_set' AND expected_kind <> 'policy_eligibility' THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_UNSUPPORTED_RESULT', 'WARNING', target_name, 'expected_result.kind',
                    'policy sets accept the public policy_eligibility result kind',
                    'Use result_kind => policy_eligibility and the subject as result_key.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    IF target_kind = 'derived_relation' AND expected_kind <> 'derived_fact' THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected, sampled_time,
            authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_UNSUPPORTED_RESULT', 'WARNING', target_name, 'expected_result.kind',
                    'derived relations accept the public derived_fact result kind',
                    'Use result_kind => derived_fact and the semantic key as result_key.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;

    expected_key_numeric := pgreact_internal.m40_subject_key(to_jsonb(expected_key));
    IF target_kind IN ('rule', 'derived_relation')
       AND (expected_key_numeric IS NULL OR expected_key_numeric <> subject_key) THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected,
            sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_EXPECTED_RESULT_INVALID', 'ERROR', target_name,
                    'expected_result.key',
                    'the expected result key must equal the bigint subject key',
                    'Use the subject key as result_key.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    IF target_kind = 'decision_program' AND expected_key_numeric IS NULL THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected,
            sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_EXPECTED_RESULT_INVALID', 'ERROR', target_name,
                    'expected_result.key',
                    'decision result keys must be bigint candidate keys',
                    'Use the candidate key as result_key.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;

    IF target_kind = 'derived_relation' THEN
        
        SELECT version.relation_version_id, version.version,
               version.public_view_oid, version.public_view_name
        INTO derived_row
        FROM pgreact_internal.derived_relations relation
        JOIN pgreact_internal.derived_relation_versions version USING (relation_id)
        WHERE relation.relation_name = target_name AND version.state = 'ACTIVE'
        ORDER BY version.version DESC
        LIMIT 1;
        IF derived_row.relation_version_id IS NULL THEN
            RETURN pgreact_internal.m40_result(
                target_kind, target_name, NULL, 'unavailable', subject, expected,
                sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                    pgreact_internal.m40_finding(
                        'M40_EVIDENCE_UNAVAILABLE', 'WARNING', target_name, 'version',
                        'the active derived relation version is unavailable',
                        'Refresh or restore the derived relation before asking why-not.' )),
                limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
        END IF;
        target_version := derived_row.version::text;
        source_oid := derived_row.public_view_oid;
        source_name := derived_row.public_view_name;
        IF source_oid IS NULL OR NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
            RETURN pgreact_internal.m40_result(
                target_kind, target_name, target_version, 'unavailable', subject, expected,
                sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                    pgreact_internal.m40_finding(
                        'M40_UNAUTHORIZED', 'WARNING', target_name, 'source',
                        'the caller cannot read the public derived-fact view',
                        'Grant the caller SELECT on the public derived-fact view.' )),
                limits, pgreact_internal.m40_cost(started_at, 1, 0, 0, 0, 0));
        END IF;
        SELECT jsonb_build_object(
                   'fact', fact.fact,
                   'support_count', fact.support_count,
                   'first_frontier', fact.first_frontier,
                   'last_frontier', fact.last_frontier)
        INTO derived_fact
        FROM pgreact.derived_facts fact
        WHERE fact.relation_name = target_name
          AND fact.relation_version = derived_row.version
          AND fact.semantic_key = subject_key
        LIMIT 1;
        SELECT count(*) INTO derived_support_count
        FROM pgreact_internal.derived_supports support
        WHERE support.relation_version_id = derived_row.relation_version_id
          AND support.semantic_key = subject_key AND support.active;
        IF derived_fact IS NOT NULL THEN
            state := 'already_present';
            observed := jsonb_build_object('state', 'DERIVED_FACT', 'fact', derived_fact);
        ELSIF derived_support_count = 0 THEN
            state := 'complete';
            causes := jsonb_build_array(jsonb_build_object(
                'kind', 'derived_fact', 'direction', 'absent',
                'path', 'derived.' || target_name || '.fact',
                'public_evidence', jsonb_build_object(
                    'relation', target_name, 'subject_key', subject_key,
                    'support_count', 0)));
            observed := jsonb_build_object(
                'state', 'ABSENT', 'support_count', derived_support_count);
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_DERIVED_FACT_MISSING', 'WARNING', target_name, 'derived_fact',
                'the modeled derived fact has no active support',
                'Inspect the maintained source rule and its public support evidence.'));
        ELSE
            state := 'unavailable';
            causes := jsonb_build_array(jsonb_build_object(
                'kind', 'positive_support', 'direction', 'present_without_fact',
                'path', 'derived.' || target_name || '.support',
                'public_evidence', jsonb_build_object(
                    'relation', target_name, 'subject_key', subject_key,
                    'support_count', derived_support_count)));
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_EVIDENCE_UNAVAILABLE', 'WARNING', target_name, 'derived_fact',
                'active support exists but the derived fact is not available',
                'Reconcile the derived relation before treating the absence as complete.'));
            observed := jsonb_build_object(
                'state', 'ABSENT', 'support_count', derived_support_count);
        END IF;
        SELECT COALESCE(jsonb_agg(value ORDER BY value ->> 'path'), '[]'::jsonb)
        INTO causes FROM jsonb_array_elements(causes) item(value);
        IF state = 'complete' OR state = 'already_present' THEN
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_NO_EFFECT', 'INFO', target_name, 'why_not',
                'why-not evaluation was read-only',
                'The request changed no source or pg-react state.'));
        END IF;
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, target_version, state, subject, expected,
            sampled_time, authoritative_frontier, observed, causes, findings, limits,
            pgreact_internal.m40_cost(started_at, 1, derived_support_count,
                                      jsonb_array_length(causes),
                                      CASE WHEN jsonb_array_length(causes) > 0 THEN 1 ELSE 0 END,
                                      jsonb_array_length(causes)));
    END IF;

    IF target_kind = 'rule' THEN
        SELECT version.rule_version_id, version.source_view_oid, version.source_view_name,
               version.key_column, version.state
        INTO STRICT decision_row
        FROM pgreact_internal.api_declarations declaration
        JOIN pgreact_internal.rule_versions version
          ON version.rule_version_id = declaration.delegated_id
        WHERE declaration.kind = 'rule'
          AND declaration.object_name = target_name
          AND declaration.state = 'DEPLOYED'
        ORDER BY version.created_at DESC
        LIMIT 1;
        target_version := '1';
        source_oid := decision_row.source_view_oid;
        source_name := decision_row.source_view_name;
        SELECT relkind, relrowsecurity INTO relation_kind, rls_enabled
        FROM pg_class WHERE oid = source_oid;
        IF relation_kind IS NULL THEN
            source_complete := false;
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_SCHEMA_DRIFT', 'WARNING', target_name, 'source',
                'the deployed rule source no longer exists',
                'Restore the source relation or deploy a replacement rule.'));
        ELSIF rls_enabled THEN
            source_complete := false;
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_RLS_REJECTED', 'WARNING', target_name, 'source',
                'row-level security prevents a safe complete answer',
                'Use a source with the inherited fail-closed RLS contract.'));
        ELSIF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
            source_complete := false;
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_UNAUTHORIZED', 'WARNING', target_name, 'source',
                'the caller lacks SELECT on a source needed for this answer',
                'Grant the caller read access to the source relation.'));
        ELSE
            IF NOT EXISTS (
                SELECT 1 FROM pg_attribute
                WHERE attrelid = source_oid AND attname = decision_row.key_column
                  AND attnum > 0 AND NOT attisdropped) THEN
                source_complete := false;
                findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                    'M40_SCHEMA_DRIFT', 'WARNING', target_name, 'source.key_column',
                    'the deployed rule key column no longer exists',
                    'Restore the declared key column or deploy a replacement rule.'));
            ELSE
                EXECUTE format('SELECT count(*) FROM %s s WHERE s.%I = $1',
                               source_oid::regclass, decision_row.key_column)
                INTO source_count USING subject_key;
                EXECUTE format('SELECT to_jsonb(s) FROM %s s WHERE s.%I = $1 LIMIT 1',
                               source_oid::regclass, decision_row.key_column)
                INTO source_row USING subject_key;
                SELECT jsonb_build_object(
                           'semantic_key', current_match.semantic_key,
                           'active', current_match.active,
                           'generation', current_match.generation,
                           'revision', current_match.revision,
                           'bindings', current_match.bindings)
                INTO match_row
                FROM pgreact.matches current_match
                WHERE current_match.name = target_name
                  AND current_match.semantic_key = subject_key
                  AND current_match.active
                ORDER BY current_match.revision DESC
                LIMIT 1;
                IF match_row IS NOT NULL THEN
                    state := 'already_present';
                    observed := jsonb_build_object('state', 'MATCH', 'match', match_row);
                ELSE
                    IF source_count = 0 THEN
                        causes := causes || jsonb_build_array(jsonb_build_object(
                            'kind', 'missing_input', 'direction', 'absent',
                            'path', 'source.' || decision_row.key_column::text,
                            'public_evidence', jsonb_build_object(
                                'source', source_name, 'key', subject_key, 'row', NULL)));
                    ELSE
                        causes := causes || jsonb_build_array(jsonb_build_object(
                            'kind', 'positive_support', 'direction', 'present_but_not_active',
                            'path', 'source.' || decision_row.key_column::text,
                            'public_evidence', jsonb_build_object(
                                'source', source_name, 'key', subject_key, 'row', source_row)));
                        source_complete := false;
                        findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                            'M40_EVIDENCE_UNAVAILABLE', 'WARNING', target_name, 'activation',
                            'the source row is present but no active match is available',
                            'Refresh the deployed rule before treating the absence as complete.'));
                    END IF;
                    IF decision_row.state <> 'ACTIVE' THEN
                        causes := causes || jsonb_build_array(jsonb_build_object(
                            'kind', 'lifecycle_revision', 'direction', 'disqualifying',
                            'path', 'runtime.state',
                            'public_evidence', jsonb_build_object(
                                'state', decision_row.state)));
                    END IF;
                    FOR scope_row IN
                        SELECT set.set_name, version.version,
                               EXISTS (SELECT 1
                                       FROM pgreact_internal.policy_set_runtime_barriers barrier
                                       WHERE barrier.policy_set_version_id = version.policy_set_version_id
                                         AND barrier.cleared_at IS NULL) AS blocked
                        FROM pgreact_internal.policy_set_members member
                        JOIN pgreact_internal.policy_set_versions version
                          USING (policy_set_version_id)
                        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
                        WHERE member.member_kind = 'rule'
                          AND member.member_name = target_name
                          AND member.member_version IN ('1', decision_row.rule_version_id::text)
                          AND member.scope_mode = 'POLICY_SET_REQUIRED'
                          AND version.state = 'DEPLOYED'
                          AND version.valid_from <= sampled_time
                          AND (version.valid_to IS NULL OR sampled_time < version.valid_to)
                    LOOP
                        IF scope_row.blocked THEN
                            source_complete := false;
                            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                                'M40_EVIDENCE_UNAVAILABLE', 'WARNING', target_name,
                                'applicability', 'a required policy-set runtime barrier is active',
                                'Repair the policy-set source before using the answer.'));
                        ELSIF NOT pgreact_internal.m30_subject_eligible(
                                  pgreact_api.target('policy_set', scope_row.set_name, scope_row.version),
                                  subject) THEN
                            causes := causes || jsonb_build_array(jsonb_build_object(
                                'kind', 'applicability', 'direction', 'disqualifying',
                                'path', 'policy_set.' || scope_row.set_name || '.eligibility',
                                'public_evidence', jsonb_build_object(
                                    'policy_set', scope_row.set_name,
                                    'version', scope_row.version,
                                    'subject', subject)));
                        END IF;
                    END LOOP;
                END IF;
            END IF;
        END IF;
        IF state IS NULL THEN
            state := CASE WHEN source_complete THEN 'complete' ELSE 'unavailable' END;
        END IF;
        SELECT COALESCE(jsonb_agg(value ORDER BY value ->> 'path'), '[]'::jsonb)
        INTO causes FROM jsonb_array_elements(causes) item(value);
        IF state = 'complete' OR state = 'already_present' THEN
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_NO_EFFECT', 'INFO', target_name, 'why_not',
                'why-not evaluation was read-only',
                'The request changed no source or pg-react state.'));
        END IF;
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, target_version, state, subject, expected,
            sampled_time, authoritative_frontier,
            COALESCE(observed, jsonb_build_object('state', 'ABSENT', 'source', source_name)),
            causes, findings, limits,
            pgreact_internal.m40_cost(started_at, 1, jsonb_array_length(causes),
                                      jsonb_array_length(causes),
                                      CASE WHEN jsonb_array_length(causes) > 0 THEN 1 ELSE 0 END,
                                      jsonb_array_length(causes)));
    END IF;

    IF target_kind = 'decision_program' THEN
        IF expected_key !~ '^-?[0-9]+$' THEN
            RETURN pgreact_internal.m40_result(
                target_kind, target_name, NULL, 'unsupported', subject, expected,
                sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                    pgreact_internal.m40_finding(
                        'M40_EXPECTED_RESULT_INVALID', 'ERROR', target_name,
                        'expected_result.key', 'decision result keys must be bigint candidate keys',
                        'Use the candidate key as result_key.' )),
                limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
        END IF;
        SELECT version.*
        INTO decision_row
        FROM pgreact_internal.decision_programs program
        JOIN pgreact_internal.decision_program_versions version USING (program_id)
        WHERE program.program_name = target_name
          AND program.state <> 'REMOVED'
          AND version.state = 'DEPLOYED'
        ORDER BY version.valid_from DESC, version.version_no DESC
        LIMIT 1;
        IF decision_row.version_id IS NULL THEN
            RETURN pgreact_internal.m40_result(
                target_kind, target_name, NULL, 'unavailable', subject, expected,
                sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                    pgreact_internal.m40_finding(
                        'M40_EVIDENCE_UNAVAILABLE', 'WARNING', target_name, 'version',
                        'the deployed decision version is unavailable',
                        'Deploy a current decision version before asking why-not.' )),
                limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
        END IF;
        target_version := decision_row.version_no::text;
        source_oid := decision_row.candidate_relation_oid;
        source_name := decision_row.candidate_relation_name;
        IF sampled_time < decision_row.valid_from
           OR (decision_row.valid_to IS NOT NULL AND sampled_time >= decision_row.valid_to) THEN
            causes := jsonb_build_array(jsonb_build_object(
                'kind', 'inactive_policy_time', 'direction', 'disqualifying',
                'path', 'decision.validity',
                'public_evidence', jsonb_build_object(
                    'valid_from', decision_row.valid_from,
                    'valid_to', decision_row.valid_to,
                    'sampled_time', sampled_time)));
            RETURN pgreact_internal.m40_result(
                target_kind, target_name, target_version, 'complete', subject, expected,
                sampled_time, authoritative_frontier,
                jsonb_build_object('state', 'INACTIVE_TIME'), causes,
                jsonb_build_array(pgreact_internal.m40_finding(
                    'M40_NO_EFFECT', 'INFO', target_name, 'why_not',
                    'why-not evaluation was read-only',
                    'The request changed no source or pg-react state.')),
                limits, pgreact_internal.m40_cost(started_at, 1, 0, 1, 1, 1));
        END IF;
        SELECT relkind, relrowsecurity INTO relation_kind, rls_enabled
        FROM pg_class WHERE oid = source_oid;
        IF relation_kind IS NULL THEN
            findings := jsonb_build_array(pgreact_internal.m40_finding(
                'M40_SCHEMA_DRIFT', 'WARNING', target_name, 'source',
                'the decision candidate source no longer exists',
                'Restore the source relation or deploy a replacement decision.'));
            source_complete := false;
        ELSIF rls_enabled THEN
            findings := jsonb_build_array(pgreact_internal.m40_finding(
                'M40_RLS_REJECTED', 'WARNING', target_name, 'source',
                'row-level security prevents a safe complete answer',
                'Use a source with the inherited fail-closed RLS contract.'));
            source_complete := false;
        ELSIF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
            findings := jsonb_build_array(pgreact_internal.m40_finding(
                'M40_UNAUTHORIZED', 'WARNING', target_name, 'source',
                'the caller lacks SELECT on the candidate source',
                'Grant the caller read access to the source relation.'));
            source_complete := false;
        ELSE
            EXECUTE format('SELECT count(*) FROM %s s WHERE s.%I = $1',
                           source_oid::regclass, decision_row.subject_key_column)
            INTO candidate_count USING subject_key;
            EXECUTE format(
                'SELECT to_jsonb(s), s.%1$I::bigint, s.%2$I::bigint
                 FROM %3$s s WHERE s.%4$I = $1 AND s.%1$I = $2 LIMIT 1',
                decision_row.candidate_key_column, decision_row.priority_column,
                source_oid::regclass, decision_row.subject_key_column)
            INTO candidate_row, winner_candidate, candidate_priority
            USING subject_key, expected_key_numeric;
            SELECT jsonb_build_object(
                       'state', winner.state,
                       'winner_candidate', winner.winner_candidate,
                       'winner_priority', winner.winner_priority,
                       'winner_result', winner.winner_result,
                       'competitors', winner.competitors,
                       'competitors_truncated', winner.competitors_truncated),
                   winner.state, winner.winner_candidate, winner.winner_priority
            INTO winner_row, winner_state, winner_candidate, winner_priority
            FROM pgreact.decision_winners winner
            WHERE winner.program_name = target_name
              AND winner.subject_key = pgreact_internal.m40_subject_key(subject)
            LIMIT 1;
            observed := jsonb_build_object(
                'state', COALESCE(winner_state, 'NO_CANDIDATE'),
                'candidate_count', candidate_count,
                'expected_candidate', candidate_row,
                'winner', COALESCE(winner_row, '{}'::jsonb));
            IF winner_state = 'WINNER' AND winner_candidate = expected_key_numeric THEN
                state := 'already_present';
            ELSE
                IF candidate_row IS NULL THEN
                    causes := causes || jsonb_build_array(jsonb_build_object(
                        'kind', 'decision_candidate', 'direction', 'absent',
                        'path', 'candidate.' || expected_key,
                        'public_evidence', jsonb_build_object(
                            'source', source_name, 'subject', subject_key,
                            'candidate_key', expected_key, 'row', NULL)));
                END IF;
                IF winner_state = 'NO_CANDIDATE' OR winner_state = 'AMBIGUOUS'
                   OR winner_state IS NULL THEN
                    causes := causes || jsonb_build_array(jsonb_build_object(
                        'kind', 'decision_eligibility', 'direction', 'disqualifying',
                        'path', 'decision.state',
                        'public_evidence', jsonb_build_object(
                            'state', COALESCE(winner_state, 'NO_CANDIDATE'),
                            'candidate_count', candidate_count)));
                ELSIF candidate_row IS NOT NULL THEN
                    causes := causes || jsonb_build_array(jsonb_build_object(
                        'kind', 'decision_selection', 'direction', 'not_selected',
                        'path', 'decision.winner',
                        'public_evidence', jsonb_build_object(
                            'expected_candidate', expected_key,
                            'expected_priority', candidate_priority,
                            'winner_candidate', winner_candidate,
                            'winner_priority', winner_priority)));
                END IF;
                IF candidate_count > decision_row.max_candidates THEN
                    source_complete := false;
                    findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                        'M40_RESOURCE_LIMIT', 'WARNING', target_name, 'candidate_count',
                        'the candidate source exceeds its declared bound',
                        'Reduce candidates or deploy a decision with a larger bound.'));
                END IF;
            END IF;
        END IF;
        IF state IS NULL THEN
            state := CASE WHEN source_complete THEN 'complete' ELSE 'unavailable' END;
        END IF;
        SELECT COALESCE(jsonb_agg(value ORDER BY value ->> 'path'), '[]'::jsonb)
        INTO causes FROM jsonb_array_elements(causes) item(value);
        IF state = 'complete' OR state = 'already_present' THEN
            findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
                'M40_NO_EFFECT', 'INFO', target_name, 'why_not',
                'why-not evaluation was read-only',
                'The request changed no source or pg-react state.'));
        END IF;
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, target_version, state, subject, expected,
            sampled_time, authoritative_frontier, observed, causes, findings, limits,
            pgreact_internal.m40_cost(started_at, candidate_count, 1,
                                      jsonb_array_length(causes),
                                      CASE WHEN jsonb_array_length(causes) > 0 THEN 1 ELSE 0 END,
                                      jsonb_array_length(causes)));
    END IF;

    subject_identity := CASE WHEN jsonb_typeof(subject) = 'object'
                             THEN subject::text ELSE subject #>> '{}' END;
    IF expected_key <> subject_identity THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unsupported', subject, expected,
            sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_EXPECTED_RESULT_INVALID', 'ERROR', target_name,
                    'expected_result.key',
                    'the policy eligibility key must equal the supplied subject',
                    'Use the subject JSON value as result_key.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    SELECT version.* INTO policy_row
    FROM pgreact_internal.policy_set_versions version
    JOIN pgreact_internal.policy_sets set USING (policy_set_id)
    WHERE set.set_name = target_name AND version.state = 'DEPLOYED'
    ORDER BY version.valid_from DESC
    LIMIT 1;
    IF policy_row.policy_set_version_id IS NULL THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, NULL, 'unavailable', subject, expected,
            sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_EVIDENCE_UNAVAILABLE', 'WARNING', target_name, 'version',
                    'the deployed policy-set version is unavailable',
                    'Deploy a current policy-set version before asking why-not.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    target_version := policy_row.version;
    IF policy_row.applicability_kind <> 'relation' THEN
        RETURN pgreact_internal.m40_result(
            target_kind, target_name, target_version, 'unsupported', subject, expected,
            sampled_time, authoritative_frontier, '{}', '[]', jsonb_build_array(
                pgreact_internal.m40_finding(
                    'M40_UNSUPPORTED_TARGET', 'WARNING', target_name, 'applicability',
                    'only relational policy-set applicability is modeled in M40',
                    'Use a relation-backed policy-set or wait for a later adapter.' )),
            limits, pgreact_internal.m40_cost(started_at, 0, 0, 0, 0, 0));
    END IF;
    source_oid := policy_row.applicability_source_oid;
    source_name := policy_row.applicability_source;
    SELECT relkind, relrowsecurity INTO relation_kind, rls_enabled
    FROM pg_class WHERE oid = source_oid;
    IF relation_kind IS NULL THEN
        source_complete := false;
        findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
            'M40_SCHEMA_DRIFT', 'WARNING', target_name, 'applicability',
            'the policy-set applicability source no longer exists',
            'Restore the source relation or deploy a replacement policy set.'));
    ELSIF rls_enabled THEN
        source_complete := false;
        findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
            'M40_RLS_REJECTED', 'WARNING', target_name, 'applicability',
            'row-level security prevents a safe complete answer',
            'Use a source with the inherited fail-closed RLS contract.'));
    ELSIF NOT has_table_privilege(session_user, source_oid, 'SELECT') THEN
        source_complete := false;
        findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
            'M40_UNAUTHORIZED', 'WARNING', target_name, 'applicability',
            'the caller lacks SELECT on the applicability source',
            'Grant the caller read access to the source relation.'));
    END IF;
    IF sampled_time < policy_row.valid_from
       OR (policy_row.valid_to IS NOT NULL AND sampled_time >= policy_row.valid_to) THEN
        causes := jsonb_build_array(jsonb_build_object(
            'kind', 'inactive_policy_time', 'direction', 'disqualifying',
            'path', 'policy_set.validity',
            'public_evidence', jsonb_build_object(
                'valid_from', policy_row.valid_from,
                'valid_to', policy_row.valid_to,
                'sampled_time', sampled_time)));
        state := 'complete';
    ELSIF source_complete THEN
        IF pgreact_internal.m30_subject_eligible(
               pgreact_api.target('policy_set', target_name, target_version), subject) THEN
            state := 'already_present';
            observed := jsonb_build_object('state', 'ELIGIBLE', 'subject', subject);
        ELSE
            causes := jsonb_build_array(jsonb_build_object(
                'kind', 'applicability', 'direction', 'disqualifying',
                'path', 'policy_set.eligibility',
                'public_evidence', jsonb_build_object(
                    'policy_set', target_name, 'version', target_version,
                    'subject', subject, 'eligible', false)));
            state := 'complete';
            observed := jsonb_build_object('state', 'INELIGIBLE', 'subject', subject);
        END IF;
    ELSE
        state := 'unavailable';
    END IF;
    IF policy_row.complete_frontier < sampled_time AND state <> 'already_present' THEN
        state := 'partial';
        findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
            'M40_STALE_FRONTIER', 'WARNING', target_name, 'authoritative_frontier',
            'the installed eligibility evidence is older than the sampled time',
            'Refresh the policy set and retry the request.'));
    END IF;
    SELECT COALESCE(jsonb_agg(value ORDER BY value ->> 'path'), '[]'::jsonb)
    INTO causes FROM jsonb_array_elements(causes) item(value);
    IF state = 'complete' OR state = 'already_present' THEN
        findings := findings || jsonb_build_array(pgreact_internal.m40_finding(
            'M40_NO_EFFECT', 'INFO', target_name, 'why_not',
            'why-not evaluation was read-only',
            'The request changed no source or pg-react state.'));
    END IF;
    RETURN pgreact_internal.m40_result(
        target_kind, target_name, target_version, state, subject, expected,
        sampled_time, authoritative_frontier, observed, causes, findings, limits,
        pgreact_internal.m40_cost(started_at, 1, 1, jsonb_array_length(causes),
                                  CASE WHEN jsonb_array_length(causes) > 0 THEN 1 ELSE 0 END,
                                  jsonb_array_length(causes)));
END
$m40$;

CREATE OR REPLACE FUNCTION pgreact.explain(
    name text,
    subject jsonb DEFAULT NULL,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m40$
    SELECT CASE WHEN pgreact_internal.m40_requested($3)
        THEN pgreact_internal.m40_explain($1, $2, $3)
        ELSE pgreact_internal.m32_result(pgreact_api.explain_m31(
            pgreact_internal.m32_target($1), $2,
            pgreact_internal.m40_strip_options($3)))
    END
$m40$;

REVOKE ALL ON FUNCTION pgreact_internal.m40_finding(text, text, text, text, text, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m40_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m40_requested(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m40_strip_options(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m40_subject_key(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m40_cost(timestamptz, bigint, bigint, bigint, bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m40_result(text, text, text, text, jsonb, jsonb, timestamptz, timestamptz, jsonb, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m40_explain(text, jsonb, jsonb) FROM PUBLIC;

COMMENT ON FUNCTION pgreact.explain(text, jsonb, jsonb) IS
    'M40 bounded current-state explanation with opt-in why-not evidence';
COMMENT ON EXTENSION pg_react IS
    'M40 bounded why-not evidence over installed current-state adapters';
