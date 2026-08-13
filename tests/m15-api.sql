\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_author') THEN CREATE ROLE m15_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_operator') THEN CREATE ROLE m15_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_worker') THEN CREATE ROLE m15_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_reader') THEN CREATE ROLE m15_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm15_advanced') THEN CREATE ROLE m15_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm15_author', 'm15_operator', 'm15_worker', 'm15_reader', 'm15_advanced');

DO $$
DECLARE
    actual text[];
    expected text[] := ARRAY[
        'pgreact_api.attempts(text)',
        'pgreact_api.author_deadline_rule(text,regclass,name,name,name,name)',
        'pgreact_api.author_deadline_rule(text,regclass,name[],name,name,name)',
        'pgreact_api.author_deadline_rule(text,regclass,name[],name,name,name,name,name)',
        'pgreact_api.author_deadline_rule(text,regclass,name,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
        'pgreact_api.author_rule(jsonb,jsonb)',
        'pgreact_api.author_rule(text,regclass,name,name,name)',
        'pgreact_api.author_rule(text,regclass,name[],name,name)',
        'pgreact_api.author_rule(text,regclass,name,name,name,name,name)',
        'pgreact_api.author_rule(text,regclass,name[],name,name,name,name)',
        'pgreact_api.author_rule(text,regclass,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
        'pgreact_api.batch_status(uuid)',
        'pgreact_api.claim_batch(uuid,text,text,integer,interval)',
        'pgreact_api.claim(text,integer,interval)',
        'pgreact_api.configure_roles(regrole,regrole,regrole,regrole)',
        'pgreact_api.configure_roles(regrole,regrole,regrole,regrole,regrole)',
        'pgreact_api.deadline_history(text)',
        'pgreact_api.declare_derived_relation(text,regtype,name,integer)',
        'pgreact_api.declare_derived_relation(text,regtype,name[],integer)',
        'pgreact_api.deploy_program(jsonb,text)',
        'pgreact_api.doctor()',
        'pgreact_api.execute_batch(uuid,text)',
        'pgreact_api.execute(bigint,text,uuid)',
        'pgreact_api.explain_advanced(uuid)',
        'pgreact_api.explain_rule(text)',
        'pgreact_api.explain(text)',
        'pgreact_api.explain(text,bigint)',
        'pgreact_api.explain(text,bigint,boolean)',
        'pgreact_api.explain(text,boolean)',
        'pgreact_api.explain(text,jsonb)',
        'pgreact_api.explain(text,uuid)',
        'pgreact_api.health()',
        'pgreact_api.infer_program(jsonb)',
        'pgreact_api.jobs(text)',
        'pgreact_api.key_codecs()',
        'pgreact_api.m14_pack(jsonb)',
        'pgreact_api.managed_cycle()',
        'pgreact_api.managed_status()',
        'pgreact_api.matches(text)',
        'pgreact_api.pause_rule(text)',
        'pgreact_api.preview_program(jsonb)',
        'pgreact_api.reconcile_rule(text)',
        'pgreact_api.remove_program(text,integer)',
        'pgreact_api.remove_rule(text)',
        'pgreact_api.replace_deadline_rule(text,regclass,name[],name,name,name,name,name)',
        'pgreact_api.replace_deadline_rule(text,regclass,name,name,text,text,text,text,text)',
        'pgreact_api.replace_rule(text,regclass,name[],name,name,name,name)',
        'pgreact_api.resume_rule(text)',
        'pgreact_api.rule_status(text)',
        'pgreact_api.run_rule(text)',
        'pgreact_api.run(timestamp with time zone)',
        'pgreact_api.status(text)',
        'pgreact_api.validate_deadline_rule(regclass,name,name,name,name)',
        'pgreact_api.validate_deadline_rule(regclass,name,name,text)',
        'pgreact_api.validate_program(jsonb)',
        'pgreact_api.validate_rule(jsonb,jsonb)',
        'pgreact_api.validate_rule(regclass,name,name,name)',
        'pgreact_api.validate_rule(regclass,name,name,name,name,name)',
        'pgreact_api.validate_rule(regclass,name[],name,name,name,name)',
        'pgreact_api.validate_rule(regclass,name,text)',
        'pgreact_api.worker_protocol_compatible(integer)'];
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') IN ('0.13.0','0.14.0') THEN
        SELECT array_agg(identity ORDER BY identity) INTO expected
        FROM unnest(expected || ARRAY['pgreact_api.reconcile_program(text)']) identity;
    END IF;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') = '0.14.0' THEN
        SELECT array_agg(identity ORDER BY identity) INTO expected
        FROM unnest(expected || ARRAY[
            'pgreact_api.export_window_state(text)',
            'pgreact_api.prune_window_history(text,timestamp with time zone)',
            'pgreact_api.request_watermark(text,text,name,timestamp with time zone)',
            'pgreact_api.restore_window_state(jsonb)',
            'pgreact_api.watermark_status(text)',
            'pgreact_api.window_corrections(text,integer,text)']) identity;
    END IF;
    SELECT array_agg(procedure.oid::regprocedure::text
                     ORDER BY procedure.oid::regprocedure::text)
    INTO actual
    FROM pg_proc procedure
    JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'pgreact_api';
    IF actual IS DISTINCT FROM expected
       OR has_schema_privilege('public', 'pgreact_api', 'USAGE')
       OR EXISTS (
            SELECT 1 FROM pg_proc procedure
            JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
            WHERE namespace.nspname = 'pgreact_api'
              AND has_function_privilege('public', procedure.oid, 'EXECUTE'))
       OR has_schema_privilege('m15_reader', 'pgreact_internal', 'USAGE')
       OR has_schema_privilege('m15_worker', 'pgreact_runtime', 'USAGE') THEN
        RAISE EXCEPTION 'M15 final public inventory or private boundary changed: %', actual;
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
                                    ORDER BY procedure.oid::regprocedure::text) identities
        FROM unnest(ARRAY[
            'm15_author', 'm15_operator', 'm15_worker',
            'm15_reader', 'm15_advanced']) role_name
        CROSS JOIN pg_proc procedure
        JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
        WHERE namespace.nspname = 'pgreact_api'
          AND has_function_privilege(role_name, procedure.oid, 'EXECUTE')
        GROUP BY role_name
    ) grants;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') IN ('0.13.0','0.14.0') THEN
        actual := jsonb_set(actual, '{m15_operator}',
            (actual -> 'm15_operator') - 'pgreact_api.reconcile_program(text)');
    END IF;
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') = '0.14.0' THEN
        actual := jsonb_set(actual, '{m15_operator}',
            (actual -> 'm15_operator')
                - 'pgreact_api.export_window_state(text)'
                - 'pgreact_api.prune_window_history(text,timestamp with time zone)'
                - 'pgreact_api.request_watermark(text,text,name,timestamp with time zone)'
                - 'pgreact_api.restore_window_state(jsonb)'
                - 'pgreact_api.watermark_status(text)'
                - 'pgreact_api.window_corrections(text,integer,text)');
        actual := jsonb_set(actual, '{m15_reader}',
            (actual -> 'm15_reader') - 'pgreact_api.watermark_status(text)');
        actual := jsonb_set(actual, '{m15_advanced}',
            (actual -> 'm15_advanced') - 'pgreact_api.window_corrections(text,integer,text)');
    END IF;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'm15_advanced', to_jsonb(ARRAY['pgreact_api.explain_advanced(uuid)']),
        'm15_author', to_jsonb(ARRAY[
            'pgreact_api.author_deadline_rule(text,regclass,name,name,name,name)',
            'pgreact_api.author_deadline_rule(text,regclass,name[],name,name,name)',
            'pgreact_api.author_deadline_rule(text,regclass,name[],name,name,name,name,name)',
            'pgreact_api.author_deadline_rule(text,regclass,name,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
            'pgreact_api.author_rule(jsonb,jsonb)',
            'pgreact_api.author_rule(text,regclass,name,name,name)',
            'pgreact_api.author_rule(text,regclass,name[],name,name)',
            'pgreact_api.author_rule(text,regclass,name,name,name,name,name)',
            'pgreact_api.author_rule(text,regclass,name[],name,name,name,name)',
            'pgreact_api.author_rule(text,regclass,name,text,text,text,text,text,name[],integer,text,name[],integer,integer,numeric,integer)',
            'pgreact_api.declare_derived_relation(text,regtype,name,integer)',
            'pgreact_api.declare_derived_relation(text,regtype,name[],integer)',
            'pgreact_api.deploy_program(jsonb,text)',
            'pgreact_api.preview_program(jsonb)',
            'pgreact_api.remove_program(text,integer)',
            'pgreact_api.replace_deadline_rule(text,regclass,name[],name,name,name,name,name)',
            'pgreact_api.replace_rule(text,regclass,name[],name,name,name,name)',
            'pgreact_api.validate_deadline_rule(regclass,name,name,name,name)',
            'pgreact_api.validate_deadline_rule(regclass,name,name,text)',
            'pgreact_api.validate_program(jsonb)',
            'pgreact_api.validate_rule(jsonb,jsonb)',
            'pgreact_api.validate_rule(regclass,name,name,name)',
            'pgreact_api.validate_rule(regclass,name,name,name,name,name)',
            'pgreact_api.validate_rule(regclass,name[],name,name,name,name)',
            'pgreact_api.validate_rule(regclass,name,text)']),
        'm15_operator', to_jsonb(ARRAY[
            'pgreact_api.attempts(text)', 'pgreact_api.deadline_history(text)',
            'pgreact_api.doctor()', 'pgreact_api.explain_rule(text)',
            'pgreact_api.explain(text)', 'pgreact_api.explain(text,bigint)',
            'pgreact_api.explain(text,bigint,boolean)', 'pgreact_api.explain(text,boolean)',
            'pgreact_api.explain(text,jsonb)', 'pgreact_api.explain(text,uuid)',
            'pgreact_api.health()', 'pgreact_api.jobs(text)', 'pgreact_api.key_codecs()',
            'pgreact_api.managed_status()', 'pgreact_api.matches(text)',
            'pgreact_api.pause_rule(text)', 'pgreact_api.reconcile_rule(text)',
            'pgreact_api.remove_rule(text)',
            'pgreact_api.replace_deadline_rule(text,regclass,name,name,text,text,text,text,text)',
            'pgreact_api.resume_rule(text)', 'pgreact_api.rule_status(text)',
            'pgreact_api.run_rule(text)', 'pgreact_api.run(timestamp with time zone)',
            'pgreact_api.status(text)']),
        'm15_reader', to_jsonb(ARRAY[
            'pgreact_api.attempts(text)', 'pgreact_api.deadline_history(text)',
            'pgreact_api.doctor()', 'pgreact_api.explain_rule(text)',
            'pgreact_api.explain(text)', 'pgreact_api.explain(text,bigint)',
            'pgreact_api.explain(text,bigint,boolean)', 'pgreact_api.explain(text,boolean)',
            'pgreact_api.explain(text,jsonb)', 'pgreact_api.explain(text,uuid)',
            'pgreact_api.health()', 'pgreact_api.jobs(text)', 'pgreact_api.key_codecs()',
            'pgreact_api.managed_status()', 'pgreact_api.matches(text)',
            'pgreact_api.rule_status(text)', 'pgreact_api.status(text)']),
        'm15_worker', to_jsonb(ARRAY[
            'pgreact_api.batch_status(uuid)',
            'pgreact_api.claim_batch(uuid,text,text,integer,interval)',
            'pgreact_api.claim(text,integer,interval)',
            'pgreact_api.execute_batch(uuid,text)',
            'pgreact_api.execute(bigint,text,uuid)',
            'pgreact_api.managed_cycle()',
            'pgreact_api.worker_protocol_compatible(integer)'])) THEN
        RAISE EXCEPTION 'M15 exact five-role grants changed: %', actual;
    END IF;
