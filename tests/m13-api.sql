\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE ROLE m13_author NOLOGIN;
CREATE ROLE m13_operator NOLOGIN;
CREATE ROLE m13_worker NOLOGIN;
CREATE ROLE m13_reader NOLOGIN;
CREATE ROLE m13_other NOLOGIN;
SELECT pgreact_api.configure_roles(
    'm13_author', 'm13_operator', 'm13_worker', 'm13_reader');

DO $$
DECLARE
    actual text[];
    expected text[] := ARRAY[
        'pgreact_api.attempts(text)',
        'pgreact_api.author_deadline_rule(text,regclass,name,name,name,name)',
        'pgreact_api.author_deadline_rule(text,regclass,name,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
        'pgreact_api.author_rule(jsonb,jsonb)',
        'pgreact_api.author_rule(text,regclass,name,name,name)',
        'pgreact_api.author_rule(text,regclass,name,name,name,name,name)',
        'pgreact_api.author_rule(text,regclass,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
        'pgreact_api.batch_status(uuid)',
        'pgreact_api.claim_batch(uuid,text,text,integer,interval)',
        'pgreact_api.claim(text,integer,interval)',
        'pgreact_api.configure_roles(regrole,regrole,regrole,regrole)',
        'pgreact_api.deadline_history(text)',
        'pgreact_api.execute_batch(uuid,text)',
        'pgreact_api.execute(bigint,text,uuid)',
        'pgreact_api.explain_rule(text)',
        'pgreact_api.explain(text)',
        'pgreact_api.health()',
        'pgreact_api.jobs(text)',
        'pgreact_api.matches(text)',
        'pgreact_api.pause_rule(text)',
        'pgreact_api.reconcile_rule(text)',
        'pgreact_api.remove_rule(text)',
        'pgreact_api.replace_deadline_rule(text,regclass,name,name,text,text,text,text,text)',
        'pgreact_api.resume_rule(text)',
        'pgreact_api.rule_status(text)',
        'pgreact_api.run_rule(text)',
        'pgreact_api.run(timestamp with time zone)',
        'pgreact_api.status(text)',
        'pgreact_api.validate_deadline_rule(regclass,name,name,name,name)',
        'pgreact_api.validate_deadline_rule(regclass,name,name,text)',
        'pgreact_api.validate_rule(jsonb,jsonb)',
        'pgreact_api.validate_rule(regclass,name,name,name)',
        'pgreact_api.validate_rule(regclass,name,name,name,name,name)',
        'pgreact_api.validate_rule(regclass,name,text)',
        'pgreact_api.worker_protocol_compatible(integer)'
    ];
