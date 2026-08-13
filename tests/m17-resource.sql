\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE TEMP TABLE m17_resource_state AS SELECT jsonb_build_object(
    'program',(SELECT to_jsonb(program) - 'max_facts'
               FROM pgreact_internal.window_programs program WHERE active),
    'source_rows',(SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_data::text)
                   FROM pgreact_internal.window_source_rows row_value),
    'identities',(SELECT jsonb_agg(to_jsonb(identity) ORDER BY window_ordinal,public_window_key)
                  FROM pgreact_internal.window_identities identity),
    'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                   FROM pgreact_internal.window_corrections correction),
    'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                 FROM pgreact_internal.window_lifecycle event),
    'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
                FROM pgreact.window_evidence evidence)) AS state;

UPDATE pgreact_internal.window_programs SET max_facts=20 WHERE active;
INSERT INTO m17_reference.items VALUES (9,7,2,'1970-01-01T03:00:00Z');
SET SESSION AUTHORIZATION m17_operator;
DO $$
DECLARE error_message text;
BEGIN
    BEGIN
        PERFORM pgreact_api.run();
    EXCEPTION WHEN SQLSTATE '54000' THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT;
    END;
    IF error_message <> 'M17_RESOURCE_LIMIT: window states or corrections require 25, max_facts is 20' THEN
        RAISE EXCEPTION 'M17 max_facts diagnostic changed: %',error_message;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'program',(SELECT to_jsonb(program) - 'max_facts'
                   FROM pgreact_internal.window_programs program WHERE active),
        'source_rows',(SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_data::text)
                       FROM pgreact_internal.window_source_rows row_value),
        'identities',(SELECT jsonb_agg(to_jsonb(identity) ORDER BY window_ordinal,public_window_key)
                      FROM pgreact_internal.window_identities identity),
        'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                       FROM pgreact_internal.window_corrections correction),
        'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                     FROM pgreact_internal.window_lifecycle event),
        'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
                    FROM pgreact.window_evidence evidence))
    INTO actual;
    IF actual IS DISTINCT FROM (SELECT state FROM m17_resource_state) THEN
        RAISE EXCEPTION 'M17 max_facts failure exposed partial state';
    END IF;
END
$$;
DELETE FROM m17_reference.items WHERE item_id=9;
UPDATE pgreact_internal.window_programs SET max_facts=64 WHERE active;

INSERT INTO m17_reference.items VALUES (10,7,2,NULL);
SET SESSION AUTHORIZATION m17_operator;
DO $$
DECLARE error_message text;
BEGIN
    BEGIN PERFORM pgreact_api.run();
    EXCEPTION WHEN SQLSTATE '22004' THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT;
    END;
    IF error_message <> 'M17_EVENT_TIME_NULL: event time must be non-null' THEN
        RAISE EXCEPTION 'M17 null event-time diagnostic changed: %',error_message;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DELETE FROM m17_reference.items WHERE item_id=10;
INSERT INTO m17_reference.items VALUES (11,7,2,'infinity');
SET SESSION AUTHORIZATION m17_operator;
DO $$
DECLARE error_message text;
BEGIN
    BEGIN PERFORM pgreact_api.run();
    EXCEPTION WHEN SQLSTATE '22008' THEN GET STACKED DIAGNOSTICS error_message=MESSAGE_TEXT;
    END;
    IF error_message <> 'M17_EVENT_TIME_INFINITE: event time must be finite' THEN
        RAISE EXCEPTION 'M17 infinite event-time diagnostic changed: %',error_message;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
