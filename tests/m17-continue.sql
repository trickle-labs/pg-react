\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
INSERT INTO m17_reference.items VALUES (4,7,10,'1970-01-01T00:00:00Z');
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run(); RESET SESSION AUTHORIZATION;
UPDATE m17_reference.items SET occurred_at='1970-01-01T01:00:00Z' WHERE item_id=1;
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run(); RESET SESSION AUTHORIZATION;
UPDATE m17_reference.items SET amount=8,occurred_at='1970-01-01T01:00:00Z' WHERE item_id=4;
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run(); RESET SESSION AUTHORIZATION;
DELETE FROM m17_reference.items WHERE item_id=2;
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run(); RESET SESSION AUTHORIZATION;
UPDATE m17_reference.items SET amount=12 WHERE item_id=3;
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run(); RESET SESSION AUTHORIZATION;
CREATE TEMP TABLE m17_replay_state AS SELECT jsonb_build_object(
    'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                   FROM pgreact_internal.window_corrections correction),
    'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                 FROM pgreact_internal.window_lifecycle event),
    'program',(SELECT to_jsonb(program) FROM pgreact_internal.window_programs program WHERE active),
    'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,public_window_key)
                FROM pgreact.window_evidence evidence)) AS state;
SELECT pgreact_api.run();
DO $$
DECLARE actual text;
BEGIN
    SELECT string_agg(format('%s|F%s|%s|%s|G%s',
        replace(public_window_key::text,' ',''),lower_frontier,rule_name,
        event_kind,support_generation), E'\n' ORDER BY lifecycle_order)
    INTO actual FROM pgreact_internal.window_lifecycle;
    IF actual IS DISTINCT FROM E'[7,-1]|F1|m17.min_amount|ACTIVATE|G1\n[7,0]|F1|m17.count_all|ACTIVATE|G1\n[7,0]|F1|m17.count_amount|ACTIVATE|G1\n[7,0]|F1|m17.sum_amount|ACTIVATE|G1\n[7,0]|F2|m17.max_amount|ACTIVATE|G1\n[7,-1]|F3|m17.min_amount|DEACTIVATE|G1\n[7,1]|F3|m17.min_amount|ACTIVATE|G1\n[7,0]|F4|m17.max_amount|DEACTIVATE|G1\n[7,1]|F4|m17.count_all|ACTIVATE|G1\n[7,1]|F4|m17.count_amount|ACTIVATE|G1\n[7,1]|F4|m17.max_amount|ACTIVATE|G1\n[7,1]|F4|m17.sum_amount|ACTIVATE|G1\n[7,0]|F5|m17.count_all|DEACTIVATE|G1\n[7,0]|F5|m17.count_amount|DEACTIVATE|G1\n[7,0]|F5|m17.sum_amount|DEACTIVATE|G1\n[7,0]|F6|m17.max_amount|ACTIVATE|G2\n[7,0]|F6|m17.sum_amount|ACTIVATE|G2' THEN
        RAISE EXCEPTION 'M17 F1-F6 lifecycle changed: %', actual;
    END IF;
    IF (SELECT state FROM m17_replay_state) IS DISTINCT FROM jsonb_build_object(
        'corrections',(SELECT jsonb_agg(to_jsonb(correction) ORDER BY correction_order)
                       FROM pgreact_internal.window_corrections correction),
        'lifecycle',(SELECT jsonb_agg(to_jsonb(event) ORDER BY lifecycle_order)
                     FROM pgreact_internal.window_lifecycle event),
        'program',(SELECT to_jsonb(program) FROM pgreact_internal.window_programs program WHERE active),
        'evidence',(SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name,public_window_key)
                    FROM pgreact.window_evidence evidence)) THEN
        RAISE EXCEPTION 'M17 F6 replay changed durable state';
    END IF;
END
$$;
SELECT pgreact_api.request_watermark(
    'm17.reference','m17_reference.item_source','occurred_at','1970-01-01T01:15:00Z');
