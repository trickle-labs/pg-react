\set ON_ERROR_STOP on
DO $$
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname='pg_react') <> '0.17.0' THEN
        RAISE EXCEPTION 'M21 upgrade fixture must start at 0.17.0';
    END IF;
END
$$;
INSERT INTO pgreact_internal.runtime_events(severity,event_type,detail)
VALUES ('INFO','M21_UPGRADE_EVENT','{"preserve":true}');
SELECT 'M21 populated upgrade setup passed';