DELETE FROM m17_reference.items WHERE item_id=11;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'program',(SELECT to_jsonb(program) - 'max_facts'
                   FROM pgreact_internal.window_programs program WHERE active),
        'source_rows',(SELECT jsonb_agg(to_jsonb(row_value) ORDER BY row_data::text)
                       FROM pgreact_internal.window_source_rows row_value),
        'identities',(SELECT jsonb_agg(to_jsonb(identity) ORDER BY window_ordinal,public_window_key)
                      FROM pgreact_internal.window_identities identity),
        'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                       FROM pgreact_internal.window_corrections correction),
        'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                     FROM pgreact_internal.window_lifecycle event),
        'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,window_ordinal)
                    FROM pgreact.window_evidence evidence))
    INTO actual;
    IF actual IS DISTINCT FROM (SELECT state FROM m17_resource_state) THEN
        RAISE EXCEPTION 'M17 event-time validation failure exposed partial state';
    END IF;
END
$$;

INSERT INTO m17_reference.groups VALUES (8);
INSERT INTO m17_reference.items VALUES
    (12,7,2,'1970-01-01T03:00:00Z'),(13,8,2,'1970-01-01T03:00:00Z');
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run();
SELECT pgreact_api.request_watermark(
    'm17.reference','m17_reference.item_source','occurred_at','1970-01-01T04:15:00Z');
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb; plan json;
BEGIN
    SELECT jsonb_build_object(
        'watermark',(SELECT jsonb_build_object(
            'requested',requested_watermark,'complete',complete_watermark,'status',status)
            FROM pgreact_api.watermark_status('m17.reference')),
        'open',(SELECT jsonb_agg(jsonb_build_object(
            'key',public_window_key,'boundary',lateness_boundary,'final',final)
            ORDER BY public_window_key)
            FROM pgreact_internal.window_identities
            WHERE window_ordinal=3),
        'diagnostic',(SELECT jsonb_build_object(
            'code',code,'sqlstate',sqlstate,'details',details)
            FROM pgreact_internal.window_diagnostics
            WHERE code='M17_WATERMARK_BATCH_LIMIT'
            ORDER BY diagnostic_order DESC LIMIT 1))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'watermark',jsonb_build_object(
            'requested','1970-01-01T04:15:00Z'::timestamptz,
            'complete','1970-01-01T03:15:00Z'::timestamptz,'status','pending'),
        'open',jsonb_build_array(
            jsonb_build_object('key',jsonb_build_array(7,3),
                'boundary','1970-01-01T04:15:00Z'::timestamptz,'final',false),
            jsonb_build_object('key',jsonb_build_array(8,3),
                'boundary','1970-01-01T04:15:00Z'::timestamptz,'final',false)),
        'diagnostic',jsonb_build_object(
            'code','M17_WATERMARK_BATCH_LIMIT','sqlstate','54000',
            'details',jsonb_build_object(
                'required_minimum',2,'batch_size',1,
                'lateness_boundary','1970-01-01T04:15:00Z'::timestamptz))) THEN
        RAISE EXCEPTION 'M17 watermark batch limit or rollback changed: %',actual;
    END IF;
    SET LOCAL enable_seqscan=off;
    EXECUTE 'EXPLAIN (FORMAT JSON,COSTS OFF) '
        'SELECT public_window_key FROM pgreact_internal.window_identities '
        'WHERE program_version_id=(SELECT program_version_id '
        'FROM pgreact_internal.window_programs WHERE active) '
        'AND NOT final AND lateness_boundary <= ''1970-01-01T04:15:00Z'' '
        'ORDER BY lateness_boundary,canonical_window_key' INTO plan;
    IF plan::jsonb #>> '{0,Plan,Node Type}' NOT IN ('Index Scan','Bitmap Heap Scan')
       OR COALESCE(plan::jsonb #>> '{0,Plan,Index Name}',
                   plan::jsonb #>> '{0,Plan,Plans,0,Index Name}')
          <> 'window_identity_boundary' THEN
        RAISE EXCEPTION 'M17 indexed watermark boundary plan changed: %',plan;
    END IF;
END
$$;
SELECT 'M17 exact resource rollback, event-time failures, batch limit, and indexed boundary passed';
