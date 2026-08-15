\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname='pg_react') <> '0.18.0' THEN
        RAISE EXCEPTION 'M22 upgrade fixture must start at 0.18.0';
    END IF;
END
$$;
CREATE SCHEMA m22_upgrade;
CREATE TYPE m22_upgrade.fact_row AS (id bigint);
CREATE TABLE m22_upgrade.source(id bigint PRIMARY KEY, enabled boolean NOT NULL);
CREATE VIEW m22_upgrade.active AS SELECT id FROM m22_upgrade.source WHERE enabled;
SELECT pgreact.create_derived_relation(
    'm22_upgrade.fact', 'm22_upgrade.fact_row'::regtype, ARRAY['id'], 1);
SELECT pgreact.create_derivation_rule(
    'm22_upgrade.active', 'm22_upgrade.active'::regclass, ARRAY['id'],
    (SELECT relation_version_id FROM pgreact_internal.derived_relation_versions
      WHERE public_view_name = 'm22_upgrade.fact' AND state = 'ACTIVE'), 1);
INSERT INTO m22_upgrade.source VALUES (7, true);
SELECT pgreact.refresh_derived_relation(
    (SELECT relation_version_id FROM pgreact_internal.derived_relation_versions
      WHERE public_view_name = 'm22_upgrade.fact' AND state = 'ACTIVE'));
SELECT 'M22 populated upgrade setup passed';
