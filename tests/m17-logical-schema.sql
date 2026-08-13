\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='m17_author') THEN CREATE ROLE m17_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='m17_operator') THEN CREATE ROLE m17_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='m17_worker') THEN CREATE ROLE m17_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='m17_reader') THEN CREATE ROLE m17_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='m17_advanced') THEN CREATE ROLE m17_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm17_author','m17_operator','m17_worker','m17_reader','m17_advanced');
CREATE SCHEMA m17_reference AUTHORIZATION m17_author;
GRANT USAGE ON SCHEMA m17_reference TO m17_operator;
CREATE TYPE m17_reference.fact_row AS (account_id bigint,window_ordinal bigint);
CREATE TABLE m17_reference.groups(account_id bigint PRIMARY KEY);
CREATE TABLE m17_reference.items(
    item_id bigint PRIMARY KEY,account_id bigint NOT NULL,amount numeric,occurred_at timestamptz);
CREATE VIEW m17_reference.group_source AS SELECT account_id FROM m17_reference.groups;
CREATE VIEW m17_reference.item_source AS
SELECT item_id,account_id,amount,occurred_at FROM m17_reference.items;
CREATE TABLE m17_reference.definition(definition jsonb NOT NULL);
CREATE TABLE m17_reference.logical_export(state jsonb NOT NULL);
ALTER TYPE m17_reference.fact_row OWNER TO m17_author;
ALTER TABLE m17_reference.groups OWNER TO m17_author;
ALTER TABLE m17_reference.items OWNER TO m17_author;
ALTER TABLE m17_reference.definition OWNER TO m17_author;
ALTER TABLE m17_reference.logical_export OWNER TO m17_author;
GRANT SELECT ON m17_reference.logical_export TO m17_operator;
ALTER VIEW m17_reference.group_source OWNER TO m17_author;
ALTER VIEW m17_reference.item_source OWNER TO m17_author;
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
RESET SESSION AUTHORIZATION;
