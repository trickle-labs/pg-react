\set ON_ERROR_STOP on
CREATE ROLE m20_upgrade_author NOLOGIN;
CREATE ROLE m20_upgrade_operator NOLOGIN;
CREATE ROLE m20_upgrade_worker NOLOGIN;
CREATE ROLE m20_upgrade_reader NOLOGIN;
CREATE ROLE m20_upgrade_advanced NOLOGIN;
SELECT pgreact_api.configure_roles(
    'm20_upgrade_author', 'm20_upgrade_operator', 'm20_upgrade_worker',
    'm20_upgrade_reader', 'm20_upgrade_advanced');
CREATE SCHEMA m20_upgrade AUTHORIZATION m20_upgrade_author;
SET SESSION AUTHORIZATION m20_upgrade_author;
CREATE TYPE m20_upgrade.row_value AS (id bigint);
CREATE TABLE m20_upgrade.source(id bigint PRIMARY KEY, enabled boolean NOT NULL);
CREATE VIEW m20_upgrade.active AS SELECT id FROM m20_upgrade.source WHERE enabled;
SELECT pgreact_api.author_rule(
    rule_name => 'm20.upgrade.rule', condition => 'm20_upgrade.active'::regclass,
    semantic_key => 'id', kind => 'CONSTRAINT');
RESET SESSION AUTHORIZATION;
INSERT INTO m20_upgrade.source VALUES (1, true);
