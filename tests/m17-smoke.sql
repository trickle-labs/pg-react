\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm17_author') THEN CREATE ROLE m17_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm17_operator') THEN CREATE ROLE m17_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm17_worker') THEN CREATE ROLE m17_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm17_reader') THEN CREATE ROLE m17_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm17_advanced') THEN CREATE ROLE m17_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm17_author','m17_operator','m17_worker','m17_reader','m17_advanced');
CREATE SCHEMA m17_reference AUTHORIZATION m17_author;
CREATE TYPE m17_reference.fact_row AS (account_id bigint, window_ordinal bigint);
CREATE TABLE m17_reference.groups(account_id bigint PRIMARY KEY);
CREATE TABLE m17_reference.items(
    item_id bigint PRIMARY KEY,
    account_id bigint NOT NULL,
    amount numeric,
    occurred_at timestamptz
);
CREATE VIEW m17_reference.group_source AS SELECT account_id FROM m17_reference.groups;
CREATE VIEW m17_reference.item_source AS
SELECT item_id,account_id,amount,occurred_at FROM m17_reference.items;
ALTER TYPE m17_reference.fact_row OWNER TO m17_author;
ALTER TABLE m17_reference.groups OWNER TO m17_author;
ALTER TABLE m17_reference.items OWNER TO m17_author;
ALTER VIEW m17_reference.group_source OWNER TO m17_author;
ALTER VIEW m17_reference.item_source OWNER TO m17_author;
INSERT INTO m17_reference.groups VALUES (7);

SET SESSION AUTHORIZATION m17_author;
SELECT pgreact_api.declare_derived_relation(
    'm17_reference.count_all_alert','m17_reference.fact_row'::regtype,
    ARRAY['account_id','window_ordinal']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm17_reference.count_amount_alert','m17_reference.fact_row'::regtype,
    ARRAY['account_id','window_ordinal']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm17_reference.max_amount_alert','m17_reference.fact_row'::regtype,
    ARRAY['account_id','window_ordinal']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm17_reference.min_amount_alert','m17_reference.fact_row'::regtype,
    ARRAY['account_id','window_ordinal']::name[]);
SELECT pgreact_api.declare_derived_relation(
    'm17_reference.sum_amount_alert','m17_reference.fact_row'::regtype,
    ARRAY['account_id','window_ordinal']::name[]);
CREATE TABLE m17_reference.definition AS SELECT jsonb_build_object(
    'name','m17.reference','version',1,'max_iterations',8,'max_facts',64,
    'rules',jsonb_build_array(
        jsonb_build_object(
            'name','m17.count_all','definition','m17_reference.group_source',
            'key','account_id','target','m17_reference.count_all_alert','version',1,
            'aggregate_input',jsonb_build_object(
                'relation','m17_reference.item_source','key','account_id',
                'comparison','>=','threshold',2,
                'window',jsonb_build_object('event_time','occurred_at','duration','PT1H',
                                            'allowed_lateness','PT15M'))),
        jsonb_build_object(
            'name','m17.count_amount','definition','m17_reference.group_source',
            'key','account_id','target','m17_reference.count_amount_alert','version',1,
            'aggregate_input',jsonb_build_object(
                'relation','m17_reference.item_source','key','account_id','function','COUNT',
                'expression','amount','comparison','>=','threshold',2,
                'window',jsonb_build_object('event_time','occurred_at','duration','PT1H',
                                            'allowed_lateness','PT15M'))),
        jsonb_build_object(
            'name','m17.max_amount','definition','m17_reference.group_source',
            'key','account_id','target','m17_reference.max_amount_alert','version',1,
            'aggregate_input',jsonb_build_object(
                'relation','m17_reference.item_source','key','account_id','function','MAX',
                'expression','amount','comparison','>=','threshold',8,
                'window',jsonb_build_object('event_time','occurred_at','duration','PT1H',
                                            'allowed_lateness','PT15M'))),
        jsonb_build_object(
            'name','m17.min_amount','definition','m17_reference.group_source',
            'key','account_id','target','m17_reference.min_amount_alert','version',1,
            'aggregate_input',jsonb_build_object(
                'relation','m17_reference.item_source','key','account_id','function','MIN',
                'expression','amount','comparison','<','threshold',5,
                'window',jsonb_build_object('event_time','occurred_at','duration','PT1H',
                                            'allowed_lateness','PT15M'))),
        jsonb_build_object(
            'name','m17.sum_amount','definition','m17_reference.group_source',
            'key','account_id','target','m17_reference.sum_amount_alert','version',1,
            'aggregate_input',jsonb_build_object(
                'relation','m17_reference.item_source','key','account_id','function','SUM',
                'expression','amount','comparison','>=','threshold',10,
                'window',jsonb_build_object('event_time','occurred_at','duration','PT1H',
                                            'allowed_lateness','PT15M'))))) AS definition;
