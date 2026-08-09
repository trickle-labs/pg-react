\set ON_ERROR_STOP on

CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
CREATE SCHEMA m6_entry;

CREATE TABLE m6_entry.facts (
    id bigint PRIMARY KEY
);

CREATE TABLE m6_entry.effects (
    episode_id bigint PRIMARY KEY,
    fact_id bigint NOT NULL
);

CREATE VIEW m6_entry.active_fact AS
SELECT id FROM m6_entry.facts;

CREATE FUNCTION m6_entry.record_fact(
    context pgreact.activation_context,
    match m6_entry.active_fact
) RETURNS void
LANGUAGE SQL
AS 'INSERT INTO m6_entry.effects VALUES (($1).episode_id, ($2).id)';

SELECT pgreact.create_rule(
    'm6-entry',
    'm6_entry.active_fact'::regclass,
    ARRAY['id'],
    'COMMAND',
    'm6_entry.record_fact(pgreact.activation_context,m6_entry.active_fact)'::regprocedure
) AS rule_version_id \gset
SELECT pgreact.declare_batch_safe(:'rule_version_id'::uuid, 'ACTIVATE');

CREATE TABLE m6_entry.benchmark (
    rule_version_id uuid PRIMARY KEY,
    refresh_milliseconds numeric NOT NULL
);

INSERT INTO m6_entry.benchmark
VALUES (:'rule_version_id'::uuid, -extract(epoch FROM clock_timestamp()) * 1000);

SELECT
    format('INSERT INTO m6_entry.facts SELECT generate_series(%s, %s)', batch * 128 + 1, (batch + 1) * 128),
    format('SELECT pgreact.begin_refresh(%L::uuid, %s)', :'rule_version_id', 6000 + batch),
    'BEGIN ISOLATION LEVEL READ COMMITTED',
    format('SELECT pgreact.refresh_rule(%L::uuid)', :'rule_version_id'),
    'COMMIT',
    format('SELECT pgreact.clear_refresh_barrier(%L::uuid)', :'rule_version_id'),
    'SELECT pgreact.release_refresh_lock()'
FROM generate_series(0, 63) AS batch
\gexec

UPDATE m6_entry.benchmark
SET refresh_milliseconds = refresh_milliseconds + extract(epoch FROM clock_timestamp()) * 1000;

CREATE FUNCTION m6_entry.execute_one()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE claimed record;
BEGIN
    SELECT * INTO claimed
    FROM pgreact.claim_episode(
        (SELECT rule_version_id FROM m6_entry.benchmark),
        'm6-entry-single',
        60
    );
    IF NOT FOUND THEN
        RETURN 0;
    END IF;
    PERFORM pgreact.execute_claimed_episode(
        claimed.episode_id,
        'm6-entry-single',
        claimed.lease_token
    );
    RETURN 1;
END
$$;

CREATE FUNCTION m6_entry.execute_audited_batch(batch_size integer DEFAULT 32)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE target_batch uuid; completed integer;
BEGIN
    SELECT batch_id INTO target_batch FROM pgreact.claim_batch(
        (SELECT rule_version_id FROM m6_entry.benchmark),
        'ACTIVATE', 'm6-benchmark-batch', batch_size
    ) ORDER BY item_order LIMIT 1;
    IF target_batch IS NULL THEN RETURN 0; END IF;
    SELECT count(*) INTO completed
    FROM pgreact.execute_claimed_batch(target_batch, 'm6-benchmark-batch');
    RETURN completed;
END
$$;

SELECT jsonb_build_object(
    'episodes', (SELECT count(*) FROM pgreact.episodes),
    'refresh_milliseconds', refresh_milliseconds,
    'consequence', 'commutative idempotent insert keyed by episode_id',
    'audited_batch_size', 32
) AS m6_entry_workload
FROM m6_entry.benchmark;
