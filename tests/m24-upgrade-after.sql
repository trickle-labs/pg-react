\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'pg_react') <> '0.21.0' THEN
        RAISE EXCEPTION 'M24 upgrade version changed';
    END IF;
    IF to_regclass('pgreact_internal.effective_policies') IS NULL
       OR to_regclass('pgreact_internal.effective_policy_versions') IS NULL THEN
        RAISE EXCEPTION 'M24 effective-policy catalog was not installed';
    END IF;
    IF (SELECT value FROM m24_upgrade_preserved) <> 'preserve-me' THEN
        RAISE EXCEPTION 'M24 upgrade lost existing state';
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.effective_policies) THEN
        RAISE EXCEPTION 'M24 upgrade synthesized effective policies';
    END IF;
END
$$;
SELECT 'M24 direct 0.20.0 to 0.21.0 upgrade gate passed';
