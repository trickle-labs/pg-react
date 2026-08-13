\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE EXTENSION pg_trickle;
CREATE EXTENSION pg_react;
\i /tmp/m17-smoke.sql
\i /tmp/m17-continue.sql
CREATE TABLE m17_reference.physical_control(state jsonb NOT NULL);
INSERT INTO m17_reference.physical_control
SELECT pgreact_api.export_window_state('m17.reference');
GRANT USAGE ON SCHEMA m17_reference TO m17_operator;
GRANT SELECT ON m17_reference.physical_control TO m17_operator;
CHECKPOINT;
SELECT 'M17 physical recovery setup passed';
