\set ON_ERROR_STOP on

CREATE SCHEMA m7_concurrency;
CREATE TYPE m7_concurrency.derived_row AS (id bigint);
CREATE TABLE m7_concurrency.source (id bigint PRIMARY KEY);
CREATE VIEW m7_concurrency.source_active AS SELECT id FROM m7_concurrency.source;
SELECT pgreact.create_derived_relation(
    'm7_concurrency.current_fact', 'm7_concurrency.derived_row'::regtype,
    ARRAY['id'], 1
) AS relation_version_id \gset
SELECT pgreact.create_derivation_rule(
    'm7-concurrency-derivation', 'm7_concurrency.source_active'::regclass,
    ARRAY['id'], :'relation_version_id'::uuid, 1
) AS derivation_version_id \gset
CREATE VIEW m7_concurrency.observe_fact AS
SELECT id FROM m7_concurrency.current_fact;
SELECT pgreact.create_rule(
    'm7-concurrency-observer', 'm7_concurrency.observe_fact'::regclass,
    ARRAY['id'], 'CONSTRAINT'
) AS observer_version_id \gset
CREATE TABLE m7_concurrency.control AS
SELECT :'relation_version_id'::uuid AS relation_version_id,
       :'derivation_version_id'::uuid AS derivation_version_id,
       :'observer_version_id'::uuid AS observer_version_id;
INSERT INTO m7_concurrency.source VALUES (1);
SELECT pgreact.refresh_derived_relation(:'relation_version_id'::uuid);
SELECT pgreact.refresh_rule(:'observer_version_id'::uuid);

SELECT 'M7 concurrency setup passed' AS result;
