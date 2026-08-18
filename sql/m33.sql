-- M33 installed-reality inventory and frozen v1 finding registry.

CREATE OR REPLACE FUNCTION pgreact_internal.m33_installed_inventory()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m33$
WITH function_rows AS (
    SELECT n.nspname AS schema_name,
           p.proname AS name,
           format('%I.%I(%s)', n.nspname, p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS identity,
           pg_get_function_identity_arguments(p.oid) AS identity_arguments,
           pg_get_function_arguments(p.oid) AS arguments,
           pg_get_function_result(p.oid) AS result_type,
           CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS kind,
           CASE p.provolatile WHEN 'i' THEN 'IMMUTABLE'
                              WHEN 's' THEN 'STABLE'
                              ELSE 'VOLATILE' END AS volatility,
           p.prosecdef AS security_definer,
           COALESCE(p.proconfig, ARRAY[]::text[]) AS configuration,
           COALESCE(to_jsonb(p.proargnames), '[]'::jsonb) AS argument_names,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                   'grantee', CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                                   ELSE pg_get_userbyid(a.grantee) END,
                   'privilege', a.privilege_type,
                   'grantable', a.is_grantable
               ) ORDER BY a.grantee, a.privilege_type)
               FROM aclexplode(COALESCE(
                   p.proacl, acldefault('f', p.proowner))) AS a
           ), '[]'::jsonb) AS grants
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('pgreact', 'pgreact_api')
),
type_rows AS (
    SELECT n.nspname AS schema_name,
           t.typname AS name,
           t.typtype AS kind,
           format_type(t.oid, NULL) AS identity,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                   'name', a.attname,
                   'type', format_type(a.atttypid, a.atttypmod),
                   'not_null', a.attnotnull
               ) ORDER BY a.attnum)
               FROM pg_attribute AS a
               WHERE a.attrelid = t.typrelid
                 AND a.attnum > 0
                 AND NOT a.attisdropped
           ), '[]'::jsonb) AS fields
    FROM pg_type AS t
    JOIN pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname IN ('pgreact', 'pgreact_api')
      AND t.typtype IN ('c', 'd', 'e', 'r')
),
view_rows AS (
    SELECT n.nspname AS schema_name,
           c.relname AS name,
           CASE c.relkind WHEN 'm' THEN 'materialized_view'
                          ELSE 'view' END AS kind,
           COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                   'name', a.attname,
                   'type', format_type(a.atttypid, a.atttypmod),
                   'not_null', a.attnotnull,
                   'ordinal', a.attnum
               ) ORDER BY a.attnum)
               FROM pg_attribute AS a
               WHERE a.attrelid = c.oid
                 AND a.attnum > 0
                 AND NOT a.attisdropped
           ), '[]'::jsonb) AS columns
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgreact'
      AND c.relkind IN ('v', 'm')
),
relation_grants AS (
    SELECT n.nspname AS object_schema,
           c.relname AS object_name,
           CASE c.relkind WHEN 'm' THEN 'MATERIALIZED VIEW'
                          ELSE 'VIEW' END AS object_kind,
           CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                ELSE pg_get_userbyid(a.grantee) END AS grantee,
           a.privilege_type AS privilege,
           a.is_grantable AS grantable
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    CROSS JOIN LATERAL aclexplode(COALESCE(
        c.relacl, acldefault('r', c.relowner))) AS a
    WHERE n.nspname = 'pgreact'
      AND c.relkind IN ('v', 'm')
),
function_grants AS (
    SELECT n.nspname AS object_schema,
           format('%I(%s)', p.proname,
                  pg_get_function_identity_arguments(p.oid)) AS object_name,
           'FUNCTION'::text AS object_kind,
           CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                ELSE pg_get_userbyid(a.grantee) END AS grantee,
           a.privilege_type AS privilege,
           a.is_grantable AS grantable
    FROM pg_proc AS p
    JOIN pg_namespace AS n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL aclexplode(COALESCE(
        p.proacl, acldefault('f', p.proowner))) AS a
    WHERE n.nspname IN ('pgreact', 'pgreact_api')
),
schema_grants AS (
    SELECT n.nspname AS object_schema,
           NULL::name AS object_name,
           'SCHEMA'::text AS object_kind,
           CASE WHEN a.grantee = 0 THEN 'PUBLIC'
                ELSE pg_get_userbyid(a.grantee) END AS grantee,
           a.privilege_type AS privilege,
           a.is_grantable AS grantable
    FROM pg_namespace AS n
    CROSS JOIN LATERAL aclexplode(COALESCE(
        n.nspacl, acldefault('n', n.nspowner))) AS a
    WHERE n.nspname IN ('pgreact', 'pgreact_api')
),
declaration_fields AS (
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'name', a.attname,
               'type', format_type(a.atttypid, a.atttypmod),
               'not_null', a.attnotnull,
               'ordinal', a.attnum
           ) ORDER BY a.attnum), '[]'::jsonb) AS fields
    FROM pg_attribute AS a
    JOIN pg_type AS t ON t.typrelid = a.attrelid
    JOIN pg_namespace AS n ON n.oid = t.typnamespace
    WHERE n.nspname = 'pgreact_api'
      AND t.typname = 'declaration'
      AND a.attnum > 0
      AND NOT a.attisdropped
),
aliases AS (
    SELECT jsonb_agg(jsonb_build_object(
               'alias', alias_name,
               'canonical', canonical_name,
               'present', EXISTS (
                   SELECT 1
                   FROM pg_proc AS p
                   JOIN pg_namespace AS n ON n.oid = p.pronamespace
                   WHERE format('%I.%I', n.nspname, p.proname) = alias_name
               )
           ) ORDER BY alias_name) AS rows
    FROM (VALUES
        ('pgreact_api.author_rule', 'pgreact.rule'),
        ('pgreact_api.validate_rule', 'pgreact.validate'),
        ('pgreact_api.run_rule', 'pgreact.run'),
        ('pgreact_api.rule_status', 'pgreact.status'),
        ('pgreact_api.matches', 'pgreact.matches'),
        ('pgreact_api.jobs', 'pgreact.work'),
        ('pgreact_api.attempts', 'pgreact.attempts'),
        ('pgreact_api.explain_rule', 'pgreact.explain'),
        ('pgreact_api.validate', 'pgreact.validate'),
        ('pgreact_api.preview', 'pgreact.preview'),
        ('pgreact_api.deploy', 'pgreact.deploy'),
        ('pgreact_api.remove', 'pgreact.remove'),
        ('pgreact_api.run', 'pgreact.run'),
        ('pgreact_api.explain', 'pgreact.explain'),
        ('pgreact_api.doctor', 'pgreact.doctor')
    ) AS v(alias_name, canonical_name)
)
SELECT jsonb_build_object(
    'schema_version', 1,
    'extension_version', (
        SELECT extversion FROM pg_extension WHERE extname = 'pg_react'
    ),
    'functions', COALESCE((
        SELECT jsonb_agg(to_jsonb(f) ORDER BY f.schema_name, f.name,
                         f.identity_arguments)
        FROM function_rows AS f
    ), '[]'::jsonb),
    'overloads', COALESCE((
        SELECT jsonb_agg(to_jsonb(f) ORDER BY f.schema_name, f.name,
                         f.identity_arguments)
        FROM function_rows AS f
        WHERE (SELECT count(*) FROM function_rows AS same
               WHERE same.schema_name = f.schema_name
                 AND same.name = f.name) > 1
    ), '[]'::jsonb),
    'types', COALESCE((
        SELECT jsonb_agg(to_jsonb(t) ORDER BY t.schema_name, t.name)
        FROM type_rows AS t
    ), '[]'::jsonb),
    'public_views', COALESCE((
        SELECT jsonb_agg(to_jsonb(v) ORDER BY v.schema_name, v.name)
        FROM view_rows AS v
    ), '[]'::jsonb),
    'grants', COALESCE((
        SELECT jsonb_agg(to_jsonb(g) ORDER BY g.object_schema,
                         g.object_kind, g.object_name, g.grantee, g.privilege)
        FROM (
            SELECT * FROM relation_grants
            UNION ALL
            SELECT * FROM function_grants
            UNION ALL
            SELECT * FROM schema_grants
        ) AS g
    ), '[]'::jsonb),
    'declaration_fields', (SELECT fields FROM declaration_fields),
    'aliases', COALESCE((SELECT rows FROM aliases), '[]'::jsonb)
)
$m33$;

