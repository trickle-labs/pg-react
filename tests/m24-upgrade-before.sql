\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.20.0' THEN
        RAISE EXCEPTION 'M24 upgrade fixture must start at 0.20.0';
    END IF;
END
$$;
CREATE TABLE m24_upgrade_preserved (value text NOT NULL);
INSERT INTO m24_upgrade_preserved VALUES ('preserve-me');
SELECT 'M24 populated upgrade setup passed' AS result;
