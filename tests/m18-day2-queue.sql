\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = error;

CREATE SCHEMA m18_day2 AUTHORIZATION m17_author;
SET SESSION AUTHORIZATION m17_author;
CREATE TABLE m18_day2.source(id bigint PRIMARY KEY, active boolean NOT NULL);
CREATE VIEW m18_day2.pending AS SELECT id FROM m18_day2.source WHERE active;
CREATE TABLE m18_day2.effects(id bigint PRIMARY KEY);
CREATE FUNCTION m18_day2.slow_activate(row_value m18_day2.pending)
RETURNS void LANGUAGE SQL AS $$
    WITH waited AS (SELECT pg_sleep(20))
    INSERT INTO m18_day2.effects SELECT row_value.id FROM waited
$$;
SELECT pgreact_api.author_rule(
    'day2.slow-command', 'm18_day2.pending', ARRAY['id']::name[],
    'm18_day2', 'slow_activate');
RESET SESSION AUTHORIZATION;
INSERT INTO m18_day2.source VALUES (1, true);
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run('2030-01-04T00:00:10Z');
RESET SESSION AUTHORIZATION;
