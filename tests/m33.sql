\set ON_ERROR_STOP on

DO $m33$
DECLARE
    inventory jsonb;
    registry jsonb;
    checked jsonb;
    expected_codes jsonb := jsonb_build_array(
        'M32_ACTION_DRIFT', 'M32_ADVANCED_ONLY', 'M32_AMBIGUOUS_OBJECT',
        'M32_DECLARATION_MIGRATION_REQUIRED', 'M32_DEPRECATED_COMPATIBILITY',
        'M32_INCOMPLETE_FRONTIER', 'M32_INVALID_ACTION_SIGNATURE',
        'M32_INVALID_DECLARATION', 'M32_MISSING_OBJECT', 'M32_POLICY_SCOPE_INCOMPATIBLE',
        'M32_RECOVERY_BARRIER', 'M32_RESOURCE_LIMIT', 'M32_RETRY_EXHAUSTED',
        'M32_RLS_UNSUPPORTED', 'M32_RUNTIME_NOT_READY', 'M32_RUNTIME_READY',
        'M32_SOURCE_DRIFT', 'M32_STALE_PREVIEW', 'M32_UNAUTHORIZED_OBJECT',
        'M32_UNSUPPORTED_KIND', 'M32_WORK_FAILED', 'M32_WRONG_KEY_TYPE'
    );
    valid_finding jsonb := jsonb_build_object(
        'code', 'M32_INVALID_DECLARATION',
        'severity', 'ERROR',
        'blocking', true,
        'target', 'm33-test',
        'field', 'condition',
        'message', 'invalid declaration',
        'hint', 'repair the declaration',
        'details', jsonb_build_object('source', 'm33')
    );
