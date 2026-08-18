\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

-- 1. Create the five application roles
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgreact_author') THEN
        CREATE ROLE pgreact_author NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgreact_operator') THEN
        CREATE ROLE pgreact_operator NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgreact_worker') THEN
        CREATE ROLE pgreact_worker NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgreact_reader') THEN
        CREATE ROLE pgreact_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgreact_advanced_reader') THEN
        CREATE ROLE pgreact_advanced_reader NOLOGIN;
    END IF;
END $$;

-- 2. Configure roles via pgreact_api
SELECT pgreact_api.configure_roles(
    'pgreact_author',
    'pgreact_operator',
    'pgreact_worker',
    'pgreact_reader',
    'pgreact_advanced_reader'
);

-- 3. Verify security boundary & PUBLIC revocations
DO $$
BEGIN
    -- PUBLIC must not have USAGE on private schemas
    IF has_schema_privilege('public', 'pgreact_internal', 'USAGE') THEN
        RAISE EXCEPTION 'PUBLIC has USAGE on pgreact_internal';
    END IF;
    IF has_schema_privilege('public', 'pgreact_runtime', 'USAGE') THEN
        RAISE EXCEPTION 'PUBLIC has USAGE on pgreact_runtime';
    END IF;

    -- PUBLIC must not have EXECUTE on compare
    IF has_function_privilege('public', 'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'PUBLIC has EXECUTE on pgreact.compare';
    END IF;
    IF has_function_privilege('public', 'pgreact.compare_results(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'PUBLIC has EXECUTE on pgreact.compare_results';
    END IF;
END $$;

-- 4. Verify authoritative comparison grants after configure_roles
DO $$
BEGIN
    IF NOT has_function_privilege('pgreact_author', 'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'pgreact_author lacks EXECUTE on pgreact.compare';
    END IF;
    IF NOT has_function_privilege('pgreact_operator', 'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'pgreact_operator lacks EXECUTE on pgreact.compare';
    END IF;
    IF NOT has_function_privilege('pgreact_reader', 'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'pgreact_reader lacks EXECUTE on pgreact.compare';
    END IF;
    IF has_function_privilege('pgreact_worker', 'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'pgreact_worker must not have EXECUTE on pgreact.compare';
    END IF;
    IF has_function_privilege('pgreact_advanced_reader', 'pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb)', 'EXECUTE') THEN
        RAISE EXCEPTION 'pgreact_advanced_reader must not have EXECUTE on pgreact.compare';
    END IF;
END $$;

-- 5. Verify search_path on public SECURITY DEFINER routines
DO $$
DECLARE
    bad_fn record;
BEGIN
    FOR bad_fn IN
        SELECT proname, proconfig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('pgreact', 'pgreact_api')
          AND p.prosecdef
          AND (p.proconfig IS NULL OR NOT ('search_path=pg_catalog, pg_temp' = ANY(p.proconfig)))
    LOOP
        RAISE EXCEPTION 'Public security definer function % lacks search_path=pg_catalog, pg_temp (proconfig=%)',
            bad_fn.proname, bad_fn.proconfig;
    END LOOP;
END $$;

-- 6. Protocol compatibility check
DO $$
BEGIN
    IF NOT pgreact_api.worker_protocol_compatible(1) THEN
        RAISE EXCEPTION 'Worker protocol 1 should be compatible';
    END IF;
    IF NOT pgreact_api.worker_protocol_compatible(2) THEN
        RAISE EXCEPTION 'Worker protocol 2 should be compatible';
    END IF;
    IF pgreact_api.worker_protocol_compatible(0) THEN
        RAISE EXCEPTION 'Worker protocol 0 should be incompatible';
    END IF;
    IF pgreact_api.worker_protocol_compatible(3) THEN
        RAISE EXCEPTION 'Worker protocol 3 should be incompatible';
    END IF;
END $$;

-- 7. Verify all 40 finding codes exist in installed registries
DO $$
DECLARE
    m32_codes text[];
    m34_codes text[];
    all_installed text[];
    code_count integer;
BEGIN
    SELECT ARRAY(SELECT jsonb_array_elements(pgreact_internal.m33_finding_registry() -> 'codes') ->> 'code')
    INTO m32_codes;

    SELECT ARRAY(SELECT jsonb_array_elements(pgreact_internal.m34_finding_registry() -> 'codes') ->> 'code')
    INTO m34_codes;

    SELECT ARRAY(
        SELECT DISTINCT c FROM (
            SELECT unnest(m32_codes) AS c
            UNION ALL
            SELECT unnest(m34_codes) AS c
        ) s
    ) INTO all_installed;

    code_count := cardinality(all_installed);
    IF code_count <> 40 THEN
        RAISE EXCEPTION 'Expected exactly 40 unique installed finding codes, found %: %', code_count, all_installed;
    END IF;
END $$;

-- 8. GUC Bounds Verification
SHOW pg_react.poll_interval_ms;
SHOW pg_react.batch_size;
SHOW pg_react.max_pending_jobs;

SELECT pgreact.doctor();