DO $$
DECLARE definition jsonb; preview jsonb;
BEGIN
    SELECT m17_reference.definition.definition INTO definition FROM m17_reference.definition;
    preview := pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition,preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;

INSERT INTO m17_reference.items VALUES
    (1,7,4,'1969-12-31T23:59:59.999999Z'),
    (2,7,6,'1970-01-01T00:00:00Z'),
    (3,7,5,'1970-01-01T00:00:00.000001Z');
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual text;
BEGIN
    SELECT string_agg(format('%s|%s|%s|%s|%s|%s',
        replace(public_window_key::text,' ',''),rule_name,exact_value,
        COALESCE(truth_result::text,'null'),last_correction_identity,
        support_generation), E'\n' ORDER BY window_ordinal,rule_name)
    INTO actual FROM pgreact.window_evidence WHERE program_name='m17.reference';
    IF actual IS DISTINCT FROM E'[7,-1]|m17.count_all|1|false|m17.reference@1/m17.count_all@1/[7,-1]/F1|0\n[7,-1]|m17.count_amount|1|false|m17.reference@1/m17.count_amount@1/[7,-1]/F1|0\n[7,-1]|m17.max_amount|4|false|m17.reference@1/m17.max_amount@1/[7,-1]/F1|0\n[7,-1]|m17.min_amount|4|true|m17.reference@1/m17.min_amount@1/[7,-1]/F1|1\n[7,-1]|m17.sum_amount|4|false|m17.reference@1/m17.sum_amount@1/[7,-1]/F1|0\n[7,0]|m17.count_all|2|true|m17.reference@1/m17.count_all@1/[7,0]/F1|1\n[7,0]|m17.count_amount|2|true|m17.reference@1/m17.count_amount@1/[7,0]/F1|1\n[7,0]|m17.max_amount|6|false|m17.reference@1/m17.max_amount@1/[7,0]/F1|0\n[7,0]|m17.min_amount|5|false|m17.reference@1/m17.min_amount@1/[7,0]/F1|0\n[7,0]|m17.sum_amount|11|true|m17.reference@1/m17.sum_amount@1/[7,0]/F1|1' THEN
        RAISE EXCEPTION 'M17 F1 evidence changed: %', actual;
    END IF;
    SELECT string_agg(format('%s|%s|%s',event_time,window_ordinal,
        format('[%s,%s)',window_start,window_end)), E'\n' ORDER BY event_time)
    INTO actual FROM (
        SELECT DISTINCT source.event_time,identity.window_ordinal,
               identity.window_start,identity.window_end
        FROM pgreact_internal.window_source_rows source
        JOIN pgreact_internal.window_identities identity
          USING(program_version_id,public_window_key)) boundaries;
    IF actual IS DISTINCT FROM E'1969-12-31 23:59:59.999999+00|-1|[1969-12-31 23:00:00+00,1970-01-01 00:00:00+00)\n1970-01-01 00:00:00+00|0|[1970-01-01 00:00:00+00,1970-01-01 01:00:00+00)\n1970-01-01 00:00:00.000001+00|0|[1970-01-01 00:00:00+00,1970-01-01 01:00:00+00)' THEN
        RAISE EXCEPTION 'M17 boundary assignment changed: %', actual;
    END IF;
END
$$;
SELECT 'M17 F1 exact window assignment and aggregate evidence passed';