CREATE OR REPLACE FUNCTION pgreact_internal.m33_inventory()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m33$
    SELECT pgreact_internal.m33_installed_inventory()
$m33$;

CREATE OR REPLACE VIEW pgreact_internal.m33_finding_registry AS
SELECT *
FROM (VALUES
    (1, 'M32_INVALID_DECLARATION', 'invalid declaration', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_MISSING_OBJECT', 'missing PostgreSQL object', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_AMBIGUOUS_OBJECT', 'ambiguous PostgreSQL object', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_WRONG_KEY_TYPE', 'wrong key type', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_INVALID_ACTION_SIGNATURE', 'invalid action signature', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_UNAUTHORIZED_OBJECT', 'unauthorized object', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_RLS_UNSUPPORTED', 'RLS unsupported', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_SOURCE_DRIFT', 'source drift', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_ACTION_DRIFT', 'action drift', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_STALE_PREVIEW', 'stale preview', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_UNSUPPORTED_KIND', 'unsupported ordinary kind', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_ADVANCED_ONLY', 'advanced-only operation', 'WARNING', false, '<unknown>', '<unknown>'),
    (1, 'M32_RESOURCE_LIMIT', 'resource limit', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_RECOVERY_BARRIER', 'recovery barrier', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_INCOMPLETE_FRONTIER', 'incomplete frontier', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_POLICY_SCOPE_INCOMPATIBLE', 'policy-scope incompatibility', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_DECLARATION_MIGRATION_REQUIRED', 'declaration migration required', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_DEPRECATED_COMPATIBILITY', 'deprecated compatibility surface', 'WARNING', false, '<unknown>', '<unknown>'),
    (1, 'M32_RUNTIME_READY', 'managed runtime readiness', 'INFO', false, 'managed runtime or installation target', 'runtime readiness'),
    (1, 'M32_RUNTIME_NOT_READY', 'managed runtime readiness', 'ERROR', true, '<unknown>', '<unknown>'),
    (1, 'M32_WORK_FAILED', 'durable work failure', 'ERROR', false, '<unknown>', '<unknown>'),
    (1, 'M32_RETRY_EXHAUSTED', 'exhausted retry', 'ERROR', false, '<unknown>', '<unknown>')
) AS registry(schema_version, code, category, default_severity, blocking, target, field);

CREATE OR REPLACE FUNCTION pgreact_internal.m33_finding_registry()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m33$
    SELECT jsonb_build_object(
        'schema_version', 1,
        'finding_shape', jsonb_build_array(
            'code', 'severity', 'blocking', 'target',
            'field', 'message', 'hint', 'details'
        ),
        'severity', jsonb_build_array('ERROR', 'WARNING', 'INFO'),
        'codes', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.code), '[]'::jsonb)
    )
    FROM pgreact_internal.m33_finding_registry AS r