END
$$;

CREATE SCHEMA m15_app AUTHORIZATION m15_author;
CREATE TABLE m15_app.events (
    tenant text COLLATE "C",
    event_id uuid,
    payload text NOT NULL
);
CREATE VIEW m15_app.pending AS SELECT * FROM m15_app.events;
CREATE TYPE m15_app.fact_row AS (
    tenant text COLLATE "C",
    event_id uuid,
    payload text
);
CREATE VIEW m15_app.event_fact AS SELECT tenant, event_id, payload FROM m15_app.events;
CREATE TABLE m15_app.actions (public_key jsonb PRIMARY KEY, payload text NOT NULL);
CREATE FUNCTION m15_app.record_pending(row_value m15_app.pending)
RETURNS void
LANGUAGE SQL
AS $$
    INSERT INTO m15_app.actions VALUES (
        jsonb_build_array(to_jsonb(row_value.tenant), to_jsonb(row_value.event_id)),
        row_value.payload)
    ON CONFLICT (public_key) DO UPDATE SET payload = EXCLUDED.payload
$$;
CREATE FUNCTION m15_app.record_uuid(row_value m15_app.pending)
RETURNS void
LANGUAGE SQL
AS $$
    INSERT INTO m15_app.actions VALUES (to_jsonb(row_value.event_id), row_value.payload)
    ON CONFLICT (public_key) DO UPDATE SET payload = EXCLUDED.payload
