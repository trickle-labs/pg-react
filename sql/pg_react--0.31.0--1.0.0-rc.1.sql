-- 1.0.0-rc.1 release migration over 0.31.0

-- Part C: Fix PL/pgSQL variable collision in deploy_m28
CREATE OR REPLACE FUNCTION pgreact_api.deploy_m28(
    declaration pgreact_api.declaration,
    preconditions jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $rc1$
DECLARE
    v_validation jsonb;
    v_normalized jsonb;
    v_findings jsonb;
    v_current_row pgreact_internal.api_declarations%ROWTYPE;
    v_delegated_id uuid;
    v_owner_id oid;
    v_current_found boolean;
    v_expected_digest text;
    v_allow_create boolean := true;
    v_condition_oid regclass;
    v_candidate_oid regclass;
    v_result_columns name[];
BEGIN
    IF preconditions IS NULL OR jsonb_typeof(preconditions) IS DISTINCT FROM 'object' THEN
        RAISE EXCEPTION 'M28_PRECONDITIONS: preconditions must be a JSON object';
    END IF;
    SELECT value, value -> 'normalized', value -> 'findings'
      INTO v_validation, v_normalized, v_findings
    FROM (SELECT pgreact_internal.m28_validate(declaration) AS value) checked;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_findings) finding WHERE finding ->> 'severity' = 'ERROR') THEN
        RAISE EXCEPTION 'M28_VALIDATION: %', v_findings;
    END IF;
    IF jsonb_typeof(preconditions -> 'allow_create') IS NOT NULL
       AND jsonb_typeof(preconditions -> 'allow_create') IS DISTINCT FROM 'boolean' THEN
        RAISE EXCEPTION 'M28_PRECONDITION_FIELD: allow_create must be boolean';
    END IF;
    v_allow_create := COALESCE((preconditions ->> 'allow_create')::boolean, true);
    v_expected_digest := preconditions ->> 'preview_digest';
    IF v_expected_digest IS NOT NULL
       AND v_expected_digest <> pgreact_internal.m28_digest(v_normalized) THEN
        RAISE EXCEPTION 'M28_PREVIEW_STALE'
            USING HINT = 'Preview the declaration again after changing its fields or source relations.';
    END IF;
    SELECT * INTO v_current_row
    FROM pgreact_internal.api_declarations
    WHERE kind = (declaration).kind AND object_name = (declaration).name
    FOR UPDATE;
    v_current_found := FOUND;
    SELECT oid INTO v_owner_id FROM pg_roles WHERE rolname = session_user;
    IF v_current_found AND v_current_row.owner_oid <> v_owner_id
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M28_OWNER: only the declaration owner or operator may deploy this target';
    END IF;
    IF v_current_found AND v_current_row.state = 'DEPLOYED' AND v_allow_create THEN
        RAISE EXCEPTION 'M28_EXISTS: target already exists'
            USING HINT = 'Pass allow_create=false and the current preview digest for an intentional replacement.';
    END IF;
    IF v_current_found AND v_current_row.state = 'DEPLOYED' AND NOT v_allow_create
       AND preconditions ->> 'expected_current_digest' IS DISTINCT FROM encode(v_current_row.declaration_digest, 'hex') THEN
        RAISE EXCEPTION 'M28_REPLACE_STALE'
            USING HINT = 'Preview the current target and use its exact digest as expected_current_digest.';
    END IF;

    IF (declaration).kind = 'rule' AND COALESCE((declaration).spec ->> 'delegate', 'true') = 'true' THEN
        v_condition_oid := to_regclass((declaration).spec ->> 'condition');
        SELECT pgreact_api.author_rule(
            (declaration).name, v_condition_oid, ((declaration).spec ->> 'semantic_key')::name,
            COALESCE((declaration).spec ->> 'kind', 'CONSTRAINT'),
            (declaration).spec ->> 'on_activate', (declaration).spec ->> 'on_deactivate',
            (declaration).spec ->> 'on_change', COALESCE((declaration).spec ->> 'bootstrap_policy', 'SEED_CURRENT'),
            NULL::name[], COALESCE(((declaration).spec ->> 'salience')::integer, 0),
            COALESCE((declaration).spec ->> 'agenda_group', 'default'), NULL::name[],
            COALESCE(((declaration).spec ->> 'max_attempts')::integer, 1),
            COALESCE(((declaration).spec ->> 'initial_backoff_seconds')::integer, 1),
            COALESCE(((declaration).spec ->> 'backoff_multiplier')::numeric, 2),
            COALESCE(((declaration).spec ->> 'max_backoff_seconds')::integer, 60))
        INTO v_delegated_id;
    ELSIF (declaration).kind = 'decision_program'
          AND COALESCE((declaration).spec ->> 'delegate', 'true') = 'true' THEN
        v_candidate_oid := to_regclass((declaration).spec ->> 'candidate_relation');
        SELECT ARRAY(SELECT jsonb_array_elements_text((declaration).spec -> 'results'))::name[] INTO v_result_columns;
        SELECT pgreact_api.author_decision_program(
            (declaration).name, v_candidate_oid, ((declaration).spec ->> 'subject_key')::name,
            ((declaration).spec ->> 'candidate_key')::name, ((declaration).spec ->> 'priority')::name,
            v_result_columns, COALESCE(((declaration).spec ->> 'valid_from')::timestamptz, clock_timestamp()),
            NULLIF((declaration).spec ->> 'valid_to', '')::timestamptz,
            COALESCE(((declaration).spec ->> 'max_candidates')::integer, 1000))
        INTO v_delegated_id;
    END IF;

    IF v_current_found AND v_current_row.state = 'REMOVED' THEN
        UPDATE pgreact_internal.api_declarations
        SET api_version = (declaration).api_version, spec = (declaration).spec,
            normalized = v_normalized, declaration_digest = sha256(convert_to(v_normalized::text, 'UTF8')),
            delegated_id = COALESCE(v_delegated_id, v_current_row.delegated_id), owner_oid = v_owner_id,
            state = 'DEPLOYED', deployed_at = clock_timestamp(), removed_at = NULL
        WHERE declaration_id = v_current_row.declaration_id;
    ELSE
        INSERT INTO pgreact_internal.api_declarations(
            api_version, kind, object_name, spec, normalized, declaration_digest,
            delegated_id, owner_oid, state, deployed_at)
        VALUES ((declaration).api_version, (declaration).kind, (declaration).name,
                (declaration).spec, v_normalized, sha256(convert_to(v_normalized::text, 'UTF8')),
                v_delegated_id, v_owner_id, 'DEPLOYED', clock_timestamp());
    END IF;
    RETURN pgreact_internal.m28_envelope(
        'deploy', v_normalized, 'deployed',
        jsonb_build_object('read_only', false, 'delegated_id', v_delegated_id,
                           'delegates_to', (declaration).kind), v_findings);
