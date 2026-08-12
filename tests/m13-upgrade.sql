\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE ROLE m13_upgrade_author NOLOGIN;
CREATE ROLE m13_upgrade_operator NOLOGIN;
CREATE ROLE m13_upgrade_worker NOLOGIN;
CREATE ROLE m13_upgrade_reader NOLOGIN;
GRANT USAGE ON SCHEMA pgreact_api TO
    m13_upgrade_author, m13_upgrade_operator,
    m13_upgrade_worker, m13_upgrade_reader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgreact_api TO
    m13_upgrade_author, m13_upgrade_operator,
    m13_upgrade_worker, m13_upgrade_reader;

CREATE SCHEMA m13_upgrade;
CREATE TABLE m13_upgrade.source (
    id bigint PRIMARY KEY,
    enabled boolean NOT NULL
);
CREATE VIEW m13_upgrade.condition AS
SELECT id FROM m13_upgrade.source WHERE enabled;
CREATE FUNCTION m13_upgrade.activate(
    context pgreact.activation_context,
    candidate m13_upgrade.condition
)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
INSERT INTO m13_upgrade.source VALUES (1, true);
SELECT pgreact_api.author_rule(
    'preserved-rule', 'm13_upgrade.condition'::regclass, 'id', 'COMMAND',
    'm13_upgrade.activate(pgreact.activation_context,m13_upgrade.condition)')
AS preserved_version \gset
SELECT set_config('m13.preserved_version', :'preserved_version', false);
SELECT pgreact_api.run_rule('preserved-rule');

CREATE TEMP TABLE m13_upgrade_before AS
SELECT jsonb_build_object(
    'version', (SELECT to_jsonb(version)
        FROM pgreact_internal.rule_versions version
        WHERE rule_version_id = :'preserved_version'::uuid),
    'activations', (SELECT jsonb_agg(to_jsonb(activation)
        ORDER BY activation.activation_id)
        FROM pgreact_internal.activation_state activation
        WHERE rule_version_id = :'preserved_version'::uuid),
    'events', (SELECT jsonb_agg(to_jsonb(event) ORDER BY event.event_id)
        FROM pgreact_internal.lifecycle_events event
        WHERE rule_version_id = :'preserved_version'::uuid),
    'jobs', (SELECT jsonb_agg(to_jsonb(job) ORDER BY job.episode_id)
        FROM pgreact_internal.agenda job
        WHERE rule_version_id = :'preserved_version'::uuid),
    'attempts', (SELECT jsonb_agg(to_jsonb(attempt)
        ORDER BY attempt.episode_id, attempt.attempt_no)
        FROM pgreact_internal.executions attempt
        JOIN pgreact_internal.agenda job USING (episode_id)
        WHERE job.rule_version_id = :'preserved_version'::uuid),
    'clock', (SELECT to_jsonb(clock)
        FROM pgreact_internal.clock_frontier clock)
) AS state;

ALTER EXTENSION pg_react UPDATE TO '0.10.0';

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'version', (SELECT to_jsonb(version)
            FROM pgreact_internal.rule_versions version
            WHERE rule_version_id = current_setting('m13.preserved_version')::uuid),
        'activations', (SELECT jsonb_agg(to_jsonb(activation)
            ORDER BY activation.activation_id)
            FROM pgreact_internal.activation_state activation
            WHERE rule_version_id = current_setting('m13.preserved_version')::uuid),
        'events', (SELECT jsonb_agg(to_jsonb(event) ORDER BY event.event_id)
            FROM pgreact_internal.lifecycle_events event
            WHERE rule_version_id = current_setting('m13.preserved_version')::uuid),
        'jobs', (SELECT jsonb_agg(to_jsonb(job) ORDER BY job.episode_id)
            FROM pgreact_internal.agenda job
            WHERE rule_version_id = current_setting('m13.preserved_version')::uuid),
        'attempts', (SELECT jsonb_agg(to_jsonb(attempt)
            ORDER BY attempt.episode_id, attempt.attempt_no)
            FROM pgreact_internal.executions attempt
            JOIN pgreact_internal.agenda job USING (episode_id)
            WHERE job.rule_version_id = current_setting('m13.preserved_version')::uuid),
        'clock', (SELECT to_jsonb(clock)
            FROM pgreact_internal.clock_frontier clock))
      INTO actual;
    SELECT state INTO STRICT expected FROM m13_upgrade_before;
    IF actual IS DISTINCT FROM expected
       OR (SELECT extversion FROM pg_catalog.pg_extension
           WHERE extname = 'pg_react') <> '0.10.0' THEN
        RAISE EXCEPTION 'M13 upgrade changed populated M12 state: %, %',
            actual, expected;
    END IF;