$m33$;

CREATE OR REPLACE FUNCTION pgreact_internal.m33_check_finding(finding jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m33$
DECLARE
    normalized jsonb;
    finding_code text;
    errors text[] := ARRAY[]::text[];
BEGIN
    IF finding IS NULL OR jsonb_typeof(finding) <> 'object' THEN
        RETURN jsonb_build_object(
            'valid', false,
            'code', NULL,
            'errors', jsonb_build_array('finding must be a JSON object')
        );
    END IF;

    normalized := pgreact_internal.m32_finding_shape(finding);
    finding_code := finding ->> 'code';
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_internal.m33_finding_registry AS r
        WHERE r.code = finding_code
    ) THEN
        errors := array_append(errors, 'code is not in the stable v1 registry');
    END IF;
    IF NOT (finding ?& ARRAY[
        'code', 'severity', 'blocking', 'target',
        'field', 'message', 'hint', 'details'
    ]) THEN
        errors := array_append(errors, 'finding shape is incomplete');
    END IF;
    IF finding ->> 'severity' NOT IN ('ERROR', 'WARNING', 'INFO') THEN
        errors := array_append(errors, 'severity is not one of ERROR, WARNING, INFO');
    END IF;
    IF jsonb_typeof(finding -> 'blocking') <> 'boolean' THEN
        errors := array_append(errors, 'blocking must be boolean');
    END IF;
    IF jsonb_typeof(finding -> 'details') <> 'object' THEN
        errors := array_append(errors, 'details must be an object');
    END IF;

    RETURN jsonb_build_object(
        'valid', cardinality(errors) = 0,
        'code', finding_code,
        'normalized', normalized,
        'errors', to_jsonb(errors)
    );
END
$m33$;

CREATE OR REPLACE FUNCTION pgreact_internal.m33_check_findings(findings jsonb)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m33$
    SELECT CASE WHEN jsonb_typeof($1) = 'array' THEN
        jsonb_build_object(
            'valid', COALESCE(bool_and((checked.result ->> 'valid')::boolean), true),
            'findings', COALESCE(jsonb_agg(checked.result ORDER BY checked.ordinal), '[]'::jsonb)
        )
    ELSE
        jsonb_build_object(
            'valid', false,
            'findings', jsonb_build_array(jsonb_build_object(
                'valid', false,
                'code', NULL,
                'errors', jsonb_build_array('findings must be a JSON array')
            ))
        )
    END
    FROM (
        SELECT item.ordinal,
               pgreact_internal.m33_check_finding(item.value) AS result
        FROM jsonb_array_elements(CASE WHEN jsonb_typeof($1) = 'array'
                                       THEN $1 ELSE '[]'::jsonb END)
             WITH ORDINALITY AS item(value, ordinal)
    ) AS checked
$m33$;

REVOKE ALL ON TABLE pgreact_internal.m33_finding_registry FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m33_installed_inventory() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m33_inventory() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m33_finding_registry() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m33_check_finding(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgreact_internal.m33_check_findings(jsonb) FROM PUBLIC;
