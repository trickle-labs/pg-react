\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;

CREATE SCHEMA m15_recovery;
CREATE TABLE m15_recovery.source (
    tenant text COLLATE "C" NOT NULL,
    event_id uuid NOT NULL,
    deadline timestamptz NOT NULL,
    PRIMARY KEY (tenant, event_id)
);
CREATE VIEW m15_recovery.condition AS SELECT * FROM m15_recovery.source;
CREATE TABLE m15_recovery.effects (
    public_key jsonb PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE FUNCTION m15_recovery.activate(row_value m15_recovery.condition)
RETURNS void LANGUAGE SQL AS $$
    INSERT INTO m15_recovery.effects VALUES (
        jsonb_build_array(row_value.tenant, row_value.event_id), row_value.deadline)
$$;
WITH sampled AS (SELECT clock_timestamp() AS now)
INSERT INTO m15_recovery.source
SELECT 'north', '123e4567-e89b-12d3-a456-426614174010'::uuid,
       now - interval '1 minute' FROM sampled
UNION ALL
SELECT 'south', '123e4567-e89b-12d3-a456-426614174011'::uuid,
       now + interval '1 day' FROM sampled;
SELECT pgreact_api.author_deadline_rule(
    'm15.recovery', 'm15_recovery.condition', ARRAY['tenant', 'event_id']::name[],
    'deadline', 'm15_recovery', 'activate') AS version_id \gset
SELECT pgreact_api.run();

CREATE TABLE m15_recovery.control AS
SELECT
    :'version_id'::uuid AS rule_version_id,
    pgreact_api.matches('m15.recovery') AS matches,
    pgreact_api.jobs('m15.recovery') AS jobs,
    pgreact_api.attempts('m15.recovery') AS attempts,
    pgreact_api.deadline_history('m15.recovery') AS history,
    pgreact_api.explain(
        'm15.recovery', '["north","123e4567-e89b-12d3-a456-426614174010"]'::jsonb) AS explanation,
    (SELECT jsonb_agg(jsonb_build_object(
        'semantic_key', semantic_key,
        'canonical_key', encode(canonical_key, 'hex'),
        'public_key', public_key) ORDER BY semantic_key)
     FROM pgreact_internal.semantic_key_identities
     WHERE rule_version_id = :'version_id'::uuid) AS identities;
CHECKPOINT;

SELECT 'M15 typed recovery setup passed';