END
$$;

SELECT pgreact_api.configure_roles(
    'm13_upgrade_author', 'm13_upgrade_operator',
    'm13_upgrade_worker', 'm13_upgrade_reader');

DO $$
DECLARE actual jsonb;
BEGIN
    actual := jsonb_build_object(
        'author_validate', has_function_privilege(
            'm13_upgrade_author',
            'pgreact_api.validate_rule(regclass,name,name,name)', 'EXECUTE'),
        'author_run', has_function_privilege(
            'm13_upgrade_author',
            'pgreact_api.run(timestamptz)', 'EXECUTE'),
        'operator_run', has_function_privilege(
            'm13_upgrade_operator',
            'pgreact_api.run(timestamptz)', 'EXECUTE'),
        'operator_author', has_function_privilege(
            'm13_upgrade_operator',
            'pgreact_api.author_rule(text,regclass,name,name,name)', 'EXECUTE'),
        'worker_claim', has_function_privilege(
            'm13_upgrade_worker',
            'pgreact_api.claim(text,integer,interval)', 'EXECUTE'),
        'worker_status', has_function_privilege(
            'm13_upgrade_worker',
            'pgreact_api.status(text)', 'EXECUTE'),
        'reader_status', has_function_privilege(
            'm13_upgrade_reader',
            'pgreact_api.status(text)', 'EXECUTE'),
        'reader_claim', has_function_privilege(
            'm13_upgrade_reader',
            'pgreact_api.claim(text,integer,interval)', 'EXECUTE'));
    IF actual IS DISTINCT FROM jsonb_build_object(
        'author_validate', true, 'author_run', false,
        'operator_run', true, 'operator_author', false,
        'worker_claim', true, 'worker_status', false,
        'reader_status', true, 'reader_claim', false) THEN
        RAISE EXCEPTION 'M13 upgrade grant repair changed: %', actual;
    END IF;
END
$$;

CREATE FUNCTION m13_upgrade.activate_free(candidate m13_upgrade.condition)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
SELECT pgreact_api.author_rule(
    rule_name => 'upgraded-context-free',
    condition => 'm13_upgrade.condition'::regclass,
    semantic_key => 'id',
    action_schema => 'm13_upgrade',
    on_activate => 'activate_free') AS context_free_version \gset
SELECT set_config('m13.context_free_version', :'context_free_version', false);
INSERT INTO m13_upgrade.source VALUES (2, true);
SELECT pgreact_api.run('2034-01-01 00:00:00+00');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'old_jobs', (SELECT jsonb_agg(jsonb_build_object(
            'key', state.semantic_key, 'event', job.event_kind,
            'state', job.state, 'generation', job.activation_generation)
            ORDER BY job.episode_id)
            FROM pgreact_internal.agenda job
            JOIN pgreact_internal.activation_state state
              USING (rule_version_id, activation_id)
            WHERE job.rule_version_id = current_setting('m13.preserved_version')::uuid),
        'new_jobs', (SELECT jsonb_agg(jsonb_build_object(
            'key', state.semantic_key, 'event', job.event_kind,
            'state', job.state, 'generation', job.activation_generation)
            ORDER BY job.episode_id)
            FROM pgreact_internal.agenda job
            JOIN pgreact_internal.activation_state state
              USING (rule_version_id, activation_id)
            WHERE job.rule_version_id = current_setting('m13.context_free_version')::uuid),
        'binding', (SELECT jsonb_build_object(
            'event', event_kind, 'identity', function_identity,
            'current', function_digest = sha256(convert_to(
                pg_get_functiondef(function_oid), 'UTF8')))
            FROM pgreact_internal.consequence_bindings
            WHERE rule_version_id = current_setting('m13.context_free_version')::uuid))
      INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'old_jobs', jsonb_build_array(jsonb_build_object(
            'key', 2, 'event', 'ACTIVATE', 'state', 'PENDING', 'generation', 1)),
        'new_jobs', jsonb_build_array(jsonb_build_object(
            'key', 2, 'event', 'ACTIVATE', 'state', 'PENDING', 'generation', 1)),
        'binding', jsonb_build_object(
            'event', 'ACTIVATE',
            'identity', 'm13_upgrade.activate_free(m13_upgrade.condition)',
            'current', true)) THEN
        RAISE EXCEPTION 'M13 upgraded operation changed: %', actual;
    END IF;
END
$$;

SELECT 'M13 direct 0.9.0 to 0.10.0 upgrade and grant repair passed';
