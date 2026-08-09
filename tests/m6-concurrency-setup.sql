\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA m6_concurrency;
CREATE TABLE m6_concurrency.facts (id bigint PRIMARY KEY);
CREATE TABLE m6_concurrency.effects (episode_id bigint PRIMARY KEY, fact_id bigint NOT NULL);
CREATE TABLE m6_concurrency.control (
    rule_version_id uuid PRIMARY KEY,
    batch_id uuid NOT NULL,
    sleep_enabled boolean NOT NULL
);
CREATE VIEW m6_concurrency.active_fact AS SELECT id FROM m6_concurrency.facts;
CREATE FUNCTION m6_concurrency.apply_fact(
    context pgreact.activation_context, match m6_concurrency.active_fact
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT sleep_enabled FROM m6_concurrency.control) THEN
        PERFORM pg_sleep(30);
    END IF;
    INSERT INTO m6_concurrency.effects VALUES (context.episode_id, match.id);
END
$$;
SELECT pgreact.create_rule(
    name => 'm6-concurrency', definition => 'm6_concurrency.active_fact'::regclass,
    key_columns => ARRAY['id'], kind => 'COMMAND',
    on_activate => 'm6_concurrency.apply_fact(pgreact.activation_context,m6_concurrency.active_fact)'::regprocedure
) AS rule_version_id \gset
SELECT pgreact.declare_batch_safe(:'rule_version_id'::uuid, 'ACTIVATE');
INSERT INTO m6_concurrency.facts VALUES (1), (2);
SELECT pgreact.begin_refresh(:'rule_version_id'::uuid, 6301);
BEGIN; SELECT pgreact.refresh_rule(:'rule_version_id'::uuid); COMMIT;
SELECT pgreact.clear_refresh_barrier(:'rule_version_id'::uuid);
SELECT pgreact.release_refresh_lock();
CREATE TEMP TABLE claimed AS
SELECT * FROM pgreact.claim_batch(:'rule_version_id'::uuid, 'ACTIVATE', 'm6-concurrency', 2);
SELECT batch_id::text AS batch_id FROM claimed ORDER BY item_order LIMIT 1 \gset
INSERT INTO m6_concurrency.control VALUES (:'rule_version_id'::uuid, :'batch_id'::uuid, true);

SELECT 'M6 concurrency setup passed' AS result;
