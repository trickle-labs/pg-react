-- M28 public API convergence and ergonomics.

CREATE TYPE pgreact_api.declaration AS (
    api_version text,
    kind text,
    name text,
    spec jsonb
);

CREATE TYPE pgreact_api.target AS (
    kind text,
    name text,
    version text
);

CREATE TABLE pgreact_internal.api_declarations (
    declaration_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    api_version text NOT NULL,
    kind text NOT NULL,
    object_name text NOT NULL,
    spec jsonb NOT NULL,
    normalized jsonb NOT NULL,
    declaration_digest bytea NOT NULL,
    delegated_id uuid,
    owner_oid oid NOT NULL,
    state text NOT NULL CHECK (state IN ('DEPLOYED', 'REMOVED')),
    last_preview_digest bytea,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    deployed_at timestamptz,
    removed_at timestamptz,
    UNIQUE (kind, object_name)
);

CREATE INDEX api_declarations_owner_idx
    ON pgreact_internal.api_declarations (owner_oid, state, kind, object_name);

CREATE FUNCTION pgreact_api.declaration(
    kind text,
    name text,
    spec jsonb DEFAULT '{}'::jsonb
)
RETURNS pgreact_api.declaration
LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT ROW('1', $1, $2, $3)::pgreact_api.declaration
$$;

CREATE FUNCTION pgreact_api.target(
    kind text,
    name text,
    version text DEFAULT NULL
)
RETURNS pgreact_api.target
LANGUAGE SQL IMMUTABLE AS $$
    SELECT ROW($1, $2, $3)::pgreact_api.target
$$;

CREATE FUNCTION pgreact_internal.m28_normalize(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE STRICT AS $$
    SELECT jsonb_build_object(
        'api_version', (declaration).api_version,
        'kind', (declaration).kind,
        'name', (declaration).name,
        'spec', CASE WHEN (declaration).kind = 'rule' THEN
            COALESCE((declaration).spec, '{}'::jsonb)
                || jsonb_build_object(
                    'kind', COALESCE((declaration).spec -> 'kind', '"CONSTRAINT"'::jsonb),
                    'bootstrap_policy', COALESCE((declaration).spec -> 'bootstrap_policy', '"SEED_CURRENT"'::jsonb))
            ELSE COALESCE((declaration).spec, '{}'::jsonb)
        END
    )
$$;

CREATE FUNCTION pgreact_internal.m28_digest(normalized jsonb)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m28$
DECLARE
    relation_name text;
    relation_oid oid;
    relation_kind "char";
    source text;
    sources text := '';
BEGIN
    FOR relation_name IN
        SELECT value
        FROM jsonb_each_text(COALESCE(normalized -> 'spec', '{}'::jsonb))
        WHERE key IN ('condition', 'candidate_relation', 'population_relation',
                      'candidate_catalog', 'parameter_relation')
        ORDER BY key
    LOOP
        relation_oid := to_regclass(relation_name);
        IF relation_oid IS NULL THEN
            CONTINUE;
        END IF;
        SELECT c.relkind INTO relation_kind FROM pg_class c WHERE c.oid = relation_oid;
        source := CASE WHEN relation_kind IN ('v', 'm')
                       THEN pg_get_viewdef(relation_oid, true)
                       ELSE encode(pgreact_internal.source_row_signature(relation_oid), 'hex') END;
        sources := sources || '|' || relation_name || '=' || COALESCE(source, '');
    END LOOP;
    RETURN encode(sha256(convert_to(normalized::text || sources, 'UTF8')), 'hex');
END
$m28$;

CREATE FUNCTION pgreact_internal.m28_finding(
    code text,
    severity text,
    object_identity text,
    field_path text,
    message text,
    hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'code', $1, 'severity', $2, 'blocker', $2 = 'ERROR',
        'object_identity', $3, 'field_path', $4, 'message', $5,
        'hint', $6, 'details', COALESCE($7, '{}'::jsonb),
        'evidence', '[]'::jsonb, 'truncated', false)
$$;

CREATE FUNCTION pgreact_internal.m28_validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m28$
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
        IF jsonb_typeof((target).spec -> 'results') IS DISTINCT FROM 'array'
           OR CASE WHEN jsonb_typeof((target).spec -> 'results') = 'array'
                   THEN jsonb_array_length((target).spec -> 'results') = 0 ELSE false END THEN
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
$m28$;

CREATE FUNCTION pgreact_internal.m28_envelope(
    operation text,
    normalized jsonb,
    state text,
    summary jsonb,
    findings jsonb DEFAULT '[]'::jsonb,
    diagnostics jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE AS $$
    SELECT jsonb_build_object(
        'contract_version', 16,
        'operation', $1,
        'target', jsonb_build_object(
            'kind', COALESCE($2 ->> 'kind', '<unknown>'),
            'name', COALESCE($2 ->> 'name', '<unknown>')),
        'state', $3,
        'summary', COALESCE($4, '{}'::jsonb),
        'findings', COALESCE($5, '[]'::jsonb),
        'evidence', jsonb_build_object(
            'normalized_declaration', $2,
            'declaration_digest', CASE WHEN $2 IS NULL THEN NULL
                ELSE encode(sha256(convert_to($2::text, 'UTF8')), 'hex') END),
        'diagnostics', COALESCE($6, '[]'::jsonb),
        'truncated', false)
$$;

CREATE FUNCTION pgreact_api.validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT pgreact_internal.m28_envelope(
        'validate', result -> 'normalized',
        CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(result -> 'findings') finding
                          WHERE finding ->> 'severity' = 'ERROR') THEN 'attention' ELSE 'ready' END,
        jsonb_build_object('read_only', true), result -> 'findings')
    FROM (SELECT pgreact_internal.m28_validate($1) AS result) checked
$$;

CREATE FUNCTION pgreact_api.preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m28$
DECLARE result jsonb;
    normalized jsonb;
    findings jsonb;
    digest text;
BEGIN
    IF options IS NULL OR jsonb_typeof(options) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M28_OPTIONS: options must be a JSON object';
    END IF;
    SELECT value, value -> 'normalized', value -> 'findings'
      INTO result, normalized, findings
    FROM (SELECT pgreact_internal.m28_validate(declaration) AS value) validation;
    digest := pgreact_internal.m28_digest(normalized);
    RETURN pgreact_internal.m28_envelope(
        'preview', normalized,
        CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(findings) finding
                          WHERE finding ->> 'severity' = 'ERROR') THEN 'attention' ELSE 'ready' END,
        jsonb_build_object('read_only', true, 'preview_digest', digest,
                           'options', options, 'delegates_to', (declaration).kind), findings);