BEGIN
    SELECT array_agg(procedure.oid::regprocedure::text
                     ORDER BY procedure.oid::regprocedure::text)
      INTO actual
      FROM pg_catalog.pg_proc procedure
      JOIN pg_catalog.pg_namespace namespace
        ON namespace.oid = procedure.pronamespace
     WHERE namespace.nspname = 'pgreact_api';
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M13 inventory changed: %', actual;
    END IF;
    IF has_schema_privilege('public', 'pgreact_api', 'USAGE')
       OR EXISTS (
            SELECT 1 FROM pg_catalog.pg_proc procedure
            JOIN pg_catalog.pg_namespace namespace
              ON namespace.oid = procedure.pronamespace
            WHERE namespace.nspname = 'pgreact_api'
              AND has_function_privilege('public', procedure.oid, 'EXECUTE'))
       OR has_schema_privilege('m13_reader', 'pgreact_internal', 'USAGE')
       OR has_schema_privilege('m13_worker', 'pgreact_runtime', 'USAGE') THEN
        RAISE EXCEPTION 'M13 public or private-schema boundary changed';
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_object_agg(role_name, identities ORDER BY role_name)
      INTO actual
      FROM (
        SELECT role_name, jsonb_agg(procedure.oid::regprocedure::text
                                    ORDER BY procedure.oid::regprocedure::text) AS identities
          FROM unnest(ARRAY[
                'm13_author', 'm13_operator', 'm13_reader', 'm13_worker']) role_name
          CROSS JOIN pg_catalog.pg_proc procedure
          JOIN pg_catalog.pg_namespace namespace
            ON namespace.oid = procedure.pronamespace
         WHERE namespace.nspname = 'pgreact_api'
           AND has_function_privilege(role_name, procedure.oid, 'EXECUTE')
         GROUP BY role_name
      ) grants;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'm13_author', to_jsonb(ARRAY[
            'pgreact_api.author_deadline_rule(text,regclass,name,name,name,name)',
            'pgreact_api.author_deadline_rule(text,regclass,name,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
            'pgreact_api.author_rule(jsonb,jsonb)',
            'pgreact_api.author_rule(text,regclass,name,name,name)',
            'pgreact_api.author_rule(text,regclass,name,name,name,name,name)',
            'pgreact_api.author_rule(text,regclass,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
            'pgreact_api.validate_deadline_rule(regclass,name,name,name,name)',
            'pgreact_api.validate_deadline_rule(regclass,name,name,text)',
            'pgreact_api.validate_rule(jsonb,jsonb)',
            'pgreact_api.validate_rule(regclass,name,name,name)',
            'pgreact_api.validate_rule(regclass,name,name,name,name,name)',
            'pgreact_api.validate_rule(regclass,name,text)']),
        'm13_operator', to_jsonb(ARRAY[
            'pgreact_api.attempts(text)', 'pgreact_api.deadline_history(text)',
            'pgreact_api.explain_rule(text)', 'pgreact_api.explain(text)',
            'pgreact_api.health()', 'pgreact_api.jobs(text)',
            'pgreact_api.matches(text)', 'pgreact_api.pause_rule(text)',
            'pgreact_api.reconcile_rule(text)', 'pgreact_api.remove_rule(text)',
            'pgreact_api.replace_deadline_rule(text,regclass,name,name,text,text,text,text,text)',
            'pgreact_api.resume_rule(text)', 'pgreact_api.rule_status(text)',
            'pgreact_api.run_rule(text)',
            'pgreact_api.run(timestamp with time zone)',
            'pgreact_api.status(text)']),
        'm13_reader', to_jsonb(ARRAY[
            'pgreact_api.attempts(text)', 'pgreact_api.deadline_history(text)',
            'pgreact_api.explain_rule(text)', 'pgreact_api.explain(text)',
            'pgreact_api.health()', 'pgreact_api.jobs(text)',
            'pgreact_api.matches(text)', 'pgreact_api.rule_status(text)',
            'pgreact_api.status(text)']),
        'm13_worker', to_jsonb(ARRAY[
            'pgreact_api.batch_status(uuid)',
            'pgreact_api.claim_batch(uuid,text,text,integer,interval)',
            'pgreact_api.claim(text,integer,interval)',
            'pgreact_api.execute_batch(uuid,text)',
            'pgreact_api.execute(bigint,text,uuid)',
            'pgreact_api.worker_protocol_compatible(integer)'])) THEN
        RAISE EXCEPTION 'M13 role matrix changed: %', actual;
    END IF;
END
$$;

CREATE SCHEMA m13_app AUTHORIZATION m13_author;
CREATE SCHEMA m13_decoy AUTHORIZATION m13_author;
CREATE SCHEMA m13_other_actions AUTHORIZATION m13_other;
GRANT USAGE ON SCHEMA m13_other_actions TO m13_author;
CREATE TABLE m13_app.source (
    id bigint PRIMARY KEY,
    label text NOT NULL,
    deadline timestamptz NOT NULL
);
CREATE VIEW m13_app.condition AS
SELECT id, label FROM m13_app.source;
CREATE VIEW m13_app.deadline_condition AS
SELECT id, label, deadline FROM m13_app.source;
CREATE TABLE m13_app.action_log (
    log_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    action text NOT NULL,
    payload jsonb NOT NULL
);
ALTER TABLE m13_app.source OWNER TO m13_author;
ALTER VIEW m13_app.condition OWNER TO m13_author;
ALTER VIEW m13_app.deadline_condition OWNER TO m13_author;
ALTER TABLE m13_app.action_log OWNER TO m13_author;

CREATE FUNCTION m13_app.activate_free(candidate m13_app.condition)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_app.action_log(action, payload)
      VALUES ('activate-free', to_jsonb(candidate)) $$;
CREATE FUNCTION m13_app.activate_context(
    context pgreact.activation_context,
    candidate m13_app.condition
)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_app.action_log(action, payload)
      VALUES ('activate-context', jsonb_build_object(
        'event', context.event_kind, 'row', to_jsonb(candidate))) $$;
