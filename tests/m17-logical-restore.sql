\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET SESSION AUTHORIZATION m17_author;
DO $$
DECLARE definition jsonb; preview jsonb;
BEGIN
    SELECT m17_reference.definition.definition INTO STRICT definition
    FROM m17_reference.definition;
    preview:=pgreact_api.preview_program(definition);
    PERFORM pgreact_api.deploy_program(definition,preview ->> 'plan_digest');
END
$$;
RESET SESSION AUTHORIZATION;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run();
SELECT pgreact_api.restore_window_state(
    (SELECT state FROM m17_reference.logical_export));
DO $$
DECLARE actual jsonb;
BEGIN
    actual:=pgreact_api.export_window_state('m17.reference');
    IF actual IS DISTINCT FROM (SELECT state FROM m17_reference.logical_export) THEN
        RAISE EXCEPTION 'M17 logical restore changed declaration, windows, watermarks, history, or evidence';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual text;
BEGIN
    SELECT string_agg(format('%s|%s',target_relation,
        replace(public_window_key::text,' ','')),E'\n' ORDER BY target_relation,window_ordinal)
    INTO actual FROM pgreact.window_evidence WHERE truth_result;
    IF actual IS DISTINCT FROM E'm17_reference.count_all_alert|[7,1]\nm17_reference.count_all_alert|[7,2]\nm17_reference.count_amount_alert|[7,1]\nm17_reference.max_amount_alert|[7,0]\nm17_reference.max_amount_alert|[7,1]\nm17_reference.max_amount_alert|[7,2]\nm17_reference.min_amount_alert|[7,1]\nm17_reference.sum_amount_alert|[7,0]\nm17_reference.sum_amount_alert|[7,1]\nm17_reference.sum_amount_alert|[7,2]' THEN
        RAISE EXCEPTION 'M17 logical restore changed exact facts: %',actual;
    END IF;
END
$$;
INSERT INTO m17_reference.items VALUES (14,7,2,'1970-01-01T03:30:00Z');
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual text;
BEGIN
    SELECT string_agg(format('%s|%s|%s|%s',rule_name,
        replace(public_window_key::text,' ',''),after_value,
        COALESCE(after_truth::text,'null')),E'\n' ORDER BY rule_name)
    INTO actual FROM pgreact_internal.window_corrections
    WHERE lower_frontier=10 AND public_window_key='[7,3]'::jsonb;
    IF actual IS DISTINCT FROM E'm17.count_all|[7,3]|1|false\nm17.count_amount|[7,3]|1|false\nm17.max_amount|[7,3]|2|false\nm17.min_amount|[7,3]|2|true\nm17.sum_amount|[7,3]|2|false'
       OR (SELECT lower_frontier FROM pgreact_internal.window_programs WHERE active) <> 10 THEN
        RAISE EXCEPTION 'M17 logical restore did not continue exactly: %',actual;
    END IF;
END
$$;
SELECT 'M17 logical dump/restore preserved exact state and continued execution passed';
