\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'status',(SELECT to_jsonb(status_row)
                  FROM pgreact_api.watermark_status('m17.reference') status_row),
        'requests',(SELECT jsonb_agg(jsonb_build_object(
            'operation',operation,'previous',details -> 'previous','target',details -> 'target')
            ORDER BY audit_order)
            FROM pgreact_internal.window_audits WHERE operation='REQUEST_WATERMARK'),
        'finalizations',(SELECT COALESCE(jsonb_agg(finalization_identity),'[]'::jsonb)
                         FROM pgreact_internal.window_finalizations))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'status',jsonb_build_object(
            'input_relation','m17_reference.item_source','event_time_column','occurred_at',
            'requested_watermark','1970-01-01T05:15:00Z'::timestamptz,
            'complete_watermark','-infinity'::timestamptz,
            'history_floor','-infinity'::timestamptz,'status','pending','barrier',NULL),
        'requests',jsonb_build_array(
            jsonb_build_object('operation','REQUEST_WATERMARK','previous','-infinity'::timestamptz,
                               'target','1970-01-01T01:15:00Z'::timestamptz),
            jsonb_build_object('operation','REQUEST_WATERMARK',
                               'previous','1970-01-01T01:15:00Z'::timestamptz,
                               'target','1970-01-01T03:15:00Z'::timestamptz),
            jsonb_build_object('operation','REQUEST_WATERMARK',
                               'previous','1970-01-01T03:15:00Z'::timestamptz,
                               'target','1970-01-01T04:15:00Z'::timestamptz),
            jsonb_build_object('operation','REQUEST_WATERMARK',
                               'previous','1970-01-01T04:15:00Z'::timestamptz,
                               'target','1970-01-01T05:15:00Z'::timestamptz)),
        'finalizations','[]'::jsonb) THEN
        RAISE EXCEPTION 'M17 concurrent/equal/backward watermark serialization changed: %',actual;
    END IF;
END
$$;
SELECT 'M17 concurrent watermark serialization and idempotency passed';