END
$m28$;

CREATE FUNCTION pgreact_api.deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m28$
DECLARE validation jsonb;
    normalized jsonb;
    findings jsonb;
    current_row pgreact_internal.api_declarations%ROWTYPE;
    delegated_id uuid;
    owner_id oid;
    current_found boolean;
    expected_digest text;
    allow_create boolean := true;
    condition_oid regclass;
    candidate_oid regclass;
    result_columns name[];
BEGIN
    IF preconditions IS NULL OR jsonb_typeof(preconditions) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M28_PRECONDITIONS: preconditions must be a JSON object';
    END IF;
    SELECT value, value -> 'normalized', value -> 'findings'
      INTO validation, normalized, findings
    FROM (SELECT pgreact_internal.m28_validate(declaration) AS value) checked;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(findings) finding WHERE finding ->> 'severity' = 'ERROR') THEN
        RAISE EXCEPTION 'M28_VALIDATION: %', findings;
    END IF;
    IF jsonb_typeof(preconditions -> 'allow_create') IS NOT NULL
       AND jsonb_typeof(preconditions -> 'allow_create') IS DISTINCT FROM 'boolean' THEN
        RAISE EXCEPTION 'M28_PRECONDITION_FIELD: allow_create must be boolean';
    END IF;
    allow_create := COALESCE((preconditions ->> 'allow_create')::boolean, true);
    expected_digest := preconditions ->> 'preview_digest';
    IF expected_digest IS NOT NULL
       AND expected_digest <> pgreact_internal.m28_digest(normalized) THEN
        RAISE EXCEPTION 'M28_PREVIEW_STALE'
            USING HINT = 'Preview the declaration again after changing its fields or source relations.';
    END IF;
    SELECT * INTO current_row
    FROM pgreact_internal.api_declarations
    WHERE kind = (declaration).kind AND object_name = (declaration).name
    FOR UPDATE;
    current_found := FOUND;
    SELECT oid INTO owner_id FROM pg_roles WHERE rolname = session_user;
    IF current_found AND current_row.owner_oid <> owner_id
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M28_OWNER: only the declaration owner or operator may deploy this target';
    END IF;
    IF current_found AND current_row.state = 'DEPLOYED' AND allow_create THEN
        RAISE EXCEPTION 'M28_EXISTS: target already exists'
            USING HINT = 'Pass allow_create=false and the current preview digest for an intentional replacement.';
    END IF;
    IF current_found AND current_row.state = 'DEPLOYED' AND NOT allow_create
       AND preconditions ->> 'expected_current_digest' IS DISTINCT FROM encode(current_row.declaration_digest, 'hex') THEN
        RAISE EXCEPTION 'M28_REPLACE_STALE'
            USING HINT = 'Preview the current target and use its exact digest as expected_current_digest.';
    END IF;

    IF (declaration).kind = 'rule' AND COALESCE((declaration).spec ->> 'delegate', 'true') = 'true' THEN
        condition_oid := to_regclass((declaration).spec ->> 'condition');
        SELECT pgreact_api.author_rule(
            (declaration).name, condition_oid, ((declaration).spec ->> 'semantic_key')::name,
            COALESCE((declaration).spec ->> 'kind', 'CONSTRAINT'),
            (declaration).spec ->> 'on_activate', (declaration).spec ->> 'on_deactivate',
            (declaration).spec ->> 'on_change', COALESCE((declaration).spec ->> 'bootstrap_policy', 'SEED_CURRENT'),
            NULL::name[], COALESCE(((declaration).spec ->> 'salience')::integer, 0),
            COALESCE((declaration).spec ->> 'agenda_group', 'default'), NULL::name[],
            COALESCE(((declaration).spec ->> 'max_attempts')::integer, 1),
            COALESCE(((declaration).spec ->> 'initial_backoff_seconds')::integer, 1),
            COALESCE(((declaration).spec ->> 'backoff_multiplier')::numeric, 2),
            COALESCE(((declaration).spec ->> 'max_backoff_seconds')::integer, 60))
        INTO delegated_id;
    ELSIF (declaration).kind = 'decision_program'
          AND COALESCE((declaration).spec ->> 'delegate', 'true') = 'true' THEN
        candidate_oid := to_regclass((declaration).spec ->> 'candidate_relation');
        SELECT ARRAY(SELECT jsonb_array_elements_text((declaration).spec -> 'results'))::name[] INTO result_columns;
        SELECT pgreact_api.author_decision_program(
            (declaration).name, candidate_oid, ((declaration).spec ->> 'subject_key')::name,
            ((declaration).spec ->> 'candidate_key')::name, ((declaration).spec ->> 'priority')::name,
            result_columns, COALESCE(((declaration).spec ->> 'valid_from')::timestamptz, clock_timestamp()),
            NULLIF((declaration).spec ->> 'valid_to', '')::timestamptz,
            COALESCE(((declaration).spec ->> 'max_candidates')::integer, 1000))
        INTO delegated_id;
    END IF;

    IF current_found AND current_row.state = 'REMOVED' THEN
        UPDATE pgreact_internal.api_declarations
        SET api_version = (declaration).api_version, spec = (declaration).spec,
            normalized = normalized, declaration_digest = sha256(convert_to(normalized::text, 'UTF8')),
            delegated_id = COALESCE(delegated_id, current_row.delegated_id), owner_oid = owner_id,
            state = 'DEPLOYED', deployed_at = clock_timestamp(), removed_at = NULL
        WHERE declaration_id = current_row.declaration_id;
    ELSE
        INSERT INTO pgreact_internal.api_declarations(
            api_version, kind, object_name, spec, normalized, declaration_digest,
            delegated_id, owner_oid, state, deployed_at)
        VALUES ((declaration).api_version, (declaration).kind, (declaration).name,
                (declaration).spec, normalized, sha256(convert_to(normalized::text, 'UTF8')),
                delegated_id, owner_id, 'DEPLOYED', clock_timestamp());
    END IF;
    RETURN pgreact_internal.m28_envelope(
        'deploy', normalized, 'deployed',
        jsonb_build_object('read_only', false, 'delegated_id', delegated_id,
                           'delegates_to', (declaration).kind), findings);
