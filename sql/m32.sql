-- M32 PostgreSQL-native ordinary interface over the authoritative M31 runtime.

CREATE FUNCTION pgreact_internal.m32_stable_code(code text)
RETURNS text
LANGUAGE SQL IMMUTABLE STRICT AS $m32$
    SELECT CASE
        WHEN $1 IN (
            'M32_INVALID_DECLARATION', 'M32_MISSING_OBJECT', 'M32_AMBIGUOUS_OBJECT',
            'M32_WRONG_KEY_TYPE', 'M32_INVALID_ACTION_SIGNATURE',
            'M32_UNAUTHORIZED_OBJECT', 'M32_RLS_UNSUPPORTED', 'M32_SOURCE_DRIFT',
            'M32_ACTION_DRIFT', 'M32_STALE_PREVIEW', 'M32_UNSUPPORTED_KIND',
            'M32_ADVANCED_ONLY', 'M32_RESOURCE_LIMIT', 'M32_RECOVERY_BARRIER',
            'M32_INCOMPLETE_FRONTIER', 'M32_POLICY_SCOPE_INCOMPATIBLE',
            'M32_DECLARATION_MIGRATION_REQUIRED', 'M32_DEPRECATED_COMPATIBILITY',
            'M32_RUNTIME_READY', 'M32_RUNTIME_NOT_READY', 'M32_WORK_FAILED',
            'M32_RETRY_EXHAUSTED')
            THEN $1
        WHEN $1 LIKE '%UNSUPPORTED_KIND%' THEN 'M32_UNSUPPORTED_KIND'
        WHEN $1 LIKE '%NOT_FOUND%' OR $1 LIKE '%RELATION_NOT_FOUND%'
            THEN 'M32_MISSING_OBJECT'
        WHEN $1 LIKE '%AMBIGU%' OR $1 LIKE '%DUPLICATE%' THEN 'M32_AMBIGUOUS_OBJECT'
        WHEN $1 LIKE '%RLS%' THEN 'M32_RLS_UNSUPPORTED'
        WHEN $1 LIKE '%UNAUTHORIZED%' THEN 'M32_UNAUTHORIZED_OBJECT'
        WHEN $1 LIKE '%STALE%' THEN 'M32_STALE_PREVIEW'
        WHEN $1 LIKE '%ACTION%DRIFT%' THEN 'M32_ACTION_DRIFT'
        WHEN $1 LIKE '%DRIFT%' THEN 'M32_SOURCE_DRIFT'
        WHEN $1 LIKE '%INCOMPLETE%FRONTIER%' OR $1 LIKE '%FRONTIER%INCOMPLETE%'
            THEN 'M32_INCOMPLETE_FRONTIER'
        WHEN $1 LIKE '%POLICY%SCOPE%' OR $1 LIKE '%SCOPE%INCOMPATIB%'
            THEN 'M32_POLICY_SCOPE_INCOMPATIBLE'
        WHEN $1 LIKE '%RUNTIME%NOT%READY%' OR $1 LIKE '%RUNTIME%BLOCK%'
            THEN 'M32_RUNTIME_NOT_READY'
        WHEN $1 LIKE '%READY%' THEN 'M32_RUNTIME_READY'
        WHEN $1 LIKE '%WORK%FAIL%' THEN 'M32_WORK_FAILED'
        WHEN $1 LIKE '%RETRY%' OR $1 LIKE '%EXHAUST%' THEN 'M32_RETRY_EXHAUSTED'
        WHEN $1 LIKE '%LIMIT%' OR $1 LIKE '%OVER_LIMIT%' THEN 'M32_RESOURCE_LIMIT'
        WHEN $1 LIKE '%BARRIER%' THEN 'M32_RECOVERY_BARRIER'
        WHEN $1 LIKE '%MIGRATION%' THEN 'M32_DECLARATION_MIGRATION_REQUIRED'
        WHEN $1 LIKE '%ACTION%' OR $1 LIKE '%CONSEQUENCE%' THEN 'M32_INVALID_ACTION_SIGNATURE'
        WHEN $1 LIKE '%ADVANCED%' THEN 'M32_ADVANCED_ONLY'
        WHEN $1 LIKE '%DEPRECATED%' THEN 'M32_DEPRECATED_COMPATIBILITY'
        WHEN $1 LIKE '%KEY%' THEN 'M32_WRONG_KEY_TYPE'
        ELSE 'M32_INVALID_DECLARATION'
    END
$m32$;

