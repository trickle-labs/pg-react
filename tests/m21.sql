\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = warning;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm21_author') THEN CREATE ROLE m21_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm21_operator') THEN CREATE ROLE m21_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm21_worker') THEN CREATE ROLE m21_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm21_reader') THEN CREATE ROLE m21_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm21_advanced') THEN CREATE ROLE m21_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles('m21_author','m21_operator','m21_worker','m21_reader','m21_advanced');
GRANT USAGE ON SCHEMA pgtrickle TO m21_author;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.retention_status();
    IF actual ->> 'contract_version' <> '9'
       OR (actual #>> '{policy,enabled}') <> 'false' THEN
        RAISE EXCEPTION 'M21 default policy changed: %', actual;
    END IF;
END
$$;

SET SESSION AUTHORIZATION m21_reader;
DO $$
BEGIN
    BEGIN
        PERFORM pgreact_api.retention_preview(clock_timestamp() - interval '1 hour');
        RAISE EXCEPTION 'M21 reader preview was authorized';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    IF (pgreact_api.retention_metrics() ->> 'contract_version') <> '9'
       OR (pgreact_api.retention_doctor() ->> 'status') <> 'ready' THEN
        RAISE EXCEPTION 'M21 reader diagnosis changed';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

CREATE SCHEMA m21_app AUTHORIZATION m21_author;
CREATE TABLE m21_app.source(id bigint PRIMARY KEY, enabled boolean NOT NULL);
ALTER TABLE m21_app.source OWNER TO m21_author;
CREATE VIEW m21_app.active AS SELECT id FROM m21_app.source WHERE enabled;
ALTER VIEW m21_app.active OWNER TO m21_author;
SET SESSION AUTHORIZATION m21_author;
SELECT pgreact_api.author_rule(
    rule_name => 'm21.live', condition => 'm21_app.active'::regclass,
    semantic_key => 'id', kind => 'CONSTRAINT');
RESET SESSION AUTHORIZATION;
INSERT INTO m21_app.source VALUES (1, true);
SET SESSION AUTHORIZATION m21_operator;
SELECT pgreact_api.run('2030-01-01T00:00:00Z');
RESET SESSION AUTHORIZATION;

UPDATE pgreact_internal.lifecycle_events event
SET transitioned_at = '1970-01-01T00:00:00Z'
FROM pgreact_internal.rules rule
WHERE event.rule_id = rule.rule_id AND rule.rule_name = 'm21.live';
INSERT INTO pgreact_internal.runtime_events(severity,event_type,detail)
VALUES ('INFO','M21_TEST_1','{"n":1}'), ('INFO','M21_TEST_2','{"n":2}'), ('INFO','M21_TEST_3','{"n":3}');

SELECT pgreact_api.retention_configure(
    '0 seconds','0 seconds','0 seconds','0 seconds','0 seconds','0 seconds','0 seconds','0 seconds',true);

DO $$
DECLARE actual jsonb; runtime jsonb; lifecycle jsonb;
BEGIN
    actual := pgreact_api.retention_preview(clock_timestamp() - interval '1 minute', 1);
    SELECT value INTO runtime FROM jsonb_array_elements(actual -> 'families') value
    WHERE value ->> 'family' = 'runtime_events';
    SELECT value INTO lifecycle FROM jsonb_array_elements(actual -> 'families') value
    WHERE value ->> 'family' = 'lifecycle_events';
    IF (runtime ->> 'eligible_rows')::bigint <> 3
       OR (lifecycle ->> 'protected_rows')::bigint < 1
       OR (lifecycle #>> '{blocking_reasons,active_state}')::bigint < 1
       OR (actual #>> '{policy,enabled}') <> 'true' THEN
        RAISE EXCEPTION 'M21 preview changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.retention_apply(clock_timestamp() - interval '1 minute', 1);
    IF actual ->> 'outcome' <> 'partial'
       OR (actual #>> '{family_counts,runtime_events}') <> '1'
       OR (actual ->> 'removed_rows')::bigint < 1 THEN
        RAISE EXCEPTION 'M21 bounded apply changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.retention_apply(clock_timestamp() - interval '1 minute', 10);

DO $$
DECLARE actual jsonb; audit jsonb; detail jsonb; active_count bigint; event_count bigint; runtime_ids jsonb; batch_states jsonb;
BEGIN
    actual := pgreact_api.retention_apply(clock_timestamp() - interval '1 minute', 10);
    SELECT count(*) INTO active_count FROM m21_app.active;
    SELECT count(*) INTO event_count FROM pgreact_internal.runtime_events WHERE event_type LIKE 'M21_TEST_%';
    audit := pgreact_api.retention_audit(10);
    detail := pgreact_api.retention_detail('runtime_events','1');
    SELECT COALESCE(jsonb_agg(item.value ->> 'historical_identity' ORDER BY (item.value ->> 'historical_identity')::integer DESC), '[]'::jsonb)
    INTO runtime_ids FROM jsonb_array_elements(audit -> 'tombstones') item
    WHERE item.value ->> 'family' = 'runtime_events';
    SELECT jsonb_agg(item.value ->> 'state' ORDER BY item.ordinality)
    INTO batch_states FROM jsonb_array_elements(audit -> 'batches') WITH ORDINALITY item;
    IF actual ->> 'outcome' <> 'NOOP' OR active_count <> 1 OR event_count <> 0
       OR runtime_ids <> '["3","2","1"]'::jsonb OR batch_states <> '["COMPLETED","PARTIAL"]'::jsonb
       OR detail ->> 'retained' <> 'false'
       OR (detail #>> '{diagnostic,code}') <> 'M21_HISTORY_NOT_RETAINED' THEN
        RAISE EXCEPTION 'M21 idempotence, audit, or truth preservation changed: % / % / % / % / %',
            actual, active_count, event_count, runtime_ids, batch_states;
    END IF;
END
$$;

SELECT 'M21 audited retention, dependency protection, bounded apply, idempotence, security, and truth-preservation gate passed';
