\set ON_ERROR_STOP on

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_upgrade_author') THEN CREATE ROLE m15_upgrade_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_upgrade_operator') THEN CREATE ROLE m15_upgrade_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_upgrade_worker') THEN CREATE ROLE m15_upgrade_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_upgrade_reader') THEN CREATE ROLE m15_upgrade_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_upgrade_advanced') THEN CREATE ROLE m15_upgrade_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm15_upgrade_author', 'm15_upgrade_operator', 'm15_upgrade_worker',
    'm15_upgrade_reader', 'm15_upgrade_advanced');

CREATE SCHEMA m15_upgrade;
CREATE TABLE m15_upgrade.source (id bigint PRIMARY KEY, payload text NOT NULL);
CREATE VIEW m15_upgrade.pending AS SELECT * FROM m15_upgrade.source;
CREATE FUNCTION m15_upgrade.record(row_value m15_upgrade.pending)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
SELECT pgreact_api.author_rule(
    'm15.upgrade', 'm15_upgrade.pending'::regclass, 'id'::name,
    'm15_upgrade'::name, 'record'::name) AS version_id \gset
INSERT INTO m15_upgrade.source VALUES (42, 'preserved');
SELECT pgreact_api.run('2042-01-01 00:00:00+00');

CREATE TEMP TABLE before_upgrade AS
SELECT
    (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') AS version,
    (SELECT jsonb_agg(to_jsonb(state) ORDER BY rule_version_id, semantic_key)
     FROM pgreact_internal.activation_state state) AS activations,
    (SELECT jsonb_agg(to_jsonb(job) ORDER BY episode_id)
     FROM pgreact_internal.agenda job) AS jobs;

ALTER EXTENSION pg_react UPDATE TO '0.12.0';

DO $$
DECLARE before_row before_upgrade%ROWTYPE;
BEGIN
    SELECT * INTO STRICT before_row FROM before_upgrade;
    IF before_row.version <> '0.11.0'
       OR (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.12.0'
       OR before_row.activations IS DISTINCT FROM (
            SELECT jsonb_agg(to_jsonb(state) ORDER BY rule_version_id, semantic_key)
            FROM pgreact_internal.activation_state state)
       OR before_row.jobs IS DISTINCT FROM (
            SELECT jsonb_agg(to_jsonb(job) ORDER BY episode_id)
            FROM pgreact_internal.agenda job)
       OR pgreact_api.key_codecs() ->> 'codec_version' <> '2'
       OR (SELECT count(*) FROM pgreact_internal.semantic_key_identities) <> 0
       OR (SELECT count(*) FROM pgreact_internal.managed_processes) <> 0
       OR NOT has_function_privilege(
            'm15_upgrade_author',
            'pgreact_api.author_rule(text,regclass,name[],name,name)', 'EXECUTE')
       OR NOT has_function_privilege(
            'm15_upgrade_operator', 'pgreact_api.managed_status()', 'EXECUTE')
       OR NOT has_function_privilege(
            'm15_upgrade_worker', 'pgreact_api.managed_cycle()', 'EXECUTE')
       OR NOT has_function_privilege(
            'm15_upgrade_reader', 'pgreact_api.key_codecs()', 'EXECUTE')
       OR NOT has_function_privilege(
            'm15_upgrade_advanced', 'pgreact_api.explain_advanced(uuid)', 'EXECUTE')
       OR has_schema_privilege('public', 'pgreact_api', 'USAGE')
       OR EXISTS (
            SELECT 1 FROM pg_proc procedure
            JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
            WHERE namespace.nspname = 'pgreact_api'
              AND procedure.proname LIKE '%\_m14' ESCAPE '\') THEN
        RAISE EXCEPTION 'M15 populated upgrade did not preserve exact durable state';
    END IF;
END
$$;

SELECT 'M15 populated 0.11.0 to 0.12.0 upgrade gate passed';