CREATE FUNCTION pgreact_internal.m32_finding_shape(finding jsonb)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT AS $m32$
    SELECT jsonb_build_object(
        'code', pgreact_internal.m32_stable_code(finding ->> 'code'),
        'severity', COALESCE(finding ->> 'severity', 'ERROR'),
        'blocking', COALESCE(
            finding -> 'blocking',
            finding -> 'blocker',
            CASE WHEN COALESCE(finding ->> 'severity', 'ERROR') = 'ERROR'
                 THEN 'true'::jsonb ELSE 'false'::jsonb END),
        'target', COALESCE(finding ->> 'target', finding ->> 'object_identity', '<unknown>'),
        'field', COALESCE(finding ->> 'field', finding ->> 'field_path', '<unknown>'),
        'message', COALESCE(finding ->> 'message', ''),
        'hint', COALESCE(finding ->> 'hint', ''),
        'details', COALESCE(finding -> 'details', '{}'::jsonb)
            || CASE WHEN (finding ->> 'code') LIKE 'M32_%' THEN '{}'::jsonb
                    ELSE jsonb_build_object('source_code', finding ->> 'code') END)
$m32$;

CREATE FUNCTION pgreact_internal.m32_findings(findings jsonb)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT AS $m32$
    SELECT COALESCE(jsonb_agg(pgreact_internal.m32_finding_shape(value)
                              ORDER BY ordinal), '[]'::jsonb)
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(findings) = 'array'
                                   THEN findings ELSE '[]'::jsonb END)
         WITH ORDINALITY items(value, ordinal)
$m32$;

CREATE FUNCTION pgreact_internal.m32_result(result jsonb)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT AS $m32$
    SELECT result
        || CASE WHEN result ? 'findings'
                THEN jsonb_build_object('findings',
                         pgreact_internal.m32_findings(result -> 'findings'))
                ELSE '{}'::jsonb END
        || CASE WHEN result ? 'diagnostics'
                THEN jsonb_build_object('diagnostics',
                         pgreact_internal.m32_findings(result -> 'diagnostics'))
                ELSE '{}'::jsonb END
$m32$;