SELECT pgreact_api.run(); SELECT pgreact_api.run();
DO $$
DECLARE before_state jsonb; error_state text;
BEGIN
    SELECT jsonb_build_object(
        'requested',requested_watermark,'complete',complete_watermark,
        'finalizations',(SELECT jsonb_agg(finalization_identity ORDER BY lateness_boundary)
                         FROM pgreact_internal.window_finalizations))
    INTO before_state FROM pgreact_internal.window_programs WHERE active;
    PERFORM pgreact_api.request_watermark(
        'm17.reference','m17_reference.item_source','occurred_at','1970-01-01T01:15:00Z');
    BEGIN
        PERFORM pgreact_api.request_watermark(
            'm17.reference','m17_reference.item_source','occurred_at','1970-01-01T01:00:00Z');
    EXCEPTION WHEN SQLSTATE '22023' THEN GET STACKED DIAGNOSTICS error_state = MESSAGE_TEXT;
    END;
    IF before_state IS DISTINCT FROM jsonb_build_object(
            'requested','1970-01-01T01:15:00Z'::timestamptz,
            'complete','1970-01-01T01:15:00Z'::timestamptz,
            'finalizations',jsonb_build_array(
                '[7,-1]@1970-01-01T00:15:00.000000Z',
                '[7,0]@1970-01-01T01:15:00.000000Z'))
       OR error_state NOT LIKE 'M17_WATERMARK_BACKWARD:%'
       OR before_state IS DISTINCT FROM (
            SELECT jsonb_build_object(
                'requested',requested_watermark,'complete',complete_watermark,
                'finalizations',(SELECT jsonb_agg(finalization_identity ORDER BY lateness_boundary)
                                 FROM pgreact_internal.window_finalizations))
            FROM pgreact_internal.window_programs WHERE active) THEN
        RAISE EXCEPTION 'M17 completed/repeated/backward watermark changed: %, %',
            before_state,error_state;
    END IF;
END
$$;
RESET SESSION AUTHORIZATION;
INSERT INTO m17_reference.items VALUES (5,7,1,'1970-01-01T01:30:00Z');
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run(); RESET SESSION AUTHORIZATION;
INSERT INTO m17_reference.items VALUES (6,7,10,'1970-01-01T02:00:00Z');
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run(); RESET SESSION AUTHORIZATION;
INSERT INTO m17_reference.items VALUES (7,7,NULL,'1970-01-01T02:30:00Z');
SET SESSION AUTHORIZATION m17_operator; SELECT pgreact_api.run();
SELECT pgreact_api.request_watermark(
    'm17.reference','m17_reference.item_source','occurred_at','1970-01-01T03:15:00Z');
