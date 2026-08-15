\set ON_ERROR_STOP on
DO $$
DECLARE actual jsonb;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname='pg_react') <> '0.18.0' THEN
        RAISE EXCEPTION 'M21 upgrade version changed';
    END IF;
    IF to_regclass('pgreact_internal.retention_policies') IS NULL
       OR to_regprocedure('pgreact_api.retention_apply(timestamp with time zone,integer)') IS NULL
       OR NOT EXISTS (SELECT 1 FROM pgreact_internal.runtime_events WHERE event_type='M21_UPGRADE_EVENT') THEN
        RAISE EXCEPTION 'M21 populated upgrade state changed';
    END IF;
    actual := pgreact_api.retention_status();
    IF actual ->> 'contract_version' <> '9' OR (actual #>> '{policy,enabled}') <> 'false' THEN
        RAISE EXCEPTION 'M21 upgrade policy default changed: %', actual;
    END IF;
END
$$;
SELECT 'M21 direct 0.17.0 to 0.18.0 upgrade gate passed';
