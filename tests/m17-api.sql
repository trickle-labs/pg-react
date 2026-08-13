\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'request',to_regprocedure('pgreact_api.request_watermark(text,text,name,timestamptz)')::text,
        'status',to_regprocedure('pgreact_api.watermark_status(text)')::text,
        'history',to_regprocedure('pgreact_api.window_corrections(text,integer,text)')::text,
        'prune',to_regprocedure('pgreact_api.prune_window_history(text,timestamptz)')::text,
        'author',jsonb_build_object(
            'request',has_function_privilege('m17_author','pgreact_api.request_watermark(text,text,name,timestamptz)','EXECUTE'),
            'status',has_function_privilege('m17_author','pgreact_api.watermark_status(text)','EXECUTE'),
            'history',has_function_privilege('m17_author','pgreact_api.window_corrections(text,integer,text)','EXECUTE')),
        'operator',jsonb_build_object(
            'request',has_function_privilege('m17_operator','pgreact_api.request_watermark(text,text,name,timestamptz)','EXECUTE'),
            'status',has_function_privilege('m17_operator','pgreact_api.watermark_status(text)','EXECUTE'),
            'history',has_function_privilege('m17_operator','pgreact_api.window_corrections(text,integer,text)','EXECUTE'),
            'prune',has_function_privilege('m17_operator','pgreact_api.prune_window_history(text,timestamptz)','EXECUTE')),
        'reader',jsonb_build_object(
            'status',has_function_privilege('m17_reader','pgreact_api.watermark_status(text)','EXECUTE'),
            'history',has_function_privilege('m17_reader','pgreact_api.window_corrections(text,integer,text)','EXECUTE'),
            'evidence',has_table_privilege('m17_reader','pgreact.window_evidence','SELECT'),
            'diagnostics',has_table_privilege('m17_reader','pgreact.window_diagnostics','SELECT')),
        'advanced',jsonb_build_object(
            'history',has_function_privilege('m17_advanced','pgreact_api.window_corrections(text,integer,text)','EXECUTE')),
        'public',jsonb_build_object(
            'request',has_function_privilege('public','pgreact_api.request_watermark(text,text,name,timestamptz)','EXECUTE'),
            'evidence',has_table_privilege('public','pgreact.window_evidence','SELECT')))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'request','pgreact_api.request_watermark(text,text,name,timestamp with time zone)',
        'status','pgreact_api.watermark_status(text)',
        'history','pgreact_api.window_corrections(text,integer,text)',
        'prune','pgreact_api.prune_window_history(text,timestamp with time zone)',
        'author',jsonb_build_object('request',false,'status',false,'history',false),
        'operator',jsonb_build_object('request',true,'status',true,'history',true,'prune',true),
        'reader',jsonb_build_object('status',true,'history',false,'evidence',true,'diagnostics',true),
        'advanced',jsonb_build_object('history',true),
        'public',jsonb_build_object('request',false,'evidence',false)) THEN
        RAISE EXCEPTION 'M17 public API or exact grant matrix changed: %',actual;
    END IF;
END
$$;
CREATE TEMP TABLE m17_permission_state AS
SELECT to_jsonb(status_row) AS status FROM pgreact_api.watermark_status('m17.reference') status_row;
SET SESSION AUTHORIZATION m17_author;
DO $$
DECLARE denied_message text;
BEGIN
    BEGIN
        PERFORM pgreact_api.request_watermark(
            'm17.reference','m17_reference.item_source','occurred_at','1970-01-01T01:15:00Z');
    EXCEPTION WHEN SQLSTATE '42501' THEN GET STACKED DIAGNOSTICS denied_message = MESSAGE_TEXT;
    END;
    IF denied_message IS NULL THEN
        RAISE EXCEPTION 'M17 author unexpectedly advanced a watermark';
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DO $$
BEGIN
    IF (SELECT status FROM m17_permission_state) IS DISTINCT FROM (
        SELECT to_jsonb(status_row) FROM pgreact_api.watermark_status('m17.reference') status_row) THEN
        RAISE EXCEPTION 'M17 unauthorized watermark request changed state';
    END IF;
END
$$;

SET SESSION AUTHORIZATION m17_reader;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT to_jsonb(status_row) INTO actual
    FROM pgreact_api.watermark_status('m17.reference') status_row;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'input_relation','m17_reference.item_source','event_time_column','occurred_at',
        'requested_watermark','-infinity'::timestamptz,
        'complete_watermark','-infinity'::timestamptz,
        'history_floor','-infinity'::timestamptz,'status','complete','barrier',NULL) THEN
        RAISE EXCEPTION 'M17 reader watermark status changed: %',actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m17_advanced;
DO $$
DECLARE actual text;
BEGIN
    SELECT string_agg(format('%s|%s|F%s|%s',correction_identity,
        replace(public_window_key::text,' ',''),lower_frontier,next_cursor),E'\n')
    INTO actual FROM pgreact_api.window_corrections('m17.reference',2,NULL);
    IF actual IS DISTINCT FROM E'm17.reference@1/m17.count_all@1/[7,-1]/F1|[7,-1]|F1|m17.reference@1/m17.count_all@1/[7,-1]/F1\nm17.reference@1/m17.count_amount@1/[7,-1]/F1|[7,-1]|F1|m17.reference@1/m17.count_amount@1/[7,-1]/F1' THEN
        RAISE EXCEPTION 'M17 bounded correction history changed: %',actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION m17_author;
DO $$
DECLARE candidate jsonb; actual jsonb;
BEGIN
    SELECT definition INTO candidate FROM m17_reference.definition;
    candidate := jsonb_set(candidate,'{rules,0,aggregate_input,window,duration}','"P1M"');
    SELECT jsonb_agg(jsonb_build_object(
        'contract_version',contract_version,'code',code,'severity',severity,
        'object_identity',object_identity,'message',message,'hint',hint,'details',details)
        ORDER BY code,object_identity)
    INTO actual FROM pgreact_api.validate_program(candidate);
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
        'contract_version',6,'code','M17_WINDOW_INTERVAL_INVALID','severity','ERROR',
        'object_identity','m17.count_all','message','window duration or allowed lateness is invalid',
        'hint','Use fixed integral microsecond intervals; duration must be positive and lateness nonnegative.',
        'details',jsonb_build_object('duration','P1M','allowed_lateness','PT15M'))) THEN
        RAISE EXCEPTION 'M17 invalid interval diagnostic changed: %',actual;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
SELECT 'M17 exact API, permissions, bounded history, and validation diagnostics passed';