CREATE FUNCTION pgreact.rule(
    name text,
    condition regclass,
    semantic_key name,
    kind text DEFAULT 'CONSTRAINT',
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS pgreact_api.declaration
LANGUAGE SQL IMMUTABLE AS $m32$
    SELECT pgreact_api.declaration(
        'rule', $1,
        jsonb_strip_nulls(jsonb_build_object(
            'condition', $2::text,
            'semantic_key', $3::text,
            'kind', $4,
            'on_activate', $5::text,
            'on_deactivate', $6::text,
            'on_change', $7::text,
            'bootstrap_policy', $8,
            'change_columns', to_jsonb($9),
            'salience', $10,
            'agenda_group', $11,
            'conflict_key_columns', to_jsonb($12),
            'max_attempts', $13,
            'initial_backoff_seconds', $14,
            'backoff_multiplier', $15,
            'max_backoff_seconds', $16,
            'delegate', true)))
$m32$;

CREATE FUNCTION pgreact.decision(
    name text,
    candidate_relation regclass,
    subject_key name,
    candidate_key name,
    priority name,
    results name[],
    valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL,
    max_candidates integer DEFAULT 1000
)
RETURNS pgreact_api.declaration
LANGUAGE SQL VOLATILE AS $m32$
    SELECT pgreact_api.declaration(
        'decision_program', $1,
        jsonb_strip_nulls(jsonb_build_object(
            'candidate_relation', $2::text,
            'subject_key', $3::text,
            'candidate_key', $4::text,
            'priority', $5::text,
            'results', to_jsonb($6),
            'valid_from', $7,
            'valid_to', $8,
            'max_candidates', $9,
            'delegate', true)))
$m32$;

CREATE FUNCTION pgreact.policy_set(
    name text,
    version text,
    members pgreact_api.declaration[],
    applicability regclass,
    subject_keys name[],
    valid_from timestamptz DEFAULT clock_timestamp(),
    valid_to timestamptz DEFAULT NULL,
    evidence_limit integer DEFAULT 100
)
RETURNS pgreact_api.declaration
LANGUAGE plpgsql VOLATILE AS $m32$
DECLARE member_json jsonb;
BEGIN
    IF cardinality(COALESCE(members, ARRAY[]::pgreact_api.declaration[])) = 0 THEN
        RAISE EXCEPTION 'M32_MEMBERS: policy_set requires at least one typed member';
    END IF;
    IF cardinality(COALESCE(subject_keys, ARRAY[]::name[])) = 0 THEN
        RAISE EXCEPTION 'M32_SUBJECT_KEYS: policy_set requires at least one subject key';
    END IF;
    SELECT jsonb_agg(jsonb_build_object(
               'kind', item.kind,
               'name', item.name,
               'version', '1',
               'match_keys', CASE item.kind
                   WHEN 'rule' THEN jsonb_build_array(
                       item.spec ->> 'semantic_key')
                   WHEN 'decision_program'
                       THEN jsonb_build_array(
                           item.spec ->> 'candidate_key')
               END,
               'subject_keys', to_jsonb(subject_keys),
               'scope_mode', 'POLICY_SET_REQUIRED')
           ORDER BY item.ordinality)
    INTO member_json
    FROM unnest(members) WITH ORDINALITY AS item;
    IF EXISTS (
        SELECT 1
        FROM unnest(members) AS item
        WHERE item.kind NOT IN ('rule', 'decision_program')
    ) THEN
        RAISE EXCEPTION 'M32_MEMBER_KIND: policy_set members must be pgreact.rule or pgreact.decision';
    END IF;
    RETURN pgreact_api.declaration(
        'policy_set', name,
        jsonb_strip_nulls(jsonb_build_object(
            'version', version,
            'members', member_json,
            'applicability', jsonb_build_object(
                'source_kind', 'relation',
                'relation', applicability::text,
                'subject_keys', to_jsonb(subject_keys)),
            'valid_from', valid_from,
            'valid_to', valid_to,
            'evidence_limit', evidence_limit)));
END
$m32$;

CREATE OR REPLACE FUNCTION pgreact_internal.m28_validate(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m32$
DECLARE
    findings jsonb := '[]'::jsonb;
    unknown_field text;
    relation_name text;
    required_field text;
    allowed_fields text[] := ARRAY[
        'condition', 'semantic_key', 'kind', 'on_activate', 'on_deactivate', 'on_change',
        'bootstrap_policy', 'candidate_relation', 'subject_key', 'candidate_key', 'priority',
        'results', 'valid_from', 'valid_to', 'max_candidates', 'primitive', 'duration',
        'deadline_column', 'family_name', 'parameter_relation', 'parameter_key',
        'parameter_value_columns', 'parameter_values', 'definition', 'program_name',
        'current_version', 'proposed_version', 'population_relation', 'population_key',
        'candidate_catalog', 'catalog_candidate_key', 'catalog_default_column',
        'require_default', 'exclusive', 'max_absolute_distribution_delta',
        'max_relative_distribution_delta', 'evidence_limit', 'population_limit', 'options',
        'delegate', 'salience', 'agenda_group', 'max_attempts', 'initial_backoff_seconds',
        'backoff_multiplier', 'max_backoff_seconds'
    ];
    target pgreact_api.declaration := declaration;
BEGIN
    IF target IS NULL THEN
        findings := findings || pgreact_internal.m28_finding(
            'M28_DECLARATION_NULL', 'ERROR', '<unnamed>', '<declaration>',
            'declaration is required', 'Build a versioned declaration with pgreact_api.declaration()');
        RETURN jsonb_build_object('normalized', NULL, 'findings', findings);
    END IF;
    IF (target).api_version IS DISTINCT FROM '1' THEN
        findings := findings || pgreact_internal.m28_finding(
            'M28_API_VERSION', 'ERROR', COALESCE((target).name, '<unnamed>'), 'api_version',
            'only declaration API version 1 is supported', 'Set api_version to 1');
    END IF;
    IF (target).kind IS NULL OR (target).kind NOT IN (
        'rule', 'derived_program', 'temporal_policy', 'shared_condition',
        'effective_policy', 'parameter_family', 'decision_program', 'decision_analysis') THEN
        findings := findings || pgreact_internal.m28_finding(
            'M28_KIND', 'ERROR', COALESCE((target).name, '<unnamed>'), 'kind',
            'declaration kind is unsupported',
            'Use rule, derived_program, temporal_policy, shared_condition, effective_policy, parameter_family, decision_program, or decision_analysis');
    END IF;
    IF (target).name IS NULL OR (target).name !~ '^[A-Za-z_][A-Za-z0-9_.-]*$' THEN
        findings := findings || pgreact_internal.m28_finding(
            'M28_NAME', 'ERROR', COALESCE((target).name, '<unnamed>'), 'name',
            'name must be a stable non-empty public name',
            'Use letters, digits, underscore, dot, or hyphen and start with a letter or underscore');
    END IF;
    IF (target).spec IS NULL OR jsonb_typeof((target).spec) IS DISTINCT FROM 'object' THEN
        findings := findings || pgreact_internal.m28_finding(
            'M28_SPEC', 'ERROR', COALESCE((target).name, '<unnamed>'), 'spec',
            'spec must be a JSON object', 'Provide named declaration fields in spec');
        RETURN jsonb_build_object('normalized', pgreact_internal.m28_normalize(target), 'findings', findings);
    END IF;
    SELECT key INTO unknown_field
    FROM jsonb_object_keys((target).spec) AS key
    WHERE key <> ALL (allowed_fields)
    ORDER BY key LIMIT 1;
    IF unknown_field IS NOT NULL THEN
        findings := findings || pgreact_internal.m28_finding(
            'M28_FIELD_UNKNOWN', 'ERROR', (target).name, 'spec.' || unknown_field,
            'declaration contains an unknown field',
            'Remove the field or use a newer supported API version', jsonb_build_object('field', unknown_field));
    END IF;
    IF (target).kind IN ('rule', 'temporal_policy', 'shared_condition', 'effective_policy') THEN
        FOREACH required_field IN ARRAY ARRAY['condition', 'semantic_key'] LOOP
            IF NOT ((target).spec ? required_field)
               OR NULLIF(btrim((target).spec ->> required_field), '') IS NULL THEN
                findings := findings || pgreact_internal.m28_finding(
                    'M28_FIELD_REQUIRED', 'ERROR', (target).name, 'spec.' || required_field,
                    'required declaration field is missing', 'Provide a stable named value');
            END IF;
        END LOOP;
        relation_name := (target).spec ->> 'condition';
        IF relation_name IS NOT NULL AND relation_name !~ '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$' THEN
            findings := findings || pgreact_internal.m28_finding(
                'M28_RELATION_NAME', 'ERROR', (target).name, 'spec.condition',
                'relation references must be schema-qualified', 'Use schema_name.object_name');
        ELSIF relation_name IS NOT NULL AND to_regclass(relation_name) IS NULL THEN
            findings := findings || pgreact_internal.m28_finding(
                'M28_RELATION_NOT_FOUND', 'ERROR', (target).name, 'spec.condition',
                'declared PostgreSQL relation was not found', 'Create the relation or correct its qualified name');
        END IF;
    ELSIF (target).kind = 'derived_program' THEN
        IF jsonb_typeof((target).spec -> 'definition') IS DISTINCT FROM 'object' THEN
            findings := findings || pgreact_internal.m28_finding(
                'M28_FIELD_REQUIRED', 'ERROR', (target).name, 'spec.definition',
                'derived programs require a named definition object', 'Provide the existing derived-program definition');
        END IF;
    ELSIF (target).kind = 'parameter_family' THEN
        FOREACH required_field IN ARRAY ARRAY['parameter_relation', 'parameter_key', 'parameter_value_columns'] LOOP
            IF NOT ((target).spec ? required_field)
               OR NULLIF(btrim((target).spec ->> required_field), '') IS NULL THEN
                findings := findings || pgreact_internal.m28_finding(
                    'M28_FIELD_REQUIRED', 'ERROR', (target).name, 'spec.' || required_field,
                    'required parameter-family field is missing', 'Provide the existing named family fields');
            END IF;
        END LOOP;
    ELSIF (target).kind = 'decision_program' THEN
        FOREACH required_field IN ARRAY ARRAY['candidate_relation', 'subject_key', 'candidate_key', 'priority', 'results'] LOOP
            IF NOT ((target).spec ? required_field)
               OR NULLIF(btrim((target).spec ->> required_field), '') IS NULL THEN
                findings := findings || pgreact_internal.m28_finding(
                    'M28_FIELD_REQUIRED', 'ERROR', (target).name, 'spec.' || required_field,
                    'required decision-program field is missing', 'Provide the existing named decision fields');
            END IF;
        END LOOP;
        relation_name := (target).spec ->> 'candidate_relation';
        IF relation_name IS NOT NULL AND relation_name !~ '^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*$' THEN
            findings := findings || pgreact_internal.m28_finding(
                'M28_RELATION_NAME', 'ERROR', (target).name, 'spec.candidate_relation',
                'relation references must be schema-qualified', 'Use schema_name.object_name');
        ELSIF relation_name IS NOT NULL AND to_regclass(relation_name) IS NULL THEN
            findings := findings || pgreact_internal.m28_finding(
                'M28_RELATION_NOT_FOUND', 'ERROR', (target).name, 'spec.candidate_relation',
                'declared PostgreSQL relation was not found', 'Create the relation or correct its qualified name');
        END IF;
        IF (jsonb_typeof((target).spec -> 'results') IS DISTINCT FROM 'array'
            OR CASE WHEN jsonb_typeof((target).spec -> 'results') = 'array'
                    THEN jsonb_array_length((target).spec -> 'results') = 0 ELSE false END) THEN
            findings := findings || pgreact_internal.m28_finding(
                'M28_RESULTS', 'ERROR', (target).name, 'spec.results',
                'results must be a non-empty array of column names', 'Name at least one result column');
        END IF;
    ELSIF (target).kind = 'decision_analysis' THEN
        FOREACH required_field IN ARRAY ARRAY['program_name', 'current_version', 'proposed_version', 'population_relation', 'population_key', 'candidate_catalog'] LOOP
            IF NOT ((target).spec ? required_field)
               OR NULLIF(btrim((target).spec ->> required_field), '') IS NULL THEN
                findings := findings || pgreact_internal.m28_finding(
                    'M28_FIELD_REQUIRED', 'ERROR', (target).name, 'spec.' || required_field,
                    'required decision-analysis field is missing', 'Provide the existing M27 analysis identity');
            END IF;
        END LOOP;
    END IF;
    RETURN jsonb_build_object('normalized', pgreact_internal.m28_normalize(target), 'findings', findings);
END
$m32$;

ALTER FUNCTION pgreact_api.validate(pgreact_api.declaration) RENAME TO validate_m31;
ALTER FUNCTION pgreact_api.preview(pgreact_api.declaration, jsonb) RENAME TO preview_m31;
ALTER FUNCTION pgreact_api.deploy(pgreact_api.declaration, jsonb) RENAME TO deploy_m31;
ALTER FUNCTION pgreact_api.status(pgreact_api.target, jsonb) RENAME TO status_m31;
ALTER FUNCTION pgreact_api.explain(pgreact_api.target, jsonb, jsonb) RENAME TO explain_m31;
ALTER FUNCTION pgreact_api.doctor(pgreact_api.target, jsonb) RENAME TO doctor_m31;
ALTER FUNCTION pgreact_api.run(pgreact_api.target, timestamptz) RENAME TO run_m31_target;
ALTER FUNCTION pgreact_api.run(timestamptz) RENAME TO run_m31_global;
ALTER FUNCTION pgreact_api.remove(pgreact_api.target, jsonb) RENAME TO remove_m31;

CREATE FUNCTION pgreact.validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.validate_m31($1))
$m32$;

CREATE FUNCTION pgreact_internal.m32_preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
DECLARE result jsonb;
    current_state text := 'ABSENT';
    current_digest text;
BEGIN
    result := pgreact_internal.m32_result(pgreact_api.preview_m31(declaration, options));
    SELECT lower(row_data.state),
           encode(row_data.declaration_digest, 'hex')
    INTO current_state, current_digest
    FROM pgreact_internal.api_declarations row_data
    WHERE row_data.kind = (declaration).kind
      AND row_data.object_name = (declaration).name;
    IF current_state = 'ABSENT' AND (declaration).kind = 'policy_set' THEN
        SELECT lower(version.state),
               encode(version.declaration_digest, 'hex')
        INTO current_state, current_digest
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = (declaration).name
          AND version.state = 'DEPLOYED'
          AND version.version = (declaration).spec ->> 'version'
        ORDER BY version.valid_from DESC, version.created_at DESC
        LIMIT 1;
        current_state := COALESCE(current_state, 'ABSENT');
    END IF;
    RETURN result || jsonb_build_object(
        'summary', COALESCE(result -> 'summary', '{}'::jsonb)
            || jsonb_build_object(
                'deployment', CASE WHEN current_state = 'deployed'
                                   THEN 'replacement' ELSE 'create' END,
                'current_state', current_state,
                'current_declaration_digest', current_digest));
END
$m32$;

CREATE FUNCTION pgreact.preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_preview($1, $2)
$m32$;

CREATE FUNCTION pgreact.deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.deploy_m31($1, $2))
$m32$;

