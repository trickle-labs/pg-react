\set ON_ERROR_STOP on
DO $$
DECLARE before_state jsonb; error_message text;
BEGIN
    before_state:=pgreact_api.export_window_state('m17.reference');
    IF before_state IS DISTINCT FROM (SELECT state FROM m17_reference.physical_control) THEN
        RAISE EXCEPTION 'M17 crash restart changed complete temporal state';
    END IF;
    IF pg_is_in_recovery() THEN
        BEGIN
            PERFORM pgreact_api.request_watermark(
                'm17.reference','m17_reference.item_source','occurred_at',
                '1970-01-01T04:15:00Z');
        EXCEPTION WHEN SQLSTATE '25006' THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT;
        END;
        IF error_message <> 'M17_WATERMARK_STANDBY: watermark requests require a writable primary'
           OR pgreact_api.export_window_state('m17.reference') IS DISTINCT FROM before_state THEN
            RAISE EXCEPTION 'M17 standby watermark behavior changed: %',error_message;
        END IF;
    END IF;
END
$$;
SELECT 'M17 crash restart preserved exact temporal state';
