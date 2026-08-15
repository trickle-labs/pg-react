\set ON_ERROR_STOP on
DO $$
DECLARE actual text;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.20.0' THEN
        RAISE EXCEPTION 'M23 upgrade version changed';
    END IF;
    IF to_regclass('pgreact_internal.temporal_rules') IS NULL
       OR to_regclass('pgreact_internal.temporal_state') IS NULL
       OR to_regclass('pgreact_internal.temporal_history') IS NULL THEN
        RAISE EXCEPTION 'M23 temporal catalog was not installed';
    END IF;
    SELECT value INTO actual FROM m23_upgrade.important_state WHERE id = 7;
    IF actual <> 'preserve-me' THEN RAISE EXCEPTION 'M23 upgrade lost existing state'; END IF;
    IF (SELECT count(*) FROM pgreact_internal.temporal_rules) <> 0 THEN
        RAISE EXCEPTION 'M23 upgrade synthesized temporal declarations';
    END IF;
END
$$;
SELECT 'M23 direct 0.19.0 to 0.20.0 upgrade gate passed';