CREATE FUNCTION pgreact_internal.m32_target(
    target_name text,
    target_kind text DEFAULT NULL,
    target_version text DEFAULT NULL
)
RETURNS pgreact_api.target
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
DECLARE found_target pgreact_api.target;
    found_kind text;
    found_name text;
    target_count integer;
BEGIN
    SELECT count(*) INTO target_count
    FROM (
        SELECT kind, object_name
        FROM pgreact_internal.api_declarations
        WHERE state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
    ) targets
    WHERE object_name = target_name
      AND (target_kind IS NULL OR kind = target_kind);
    IF target_count = 0 THEN
        RAISE EXCEPTION 'M32_TARGET_NOT_FOUND: no deployed ordinary object named %', target_name;
    ELSIF target_count > 1 THEN
        RAISE EXCEPTION 'M32_TARGET_AMBIGUOUS: more than one deployed ordinary object is named %',
            target_name;
    END IF;
    SELECT kind, object_name
    INTO found_kind, found_name
    FROM (
        SELECT kind, object_name
        FROM pgreact_internal.api_declarations
        WHERE state = 'DEPLOYED'
        UNION
        SELECT 'policy_set', set.set_name
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE version.state = 'DEPLOYED'
    ) targets
    WHERE object_name = target_name
      AND (target_kind IS NULL OR kind = target_kind);
    found_target := ROW(found_kind, found_name, target_version)::pgreact_api.target;
    RETURN found_target;
