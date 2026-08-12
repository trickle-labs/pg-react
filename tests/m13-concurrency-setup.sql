\set ON_ERROR_STOP on
CREATE SCHEMA m13_concurrency;
CREATE TABLE m13_concurrency.source (id bigint PRIMARY KEY);
CREATE VIEW m13_concurrency.condition AS SELECT id FROM m13_concurrency.source;
CREATE FUNCTION m13_concurrency.activate(candidate m13_concurrency.condition)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
SELECT pgreact_api.author_rule(
    rule_name => 'concurrent-rule',
    condition => 'm13_concurrency.condition'::regclass,
    semantic_key => 'id',
    action_schema => 'm13_concurrency',
    on_activate => 'activate');
INSERT INTO m13_concurrency.source VALUES (1);
