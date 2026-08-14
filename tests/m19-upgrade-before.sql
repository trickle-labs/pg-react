\set ON_ERROR_STOP on
SET client_min_messages = warning;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_author') THEN CREATE ROLE m19_author NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_operator') THEN CREATE ROLE m19_operator NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_worker') THEN CREATE ROLE m19_worker NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_reader') THEN CREATE ROLE m19_reader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'm19_advanced') THEN CREATE ROLE m19_advanced NOLOGIN; END IF;
END
$$;
SELECT pgreact_api.configure_roles(
    'm19_author', 'm19_operator', 'm19_worker', 'm19_reader', 'm19_advanced');
CREATE SCHEMA m19_upgrade AUTHORIZATION m19_author;
SET SESSION AUTHORIZATION m19_author;
CREATE TABLE m19_upgrade.source(id bigint PRIMARY KEY, enabled boolean NOT NULL);
CREATE VIEW m19_upgrade.active AS SELECT id FROM m19_upgrade.source WHERE enabled;
SELECT pgreact_api.author_rule(
    rule_name => 'm19.upgrade.scheduled', condition => 'm19_upgrade.active'::regclass,
    semantic_key => 'id', kind => 'CONSTRAINT');
RESET SESSION AUTHORIZATION;
SELECT 'M19 populated pre-upgrade state created';