END
$m28$;

CREATE FUNCTION pgreact_internal.m28_status(target pgreact_api.target)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m28$
DECLARE row pgreact_internal.api_declarations%ROWTYPE;
    normalized jsonb;
BEGIN
    SELECT * INTO row FROM pgreact_internal.api_declarations
    WHERE kind = (target).kind AND object_name = (target).name;
    IF FOUND THEN
        RETURN pgreact_internal.m28_envelope(
            'status', row.normalized, lower(row.state),
            jsonb_build_object('declaration_id', row.declaration_id,
                               'declaration_digest', encode(row.declaration_digest, 'hex'),
                               'delegated_id', row.delegated_id, 'owner', pg_get_userbyid(row.owner_oid),
                               'created_at', row.created_at, 'deployed_at', row.deployed_at,
                               'removed_at', row.removed_at));
    END IF;
    IF (target).kind = 'rule' AND EXISTS (SELECT 1 FROM pgreact.rules WHERE rule_name = (target).name) THEN
        normalized := jsonb_build_object('api_version', '1', 'kind', 'rule', 'name', (target).name,
                                          'spec', jsonb_build_object('source', 'specialized_api'));
        RETURN pgreact_internal.m28_envelope(
            'status', normalized, 'deployed',
            jsonb_build_object('delegated', true, 'source', 'specialized_api'));
    END IF;
    normalized := jsonb_build_object('api_version', '1', 'kind', (target).kind, 'name', (target).name, 'spec', '{}'::jsonb);
    RETURN pgreact_internal.m28_envelope(
        'status', normalized, 'not_found',
        jsonb_build_object('read_only', true),
        jsonb_build_array(pgreact_internal.m28_finding(
            'M28_TARGET_NOT_FOUND', 'ERROR', (target).name, 'target',
            'target was not found', 'Check the stable kind and name')));