END
$m32$;

CREATE FUNCTION pgreact.status(
    name text,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.status_m31(
        pgreact_internal.m32_target($1), $2))
$m32$;

CREATE FUNCTION pgreact.explain(
    name text,
    subject jsonb DEFAULT NULL,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.explain_m31(
        pgreact_internal.m32_target($1), $2, $3))
$m32$;

CREATE FUNCTION pgreact.doctor(
    name text,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.doctor_m31(
        pgreact_internal.m32_target($1), $2))
$m32$;

CREATE FUNCTION pgreact.doctor()
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT jsonb_build_object(
        'contract_version', 20,
        'operation', 'doctor',
        'state', CASE WHEN EXISTS (
            SELECT 1 FROM pgreact.health_check() diagnostic
            WHERE pgreact_internal.m32_finding_shape(to_jsonb(diagnostic)) ->> 'blocking' = 'true'
        ) THEN 'attention'
                      ELSE 'ready' END,
        'diagnostics', COALESCE(
            (SELECT jsonb_agg(pgreact_internal.m32_finding_shape(to_jsonb(diagnostic))
                              ORDER BY diagnostic.code, diagnostic.object_identity)
             FROM pgreact.health_check() diagnostic), '[]'::jsonb),
        'truncated', false)
$m32$;

