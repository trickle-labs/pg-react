INSERT INTO pgreact_internal.operational_settings_snapshot (singleton, settings)
SELECT true, to_jsonb(settings) FROM pgreact_internal.operational_settings settings
WHERE settings.singleton;
