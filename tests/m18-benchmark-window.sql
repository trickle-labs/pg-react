\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = error;

CREATE TYPE m18_bench.window_fact AS (account_id bigint, window_ordinal bigint);
CREATE TABLE m18_bench.groups(account_id bigint PRIMARY KEY);
INSERT INTO m18_bench.groups SELECT generate_series(1, (SELECT windows FROM m18_bench.config));
CREATE TABLE m18_bench.window_control(enabled boolean NOT NULL);
INSERT INTO m18_bench.window_control VALUES (true);
CREATE VIEW m18_bench.group_source AS
SELECT account_id FROM m18_bench.groups
WHERE (SELECT enabled FROM m18_bench.window_control);
CREATE VIEW m18_bench.item_source AS
SELECT id, account_id, amount, occurred_at FROM m18_bench.facts
WHERE id <= (SELECT windows FROM m18_bench.config)
  AND (SELECT enabled FROM m18_bench.window_control);
SELECT pgreact_api.declare_derived_relation(
    'm18_bench.window_alert', 'm18_bench.window_fact'::regtype,
    ARRAY['account_id','window_ordinal']::name[]);
DO $body$
DECLARE definition jsonb; preview jsonb; fact_limit integer;
BEGIN
    SELECT facts * 3 INTO fact_limit FROM m18_bench.config;
    definition := jsonb_build_object(
        'name','m18.benchmark.windows','version',1,'max_iterations',8,
        'max_facts',fact_limit,'rules',jsonb_build_array(jsonb_build_object(
            'name','m18.benchmark.window','definition','m18_bench.group_source',
            'key','account_id','target','m18_bench.window_alert','version',1,
            'aggregate_input',jsonb_build_object(
                'relation','m18_bench.item_source','key','account_id','function','COUNT',
                'expression','amount','comparison','>=','threshold',1,
                'window',jsonb_build_object('event_time','occurred_at','duration','PT1H',
                                            'allowed_lateness','PT15M')))));
    preview := pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition, preview ->> 'plan_digest');
END
$body$;
SELECT pgreact_api.run('2030-01-01T00:02:00Z');