$$;
CREATE FUNCTION m15_app.record_text(row_value m15_app.pending)
RETURNS void
LANGUAGE SQL
AS $$
    INSERT INTO m15_app.actions VALUES (to_jsonb(row_value.tenant), row_value.payload)
    ON CONFLICT (public_key) DO UPDATE SET payload = EXCLUDED.payload
$$;
ALTER TABLE m15_app.events OWNER TO m15_author;
ALTER VIEW m15_app.pending OWNER TO m15_author;
ALTER TYPE m15_app.fact_row OWNER TO m15_author;
ALTER VIEW m15_app.event_fact OWNER TO m15_author;
ALTER TABLE m15_app.actions OWNER TO m15_author;
ALTER FUNCTION m15_app.record_pending(m15_app.pending) OWNER TO m15_author;
ALTER FUNCTION m15_app.record_uuid(m15_app.pending) OWNER TO m15_author;
ALTER FUNCTION m15_app.record_text(m15_app.pending) OWNER TO m15_author;
SET SESSION AUTHORIZATION m15_author;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(diagnostic) ORDER BY code, object_identity)
    INTO actual
    FROM pgreact_api.validate_rule(
        'm15_app.pending', ARRAY['tenant', 'event_id']::name[],
        'm15_app', 'record_pending') diagnostic;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version', 5, 'code', 'OK', 'severity', 'INFO',
        'object_identity', 'm15_app.pending',
        'message', 'typed semantic key and actions are valid',
        'hint', 'Call author_rule with the same ordered key columns.',
        'details', jsonb_build_object('key_columns', ARRAY['tenant', 'event_id']::name[]))) THEN
        RAISE EXCEPTION 'M15 validation output changed: %', actual;
    END IF;
