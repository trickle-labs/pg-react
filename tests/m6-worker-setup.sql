\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA m6_worker;
CREATE TABLE m6_worker.facts (id bigint PRIMARY KEY, value text NOT NULL);
CREATE TABLE m6_worker.effects (
    episode_id bigint PRIMARY KEY,
    event_kind text NOT NULL,
    fact_id bigint NOT NULL,
    old_value text,
    new_value text
);
CREATE TABLE m6_worker.control (rule_version_id uuid PRIMARY KEY);
CREATE VIEW m6_worker.active_fact AS SELECT id, value FROM m6_worker.facts;
CREATE FUNCTION m6_worker.on_activate(
    context pgreact.activation_context, match m6_worker.active_fact
) RETURNS void LANGUAGE SQL AS
'INSERT INTO m6_worker.effects VALUES (($1).episode_id, ($1).event_kind, ($2).id, NULL, ($2).value)';
CREATE FUNCTION m6_worker.on_change(
    context pgreact.activation_context,
    old_match m6_worker.active_fact,
    new_match m6_worker.active_fact
) RETURNS void LANGUAGE SQL AS
'INSERT INTO m6_worker.effects VALUES (($1).episode_id, ($1).event_kind, ($2).id, ($2).value, ($3).value)';
CREATE FUNCTION m6_worker.on_deactivate(
    context pgreact.activation_context, match m6_worker.active_fact
) RETURNS void LANGUAGE SQL AS
'INSERT INTO m6_worker.effects VALUES (($1).episode_id, ($1).event_kind, ($2).id, ($2).value, NULL)';

SELECT pgreact.create_rule(
    name => 'm6-worker', definition => 'm6_worker.active_fact'::regclass,
    key_columns => ARRAY['id'], kind => 'COMMAND',
    on_activate => 'm6_worker.on_activate(pgreact.activation_context,m6_worker.active_fact)'::regprocedure,
    on_deactivate => 'm6_worker.on_deactivate(pgreact.activation_context,m6_worker.active_fact)'::regprocedure,
    on_change => 'm6_worker.on_change(pgreact.activation_context,m6_worker.active_fact,m6_worker.active_fact)'::regprocedure,
    change_columns => ARRAY['value']
) AS rule_version_id \gset
INSERT INTO m6_worker.control VALUES (:'rule_version_id'::uuid);
SELECT pgreact.declare_batch_safe(:'rule_version_id'::uuid, event_kind)
FROM unnest(ARRAY['ACTIVATE', 'CHANGE', 'DEACTIVATE']) AS event_kind;
INSERT INTO m6_worker.facts VALUES (1, 'a'), (2, 'b');

SELECT 'M6 protocol-2 worker setup passed' AS result;
