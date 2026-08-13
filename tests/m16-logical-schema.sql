\set ON_ERROR_STOP on
SELECT pgreact_api.configure_roles(
    'm16_author', 'm16_operator', 'm16_worker', 'm16_reader', 'm16_advanced');
CREATE SCHEMA m16 AUTHORIZATION m16_author;
CREATE TYPE m16.fact_row AS (id bigint);
CREATE TABLE m16.groups (id bigint PRIMARY KEY);
CREATE TABLE m16.items (
    item_id bigint PRIMARY KEY,
    id bigint NOT NULL,
    units integer,
    amount numeric,
    label text COLLATE "C",
    occurred_on date,
    overflow_value real
);
CREATE VIEW m16.group_source AS SELECT id FROM m16.groups;
CREATE VIEW m16.item_source AS
SELECT id, units, amount, label, occurred_on, overflow_value FROM m16.items;
ALTER TYPE m16.fact_row OWNER TO m16_author;
ALTER TABLE m16.groups OWNER TO m16_author;
ALTER TABLE m16.items OWNER TO m16_author;
ALTER VIEW m16.group_source OWNER TO m16_author;
ALTER VIEW m16.item_source OWNER TO m16_author;