END
$rc1$;

-- Part B: Fix comparison grants in configure_roles
CREATE OR REPLACE FUNCTION pgreact_api.configure_roles(
    author_role regrole,
    operator_role regrole,
    worker_role regrole,
    reader_role regrole,
    advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $rc1$
BEGIN
    PERFORM pgreact_api.configure_roles_m30(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT USAGE ON SCHEMA pgreact, pgreact_api TO %I, %I, %I',
                   author_role::text, operator_role::text, reader_role::text);
    EXECUTE format('GRANT USAGE ON TYPE pgreact_api.declaration, pgreact_api.target TO %I, %I, %I',
                   author_role::text, operator_role::text, reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.declaration(text,text,jsonb), '
        || 'pgreact_api.target(text,text,text) TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.validate_program(jsonb), '
        || 'pgreact_api.preview_program(jsonb), '
        || 'pgreact_api.declare_derived_relation(text,regtype,name[],integer), '
        || 'pgreact_api.deploy_program(jsonb,text), '
        || 'pgreact_api.remove_program(text,integer) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.request_watermark(text,text,name,timestamptz), '
        || 'pgreact_api.prune_window_history(text,timestamptz), '
        || 'pgreact_api.export_window_state(text), '
        || 'pgreact_api.restore_window_state(jsonb), '
        || 'pgreact_api.watermark_status(text) TO %I', operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.watermark_status(text) TO %I', reader_role::text);
    EXECUTE 'REVOKE ALL ON FUNCTION '
        || 'pgreact_api.validate(pgreact_api.declaration), '
        || 'pgreact_api.preview(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.deploy(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.status(pgreact_api.target,jsonb), '
        || 'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
        || 'pgreact_api.doctor(pgreact_api.target,jsonb), '
        || 'pgreact_api.run(pgreact_api.target,timestamptz), '
        || 'pgreact_api.run(timestamptz), '
        || 'pgreact_api.remove(pgreact_api.target,jsonb), '
        || 'pgreact_api.configure_roles(regrole,regrole,regrole,regrole,regrole) '
        || 'FROM PUBLIC';
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.validate(pgreact_api.declaration), '
        || 'pgreact_api.preview(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.deploy(pgreact_api.declaration,jsonb), '
        || 'pgreact_api.remove(pgreact_api.target,jsonb), '
        || 'pgreact_api.run(pgreact_api.target,timestamptz) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.status(pgreact_api.target,jsonb), '
        || 'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
        || 'pgreact_api.doctor(pgreact_api.target,jsonb), '
        || 'pgreact_api.run(timestamptz), '
        || 'pgreact_api.run(pgreact_api.target,timestamptz) TO %I', operator_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact_api.status(pgreact_api.target,jsonb), '
        || 'pgreact_api.explain(pgreact_api.target,jsonb,jsonb), '
        || 'pgreact_api.doctor(pgreact_api.target,jsonb) TO %I', reader_role::text);
    EXECUTE format('REVOKE ALL ON FUNCTION '
        || 'pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb), '
        || 'pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb) '
        || 'FROM PUBLIC, %I, %I',
        worker_role::text, advanced_reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION '
        || 'pgreact.compare(pgreact_api.declaration, pgreact_api.target, jsonb), '
        || 'pgreact.compare_results(pgreact_api.declaration, pgreact_api.target, jsonb) '
        || 'TO %I, %I, %I',
        author_role::text, operator_role::text, reader_role::text);
END
$rc1$;

REVOKE ALL ON FUNCTION pgreact_api.configure_roles(
    regrole, regrole, regrole, regrole, regrole) FROM PUBLIC;

DO $rc1$
DECLARE
    author_role regrole;
    operator_role regrole;
    worker_role regrole;
    reader_role regrole;
    advanced_reader_role regrole;
BEGIN
    SELECT role_oid::regrole INTO author_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid::regrole INTO operator_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid::regrole INTO worker_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'worker';
    SELECT role_oid::regrole INTO reader_role
    FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    SELECT role_oid::regrole INTO advanced_reader_role
    FROM pgreact_internal.advanced_readers;
    IF author_role IS NOT NULL AND operator_role IS NOT NULL
       AND worker_role IS NOT NULL AND reader_role IS NOT NULL
       AND advanced_reader_role IS NOT NULL THEN
        PERFORM pgreact_api.configure_roles(
            author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    END IF;
END
$rc1$;

COMMENT ON EXTENSION pg_react IS
    '1.0.0-rc.1: PostgreSQL-first durable rule and derivation API over pg_trickle';