CREATE FUNCTION m13_app.deactivate_context(
    context pgreact.activation_context,
    candidate m13_app.condition
)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_app.action_log(action, payload)
      VALUES ('deactivate-context', jsonb_build_object(
        'event', context.event_kind, 'row', to_jsonb(candidate))) $$;
CREATE FUNCTION m13_app.change_free(
    old_candidate m13_app.condition,
    new_candidate m13_app.condition
)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_app.action_log(action, payload)
      VALUES ('change-free', jsonb_build_object(
        'old', to_jsonb(old_candidate), 'new', to_jsonb(new_candidate))) $$;
CREATE FUNCTION m13_app.deadline_free(candidate m13_app.deadline_condition)
RETURNS void LANGUAGE SQL
AS $$ INSERT INTO m13_app.action_log(action, payload)
      VALUES ('deadline-free', to_jsonb(candidate)) $$;
CREATE FUNCTION m13_decoy.activate_free(candidate m13_app.condition)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
ALTER FUNCTION m13_app.activate_free(m13_app.condition) OWNER TO m13_author;
ALTER FUNCTION m13_app.activate_context(
    pgreact.activation_context, m13_app.condition) OWNER TO m13_author;
ALTER FUNCTION m13_app.deactivate_context(
    pgreact.activation_context, m13_app.condition) OWNER TO m13_author;
ALTER FUNCTION m13_app.change_free(
    m13_app.condition, m13_app.condition) OWNER TO m13_author;
ALTER FUNCTION m13_app.deadline_free(m13_app.deadline_condition) OWNER TO m13_author;
ALTER FUNCTION m13_decoy.activate_free(m13_app.condition) OWNER TO m13_author;

CREATE FUNCTION m13_app.ambiguous(candidate m13_app.condition)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
CREATE FUNCTION m13_app.ambiguous(
    context pgreact.activation_context,
    candidate m13_app.condition
)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
CREATE FUNCTION m13_app.bad_default(
    candidate m13_app.condition,
    ignored text DEFAULT NULL
)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
CREATE FUNCTION m13_app.bad_variadic(
    candidate m13_app.condition,
    VARIADIC ignored text[]
)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
CREATE FUNCTION m13_app.bad_poly(candidate anyelement)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
ALTER FUNCTION m13_app.ambiguous(m13_app.condition) OWNER TO m13_author;
ALTER FUNCTION m13_app.ambiguous(
    pgreact.activation_context, m13_app.condition) OWNER TO m13_author;
ALTER FUNCTION m13_app.bad_default(m13_app.condition,text) OWNER TO m13_author;
ALTER FUNCTION m13_app.bad_variadic(m13_app.condition,text[]) OWNER TO m13_author;
ALTER FUNCTION m13_app.bad_poly(anyelement) OWNER TO m13_author;
CREATE FUNCTION m13_other_actions.unauthorized(candidate m13_app.condition)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
ALTER FUNCTION m13_other_actions.unauthorized(m13_app.condition) OWNER TO m13_other;
GRANT EXECUTE ON FUNCTION m13_other_actions.unauthorized(m13_app.condition)
TO m13_author;

SET SESSION AUTHORIZATION m13_author;
SET search_path = m13_decoy, m13_app, pg_catalog;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'case', test_case, 'code', code, 'severity', severity)
        ORDER BY test_case)
      INTO actual
      FROM (
        SELECT 'ambiguous' AS test_case, code, severity
          FROM pgreact_api.validate_rule(
            'm13_app.condition', 'id', 'm13_app', 'ambiguous')
        UNION ALL
        SELECT 'default', code, severity
          FROM pgreact_api.validate_rule(
            'm13_app.condition', 'id', 'm13_app', 'bad_default')
        UNION ALL
        SELECT 'missing', code, severity
          FROM pgreact_api.validate_rule(
            'm13_app.condition', 'id', 'm13_app', 'missing')
        UNION ALL
        SELECT 'polymorphic', code, severity
          FROM pgreact_api.validate_rule(
            'm13_app.condition', 'id', 'm13_app', 'bad_poly')
        UNION ALL
        SELECT 'unauthorized', code, severity
          FROM pgreact_api.validate_rule(
            'm13_app.condition', 'id', 'm13_other_actions', 'unauthorized')
        UNION ALL
        SELECT 'variadic', code, severity
          FROM pgreact_api.validate_rule(
            'm13_app.condition', 'id', 'm13_app', 'bad_variadic')
      ) diagnostics;
    IF actual IS DISTINCT FROM '[
        {"case":"ambiguous","code":"M13_ACTION_AMBIGUOUS","severity":"ERROR"},
        {"case":"default","code":"M13_ACTION_SIGNATURE","severity":"ERROR"},
        {"case":"missing","code":"M13_ACTION_NOT_FOUND","severity":"ERROR"},
        {"case":"polymorphic","code":"M13_ACTION_SIGNATURE","severity":"ERROR"},
        {"case":"unauthorized","code":"M13_ACTION_UNAUTHORIZED","severity":"ERROR"},
        {"case":"variadic","code":"M13_ACTION_SIGNATURE","severity":"ERROR"}
    ]'::jsonb THEN
        RAISE EXCEPTION 'M13 resolution diagnostics changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.author_rule(
    rule_name => 'constraint-rule',
    condition => 'm13_app.condition'::regclass,
    semantic_key => 'id',
    kind => 'CONSTRAINT');