BEGIN
    inventory := pgreact_internal.m33_installed_inventory();
    IF NOT (inventory ?& ARRAY[
        'schema_version', 'extension_version', 'functions', 'overloads',
        'types', 'public_views', 'grants', 'declaration_fields', 'aliases'
    ]) THEN
        RAISE EXCEPTION 'M33 installed inventory is incomplete: %', inventory;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(inventory -> 'functions') AS item
        WHERE item ->> 'schema_name' = 'pgreact'
          AND item ->> 'name' = 'rule'
    ) THEN
        RAISE EXCEPTION 'M33 inventory omitted canonical rule function';
    END IF;
    IF (
        SELECT count(*)
        FROM jsonb_array_elements(inventory -> 'overloads') AS item
        WHERE item ->> 'schema_name' = 'pgreact'
          AND item ->> 'name' = 'preview_rule'
    ) < 2 THEN
        RAISE EXCEPTION 'M33 inventory did not preserve overload identities';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(inventory -> 'types') AS item
        WHERE item ->> 'schema_name' = 'pgreact_api'
          AND item ->> 'name' = 'declaration'
    ) THEN
        RAISE EXCEPTION 'M33 inventory omitted declaration type';
    END IF;
    IF (
        SELECT jsonb_agg(item ->> 'name' ORDER BY (item ->> 'ordinal')::integer)
        FROM jsonb_array_elements(inventory -> 'declaration_fields') AS item
    ) <> jsonb_build_array('api_version', 'kind', 'name', 'spec') THEN
        RAISE EXCEPTION 'M33 declaration fields changed: %', inventory -> 'declaration_fields';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(inventory -> 'public_views') AS item
        WHERE item ->> 'schema_name' = 'pgreact'
          AND item ->> 'name' = 'health'
    ) THEN
        RAISE EXCEPTION 'M33 inventory omitted health view';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(inventory -> 'grants') AS item
        WHERE item ->> 'object_schema' = 'pgreact'
          AND item ->> 'object_name' = 'health'
          AND item ->> 'privilege' = 'SELECT'
    ) THEN
        RAISE EXCEPTION 'M33 inventory omitted public view grant';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(inventory -> 'grants') AS item
        WHERE item ->> 'object_kind' = 'FUNCTION'
          AND item ->> 'object_schema' = 'pgreact'
          AND item ->> 'privilege' = 'EXECUTE'
    ) THEN
        RAISE EXCEPTION 'M33 inventory omitted function grant';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(inventory -> 'aliases') AS item
        WHERE item ->> 'alias' = 'pgreact_api.author_rule'
          AND (item ->> 'present')::boolean
    ) THEN
        RAISE EXCEPTION 'M33 inventory omitted compatibility alias';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pgreact.api_inventory AS documented
        WHERE documented.surface_kind = 'FUNCTION'
          AND NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements(inventory -> 'functions') AS installed
              WHERE installed ->> 'identity' = documented.identity
          )
    ) OR EXISTS (
        SELECT 1
        FROM pgreact.api_inventory AS documented
        WHERE documented.surface_kind = 'TYPE'
          AND NOT EXISTS (
              SELECT 1
              FROM jsonb_array_elements(inventory -> 'types') AS installed
              WHERE installed ->> 'identity' = documented.identity
          )
    ) THEN
        RAISE EXCEPTION 'M33 inventory disagrees with installed api_inventory view';
    END IF;

    registry := pgreact_internal.m33_finding_registry();
    IF registry -> 'finding_shape' <> jsonb_build_array(
        'code', 'severity', 'blocking', 'target',
        'field', 'message', 'hint', 'details'
    ) OR registry -> 'severity' <> jsonb_build_array('ERROR', 'WARNING', 'INFO') THEN
        RAISE EXCEPTION 'M33 finding registry envelope changed: %', registry;
    END IF;
    IF (
        SELECT jsonb_agg(item ->> 'code' ORDER BY item ->> 'code')
        FROM jsonb_array_elements(registry -> 'codes') AS item
    ) <> expected_codes THEN
        RAISE EXCEPTION 'M33 finding registry codes changed: %', registry -> 'codes';
    END IF;
    checked := pgreact_internal.m33_check_finding(valid_finding);
    IF checked ->> 'valid' <> 'true'
       OR checked ->> 'code' <> 'M32_INVALID_DECLARATION'
       OR checked -> 'normalized' <> valid_finding
       OR checked -> 'errors' <> '[]'::jsonb THEN
        RAISE EXCEPTION 'M33 valid finding check changed: %', checked;
    END IF;
    checked := pgreact_internal.m33_check_finding(
        jsonb_set(valid_finding, '{code}', '"M33_NOT_REGISTERED"'::jsonb));
    IF checked ->> 'valid' <> 'false'
       OR NOT (checked -> 'errors' ? 'code is not in the stable v1 registry') THEN
        RAISE EXCEPTION 'M33 unknown finding code was accepted: %', checked;
    END IF;
    checked := pgreact_internal.m33_check_findings(jsonb_build_array(valid_finding));
    IF checked ->> 'valid' <> 'true'
       OR jsonb_array_length(checked -> 'findings') <> 1 THEN
        RAISE EXCEPTION 'M33 finding-array check changed: %', checked;
    END IF;

    IF has_schema_privilege('public', 'pgreact_internal', 'USAGE')
       OR EXISTS (
           SELECT 1
           FROM pg_proc AS p
           JOIN pg_namespace AS n ON n.oid = p.pronamespace
           WHERE n.nspname = 'pgreact_internal'
             AND p.proname LIKE 'm33_%'
             AND has_function_privilege('public', p.oid, 'EXECUTE')
       ) THEN
        RAISE EXCEPTION 'M33 internal inventory surface is publicly executable';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgreact_internal'
          AND p.proname LIKE 'm33_%'
          AND p.prosecdef
          AND NOT (COALESCE(p.proconfig, ARRAY[]::text[]) @>
                   ARRAY['search_path=pg_catalog, pg_temp'])
    ) THEN
        RAISE EXCEPTION 'M33 SECURITY DEFINER inventory function has unsafe search_path';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('pgreact', 'pgreact_api')
          AND p.prosecdef
          AND NOT (COALESCE(p.proconfig, ARRAY[]::text[]) @>
                   ARRAY['search_path=pg_catalog, pg_temp'])
    ) THEN
        RAISE EXCEPTION 'M33 public SECURITY DEFINER routine has unsafe search_path';
    END IF;
END
$m33$;