END
$m28$;

CREATE FUNCTION pgreact_api.status(
    target pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT pgreact_internal.m28_status($1)
$$;

CREATE FUNCTION pgreact_api.explain(
    target pgreact_api.target,
    subject jsonb DEFAULT NULL,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT pgreact_internal.m28_status($1)
        || jsonb_build_object('operation', 'explain',
                              'evidence', jsonb_build_object('subject', $2, 'options', $3))
$$;

CREATE FUNCTION pgreact_api.doctor(
    target pgreact_api.target,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT pgreact_internal.m28_status($1)
        || jsonb_build_object('operation', 'doctor',
                              'diagnostics', jsonb_build_array(jsonb_build_object(
                                  'code', 'M28_API_READY', 'severity', 'INFO',
                                  'object_identity', ($1).name,
                                  'message', 'canonical façade is available',
                                  'hint', 'Use validate, preview, deploy, run, status, and explain')))
$$;

CREATE FUNCTION pgreact_api.run(
    target pgreact_api.target,
    sampled_time timestamptz DEFAULT clock_timestamp()
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m28$
DECLARE result jsonb;
BEGIN
    IF (target).kind = 'rule' THEN
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.api_declarations
            WHERE kind = (target).kind AND object_name = (target).name
              AND delegated_id IS NOT NULL AND state = 'DEPLOYED') THEN
            PERFORM pgreact_api.run_rule((target).name);
        END IF;
        result := pgreact_internal.m28_status(target);
    ELSE
        result := pgreact_api.run(sampled_time);
    END IF;
    RETURN result || jsonb_build_object('operation', 'run', 'sampled_time', sampled_time);
END
$m28$;

CREATE FUNCTION pgreact_api.remove(
    target pgreact_api.target,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m28$
DECLARE row pgreact_internal.api_declarations%ROWTYPE;
    normalized jsonb;
    owner_id oid;
BEGIN
    SELECT * INTO row FROM pgreact_internal.api_declarations
    WHERE kind = (target).kind AND object_name = (target).name FOR UPDATE;
    IF NOT FOUND THEN
        RETURN pgreact_internal.m28_status(target);
    END IF;
    SELECT oid INTO owner_id FROM pg_roles WHERE rolname = session_user;
    IF row.owner_oid <> owner_id AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M28_OWNER: only the declaration owner or operator may remove this target';
    END IF;
    normalized := row.normalized;
    UPDATE pgreact_internal.api_declarations
    SET state = 'REMOVED', removed_at = clock_timestamp()
    WHERE declaration_id = row.declaration_id;
    RETURN pgreact_internal.m28_envelope(
        'remove', normalized, 'removed',
        jsonb_build_object('read_only', false, 'declaration_id', row.declaration_id));
END
$m28$;

CREATE VIEW pgreact.api_declarations AS
SELECT declaration_id, api_version, kind, object_name AS name, normalized,
       encode(declaration_digest, 'hex') AS declaration_digest,
       delegated_id, pg_get_userbyid(owner_oid) AS owner, state,
       last_preview_digest, created_at, deployed_at, removed_at
FROM pgreact_internal.api_declarations;

CREATE VIEW pgreact.api_inventory AS
SELECT 'FUNCTION'::text AS surface_kind,
       format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)) AS identity,
       CASE WHEN p.proname IN ('declaration', 'target', 'validate', 'preview', 'deploy',
                               'remove', 'run', 'status', 'explain', 'doctor')
            THEN 'ordinary' ELSE 'advanced' END AS classification,
       pg_get_function_identity_arguments(p.oid) AS arguments,
       pg_get_function_result(p.oid) AS result_type,
       CASE p.provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END AS volatility,
       p.prosecdef AS security_definer,
       COALESCE((SELECT array_agg((acl.grantee::regrole)::text || ':' || acl.privilege_type
                                  ORDER BY (acl.grantee::regrole)::text, acl.privilege_type)
                 FROM aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) acl),
                ARRAY[]::text[]) AS grants,
       CASE WHEN p.proname IN ('declaration', 'target', 'validate', 'preview', 'deploy',
                               'remove', 'run', 'status', 'explain', 'doctor')
            THEN 16 ELSE NULL END AS contract_version
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pgreact_api'
UNION ALL
SELECT 'TYPE', format('%I.%I', n.nspname, t.typname),
       CASE WHEN t.typname IN ('declaration', 'target') THEN 'ordinary' ELSE 'advanced' END,
       NULL, format_type(t.oid, NULL), NULL, false, ARRAY[]::text[],
       CASE WHEN t.typname IN ('declaration', 'target') THEN 16 ELSE NULL END
FROM pg_type t
JOIN pg_namespace n ON n.oid = t.typnamespace
WHERE n.nspname = 'pgreact_api' AND t.typtype IN ('c', 'd', 'e', 'r');

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m27;

CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $m28$
BEGIN
    PERFORM pgreact_internal.configure_roles_m27(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT SELECT ON pgreact.api_declarations, pgreact.api_inventory TO %I, %I', reader_role::text, operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.validate(pgreact_api.declaration), '
        'pgreact_api.preview(pgreact_api.declaration,jsonb), '
        'pgreact_api.deploy(pgreact_api.declaration,jsonb), '
        'pgreact_api.remove(pgreact_api.target,jsonb) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.status(pgreact_api.target,jsonb), '
        'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
        'pgreact_api.doctor(pgreact_api.target,jsonb) TO %I, %I', reader_role::text, operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.run(pgreact_api.target,timestamptz) TO %I, %I',
                   author_role::text, operator_role::text);
END
$m28$;

DO $m28$
DECLARE author_role regrole;
    operator_role regrole;
    worker_role regrole;
    reader_role regrole;
    advanced_reader_role regrole;
BEGIN
    SELECT role_oid::regrole INTO author_role FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid::regrole INTO operator_role FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid::regrole INTO worker_role FROM pgreact_internal.application_roles WHERE role_kind = 'worker';
    SELECT role_oid::regrole INTO reader_role FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    SELECT role_oid::regrole INTO advanced_reader_role FROM pgreact_internal.advanced_readers;
    IF author_role IS NOT NULL AND operator_role IS NOT NULL AND worker_role IS NOT NULL
       AND reader_role IS NOT NULL AND advanced_reader_role IS NOT NULL THEN
        PERFORM pgreact_api.configure_roles(author_role, operator_role, worker_role,
                                            reader_role, advanced_reader_role);
    END IF;
END
$m28$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;
REVOKE ALL ON pgreact.api_declarations FROM PUBLIC;

COMMENT ON TYPE pgreact_api.declaration IS
    'M28 versioned named declaration envelope; complex fields stay in named JSONB spec fields';
COMMENT ON TYPE pgreact_api.target IS
    'M28 names-first target reference with optional historical version';
COMMENT ON EXTENSION pg_react IS
    'M28 public API convergence: versioned declarations, names-first targets, common envelopes, and additive façade verbs';
