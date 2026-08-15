\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.22.0' THEN
        RAISE EXCEPTION 'M25 upgrade version changed';
    END IF;
    IF to_regclass('pgreact_internal.parameter_families') IS NULL
       OR to_regclass('pgreact_internal.parameter_family_consumers') IS NULL THEN
        RAISE EXCEPTION 'M25 parameter-family catalog was not installed';
    END IF;
    IF (SELECT value FROM m25_upgrade_preserved) <> 'preserve-me' THEN
        RAISE EXCEPTION 'M25 upgrade lost existing state';
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.parameter_families) THEN
        RAISE EXCEPTION 'M25 upgrade synthesized parameter families';
    END IF;
END
$$;
SELECT 'M25 direct 0.21.0 to 0.22.0 upgrade gate passed';
