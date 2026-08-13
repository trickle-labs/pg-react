\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m15_lifecycle AUTHORIZATION m15_author;
CREATE TABLE m15_lifecycle.source (
    tenant text COLLATE "C" NOT NULL,
    event_id uuid NOT NULL,
    payload text NOT NULL,
    PRIMARY KEY (tenant, event_id)
);
CREATE VIEW m15_lifecycle.condition AS SELECT * FROM m15_lifecycle.source;
CREATE TABLE m15_lifecycle.log (
    log_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event text NOT NULL,
    public_key jsonb NOT NULL,
    payload text NOT NULL
);
CREATE FUNCTION m15_lifecycle.activate(row_value m15_lifecycle.condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m15_lifecycle.log(event, public_key, payload)
    VALUES ('activate', jsonb_build_array(row_value.tenant, row_value.event_id), row_value.payload)
$$;
CREATE FUNCTION m15_lifecycle.deactivate(row_value m15_lifecycle.condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m15_lifecycle.log(event, public_key, payload)
    VALUES ('deactivate', jsonb_build_array(row_value.tenant, row_value.event_id), row_value.payload)
$$;
CREATE FUNCTION m15_lifecycle.change(
    old_row m15_lifecycle.condition, new_row m15_lifecycle.condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m15_lifecycle.log(event, public_key, payload)
    VALUES ('change', jsonb_build_array(new_row.tenant, new_row.event_id),
            old_row.payload || '->' || new_row.payload)
$$;
ALTER TABLE m15_lifecycle.source OWNER TO m15_author;
ALTER VIEW m15_lifecycle.condition OWNER TO m15_author;
ALTER TABLE m15_lifecycle.log OWNER TO m15_author;
ALTER FUNCTION m15_lifecycle.activate(m15_lifecycle.condition) OWNER TO m15_author;
ALTER FUNCTION m15_lifecycle.deactivate(m15_lifecycle.condition) OWNER TO m15_author;
ALTER FUNCTION m15_lifecycle.change(m15_lifecycle.condition,m15_lifecycle.condition) OWNER TO m15_author;

SET SESSION AUTHORIZATION m15_author;
SELECT pgreact_api.author_rule(
    'm15.lifecycle', 'm15_lifecycle.condition', ARRAY['tenant', 'event_id']::name[],
    'm15_lifecycle', 'activate', 'deactivate', 'change');
RESET SESSION AUTHORIZATION;
INSERT INTO m15_lifecycle.source VALUES (
    'north', '123e4567-e89b-12d3-a456-426614174020', 'first');
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;
UPDATE m15_lifecycle.source SET payload = 'second';
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;
DELETE FROM m15_lifecycle.source;
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(to_jsonb(entry) - 'log_id' ORDER BY log_id)
    INTO actual FROM m15_lifecycle.log entry;
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('event', 'activate',
            'public_key', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174020'),
            'payload', 'first'),
        jsonb_build_object('event', 'change',
            'public_key', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174020'),
            'payload', 'first->second'),
        jsonb_build_object('event', 'deactivate',
            'public_key', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174020'),
            'payload', 'second'))
       OR (SELECT jsonb_agg((job - ARRAY[
                'job_id', 'available_at', 'claimed_at', 'completed_at', 'idempotency_key'])
                ORDER BY job ->> 'job_id')
           FROM jsonb_array_elements(pgreact_api.jobs('m15.lifecycle') -> 'jobs') job)
          IS DISTINCT FROM jsonb_build_array(
            jsonb_build_object('rule', 'm15.lifecycle', 'action', 'activate', 'state', 'completed',
                'key', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174020')),
            jsonb_build_object('rule', 'm15.lifecycle', 'action', 'change', 'state', 'completed',
                'key', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174020')),
            jsonb_build_object('rule', 'm15.lifecycle', 'action', 'deactivate', 'state', 'completed',
                'key', jsonb_build_array('north', '123e4567-e89b-12d3-a456-426614174020'))) THEN
        RAISE EXCEPTION 'M15 typed lifecycle changed: %', actual;
    END IF;
END
$$;

CREATE SEQUENCE m15_lifecycle.retry_sequence;
CREATE TABLE m15_lifecycle.retry_source (
    tenant text COLLATE "C" NOT NULL,
    event_id uuid NOT NULL,
    PRIMARY KEY (tenant, event_id)
);
CREATE VIEW m15_lifecycle.retry_condition AS SELECT * FROM m15_lifecycle.retry_source;
CREATE TABLE m15_lifecycle.retry_effects (public_key jsonb PRIMARY KEY);
CREATE FUNCTION m15_lifecycle.retry(row_value m15_lifecycle.retry_condition)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF nextval('m15_lifecycle.retry_sequence') = 1 THEN
        RAISE EXCEPTION 'transient typed failure';
    END IF;
    INSERT INTO m15_lifecycle.retry_effects
    VALUES (jsonb_build_array(row_value.tenant, row_value.event_id));
END
$$;
ALTER SEQUENCE m15_lifecycle.retry_sequence OWNER TO m15_author;
ALTER TABLE m15_lifecycle.retry_source OWNER TO m15_author;
ALTER VIEW m15_lifecycle.retry_condition OWNER TO m15_author;
ALTER TABLE m15_lifecycle.retry_effects OWNER TO m15_author;
ALTER FUNCTION m15_lifecycle.retry(m15_lifecycle.retry_condition) OWNER TO m15_author;
SET SESSION AUTHORIZATION m15_author;
SELECT pgreact_api.author_rule(
    'm15.retry', 'm15_lifecycle.retry_condition', ARRAY['tenant', 'event_id']::name[],
    'm15_lifecycle', 'retry');
RESET SESSION AUTHORIZATION;
INSERT INTO m15_lifecycle.retry_source VALUES (
    'retry', '123e4567-e89b-12d3-a456-426614174021');
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
SELECT pg_sleep(1.1);
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;

DO $$
DECLARE actual jsonb; job_id bigint;
BEGIN
    SELECT (job ->> 'job_id')::bigint INTO STRICT job_id
    FROM jsonb_array_elements(pgreact_api.jobs('m15.retry') -> 'jobs') job;
    SELECT jsonb_agg(attempt - ARRAY['started_at', 'finished_at', 'worker'] ORDER BY attempt ->> 'attempt')
    INTO actual FROM jsonb_array_elements(pgreact_api.attempts('m15.retry') -> 'attempts') attempt;
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('job_id', job_id, 'attempt', 1, 'status', 'retry_wait',
            'error_code', 'P0001', 'error_message', 'transient typed failure',
            'key', jsonb_build_array('retry', '123e4567-e89b-12d3-a456-426614174021')),
        jsonb_build_object('job_id', job_id, 'attempt', 2, 'status', 'completed',
            'error_code', NULL, 'error_message', NULL,
            'key', jsonb_build_array('retry', '123e4567-e89b-12d3-a456-426614174021')))
       OR NOT EXISTS (SELECT 1 FROM m15_lifecycle.retry_effects WHERE public_key =
            jsonb_build_array('retry', '123e4567-e89b-12d3-a456-426614174021')) THEN
        RAISE EXCEPTION 'M15 typed retry history changed: %', actual;
    END IF;
END
$$;

CREATE TABLE m15_lifecycle.deadline_source (
    tenant text COLLATE "C" NOT NULL,
    event_id uuid NOT NULL,
    deadline timestamptz NOT NULL,
    PRIMARY KEY (tenant, event_id)
);
CREATE VIEW m15_lifecycle.deadline_condition AS SELECT * FROM m15_lifecycle.deadline_source;
CREATE TABLE m15_lifecycle.deadline_effects (public_key jsonb PRIMARY KEY);
CREATE FUNCTION m15_lifecycle.deadline(row_value m15_lifecycle.deadline_condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m15_lifecycle.deadline_effects
    VALUES (jsonb_build_array(row_value.tenant, row_value.event_id))
$$;
ALTER TABLE m15_lifecycle.deadline_source OWNER TO m15_author;
ALTER VIEW m15_lifecycle.deadline_condition OWNER TO m15_author;
ALTER TABLE m15_lifecycle.deadline_effects OWNER TO m15_author;
ALTER FUNCTION m15_lifecycle.deadline(m15_lifecycle.deadline_condition) OWNER TO m15_author;
SET SESSION AUTHORIZATION m15_author;
SELECT pgreact_api.author_deadline_rule(
    'm15.deadline', 'm15_lifecycle.deadline_condition', ARRAY['tenant', 'event_id']::name[],
    'deadline', 'm15_lifecycle', 'deadline');
RESET SESSION AUTHORIZATION;
INSERT INTO m15_lifecycle.deadline_source VALUES (
    'due', '123e4567-e89b-12d3-a456-426614174022', clock_timestamp() - interval '1 minute');
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
SELECT pgreact_api.reconcile_rule('m15.deadline');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;

DO $$
BEGIN
    IF pgreact_api.deadline_history('m15.deadline') #> '{events,0,semantic_key}'
       IS DISTINCT FROM jsonb_build_array('due', '123e4567-e89b-12d3-a456-426614174022')
       OR pgreact_api.jobs('m15.deadline') #> '{jobs,0,key}'
          IS DISTINCT FROM jsonb_build_array('due', '123e4567-e89b-12d3-a456-426614174022')
       OR NOT EXISTS (SELECT 1 FROM m15_lifecycle.deadline_effects WHERE public_key =
            jsonb_build_array('due', '123e4567-e89b-12d3-a456-426614174022')) THEN
        RAISE EXCEPTION 'M15 typed deadline or reconciliation changed';
    END IF;
END
$$;

SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.pause_rule('m15.lifecycle');
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_author;
SELECT pgreact_api.replace_rule(
    'm15.lifecycle', 'm15_lifecycle.condition', ARRAY['tenant', 'event_id']::name[],
    'm15_lifecycle', 'activate', 'deactivate', 'change');
RESET SESSION AUTHORIZATION;
INSERT INTO m15_lifecycle.source VALUES (
    'south', '123e4567-e89b-12d3-a456-426614174023', 'replacement');
SET SESSION AUTHORIZATION m15_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;

DO $$
BEGIN
    IF pgreact_api.matches('m15.lifecycle') #> '{matches,0,key}'
       IS DISTINCT FROM jsonb_build_array('south', '123e4567-e89b-12d3-a456-426614174023')
       OR pgreact_api.status('m15.lifecycle') #> '{rules,0,key}'
          IS DISTINCT FROM jsonb_build_array('tenant', 'event_id')
       OR (SELECT count(*) FROM m15_lifecycle.log WHERE event = 'activate' AND payload = 'replacement') <> 1 THEN
        RAISE EXCEPTION 'M15 typed replacement changed';
    END IF;
END
$$;

SELECT 'M15 typed lifecycle, retry, deadline, reconciliation, and replacement gate passed';
