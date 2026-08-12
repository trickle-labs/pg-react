\set ON_ERROR_STOP on

DO $$
DECLARE
    expected text[] := ARRAY[
        'author_rule', 'claim', 'execute', 'explain_rule', 'health',
        'rule_status', 'run_rule', 'validate_rule'
    ];
    actual text[];
BEGIN
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') = '0.9.0' THEN
        expected := ARRAY[
            'author_deadline_rule', 'author_rule', 'claim', 'deadline_history',
            'execute', 'explain_rule', 'health', 'pause_rule', 'reconcile_rule',
            'remove_rule', 'replace_deadline_rule', 'resume_rule', 'rule_status',
            'run_rule', 'validate_deadline_rule', 'validate_rule'
        ];
    END IF;
    SELECT array_agg(DISTINCT p.proname ORDER BY p.proname)
      INTO actual
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgreact_api';
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M11 facade function inventory changed: %', actual;
    END IF;

    SELECT array_agg(format('%s(%s)', p.proname, pg_get_function_arguments(p.oid))
                     ORDER BY p.proname)
      INTO actual
      FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgreact_api'
       AND p.proname IN ('explain_rule', 'rule_status', 'run_rule');
    expected := ARRAY[
        'explain_rule(name text)',
        'rule_status(name text DEFAULT NULL::text)',
        'run_rule(name text)'
    ];
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M11 name-first wrapper arguments changed: %', actual;
    END IF;

    IF has_schema_privilege('public', 'pgreact_api', 'USAGE')
       OR EXISTS (
           SELECT 1 FROM pg_catalog.pg_proc p
           JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'pgreact_api'
            AND has_function_privilege('public', p.oid, 'EXECUTE')) THEN
        RAISE EXCEPTION 'M11 facade must be private by default';
    END IF;
END
$$;

CREATE ROLE m11_facade_test LOGIN;
GRANT USAGE ON SCHEMA pgreact_api TO m11_facade_test;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgreact_api TO m11_facade_test;
CREATE SCHEMA m11_author AUTHORIZATION m11_facade_test;
CREATE TABLE m11_author.facts (id bigint PRIMARY KEY, enabled boolean NOT NULL DEFAULT true);
CREATE VIEW m11_author.enabled_fact AS SELECT id FROM m11_author.facts WHERE enabled;
ALTER TABLE m11_author.facts OWNER TO m11_facade_test;
ALTER VIEW m11_author.enabled_fact OWNER TO m11_facade_test;
CREATE FUNCTION m11_author.activate(context pgreact.activation_context,
                                    match m11_author.enabled_fact)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
ALTER FUNCTION m11_author.activate(pgreact.activation_context, m11_author.enabled_fact)
    OWNER TO m11_facade_test;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := jsonb_build_object(
        'facade_usage', has_schema_privilege('m11_facade_test', 'pgreact_api', 'USAGE'),
        'facade_execute', (SELECT bool_and(has_function_privilege('m11_facade_test', p.oid, 'EXECUTE'))
                              FROM pg_catalog.pg_proc p
                              JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
                             WHERE n.nspname = 'pgreact_api'),
        'legacy_usage', has_schema_privilege('m11_facade_test', 'pgreact', 'USAGE'),
        'internal_usage', has_schema_privilege('m11_facade_test', 'pgreact_internal', 'USAGE'),
        'runtime_usage', has_schema_privilege('m11_facade_test', 'pgreact_runtime', 'USAGE'));
    IF actual IS DISTINCT FROM jsonb_build_object(
        'facade_usage', true, 'facade_execute', true,
        'legacy_usage', false, 'internal_usage', false, 'runtime_usage', false) THEN
        RAISE EXCEPTION 'M11 facade grants changed: %', actual;
    END IF;
END
$$;

SET SESSION AUTHORIZATION m11_facade_test;
DO $$
DECLARE actual jsonb; version_id uuid;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('code', code, 'severity', severity)
                     ORDER BY code, severity)
      INTO actual
      FROM pgreact_api.validate_rule('m11_author.enabled_fact'::regclass, 'id',
           'm11_author.activate(pgreact.activation_context,m11_author.enabled_fact)');
    IF actual IS DISTINCT FROM '[{"code":"OK","severity":"INFO"}]'::jsonb THEN
        RAISE EXCEPTION 'M11 facade validation changed: %', actual;
    END IF;
    SELECT pgreact_api.author_rule(
        'm11-author-rule', 'm11_author.enabled_fact'::regclass, 'id', 'COMMAND',
        'm11_author.activate(pgreact.activation_context,m11_author.enabled_fact)')
      INTO version_id;
    IF version_id IS NULL THEN RAISE EXCEPTION 'M11 facade did not author a rule'; END IF;
    SELECT pgreact_api.rule_status('m11-author-rule') INTO actual;
    actual := jsonb_build_object(
        'contract_version', actual->'contract_version',
        'rule_name', actual#>>'{rules,0,rule_name}',
        'state', actual#>>'{rules,0,state}',
        'health', actual->'health'
    );
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', CASE
            WHEN (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') = '0.9.0'
            THEN 2 ELSE 1 END,
        'rule_name', 'm11-author-rule', 'state', 'ACTIVE', 'health', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M11 facade status changed: %', actual;
    END IF;
    actual := pgreact_api.health();
    IF jsonb_build_object(
        'contract_version', actual -> 'contract_version',
        'diagnostics', actual -> 'diagnostics') IS DISTINCT FROM
       jsonb_build_object('contract_version', CASE
           WHEN (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_react') = '0.9.0'
           THEN 2 ELSE 1 END, 'diagnostics', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M11 facade health changed';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SELECT 'M11 replacement facade API gate passed';
