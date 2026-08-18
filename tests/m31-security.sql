\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'm31sec_author') THEN
        CREATE ROLE m31sec_author NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'm31sec_operator') THEN
        CREATE ROLE m31sec_operator NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'm31sec_worker') THEN
        CREATE ROLE m31sec_worker NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'm31sec_reader') THEN
        CREATE ROLE m31sec_reader NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'm31sec_advanced') THEN
        CREATE ROLE m31sec_advanced NOLOGIN;
    END IF;
END
$$;

SELECT pgreact_api.configure_roles(
    'm31sec_author', 'm31sec_operator', 'm31sec_worker',
    'm31sec_reader', 'm31sec_advanced');

DO $m31security$
DECLARE
    actual jsonb;
    expected jsonb := jsonb_build_object(
        'public_schema_usage', false,
        'public_facade_execute', false,
        'private_schema_usage', '[]'::jsonb,
        'm31_functions', jsonb_build_object(
            'm31sec_author', to_jsonb(ARRAY[
                'pgreact_api.deploy(pgreact_api.declaration,jsonb)',
                'pgreact_api.preview(pgreact_api.declaration,jsonb)',
                'pgreact_api.remove(pgreact_api.target,jsonb)',
                'pgreact_api.run(pgreact_api.target,timestamp with time zone)',
                'pgreact_api.validate(pgreact_api.declaration)']),
            'm31sec_operator', to_jsonb(ARRAY[
                'pgreact_api.doctor(pgreact_api.target,jsonb)',
                'pgreact_api.explain(pgreact_api.target,jsonb,jsonb)',
                'pgreact_api.run(pgreact_api.target,timestamp with time zone)',
                'pgreact_api.status(pgreact_api.target,jsonb)']),
            'm31sec_reader', to_jsonb(ARRAY[
                'pgreact_api.doctor(pgreact_api.target,jsonb)',
                'pgreact_api.explain(pgreact_api.target,jsonb,jsonb)',
                'pgreact_api.status(pgreact_api.target,jsonb)']),
            'm31sec_worker', '[]'::jsonb,
            'm31sec_advanced', '[]'::jsonb),
        'unsafe_m31_functions', '[]'::jsonb);
BEGIN
    WITH m31_functions(identity, procedure_oid) AS (
        VALUES
            ('pgreact_api.validate(pgreact_api.declaration)',
                'pgreact_api.validate(pgreact_api.declaration)'::regprocedure),
            ('pgreact_api.preview(pgreact_api.declaration,jsonb)',
                'pgreact_api.preview(pgreact_api.declaration,jsonb)'::regprocedure),
            ('pgreact_api.deploy(pgreact_api.declaration,jsonb)',
                'pgreact_api.deploy(pgreact_api.declaration,jsonb)'::regprocedure),
            ('pgreact_api.remove(pgreact_api.target,jsonb)',
                'pgreact_api.remove(pgreact_api.target,jsonb)'::regprocedure),
            ('pgreact_api.run(pgreact_api.target,timestamp with time zone)',
                'pgreact_api.run(pgreact_api.target,timestamptz)'::regprocedure),
            ('pgreact_api.status(pgreact_api.target,jsonb)',
                'pgreact_api.status(pgreact_api.target,jsonb)'::regprocedure),
            ('pgreact_api.explain(pgreact_api.target,jsonb,jsonb)',
                'pgreact_api.explain(pgreact_api.target,jsonb,jsonb)'::regprocedure),
            ('pgreact_api.doctor(pgreact_api.target,jsonb)',
                'pgreact_api.doctor(pgreact_api.target,jsonb)'::regprocedure)
    ),
    role_grants(role_name, identities) AS (
        SELECT role_name,
               COALESCE(jsonb_agg(functions.identity ORDER BY functions.identity)
                        FILTER (WHERE has_function_privilege(
                            role_name, functions.procedure_oid, 'EXECUTE')), '[]'::jsonb)
        FROM unnest(ARRAY[
            'm31sec_author', 'm31sec_operator', 'm31sec_reader',
            'm31sec_worker', 'm31sec_advanced']) role_name
        CROSS JOIN m31_functions functions
        GROUP BY role_name
    )
    SELECT jsonb_build_object(
        'public_schema_usage', has_schema_privilege('public', 'pgreact_api', 'USAGE'),
        'public_facade_execute', EXISTS (
            SELECT 1
            FROM pg_catalog.pg_proc procedure
            JOIN pg_catalog.pg_namespace namespace
              ON namespace.oid = procedure.pronamespace
            WHERE namespace.nspname = 'pgreact_api'
              AND has_function_privilege('public', procedure.oid, 'EXECUTE')),
        'private_schema_usage', COALESCE((
            SELECT jsonb_agg(role_name ORDER BY role_name)
            FROM unnest(ARRAY[
                'm31sec_author', 'm31sec_operator', 'm31sec_reader',
                'm31sec_worker', 'm31sec_advanced']) role_name
            WHERE has_schema_privilege(role_name, 'pgreact_internal', 'USAGE')
               OR has_schema_privilege(role_name, 'pgreact_runtime', 'USAGE')), '[]'::jsonb),
        'm31_functions', COALESCE((
            SELECT jsonb_object_agg(role_name, identities ORDER BY role_name)
            FROM role_grants), '{}'::jsonb),
        'unsafe_m31_functions', COALESCE((
            SELECT jsonb_agg(functions.identity ORDER BY functions.identity)
            FROM m31_functions functions
            JOIN pg_catalog.pg_proc procedure ON procedure.oid = functions.procedure_oid
            WHERE NOT procedure.prosecdef
               OR procedure.proconfig IS NULL
               OR NOT ('search_path=pg_catalog, pg_temp' = ANY(procedure.proconfig))), '[]'::jsonb)
    ) INTO actual;

    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M31 security role-isolation matrix changed: expected %, actual %',
            expected, actual;
    END IF;
END
$m31security$;

SELECT 'M31_SECURITY_ROLE_ISOLATION_OK' AS result;
