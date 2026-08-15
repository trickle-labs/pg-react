\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.19.0' THEN
        RAISE EXCEPTION 'M23 upgrade fixture must start at 0.19.0';
    END IF;
END
$$;
CREATE SCHEMA m23_upgrade;
CREATE TABLE m23_upgrade.important_state (id bigint PRIMARY KEY, value text NOT NULL);
INSERT INTO m23_upgrade.important_state VALUES (7, 'preserve-me');
SELECT frontier AS m23_frontier_before FROM pgreact_internal.clock_frontier \gset
SELECT 'M23 populated upgrade setup passed' AS result;