END
$$;
SELECT pgreact_api.author_rule(
    'm15.pending', 'm15_app.pending', ARRAY['tenant', 'event_id']::name[],
    'm15_app', 'record_pending');
SELECT pgreact_api.author_rule(
    'm15.uuid', 'm15_app.pending', ARRAY['event_id']::name[],
    'm15_app', 'record_uuid');
SELECT pgreact_api.author_rule(
    'm15.text', 'm15_app.pending', ARRAY['tenant']::name[],
    'm15_app', 'record_text');
SELECT pgreact_api.declare_derived_relation(
    'm15_app.fact', 'm15_app.fact_row'::regtype,
    ARRAY['tenant', 'event_id']::name[]);
DO $$
DECLARE
    definition jsonb := jsonb_build_object(
        'name', 'm15.program', 'version', 1, 'max_iterations', 8, 'max_facts', 16,
        'rules', jsonb_build_array(jsonb_build_object(
            'name', 'm15.event_fact', 'definition', 'm15_app.event_fact',
            'key', jsonb_build_array('tenant', 'event_id'),
            'target', 'm15_app.fact', 'version', 1)));
    preview jsonb;
BEGIN
    preview := pgreact_api.preview_program(definition);
    IF preview - 'plan_digest' IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5,
        'program', definition || jsonb_build_object('rules', jsonb_build_array(
            (definition #> '{rules,0}') || jsonb_build_object('inputs', '[]'::jsonb)))) THEN
        RAISE EXCEPTION 'M15 typed program preview changed: %', preview;
    END IF;
    PERFORM pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;

INSERT INTO m15_app.events VALUES (
    'north', '123e4567-e89b-12d3-a456-426614174000', 'ready');
SELECT pgreact_api.run();
SET SESSION AUTHORIZATION m15_worker;
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.managed_cycle();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'state', 'backpressure', 'pending_jobs', 0,
        'processed_jobs', 3, 'run', NULL) THEN
        RAISE EXCEPTION 'M15 backpressure cycle changed: %', actual;
    END IF;
    actual := pgreact_api.managed_cycle();
    IF actual ->> 'state' <> 'ready'
       OR actual ->> 'pending_jobs' <> '0'
       OR actual ->> 'processed_jobs' <> '0'
       OR actual -> 'run' ->> 'contract_version' <> '5' THEN
        RAISE EXCEPTION 'M15 resumed managed cycle changed: %', actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.key_codecs();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5, 'codec_version', 2, 'max_arity', 4,
        'scalar_types', jsonb_build_array('bigint', 'uuid', 'text'),
        'null_components', false, 'component_order', 'declared',
        'text_collation', 'C') THEN
        RAISE EXCEPTION 'M15 codec matrix changed: %', actual;
    END IF;
    actual := pgreact_api.status('m15.pending');
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5,
        'rules', jsonb_build_array(jsonb_build_object(
            'rule', 'm15.pending', 'condition', 'm15_app.pending',
            'key', jsonb_build_array('tenant', 'event_id'), 'state', 'active',
            'actions', jsonb_build_array(jsonb_build_object(
                'action', 'activate',
                'function', 'm15_app.record_pending(m15_app.pending)'))))) THEN
        RAISE EXCEPTION 'M15 status output changed: %', actual;
    END IF;
    SELECT jsonb_agg(to_jsonb(action_row) ORDER BY public_key::text)
    INTO actual FROM m15_app.actions action_row;
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('public_key', '123e4567-e89b-12d3-a456-426614174000', 'payload', 'ready'),
        jsonb_build_object('public_key', 'north', 'payload', 'ready'),
        jsonb_build_object(
            'public_key', jsonb_build_array(
                'north', '123e4567-e89b-12d3-a456-426614174000'),
            'payload', 'ready')) THEN
        RAISE EXCEPTION 'M15 managed action output changed: %', actual;
    END IF;
    SELECT jsonb_object_agg(match ->> 'rule', match -> 'key' ORDER BY match ->> 'rule')
    INTO actual FROM jsonb_array_elements(pgreact_api.matches() -> 'matches') match;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'm15.event_fact', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174000'),
        'm15.pending', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174000'),
        'm15.text', 'north',
        'm15.uuid', '123e4567-e89b-12d3-a456-426614174000') THEN
        RAISE EXCEPTION 'M15 public matches output changed: %', actual;
    END IF;
    actual := pgreact_api.doctor();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 5, 'status', 'ready', 'diagnostics', '[]'::jsonb) THEN
        RAISE EXCEPTION 'M15 doctor output changed: %', actual;
    END IF;
    SELECT jsonb_agg(to_jsonb(fact_row) ORDER BY tenant, event_id)
    INTO actual FROM m15_app.fact fact_row;
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'tenant', 'north', 'event_id', '123e4567-e89b-12d3-a456-426614174000',
        'payload', 'ready')) THEN
        RAISE EXCEPTION 'M15 typed derived fact output changed: %', actual;
    END IF;
    actual := pgreact_api.explain(
        'm15_app.fact', jsonb_build_array(
            'north', '123e4567-e89b-12d3-a456-426614174000'));
    IF actual -> 'target' IS DISTINCT FROM jsonb_build_object(
        'kind', 'fact', 'name', 'm15_app.fact',
        'key', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174000'))
       OR actual #> '{evidence,fact}' IS DISTINCT FROM jsonb_build_object(
            'tenant', 'north', 'event_id', '123e4567-e89b-12d3-a456-426614174000',
            'payload', 'ready') THEN
        RAISE EXCEPTION 'M15 typed explanation output changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE before_identities bigint;
BEGIN
    SELECT count(*) INTO before_identities
    FROM pgreact_internal.semantic_key_identities;
    BEGIN
        INSERT INTO m15_app.events VALUES (
            'north', '123e4567-e89b-12d3-a456-426614174001', 'duplicate');
        PERFORM pgreact_internal.sync_semantic_keys();
        RAISE EXCEPTION 'duplicate fixture unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'M15_KEY_DUPLICATE: key "north" occurs 2 times in m15_app.pending' THEN
            RAISE;
        END IF;
    END;
    BEGIN
        INSERT INTO m15_app.events VALUES (
            NULL, '123e4567-e89b-12d3-a456-426614174002', 'null');
        PERFORM pgreact_internal.sync_semantic_keys();
        RAISE EXCEPTION 'null fixture unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'M15_KEY_NULL: every semantic key component in m15_app.event_fact must be non-null' THEN
            RAISE;
        END IF;
    END;
    IF (SELECT count(*) FROM pgreact_internal.semantic_key_identities) <> before_identities THEN
        RAISE EXCEPTION 'failed key validation partially mutated identity state';
    END IF;
END
$$;

SELECT 'M15 managed runtime and typed-key API gate passed';