CREATE FUNCTION pgreact_internal.m32_remove(
    target_kind text,
    target_name text,
    target_version text,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(CASE
        WHEN EXISTS (
            SELECT 1
            FROM pgreact_internal.policy_set_versions version
            JOIN pgreact_internal.policy_sets set USING (policy_set_id)
            WHERE set.set_name = $2
              AND version.state = 'DEPLOYED'
        )
            THEN pgreact_api.remove_m31(pgreact_api.target('policy_set', $2, $3), $4)
        ELSE pgreact_api.remove_m31(pgreact_api.target($1, $2, $3), $4)
    END)
$m32$;

CREATE FUNCTION pgreact_internal.m32_remove(
    target pgreact_api.target,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
BEGIN
    RETURN pgreact_internal.m32_remove(
        (target).kind, (target).name, (target).version, preconditions);
END
$m32$;

CREATE FUNCTION pgreact.remove(
    name text,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_remove(pgreact_internal.m32_target($1), $2)
$m32$;

CREATE FUNCTION pgreact.run(
    sampled_time timestamptz DEFAULT clock_timestamp()
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.run_m31_global($1))
$m32$;

CREATE FUNCTION pgreact.export(
    name text,
    kind text DEFAULT NULL,
    version text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
DECLARE declaration pgreact_internal.api_declarations%ROWTYPE;
    policy_normalized jsonb;
    policy_spec jsonb;
    policy_members jsonb;
    policy_name text;
    digest text;
    target_count integer;
BEGIN
    SELECT count(*) INTO target_count
    FROM pgreact_internal.api_declarations row_data
    WHERE row_data.object_name = export.name
      AND row_data.state = 'DEPLOYED'
      AND (export.kind IS NULL OR row_data.kind = export.kind);
    IF target_count = 0 AND (export.kind IS NULL OR export.kind = 'policy_set') THEN
        SELECT version.normalized, set.set_name
        INTO policy_normalized, policy_name
        FROM pgreact_internal.policy_set_versions version
        JOIN pgreact_internal.policy_sets set USING (policy_set_id)
        WHERE set.set_name = export.name
          AND version.state = 'DEPLOYED'
          AND (export.version IS NULL OR version.version = export.version)
        ORDER BY version.valid_from DESC, version.created_at DESC
        LIMIT 1;
        IF FOUND THEN
            SELECT jsonb_agg(item.member - 'disposition' ORDER BY item.ordinality)
            INTO policy_members
            FROM jsonb_array_elements(policy_normalized -> 'spec' -> 'members')
                 WITH ORDINALITY AS item(member, ordinality);
            policy_spec := jsonb_set(
                policy_normalized -> 'spec', '{members}', COALESCE(policy_members, '[]'::jsonb));
            digest := encode(sha256(convert_to(jsonb_build_object(
                'api_version', '1',
                'kind', 'policy_set',
                'name', policy_name,
                'spec', policy_spec)::text, 'UTF8')), 'hex');
            RETURN jsonb_build_object(
                'api_version', '1',
                'kind', 'policy_set',
                'name', policy_name,
                'spec', policy_spec,
                'declaration_digest', digest,
                'digest', digest);
        END IF;
    END IF;
    IF target_count = 0 THEN
        RAISE EXCEPTION 'M32_EXPORT_NOT_FOUND: no deployed ordinary object named %', name;
    END IF;
    IF target_count > 1 THEN
        RAISE EXCEPTION 'M32_EXPORT_AMBIGUOUS: more than one deployed ordinary object is named %',
            name;
    END IF;
    SELECT * INTO declaration
    FROM pgreact_internal.api_declarations row_data
    WHERE row_data.object_name = export.name
      AND row_data.state = 'DEPLOYED'
      AND (export.kind IS NULL OR row_data.kind = export.kind);
    IF declaration.kind NOT IN ('rule', 'decision_program', 'policy_set') THEN
        RAISE EXCEPTION 'M32_EXPORT_KIND: only ordinary objects can be exported';
    END IF;
    digest := encode(sha256(convert_to(jsonb_build_object(
        'api_version', declaration.api_version,
        'kind', declaration.kind,
        'name', declaration.object_name,
        'spec', declaration.normalized -> 'spec')::text, 'UTF8')), 'hex');
    RETURN jsonb_build_object(
        'api_version', declaration.api_version,
        'kind', declaration.kind,
        'name', declaration.object_name,
        'spec', declaration.normalized -> 'spec',
        'declaration_digest', digest,
        'digest', digest);
END
$m32$;

CREATE FUNCTION pgreact.import(
    document jsonb,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
DECLARE declaration pgreact_api.declaration;
    expected_digest text;
    actual_digest text;
BEGIN
    IF jsonb_typeof(document) IS DISTINCT FROM 'object'
       OR document ->> 'kind' IS NULL
       OR document ->> 'name' IS NULL
       OR jsonb_typeof(document -> 'spec') IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M32_IMPORT_DOCUMENT: export must contain kind, name, and object spec';
    END IF;
    expected_digest := COALESCE(document ->> 'declaration_digest', document ->> 'digest');
    actual_digest := encode(sha256(convert_to(jsonb_build_object(
        'api_version', COALESCE(document ->> 'api_version', '1'),
        'kind', document ->> 'kind',
        'name', document ->> 'name',
        'spec', document -> 'spec')::text, 'UTF8')), 'hex');
    IF expected_digest IS NOT NULL AND expected_digest <> actual_digest THEN
        RAISE EXCEPTION 'M32_IMPORT_DIGEST: canonical export digest does not match document';
    END IF;
    declaration := pgreact_api.declaration(
        COALESCE(document ->> 'kind', 'unknown'),
        document ->> 'name',
        document -> 'spec');
    RETURN pgreact.deploy(declaration, preconditions);
END
$m32$;

CREATE FUNCTION pgreact.import(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact.deploy($1, $2)
$m32$;

CREATE FUNCTION pgreact_api.validate(declaration pgreact_api.declaration)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact.validate($1)
$m32$;

CREATE FUNCTION pgreact_api.preview(
    declaration pgreact_api.declaration, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact.preview($1, $2)
$m32$;

CREATE FUNCTION pgreact_api.deploy(
    declaration pgreact_api.declaration, preconditions jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact.deploy($1, $2)
$m32$;

CREATE FUNCTION pgreact_api.status(
    target pgreact_api.target, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.status_m31($1, $2))
$m32$;

CREATE FUNCTION pgreact_api.explain(
    target pgreact_api.target, subject jsonb DEFAULT NULL, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.explain_m31($1, $2, $3))
$m32$;

CREATE FUNCTION pgreact_api.doctor(
    target pgreact_api.target, options jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.doctor_m31($1, $2))
$m32$;

CREATE FUNCTION pgreact_api.run(
    target pgreact_api.target, sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.run_m31_target($1, $2))
$m32$;

CREATE FUNCTION pgreact_api.run(
    sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_result(pgreact_api.run_m31_global($1))
$m32$;

CREATE FUNCTION pgreact_api.remove(
    target pgreact_api.target, preconditions jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE SQL VOLATILE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m32$
    SELECT pgreact_internal.m32_remove($1, $2)
$m32$;

CREATE OR REPLACE VIEW pgreact.rules AS
SELECT r.rule_id, r.rule_name, v.rule_version_id, pg_get_userbyid(v.owner_oid) AS owner,
       v.source_view_name, v.key_column, v.consequence_identity, v.bootstrap_policy, v.state,
       v.created_at, r.rule_name AS name, 'rule'::text AS kind,
       '1'::text AS version,
       encode(COALESCE(api.declaration_digest, ''::bytea), 'hex') AS declaration_digest
FROM pgreact_internal.rules r
JOIN pgreact_internal.rule_versions v USING (rule_id)
LEFT JOIN pgreact_internal.api_declarations api
  ON api.kind = 'rule' AND api.object_name = r.rule_name AND api.state = 'DEPLOYED'
WHERE v.state <> 'REMOVED';

CREATE VIEW pgreact.matches AS
SELECT rule.name, rule.rule_name, rule.rule_version_id, activation.activation_id,
       activation.semantic_key, activation.current_bindings AS bindings,
       activation.active, activation.generation, activation.first_seen_at,
       activation.last_seen_at, activation.deactivated_at, activation.revision
FROM pgreact.activations activation
JOIN pgreact.rules rule USING (rule_version_id);

CREATE VIEW pgreact.decisions AS
SELECT program.program_id, program.program_name AS name, program.program_name,
       program.owner, program.state, program.version_id, program.version_no,
       program.candidate_relation, program.subject_key_column,
       program.candidate_key_column, program.priority_column, program.result_columns,
       program.result_types, program.max_candidates, program.valid_from, program.valid_to,
       program.source_signature, program.source_definition_digest, program.version_state,
       program.deployed_at
FROM pgreact.decision_programs program;

CREATE OR REPLACE VIEW pgreact.policy_sets AS
SELECT set.policy_set_id, set.set_name, pg_get_userbyid(set.owner_oid) AS owner,
       set.created_at, set.set_name AS name
FROM pgreact_internal.policy_sets set;

CREATE VIEW pgreact.work AS
SELECT 'rule'::text AS kind, rule.rule_name AS name, rule.version,
       episode.episode_id::text AS work_id, episode.state,
       (episode.state IN ('PENDING', 'LEASED')) AS claimable,
       episode.completed_at AS updated_at
FROM pgreact.episodes episode
JOIN pgreact.rules rule USING (rule_version_id)
UNION ALL
SELECT 'decision'::text, program.program_name, version.version_no::text,
       work.subject_key::text, state.state, work.claimable, work.updated_at
FROM pgreact_internal.decision_work work
JOIN pgreact_internal.decision_programs program USING (program_id)
JOIN pgreact_internal.decision_program_versions version
  ON version.program_id = work.program_id
JOIN pgreact_internal.decision_subject_state state
  ON state.program_id = work.program_id
 AND state.subject_key = work.subject_key
 AND version.version_id = state.version_id;

CREATE OR REPLACE VIEW pgreact.attempts AS
SELECT execution.execution_id, execution.episode_id, execution.attempt_no,
       execution.worker_id, execution.started_at, execution.finished_at,
       execution.status, execution.error_message, execution.error_code,
       execution.event_kind, rule.rule_name AS name
FROM pgreact_internal.executions execution
LEFT JOIN pgreact_internal.agenda episode USING (episode_id)
LEFT JOIN pgreact_internal.rules rule USING (rule_id);

CREATE VIEW pgreact.health AS
SELECT finding ->> 'code' AS code,
       finding ->> 'severity' AS severity,
       finding ->> 'target' AS target,
       finding ->> 'field' AS field,
       finding ->> 'message' AS message,
       finding ->> 'hint' AS hint,
       finding -> 'details' AS details,
       (finding ->> 'blocking')::boolean AS blocking
FROM (
    SELECT pgreact_internal.m32_finding_shape(to_jsonb(diagnostic)) AS finding
    FROM pgreact.health_check() diagnostic
) shaped;

COMMENT ON EXTENSION pg_react IS
    'M32 PostgreSQL-native ordinary interface over the authoritative M31 runtime';