SELECT pgreact_api.author_rule(
    rule_name => 'context-rule',
    condition => 'm13_app.condition'::regclass,
    semantic_key => 'id',
    action_schema => 'm13_app',
    on_activate => 'activate_context');
SELECT pgreact_api.author_rule(
    rule_name => 'lifecycle-rule',
    condition => 'm13_app.condition'::regclass,
    semantic_key => 'id',
    action_schema => 'm13_app',
    on_activate => 'activate_free',
    on_deactivate => 'deactivate_context',
    on_change => 'change_free');
SELECT pgreact_api.author_deadline_rule(
    rule_name => 'deadline-rule',
    condition => 'm13_app.deadline_condition'::regclass,
    semantic_key => 'id',
    deadline_column => 'deadline',
    action_schema => 'm13_app',
    on_activate => 'deadline_free');
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'rule', rule.rule_name,
        'event', binding.event_kind,
        'action', binding.function_identity)
        ORDER BY rule.rule_name, binding.event_kind)
      INTO actual
      FROM pgreact_internal.consequence_bindings binding
      JOIN pgreact_internal.rule_versions version USING (rule_version_id)
      JOIN pgreact_internal.rules rule USING (rule_id)
     WHERE rule.rule_name IN ('context-rule', 'deadline-rule', 'lifecycle-rule');
    IF actual IS DISTINCT FROM '[
        {"rule":"context-rule","event":"ACTIVATE","action":"m13_app.activate_context(pgreact.activation_context,m13_app.condition)"},
        {"rule":"deadline-rule","event":"ACTIVATE","action":"m13_app.deadline_free(m13_app.deadline_condition)"},
        {"rule":"lifecycle-rule","event":"ACTIVATE","action":"m13_app.activate_free(m13_app.condition)"},
        {"rule":"lifecycle-rule","event":"CHANGE","action":"m13_app.change_free(m13_app.condition,m13_app.condition)"},
        {"rule":"lifecycle-rule","event":"DEACTIVATE","action":"m13_app.deactivate_context(pgreact.activation_context,m13_app.condition)"}
    ]'::jsonb THEN
        RAISE EXCEPTION 'M13 immutable action bindings changed: %', actual;
    END IF;
END
$$;

SET SESSION AUTHORIZATION m13_reader;
DO $$
DECLARE actual jsonb; expected_rule jsonb;
BEGIN
    expected_rule := jsonb_build_object(
        'rule', 'lifecycle-rule',
        'condition', 'm13_app.condition',
        'key', 'id',
        'state', 'active',
        'actions', jsonb_build_array(
            jsonb_build_object(
                'action', 'activate',
                'function', 'm13_app.activate_free(m13_app.condition)'),
            jsonb_build_object(
                'action', 'change',
                'function', 'm13_app.change_free(m13_app.condition,m13_app.condition)'),
            jsonb_build_object(
                'action', 'deactivate',
                'function', 'm13_app.deactivate_context(pgreact.activation_context,m13_app.condition)')));
    actual := jsonb_build_object(
        'status', pgreact_api.status('lifecycle-rule'),
        'explain', pgreact_api.explain('lifecycle-rule'));
    IF actual IS DISTINCT FROM jsonb_build_object(
        'status', jsonb_build_object(
            'contract_version', 3,
            'rules', jsonb_build_array(expected_rule)),
        'explain', jsonb_build_object(
            'contract_version', 3,
            'rule', expected_rule,
            'matches', '[]'::jsonb,
            'jobs', '[]'::jsonb,
            'attempts', '[]'::jsonb)) THEN
        RAISE EXCEPTION 'M13 friendly inspection vocabulary changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m13_author;