SELECT pgreact_api.run();
SET pg_react.m17_fail_watermark=on;
SELECT pgreact_api.run();
SET pg_react.m17_fail_watermark=off;
SELECT pgreact_api.run();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual text; actual_json jsonb;
BEGIN
    SELECT string_agg(format('%s|F%s|%s|%s',public_window_key,lower_frontier,
        aggregate_values,aggregate_truths), E'\n' ORDER BY window_ordinal,lower_frontier)
    INTO actual FROM (
        SELECT replace(public_window_key::text,' ','') AS public_window_key,
               window_ordinal,lower_frontier,
               string_agg(COALESCE(after_value,'null'),',' ORDER BY rule_name) AS aggregate_values,
               string_agg(COALESCE(after_truth::text,'null'),',' ORDER BY rule_name) AS aggregate_truths
        FROM pgreact_internal.window_corrections
        GROUP BY public_window_key,window_ordinal,lower_frontier) history;
    IF actual IS DISTINCT FROM E'[7,-1]|F1|1,1,4,4,4|false,false,false,true,false\n[7,-1]|F3|0,0,null,null,null|false,false,null,null,null\n[7,0]|F1|2,2,6,5,11|true,true,false,false,true\n[7,0]|F2|3,3,10,5,21|true,true,true,false,true\n[7,0]|F4|2,2,6,5,11|true,true,false,false,true\n[7,0]|F5|1,1,5,5,5|false,false,false,false,false\n[7,0]|F6|1,1,12,12,12|false,false,true,false,true\n[7,1]|F3|1,1,4,4,4|false,false,false,true,false\n[7,1]|F4|2,2,8,4,12|true,true,true,true,true\n[7,1]|F7|3,3,8,1,13|true,true,true,true,true\n[7,2]|F8|1,1,10,10,10|false,false,true,false,true\n[7,2]|F9|2,1,10,10,10|true,false,true,false,true' THEN
        RAISE EXCEPTION 'M17 exact correction history changed: %', actual;
    END IF;
    SELECT string_agg(format('%s|%s|G%s|%s',target_relation,
        replace(public_window_key::text,' ',''),support_generation,last_correction_identity),
        E'\n' ORDER BY target_relation,window_ordinal)
    INTO actual FROM pgreact.window_evidence WHERE truth_result;
    IF actual IS DISTINCT FROM E'm17_reference.count_all_alert|[7,1]|G1|m17.reference@1/m17.count_all@1/[7,1]/F7\nm17_reference.count_all_alert|[7,2]|G1|m17.reference@1/m17.count_all@1/[7,2]/F9\nm17_reference.count_amount_alert|[7,1]|G1|m17.reference@1/m17.count_amount@1/[7,1]/F7\nm17_reference.max_amount_alert|[7,0]|G2|m17.reference@1/m17.max_amount@1/[7,0]/F6\nm17_reference.max_amount_alert|[7,1]|G1|m17.reference@1/m17.max_amount@1/[7,1]/F7\nm17_reference.max_amount_alert|[7,2]|G1|m17.reference@1/m17.max_amount@1/[7,2]/F9\nm17_reference.min_amount_alert|[7,1]|G1|m17.reference@1/m17.min_amount@1/[7,1]/F7\nm17_reference.sum_amount_alert|[7,0]|G2|m17.reference@1/m17.sum_amount@1/[7,0]/F6\nm17_reference.sum_amount_alert|[7,1]|G1|m17.reference@1/m17.sum_amount@1/[7,1]/F7\nm17_reference.sum_amount_alert|[7,2]|G1|m17.reference@1/m17.sum_amount@1/[7,2]/F9' THEN
        RAISE EXCEPTION 'M17 exact facts/evidence changed: %', actual;
    END IF;
    SELECT string_agg(format('F%s|%s|%s|%s|G%s',lower_frontier,
        replace(public_window_key::text,' ',''),rule_name,event_kind,support_generation),
        E'\n' ORDER BY lifecycle_order)
    INTO actual FROM pgreact_internal.window_lifecycle;
    IF actual IS DISTINCT FROM E'F1|[7,-1]|m17.min_amount|ACTIVATE|G1\nF1|[7,0]|m17.count_all|ACTIVATE|G1\nF1|[7,0]|m17.count_amount|ACTIVATE|G1\nF1|[7,0]|m17.sum_amount|ACTIVATE|G1\nF2|[7,0]|m17.max_amount|ACTIVATE|G1\nF3|[7,-1]|m17.min_amount|DEACTIVATE|G1\nF3|[7,1]|m17.min_amount|ACTIVATE|G1\nF4|[7,0]|m17.max_amount|DEACTIVATE|G1\nF4|[7,1]|m17.count_all|ACTIVATE|G1\nF4|[7,1]|m17.count_amount|ACTIVATE|G1\nF4|[7,1]|m17.max_amount|ACTIVATE|G1\nF4|[7,1]|m17.sum_amount|ACTIVATE|G1\nF5|[7,0]|m17.count_all|DEACTIVATE|G1\nF5|[7,0]|m17.count_amount|DEACTIVATE|G1\nF5|[7,0]|m17.sum_amount|DEACTIVATE|G1\nF6|[7,0]|m17.max_amount|ACTIVATE|G2\nF6|[7,0]|m17.sum_amount|ACTIVATE|G2\nF8|[7,2]|m17.max_amount|ACTIVATE|G1\nF8|[7,2]|m17.sum_amount|ACTIVATE|G1\nF9|[7,2]|m17.count_all|ACTIVATE|G1' THEN
        RAISE EXCEPTION 'M17 exact lifecycle history changed: %', actual;
    END IF;
    SELECT jsonb_build_object(
        'requested',requested_watermark,'complete',complete_watermark,'status',status,
        'finalizations',(SELECT jsonb_agg(finalization_identity ORDER BY lateness_boundary)
                         FROM pgreact_internal.window_finalizations),
        'diagnostics',(SELECT jsonb_agg(jsonb_build_object(
            'code',code,'sqlstate',sqlstate,'details',details) ORDER BY diagnostic_order)
            FROM pgreact_internal.window_diagnostics))
    INTO actual_json FROM pgreact_api.watermark_status('m17.reference');
    IF actual_json IS DISTINCT FROM jsonb_build_object(
        'requested','1970-01-01T03:15:00Z'::timestamptz,
        'complete','1970-01-01T03:15:00Z'::timestamptz,'status','complete',
        'finalizations',jsonb_build_array(
            '[7,-1]@1970-01-01T00:15:00.000000Z','[7,0]@1970-01-01T01:15:00.000000Z',
            '[7,1]@1970-01-01T02:15:00.000000Z','[7,2]@1970-01-01T03:15:00.000000Z'),
        'diagnostics',jsonb_build_array(jsonb_build_object(
            'code','M17_WATERMARK_BATCH_FAILED','sqlstate','XX000',
            'details',jsonb_build_object(
                'complete_watermark','1970-01-01T02:15:00Z'::timestamptz,
                'requested_watermark','1970-01-01T03:15:00Z'::timestamptz)))) THEN
        RAISE EXCEPTION 'M17 watermark failure/resume/finalization changed: %', actual_json;
    END IF;
END
$$;
SELECT 'M17 F1-F9 corrections, replay, watermark batching, failure rollback, and finalization passed';
