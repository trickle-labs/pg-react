\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.21.0' THEN
        RAISE EXCEPTION 'M25 upgrade fixture must start at 0.21.0';
    END IF;
END
$$;
CREATE TABLE m25_upgrade_preserved (value text NOT NULL);
INSERT INTO m25_upgrade_preserved VALUES ('preserve-me');
SELECT 'M25 populated upgrade setup passed' AS result;
