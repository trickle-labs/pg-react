-- M54 adoption hardening: ordinary declarations, reviewed deployment, and
-- names-first recovery over the existing authoritative runtime.

DO $m54$
DECLARE definition text;
BEGIN
    SELECT pg_get_functiondef(
        'pgreact_internal.m28_validate_m41(pgreact_api.declaration)'::regprocedure)
    INTO definition;
    definition := replace(definition,
        '''backoff_multiplier'', ''max_backoff_seconds''',
        '''backoff_multiplier'', ''max_backoff_seconds'', ''change_columns'', ''conflict_key_columns''');
    definition := replace(definition, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
    EXECUTE definition;
    SELECT pg_get_functiondef(
        'pgreact.export_m32(text,text,text)'::regprocedure)
    INTO definition;
    definition := replace(definition, 'export.name', '$1');
    definition := replace(definition, 'export.kind', '$2');
    definition := replace(definition, 'export.version', '$3');
    definition := replace(definition, ', name;', ', $1;');
    definition := replace(definition, 'CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION');
    EXECUTE definition;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_finding(
    code text, severity text, field_path text, message text, hint text,
    details jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL IMMUTABLE
AS $m54$
    SELECT jsonb_build_object(
        'code', $1, 'severity', $2, 'blocking', $2 = 'ERROR',
        'field', $3, 'message', $4, 'hint', $5,
        'details', COALESCE($6, '{}'::jsonb))
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_rule_findings(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    spec jsonb := (declaration).spec;
    source_oid oid := to_regclass(spec ->> 'condition');
    field text;
    column_name name;
    columns jsonb;
    findings jsonb := '[]'::jsonb;
    field_count integer;
BEGIN
    IF (declaration).kind IS DISTINCT FROM 'rule' THEN
        RETURN findings;
    END IF;
    FOREACH field IN ARRAY ARRAY['change_columns', 'conflict_key_columns'] LOOP
        IF spec ? field THEN
            columns := spec -> field;
            IF jsonb_typeof(columns) IS DISTINCT FROM 'array' THEN
                findings := findings || jsonb_build_array(pgreact_internal.m54_finding(
                    'M54_COLUMNS_SHAPE', 'ERROR', 'spec.' || field,
                    field || ' must be an array of column names',
                    'Use ARRAY[...]::name[] or omit the field.'));
                CONTINUE;
            END IF;
            field_count := jsonb_array_length(columns);
            IF field_count > 32 THEN
                findings := findings || jsonb_build_array(pgreact_internal.m54_finding(
                    'M54_COLUMNS_LIMIT', 'ERROR', 'spec.' || field,
                    field || ' may contain at most 32 columns',
                    'Split the rule or choose a smaller projected set.'));
            END IF;
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements(columns) item
                WHERE jsonb_typeof(item) IS DISTINCT FROM 'string') THEN
                findings := findings || jsonb_build_array(pgreact_internal.m54_finding(
                    'M54_COLUMNS_NAME', 'ERROR', 'spec.' || field,
                    field || ' entries must be strings',
                    'Use PostgreSQL column names.'));
                CONTINUE;
            END IF;
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements_text(columns) item
                GROUP BY item HAVING count(*) > 1) THEN
                findings := findings || jsonb_build_array(pgreact_internal.m54_finding(
                    'M54_COLUMNS_DUPLICATE', 'ERROR', 'spec.' || field,
                    field || ' must not contain duplicate columns',
                    'Keep each projected column once.'));
            END IF;
            IF source_oid IS NOT NULL AND EXISTS (
                SELECT 1 FROM jsonb_array_elements_text(columns) item
                WHERE NOT EXISTS (
                    SELECT 1 FROM pg_catalog.pg_attribute attribute
                    WHERE attribute.attrelid = source_oid
                      AND attribute.attname = item::name
                      AND attribute.attnum > 0
                      AND NOT attribute.attisdropped)) THEN
                findings := findings || jsonb_build_array(pgreact_internal.m54_finding(
                    'M54_COLUMNS_NOT_PROJECTED', 'ERROR', 'spec.' || field,
                    field || ' must contain only columns projected by the condition',
                    'Add the column to the condition view or remove it.'));
            END IF;
        END IF;
    END LOOP;
    IF spec ? 'change_columns' AND jsonb_typeof(spec -> 'change_columns') = 'array'
       AND jsonb_array_length(spec -> 'change_columns') > 0
       AND source_oid IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM jsonb_array_elements_text(spec -> 'change_columns') item
           WHERE item::name = (spec ->> 'semantic_key')::name) THEN
        findings := findings || jsonb_build_array(pgreact_internal.m54_finding(
            'M54_SEMANTIC_KEY_WATCHED', 'ERROR', 'spec.change_columns',
            'semantic_key cannot also be a watched change column',
            'Watch a non-key projected value instead.'));
    END IF;
    RETURN findings;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_source_fingerprint(normalized jsonb)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
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
            sources := sources || '|' || relation_name || '=missing';
            CONTINUE;
        END IF;
        SELECT class.relkind INTO relation_kind
        FROM pg_catalog.pg_class class WHERE class.oid = relation_oid;
        source := CASE WHEN relation_kind IN ('v', 'm')
                       THEN pg_get_viewdef(relation_oid, true)
                       ELSE encode(pgreact_internal.source_row_signature(relation_oid), 'hex') END;
        sources := sources || '|' || relation_name || '=' || COALESCE(source, '');
    END LOOP;
    RETURN encode(sha256(convert_to(sources, 'UTF8')), 'hex');
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_name_array(spec jsonb, field text)
RETURNS name[]
LANGUAGE SQL IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT CASE WHEN $1 ? $2
                THEN ARRAY(SELECT value::name FROM jsonb_array_elements_text($1 -> $2) value)
                ELSE NULL::name[] END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_validate(
    declaration pgreact_api.declaration
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    result jsonb := pgreact.validate_m53(declaration);
    extra jsonb := pgreact_internal.m54_rule_findings(declaration);
BEGIN
    IF jsonb_array_length(extra) = 0 THEN
        RETURN result;
    END IF;
    RETURN result
        || jsonb_build_object(
            'state', CASE WHEN EXISTS (
                SELECT 1 FROM jsonb_array_elements(extra) item
                WHERE item ->> 'severity' = 'ERROR')
                THEN 'attention' ELSE result ->> 'state' END,
            'findings', COALESCE(result -> 'findings', '[]'::jsonb) || extra);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_is_package(
    declaration pgreact_api.declaration
)
RETURNS boolean
LANGUAGE SQL IMMUTABLE STRICT
AS $m54$
    SELECT ($1).kind = 'policy_set'
       AND (($1).spec ? 'support' OR ($1).spec ? 'dependencies' OR EXISTS (
           SELECT 1 FROM jsonb_array_elements(CASE
               WHEN jsonb_typeof(($1).spec -> 'members') = 'array'
               THEN ($1).spec -> 'members' ELSE '[]'::jsonb END) item
           WHERE jsonb_typeof(item -> 'declaration') = 'object'))
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_current_work(
    declaration pgreact_api.declaration,
    current_row pgreact_internal.api_declarations
)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    work_state text;
BEGIN
    IF (declaration).kind = 'rule' THEN
        SELECT CASE WHEN bool_or(state = 'LEASED') THEN 'LEASED'
                    WHEN bool_or(state = 'PENDING') THEN 'PENDING'
                    WHEN bool_or(state = 'RETRY_WAIT') THEN 'RETRY_WAIT'
                    ELSE 'DRAINED' END
        INTO work_state
        FROM pgreact_internal.agenda
        WHERE rule_version_id = current_row.delegated_id
          AND state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
        RETURN COALESCE(work_state, 'DRAINED');
    ELSIF (declaration).kind = 'decision_program' THEN
        SELECT CASE WHEN bool_or(claimable) THEN 'CLAIMABLE' ELSE 'DRAINED' END
        INTO work_state
        FROM pgreact_internal.decision_work
        WHERE program_id = (SELECT version.program_id
                            FROM pgreact_internal.decision_program_versions version
                            WHERE version.version_id = current_row.delegated_id);
        RETURN COALESCE(work_state, 'DRAINED');
    END IF;
    RETURN 'NOT_APPLICABLE';
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_preview(
    declaration pgreact_api.declaration,
    options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    base jsonb;
    normalized_decl jsonb;
    current_row pgreact_internal.api_declarations%ROWTYPE;
    current_found boolean;
    current_state text := 'absent';
    current_digest text;
    current_source text;
    source_fingerprint text;
    proposed_digest text;
    action text;
    work_state text := 'NOT_APPLICABLE';
    old_work_required boolean := false;
    plan_digest text;
    extra jsonb;
BEGIN
    IF pgreact_internal.m54_is_package(declaration) THEN
        RETURN pgreact.preview_m53(declaration, options);
    END IF;
    base := pgreact.preview_m53(declaration, options);
    normalized_decl := base -> 'evidence' -> 'normalized_declaration';
    extra := pgreact_internal.m54_rule_findings(declaration);
    SELECT * INTO current_row
    FROM pgreact_internal.api_declarations row_data
    WHERE row_data.kind = (declaration).kind
      AND row_data.object_name = (declaration).name;
    current_found := FOUND;
    IF current_found THEN
        current_state := lower(current_row.state);
        current_digest := encode(current_row.declaration_digest, 'hex');
        current_source := COALESCE(
            encode(current_row.last_preview_digest, 'hex'),
            pgreact_internal.m54_source_fingerprint(current_row.normalized));
        work_state := pgreact_internal.m54_current_work(declaration, current_row);
    END IF;
    source_fingerprint := pgreact_internal.m54_source_fingerprint(normalized_decl);
    proposed_digest := encode(sha256(convert_to(normalized_decl::text, 'UTF8')), 'hex');
    action := CASE WHEN NOT current_found OR current_state <> 'deployed' THEN 'ADD'
                   WHEN current_digest = proposed_digest
                        AND current_source = source_fingerprint
                   THEN 'KEEP' ELSE 'REPLACE' END;
    old_work_required := (declaration).kind = 'rule'
        AND COALESCE((declaration).spec ->> 'kind', 'CONSTRAINT') = 'COMMAND'
        AND work_state IN ('PENDING', 'LEASED', 'RETRY_WAIT')
        AND action = 'REPLACE';
    plan_digest := encode(sha256(convert_to(jsonb_build_object(
        'kind', (declaration).kind, 'name', (declaration).name,
        'normalized', normalized_decl, 'action', action,
        'current_state', current_state, 'current_digest', current_digest,
        'source_fingerprint', source_fingerprint, 'work_state', work_state,
        'old_work_required', old_work_required)::text,
        'UTF8')), 'hex');
    RETURN base
        || jsonb_build_object(
            'state', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(extra) item
                                       WHERE item ->> 'severity' = 'ERROR')
                          OR base ->> 'state' = 'attention'
                          THEN 'attention' ELSE 'ready' END,
            'summary', COALESCE(base -> 'summary', '{}'::jsonb)
                || jsonb_build_object(
                    'action', action,
                    'deployment', CASE action WHEN 'ADD' THEN 'create'
                                              WHEN 'KEEP' THEN 'keep'
                                              ELSE 'replacement' END,
                    'current_state', current_state,
                    'current_declaration_digest', current_digest,
                    'proposed_declaration_digest', proposed_digest,
                    'source_fingerprint', source_fingerprint,
                    'current_source_fingerprint', current_source,
                    'work_state', work_state,
                    'old_work_policy_required', old_work_required,
                    'old_work_policy', NULL,
                    'plan_digest', plan_digest,
                    'legacy_preview_digest', base -> 'summary' ->> 'preview_digest',
                    'blockers', CASE WHEN jsonb_array_length(extra) > 0
                                     THEN extra ELSE COALESCE(base -> 'summary' -> 'blockers', '[]'::jsonb) END),
            'findings', COALESCE(base -> 'findings', '[]'::jsonb) || extra);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact.review_token(preview_result jsonb)
RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    digest text;
    digest_kind text;
    proposed_digest text;
    payload jsonb;
    token text;
BEGIN
    IF jsonb_typeof(preview_result) IS DISTINCT FROM 'object'
       OR preview_result ->> 'operation' IS DISTINCT FROM 'preview'
       OR preview_result ->> 'state' IS DISTINCT FROM 'ready'
       OR jsonb_typeof(preview_result -> 'target') IS DISTINCT FROM 'object'
       OR NULLIF(preview_result -> 'target' ->> 'kind', '') IS NULL
       OR NULLIF(preview_result -> 'target' ->> 'name', '') IS NULL THEN
        RAISE EXCEPTION 'M54_REVIEW_TOKEN_INVALID: expected a successful preview result';
    END IF;
    digest_kind := CASE WHEN preview_result -> 'target' ->> 'kind' = 'policy_set'
                        THEN 'plan_digest' ELSE 'preview_digest' END;
    digest := CASE WHEN digest_kind = 'plan_digest'
                   THEN preview_result -> 'summary' ->> 'plan_digest'
                   ELSE preview_result -> 'summary' ->> 'preview_digest' END;
    proposed_digest := COALESCE(preview_result -> 'summary' ->> 'proposed_declaration_digest',
                                preview_result -> 'summary' ->> 'definition_digest',
                                preview_result -> 'evidence' ->> 'declaration_digest');
    IF digest IS NULL OR digest !~ '^[0-9a-f]{64}$' OR proposed_digest IS NULL THEN
        RAISE EXCEPTION 'M54_REVIEW_TOKEN_INVALID: preview has no complete review identity';
    END IF;
    payload := jsonb_build_object(
        'token_version', 1, 'operation', 'preview', 'digest_kind', digest_kind,
        'target', preview_result -> 'target',
        'proposed_declaration_digest', proposed_digest, 'digest', digest,
        'contract_version', preview_result -> 'contract_version');
    token := 'm54.v1.' || encode(convert_to(payload::text, 'UTF8'), 'hex');
    IF octet_length(token) > 4096 THEN
        RAISE EXCEPTION 'M54_REVIEW_TOKEN_LIMIT: review token exceeds 4096 bytes';
    END IF;
    RETURN token;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_decode_review_token(token text)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE decoded bytea;
    payload jsonb;
BEGIN
    IF token IS NULL OR octet_length(token) > 4096 OR token NOT LIKE 'm54.v1.%'
       OR substring(token from 8) !~ '^[0-9a-f]+$'
       OR length(substring(token from 8)) % 2 <> 0 THEN
        RETURN NULL;
    END IF;
    decoded := decode(substring(token from 8), 'hex');
    payload := convert_from(decoded, 'UTF8')::jsonb;
    IF jsonb_typeof(payload) IS DISTINCT FROM 'object'
       OR payload ->> 'token_version' IS DISTINCT FROM '1' THEN
        RETURN NULL;
    END IF;
    RETURN payload;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_replace_decision(
    current_version_id uuid,
    program_name text,
    candidate_relation regclass,
    subject_key_column name,
    candidate_key_column name,
    priority_column name,
    result_columns name[],
    valid_from timestamptz,
    valid_to timestamptz,
    max_candidates integer
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    old_program pgreact_internal.decision_programs%ROWTYPE;
    old_version pgreact_internal.decision_program_versions%ROWTYPE;
    new_program_id uuid;
    next_version integer;
    next_version_id uuid;
    temporary_name text := program_name || '#m54-' || replace(gen_random_uuid()::text, '-', '');
    frontier timestamptz;
BEGIN
    SELECT program.* INTO STRICT old_program
    FROM pgreact_internal.decision_programs program
    JOIN pgreact_internal.decision_program_versions version USING (program_id)
    WHERE version.version_id = current_version_id
    FOR UPDATE;
    SELECT * INTO STRICT old_version
    FROM pgreact_internal.decision_program_versions
    WHERE version_id = current_version_id
    FOR UPDATE;
    IF NOT pg_has_role(session_user, old_program.owner_oid, 'USAGE')
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M54_OWNER: only the decision owner or operator may replace this target';
    END IF;
    UPDATE pgreact_internal.decision_programs
    SET program_name = temporary_name WHERE program_id = old_program.program_id;
    next_version_id := pgreact_api.author_decision_program(
        program_name, candidate_relation, subject_key_column, candidate_key_column,
        priority_column, result_columns, valid_from, valid_to, max_candidates);
    SELECT version.program_id INTO new_program_id
    FROM pgreact_internal.decision_program_versions version
    WHERE version.version_id = next_version_id;
    SELECT COALESCE(max(version_no), 0) + 1 INTO next_version
    FROM pgreact_internal.decision_program_versions version
    WHERE version.program_id = old_program.program_id;
    UPDATE pgreact_internal.decision_program_versions
    SET program_id = old_program.program_id, version_no = next_version
    WHERE version_id = next_version_id;
    UPDATE pgreact_internal.decision_program_versions
    SET state = 'RETIRED'
    WHERE program_id = old_program.program_id AND version_id <> next_version_id;
    DELETE FROM pgreact_internal.decision_programs
    WHERE program_id = new_program_id;
    UPDATE pgreact_internal.decision_programs
    SET program_name = old_program.program_name, state = old_program.state
    WHERE program_id = old_program.program_id;
    SELECT clock.frontier INTO frontier
    FROM pgreact_internal.clock_frontier clock;
    PERFORM pgreact_internal.refresh_decision_program(old_program.program_id, frontier);
    RETURN next_version_id;
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact_internal.m54_deploy(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb,
    token_payload jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    preview jsonb;
    validation jsonb;
    normalized_decl jsonb;
    current_row pgreact_internal.api_declarations%ROWTYPE;
    current_found boolean;
    owner_id oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    action text;
    digest text;
    token_digest text;
    token_kind text;
    old_work text;
    old_work_required boolean;
    new_delegated_id uuid;
    condition_oid regclass;
    candidate_oid regclass;
    result_columns name[];
    effective_preconditions jsonb := COALESCE(preconditions, '{}'::jsonb);
BEGIN
    IF jsonb_typeof(effective_preconditions) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M54_PRECONDITIONS: preconditions must be a JSON object';
    END IF;
    validation := pgreact_internal.m54_validate(declaration);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(validation -> 'findings', '[]'::jsonb)) item
               WHERE item ->> 'severity' = 'ERROR') THEN
        RAISE EXCEPTION 'M54_VALIDATION: %', validation -> 'findings';
    END IF;
    preview := pgreact_internal.m54_preview(declaration, effective_preconditions);
    IF token_payload IS NOT NULL THEN
        IF token_payload ->> 'operation' IS DISTINCT FROM 'preview'
           OR token_payload ->> 'digest_kind' IS NULL
           OR jsonb_typeof(token_payload -> 'target') IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_UNSUPPORTED: review token shape is not supported';
        END IF;
        IF token_payload ->> 'contract_version' IS DISTINCT FROM preview ->> 'contract_version' THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_MISMATCH: token contract does not match';
        END IF;
        IF token_payload -> 'target' ->> 'kind' IS DISTINCT FROM (declaration).kind
           OR token_payload -> 'target' ->> 'name' IS DISTINCT FROM (declaration).name THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_MISMATCH: token target does not match declaration';
        END IF;
        token_digest := token_payload ->> 'digest';
        token_kind := token_payload ->> 'digest_kind';
        digest := CASE WHEN token_kind = 'plan_digest'
                       THEN preview -> 'summary' ->> 'plan_digest'
                       ELSE preview -> 'summary' ->> 'preview_digest' END;
        IF token_kind NOT IN ('plan_digest', 'preview_digest') OR digest IS NULL THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_UNSUPPORTED: token digest kind is unsupported';
        END IF;
        IF token_payload ->> 'proposed_declaration_digest' IS DISTINCT FROM
           COALESCE(preview -> 'summary' ->> 'proposed_declaration_digest',
                    preview -> 'summary' ->> 'definition_digest') THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_MISMATCH: token declaration digest does not match';
        END IF;
        IF token_digest IS DISTINCT FROM digest THEN
            RAISE EXCEPTION 'M54_REVIEW_TOKEN_STALE: reviewed preview is stale';
        END IF;
        IF token_kind = 'plan_digest' THEN
            effective_preconditions := effective_preconditions
                || jsonb_build_object('plan_digest', token_digest);
        ELSE
            effective_preconditions := effective_preconditions
                || jsonb_build_object('preview_digest', token_digest);
        END IF;
    END IF;
    IF pgreact_internal.m54_is_package(declaration) THEN
        RETURN pgreact.deploy_m53(declaration, effective_preconditions);
    END IF;
    IF effective_preconditions ->> 'preview_digest' IS NOT NULL
       AND effective_preconditions ->> 'preview_digest' NOT IN (
           preview -> 'summary' ->> 'preview_digest',
           preview -> 'summary' ->> 'legacy_preview_digest') THEN
        RAISE EXCEPTION 'M54_REVIEW_TOKEN_STALE: reviewed preview is stale';
    END IF;
    IF preview ->> 'state' <> 'ready' THEN
        RAISE EXCEPTION 'M54_VALIDATION: preview contains blocking findings';
    END IF;
    normalized_decl := preview -> 'evidence' -> 'normalized_declaration';
    action := preview -> 'summary' ->> 'action';
    old_work_required := COALESCE((preview -> 'summary' ->> 'old_work_policy_required')::boolean, false);
    old_work := COALESCE(effective_preconditions ->> 'old_work',
                         effective_preconditions ->> 'old_work_policy');
    PERFORM pg_advisory_xact_lock(hashtextextended((declaration).kind || ':' ||
                                                   (declaration).name, 5788046901200000));
    SELECT * INTO current_row
    FROM pgreact_internal.api_declarations row_data
    WHERE row_data.kind = (declaration).kind
      AND row_data.object_name = (declaration).name
    FOR UPDATE;
    current_found := FOUND;
    IF current_found AND current_row.owner_oid <> owner_id
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M54_OWNER: only the declaration owner or operator may deploy this target';
    END IF;
    IF current_found AND current_row.state = 'DEPLOYED' THEN
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.policy_set_members member
            JOIN pgreact_internal.policy_set_versions version USING (policy_set_version_id)
            JOIN pgreact_internal.policy_sets set USING (policy_set_id)
            WHERE version.state = 'DEPLOYED' AND member.package_owned
              AND member.member_kind = current_row.kind
              AND member.member_name = current_row.object_name) THEN
            RAISE EXCEPTION 'M54_PACKAGE_OWNED: replace the complete policy set';
        END IF;
    END IF;
    IF action = 'KEEP' THEN
        RETURN preview || jsonb_build_object(
            'operation', 'deploy', 'state', 'deployed',
            'summary', preview -> 'summary' || jsonb_build_object(
                'read_only', false, 'reviewed', token_payload IS NOT NULL));
    END IF;
    IF old_work_required AND old_work IS NULL THEN
        RAISE EXCEPTION 'M54_OLD_WORK_REQUIRED: choose DRAIN_OLD or CANCEL_OLD explicitly';
    END IF;
    IF old_work IS NOT NULL AND old_work NOT IN ('DRAIN_OLD', 'CANCEL_OLD') THEN
        RAISE EXCEPTION 'M54_OLD_WORK_POLICY: choose DRAIN_OLD or CANCEL_OLD';
    END IF;
    IF action = 'REPLACE' AND current_found AND current_row.state = 'DEPLOYED' THEN
        IF (declaration).kind = 'rule' THEN
            condition_oid := to_regclass(normalized_decl -> 'spec' ->> 'condition');
            SELECT pgreact_internal.replace_pack_rule(
                current_row.delegated_id, (declaration).name, condition_oid,
                ARRAY[(normalized_decl -> 'spec' ->> 'semantic_key')::name],
                normalized_decl -> 'spec' ->> 'kind',
                (normalized_decl -> 'spec' ->> 'on_activate')::regprocedure,
                (normalized_decl -> 'spec' ->> 'on_deactivate')::regprocedure,
                (normalized_decl -> 'spec' ->> 'on_change')::regprocedure,
                normalized_decl -> 'spec' ->> 'bootstrap_policy',
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'change_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'salience')::integer, 0),
                COALESCE(normalized_decl -> 'spec' ->> 'agenda_group', 'default'),
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'conflict_key_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'max_attempts')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((normalized_decl -> 'spec' ->> 'max_backoff_seconds')::integer, 60),
                COALESCE(old_work, 'DRAIN_OLD')) INTO new_delegated_id;
        ELSIF (declaration).kind = 'decision_program' THEN
            candidate_oid := to_regclass(normalized_decl -> 'spec' ->> 'candidate_relation');
            result_columns := ARRAY(SELECT value::name FROM jsonb_array_elements_text(
                normalized_decl -> 'spec' -> 'results') value);
            new_delegated_id := pgreact_internal.m54_replace_decision(
                current_row.delegated_id, (declaration).name, candidate_oid,
                (normalized_decl -> 'spec' ->> 'subject_key')::name,
                (normalized_decl -> 'spec' ->> 'candidate_key')::name,
                (normalized_decl -> 'spec' ->> 'priority')::name, result_columns,
                COALESCE((normalized_decl -> 'spec' ->> 'valid_from')::timestamptz, clock_timestamp()),
                NULLIF(normalized_decl -> 'spec' ->> 'valid_to', '')::timestamptz,
                COALESCE((normalized_decl -> 'spec' ->> 'max_candidates')::integer, 1000));
        ELSE
            RAISE EXCEPTION 'M54_KIND: ordinary replacement supports rule and decision_program';
        END IF;
    ELSE
        IF (declaration).kind = 'rule' THEN
            condition_oid := to_regclass(normalized_decl -> 'spec' ->> 'condition');
            new_delegated_id := pgreact_api.author_rule(
                (declaration).name, condition_oid,
                (normalized_decl -> 'spec' ->> 'semantic_key')::name,
                normalized_decl -> 'spec' ->> 'kind', normalized_decl -> 'spec' ->> 'on_activate',
                normalized_decl -> 'spec' ->> 'on_deactivate', normalized_decl -> 'spec' ->> 'on_change',
                normalized_decl -> 'spec' ->> 'bootstrap_policy',
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'change_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'salience')::integer, 0),
                COALESCE(normalized_decl -> 'spec' ->> 'agenda_group', 'default'),
                pgreact_internal.m54_name_array(normalized_decl -> 'spec', 'conflict_key_columns'),
                COALESCE((normalized_decl -> 'spec' ->> 'max_attempts')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((normalized_decl -> 'spec' ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((normalized_decl -> 'spec' ->> 'max_backoff_seconds')::integer, 60));
        ELSIF (declaration).kind = 'decision_program' THEN
            candidate_oid := to_regclass(normalized_decl -> 'spec' ->> 'candidate_relation');
            result_columns := ARRAY(SELECT value::name FROM jsonb_array_elements_text(
                normalized_decl -> 'spec' -> 'results') value);
            new_delegated_id := pgreact_api.author_decision_program(
                (declaration).name, candidate_oid,
                (normalized_decl -> 'spec' ->> 'subject_key')::name,
                (normalized_decl -> 'spec' ->> 'candidate_key')::name,
                (normalized_decl -> 'spec' ->> 'priority')::name, result_columns,
                COALESCE((normalized_decl -> 'spec' ->> 'valid_from')::timestamptz, clock_timestamp()),
                NULLIF(normalized_decl -> 'spec' ->> 'valid_to', '')::timestamptz,
                COALESCE((normalized_decl -> 'spec' ->> 'max_candidates')::integer, 1000));
        ELSE
            RETURN pgreact.deploy_m53(declaration, effective_preconditions);
        END IF;
    END IF;
    IF current_found THEN
        UPDATE pgreact_internal.api_declarations
        SET api_version = (declaration).api_version, spec = (declaration).spec,
            normalized = normalized_decl, declaration_digest = decode(
                preview -> 'summary' ->> 'proposed_declaration_digest', 'hex'),
            delegated_id = new_delegated_id, owner_oid = owner_id, state = 'DEPLOYED',
            last_preview_digest = decode(preview -> 'summary' ->> 'source_fingerprint', 'hex'),
            deployed_at = clock_timestamp(), removed_at = NULL
        WHERE declaration_id = current_row.declaration_id;
    ELSE
        INSERT INTO pgreact_internal.api_declarations(
            api_version, kind, object_name, spec, normalized, declaration_digest,
            delegated_id, owner_oid, state, last_preview_digest, deployed_at)
        VALUES ((declaration).api_version, (declaration).kind, (declaration).name,
            (declaration).spec, normalized_decl,
            decode(preview -> 'summary' ->> 'proposed_declaration_digest', 'hex'),
            new_delegated_id, owner_id, 'DEPLOYED',
            decode(preview -> 'summary' ->> 'source_fingerprint', 'hex'), clock_timestamp());
    END IF;
    RETURN preview || jsonb_build_object(
        'operation', 'deploy', 'state', 'deployed',
        'summary', preview -> 'summary' || jsonb_build_object(
            'read_only', false, 'delegated_id', new_delegated_id,
            'reviewed', token_payload IS NOT NULL,
            'old_work_policy', old_work));
END
$m54$;

ALTER FUNCTION pgreact.validate(pgreact_api.declaration) RENAME TO validate_m53;
ALTER FUNCTION pgreact.preview(pgreact_api.declaration, jsonb) RENAME TO preview_m53;
ALTER FUNCTION pgreact.deploy(pgreact_api.declaration, jsonb) RENAME TO deploy_m53;

CREATE FUNCTION pgreact.validate(declaration pgreact_api.declaration)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_internal.m54_validate($1)
$m54$;

CREATE FUNCTION pgreact.preview(
    declaration pgreact_api.declaration, options jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_internal.m54_preview($1, $2)
$m54$;

CREATE FUNCTION pgreact.deploy(
    declaration pgreact_api.declaration, preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact_internal.m54_deploy($1, $2, NULL)
$m54$;

CREATE FUNCTION pgreact.deploy(
    declaration pgreact_api.declaration, review_token text,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE payload jsonb;
BEGIN
    IF review_token IS NULL OR octet_length(review_token) > 4096 THEN
        RAISE EXCEPTION 'M54_REVIEW_TOKEN_LIMIT: review token must be at most 4096 bytes';
    END IF;
    payload := pgreact_internal.m54_decode_review_token(review_token);
    IF payload IS NULL THEN
        RAISE EXCEPTION 'M54_REVIEW_TOKEN_INVALID: review token is malformed or unsupported';
    END IF;
    RETURN pgreact_internal.m54_deploy($1, $3, payload);
END
$m54$;

CREATE FUNCTION pgreact_api.deploy(
    declaration pgreact_api.declaration, review_token text,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE SQL VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
    SELECT pgreact.deploy($1, $2, $3)
$m54$;

CREATE OR REPLACE FUNCTION pgreact.reconcile_rule(
    rule_name text, mode text DEFAULT 'STATE_ONLY'
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    target_version uuid;
    target_owner oid;
    target_count integer;
BEGIN
    SELECT count(*) INTO target_count
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = reconcile_rule.rule_name
      AND version.state IN ('ACTIVE', 'PAUSED');
    IF target_count <> 1 THEN
        RAISE EXCEPTION 'M54_TARGET_UNAVAILABLE: named rule is missing, ambiguous, or unauthorized';
    END IF;
    SELECT version.rule_version_id, version.owner_oid INTO target_version, target_owner
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = reconcile_rule.rule_name
      AND version.state IN ('ACTIVE', 'PAUSED');
    IF target_owner <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M54_TARGET_UNAVAILABLE: named rule is missing, ambiguous, or unauthorized';
    END IF;
    RETURN pgreact.reconcile_rule(target_version, mode);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact.sweep_expired_leases(rule_name text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE target_version uuid;
    target_owner oid;
BEGIN
    SELECT version.rule_version_id, version.owner_oid INTO target_version, target_owner
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = sweep_expired_leases.rule_name
      AND version.state IN ('ACTIVE', 'PAUSED');
    IF NOT FOUND OR (target_owner <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
                     AND NOT pgreact_internal.is_operator_admin()) THEN
        RAISE EXCEPTION 'M54_TARGET_UNAVAILABLE: named rule is missing, ambiguous, or unauthorized';
    END IF;
    RETURN pgreact.sweep_expired_leases(target_version);
END
$m54$;

CREATE OR REPLACE FUNCTION pgreact.requeue_episode(rule_name text, work_id text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE target_episode bigint;
    target_owner oid;
BEGIN
    IF work_id IS NULL OR work_id !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'M54_TARGET_UNAVAILABLE: named work item is missing, ambiguous, or unauthorized';
    END IF;
    BEGIN
        target_episode := work_id::bigint;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'M54_TARGET_UNAVAILABLE: named work item is missing, ambiguous, or unauthorized';
    END;
    SELECT version.owner_oid INTO target_owner
    FROM pgreact_internal.agenda agenda
    JOIN pgreact_internal.rules rule USING (rule_id)
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    WHERE rule.rule_name = requeue_episode.rule_name
      AND agenda.episode_id = target_episode;
    IF NOT FOUND OR (target_owner <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
                     AND NOT pgreact_internal.is_operator_admin()) THEN
        RAISE EXCEPTION 'M54_TARGET_UNAVAILABLE: named work item is missing, ambiguous, or unauthorized';
    END IF;
    PERFORM pgreact.requeue_episode(target_episode);
END
$m54$;

REVOKE ALL ON FUNCTION pgreact.review_token(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.deploy(pgreact_api.declaration,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_api.deploy(pgreact_api.declaration,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.reconcile_rule(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.sweep_expired_leases(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact.requeue_episode(text,text) FROM PUBLIC;

COMMENT ON FUNCTION pgreact.review_token(jsonb) IS
    'M54 opaque reviewed-preview evidence; not an authorization credential';
COMMENT ON FUNCTION pgreact.deploy(pgreact_api.declaration,text,jsonb) IS
    'M54 reviewed ordinary deployment; the token is evidence, not authorization';

DO $m54$
DECLARE author_role regrole;
    operator_role regrole;
    reader_role regrole;
BEGIN
    SELECT role_oid::regrole INTO author_role FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid::regrole INTO operator_role FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid::regrole INTO reader_role FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    IF author_role IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb) TO %I', author_role::text);
    END IF;
    IF operator_role IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) TO %I', operator_role::text);
    END IF;
    IF reader_role IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb) TO %I', reader_role::text);
    END IF;
END
$m54$;