INSERT INTO m13_app.source VALUES (1, 'alpha', '2030-01-01 00:00:00+00');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m13_operator;
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.run('2030-01-01 00:00:00+00');
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 3,
        'sampled_time', '2030-01-01 00:00:00+00'::timestamptz,
        'rules', jsonb_build_array(
            jsonb_build_object('rule', 'constraint-rule', 'kind', 'ordinary', 'result', 'refreshed'),
            jsonb_build_object('rule', 'context-rule', 'kind', 'ordinary', 'result', 'refreshed'),
            jsonb_build_object('rule', 'deadline-rule', 'kind', 'deadline', 'result', 'refreshed'),
            jsonb_build_object('rule', 'lifecycle-rule', 'kind', 'ordinary', 'result', 'refreshed')),
        'relations', '[]'::jsonb,
        'programs', '[]'::jsonb,
        'clock', jsonb_build_object(
            'sampled_time', '2030-01-01 00:00:00+00'::timestamptz,
            'previous_frontier', '-infinity'::timestamptz,
            'frontier', '2030-01-01 00:00:00+00'::timestamptz,
            'affected_rules', 1,
            'affected_keys', 1),
        'jobs_created', 3) THEN
        RAISE EXCEPTION 'M13 coordinated run result changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m13_worker;
DO $$
DECLARE claimed record; actual text[] := ARRAY[]::text[];
BEGIN
    FOR claimed IN SELECT * FROM pgreact_api.claim('m13-worker', 10) LOOP
        actual := actual || pgreact_api.execute(
            claimed.episode_id, 'm13-worker', claimed.lease_token);
    END LOOP;
    IF actual IS DISTINCT FROM ARRAY['COMPLETED', 'COMPLETED', 'COMPLETED'] THEN
        RAISE EXCEPTION 'M13 context action execution changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('action', action, 'payload', payload)
                     ORDER BY log_id)
      INTO actual FROM m13_app.action_log;
    IF actual IS DISTINCT FROM '[
        {"action":"activate-context","payload":{"event":"ACTIVATE","row":{"id":1,"label":"alpha"}}},
        {"action":"activate-free","payload":{"id":1,"label":"alpha"}},
        {"action":"deadline-free","payload":{"id":1,"label":"alpha","deadline":"2030-01-01T00:00:00+00:00"}}
    ]'::jsonb THEN
        RAISE EXCEPTION 'M13 exact action arguments changed: %', actual;
    END IF;
END
$$;

SET SESSION AUTHORIZATION m13_author;
UPDATE m13_app.source SET label = 'beta' WHERE id = 1;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m13_operator;
SELECT pgreact_api.run('2030-01-01 00:00:00+00');
SELECT pgreact_api.run('2030-01-01 00:00:00+00');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m13_worker;
DO $$
DECLARE claimed record; actual text[] := ARRAY[]::text[];
BEGIN
    FOR claimed IN SELECT * FROM pgreact_api.claim('m13-worker', 10) LOOP
        actual := actual || pgreact_api.execute(
            claimed.episode_id, 'm13-worker', claimed.lease_token);
    END LOOP;
    IF actual IS DISTINCT FROM ARRAY['COMPLETED'] THEN
        RAISE EXCEPTION 'M13 change execution changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m13_author;
