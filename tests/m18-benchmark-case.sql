\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = error;

DROP SCHEMA IF EXISTS m18_bench CASCADE;
CREATE SCHEMA m18_bench;
CREATE TABLE m18_bench.config(rules integer, facts integer, batch integer,
                              workers integer, windows integer, watermark integer);
INSERT INTO m18_bench.config VALUES
    (:'rules', :'facts', :'batch', :'workers', :'windows', :'watermark');
CREATE TABLE m18_bench.facts(
    id bigint PRIMARY KEY, account_id bigint NOT NULL, amount integer NOT NULL,
    occurred_at timestamptz NOT NULL);
INSERT INTO m18_bench.facts
SELECT id, CASE WHEN id <= :'windows' THEN id ELSE 0 END, 1,
       '2000-01-01 UTC'::timestamptz + ((id - 1) / 1000) * interval '1 hour'
FROM generate_series(1, :'facts') id;
CREATE TABLE m18_bench.rule_facts(
    id bigint PRIMARY KEY, account_id bigint NOT NULL, amount integer NOT NULL,
    occurred_at timestamptz NOT NULL, active boolean NOT NULL DEFAULT false);
INSERT INTO m18_bench.rule_facts
SELECT id, 1, 1, '1999-01-01 UTC'::timestamptz FROM generate_series(1, :'batch') id;
CREATE INDEX ON m18_bench.rule_facts(id) WHERE active;
CREATE VIEW m18_bench.active_fact AS
SELECT id, account_id, amount, occurred_at FROM m18_bench.rule_facts WHERE active;
CREATE TABLE m18_bench.worker_facts(
    id bigint PRIMARY KEY, account_id bigint NOT NULL, amount integer NOT NULL,
    occurred_at timestamptz NOT NULL);
CREATE VIEW m18_bench.worker_fact AS SELECT * FROM m18_bench.worker_facts;
CREATE TABLE m18_bench.effects(episode_id bigint PRIMARY KEY, fact_id bigint NOT NULL);
CREATE FUNCTION m18_bench.activate(
    context pgreact.activation_context, row_value m18_bench.worker_fact)
RETURNS void LANGUAGE SQL AS $body$
    INSERT INTO m18_bench.effects VALUES (($1).episode_id, ($2).id)
$body$;

SELECT pgreact_api.author_rule(
    'm18.benchmark.command', 'm18_bench.worker_fact'::regclass, 'id', 'COMMAND',
    'm18_bench.activate(pgreact.activation_context,m18_bench.worker_fact)');
SELECT pgreact_api.author_rule(
    format('m18.benchmark.constraint.%s', n), 'm18_bench.active_fact'::regclass,
    'id', 'CONSTRAINT')
FROM generate_series(2, :'rules') n;

CREATE UNLOGGED TABLE m18_bench.samples(kind text, milliseconds numeric, items integer);
CREATE FUNCTION m18_bench.update_batch(iteration integer) RETURNS void
LANGUAGE plpgsql AS $body$
DECLARE started timestamptz := clock_timestamp(); n integer;
BEGIN
    SELECT batch INTO n FROM m18_bench.config;
    UPDATE m18_bench.rule_facts SET active = (iteration % 2 = 1) WHERE id <= n;
    PERFORM pgreact_api.run('2030-01-01 UTC'::timestamptz + iteration * interval '1 second');
    INSERT INTO m18_bench.samples VALUES
        ('update', extract(epoch FROM clock_timestamp() - started) * 1000, n);
END
$body$;
CREATE FUNCTION m18_bench.work(worker text) RETURNS integer
LANGUAGE plpgsql AS $body$
DECLARE claimed record; started timestamptz; processed integer; total integer := 0;
BEGIN
    LOOP
        started := clock_timestamp(); processed := 0;
        FOR claimed IN SELECT * FROM pgreact_api.claim(worker, 32, interval '60 seconds')
        LOOP
            PERFORM pgreact_api.execute(claimed.episode_id, worker, claimed.lease_token);
            processed := processed + 1;
        END LOOP;
        EXIT WHEN processed = 0;
        INSERT INTO m18_bench.samples VALUES
            ('worker', extract(epoch FROM clock_timestamp() - started) * 1000, processed);
        total := total + processed;
    END LOOP;
    RETURN total;
END
$body$;
