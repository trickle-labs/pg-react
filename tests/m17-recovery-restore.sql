\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET SESSION AUTHORIZATION m17_operator;
DO $$
BEGIN
    IF pgreact_api.export_window_state('m17.reference') IS DISTINCT FROM
       (SELECT state FROM m17_reference.physical_control)
       OR pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M17 promoted physical restore changed complete temporal state';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
INSERT INTO m17_reference.items VALUES (14,7,2,'1970-01-01T03:30:00Z');
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual text;
BEGIN
    SELECT string_agg(format('%s|%s|%s',rule_name,after_value,
        COALESCE(after_truth::text,'null')),E'\n' ORDER BY rule_name)
    INTO actual FROM pgreact_internal.window_corrections
    WHERE lower_frontier=10 AND public_window_key='[7,3]'::jsonb;
    IF actual IS DISTINCT FROM E'm17.count_all|1|false\nm17.count_amount|1|false\nm17.max_amount|2|false\nm17.min_amount|2|true\nm17.sum_amount|2|false' THEN
        RAISE EXCEPTION 'M17 promoted physical restore did not continue exactly: %',actual;
    END IF;
END
$$;
SELECT 'M17 standby promotion and physical restore preserved temporal state';