DELETE FROM m13_app.source WHERE id = 1;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m13_operator;
SELECT pgreact_api.run('2030-01-01 00:00:00+00');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m13_worker;
DO $$
DECLARE claimed record; actual text[] := ARRAY[]::text[];
BEGIN
    FOR claimed IN SELECT * FROM pgreact_api.claim('m13-worker', 10) LOOP
        actual := actual || pgreact_api.execute(
            claimed.episode_id, 'm13-worker', claimed.lease_token);
    END LOOP;
    IF actual IS DISTINCT FROM ARRAY['COMPLETED'] THEN
        RAISE EXCEPTION 'M13 deactivate execution changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'actions', (SELECT jsonb_agg(jsonb_build_object(
            'action', action, 'payload', payload) ORDER BY log_id)
            FROM m13_app.action_log),
        'parity', (SELECT jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name, 'active', state.active,
            'generation', state.generation, 'revision', state.revision)
            ORDER BY rule.rule_name)
            FROM pgreact_internal.activation_state state
            JOIN pgreact_internal.rule_versions version USING (rule_version_id)
            JOIN pgreact_internal.rules rule USING (rule_id)
            WHERE rule.rule_name IN ('context-rule', 'lifecycle-rule')))
      INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'actions', '[
            {"action":"activate-context","payload":{"event":"ACTIVATE","row":{"id":1,"label":"alpha"}}},
            {"action":"activate-free","payload":{"id":1,"label":"alpha"}},
            {"action":"deadline-free","payload":{"id":1,"label":"alpha","deadline":"2030-01-01T00:00:00+00:00"}},
            {"action":"change-free","payload":{"old":{"id":1,"label":"alpha"},"new":{"id":1,"label":"beta"}}},
            {"action":"deactivate-context","payload":{"event":"DEACTIVATE","row":{"id":1,"label":"beta"}}}
        ]'::jsonb,
        'parity', '[
            {"rule":"context-rule","active":false,"generation":1,"revision":1},
            {"rule":"lifecycle-rule","active":false,"generation":1,"revision":1}
        ]'::jsonb) THEN
        RAISE EXCEPTION 'M13 context parity or lifecycle output changed: %', actual;
    END IF;
END
$$;

SET SESSION AUTHORIZATION m13_author;
INSERT INTO m13_app.source VALUES (2, 'rollback', '2030-01-01 00:00:00+00');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m13_operator;
DO $$
DECLARE failure text;
BEGIN
    PERFORM set_config('pgreact.test_fail_run_phase', 'clock', true);
    BEGIN
        PERFORM pgreact_api.run('2030-01-01 00:00:00+00');
    EXCEPTION WHEN OTHERS THEN
        failure := SQLERRM;
    END;
    PERFORM set_config('pgreact.test_fail_run_phase', '', true);
    IF failure IS DISTINCT FROM 'injected M13 run failure after clock' THEN
        RAISE EXCEPTION 'M13 run failure diagnostic changed: %', failure;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'matches', COALESCE(jsonb_agg(jsonb_build_object(
            'rule_version_id', state.rule_version_id,
            'activation_id', state.activation_id,
            'key', state.semantic_key,
            'active', state.active,
            'generation', state.generation,
            'revision', state.revision)
            ORDER BY state.rule_version_id)
            FILTER (WHERE state.semantic_key = 2), '[]'::jsonb),
        'jobs', COALESCE(jsonb_agg(to_jsonb(job) ORDER BY job.episode_id)
            FILTER (WHERE state.semantic_key = 2
                    AND job.state IN ('PENDING', 'RETRY_WAIT', 'LEASED')),
            '[]'::jsonb),
        'barriers', (SELECT COALESCE(jsonb_agg(to_jsonb(barrier)
            ORDER BY rule_version_id), '[]'::jsonb)
            FROM pgreact_internal.rule_barriers barrier),
        'lock_available', pg_try_advisory_lock(5788046901200000))
      INTO actual
      FROM pgreact_internal.activation_state state
      LEFT JOIN pgreact_internal.agenda job
        USING (rule_version_id, activation_id);
    PERFORM pg_advisory_unlock(5788046901200000);
    IF actual IS DISTINCT FROM jsonb_build_object(
        'matches', '[]'::jsonb, 'jobs', '[]'::jsonb,
        'barriers', '[]'::jsonb, 'lock_available', true) THEN
        RAISE EXCEPTION 'M13 run failure was not atomic: %', actual;
    END IF;
END
$$;

DO $$
DECLARE failure text;
BEGIN
    SET LOCAL ROLE m13_reader;
    BEGIN
        PERFORM pgreact_api.run('2030-01-01 00:00:00+00');
    EXCEPTION WHEN insufficient_privilege THEN
        failure := SQLSTATE;
    END;
    RESET ROLE;
    IF failure IS DISTINCT FROM '42501' THEN
        RAISE EXCEPTION 'M13 reader escalation unexpectedly succeeded: %', failure;
    END IF;
END
$$;

SELECT 'M13 ergonomic API, action, coordinator, and role gate passed';
