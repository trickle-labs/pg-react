\set ON_ERROR_STOP on

DO $$
DECLARE expected m6_recovery.snapshot%ROWTYPE; actual m6_recovery.snapshot%ROWTYPE;
BEGIN
    SELECT * INTO STRICT expected FROM m6_recovery.snapshot;
    SELECT
        (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM pgreact.episodes e),
        (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY episode_id, attempt_no), '[]'::jsonb)
         FROM pgreact.attempts a),
        (SELECT jsonb_agg(to_jsonb(b) ORDER BY claimed_at, batch_id) FROM pgreact.batch_history() b),
        (SELECT jsonb_agg(to_jsonb(e) ORDER BY episode_id) FROM m6_recovery.effects e)
    INTO actual;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M6 durable state changed across crash restart: %', to_jsonb(actual);
    END IF;
END
$$;

SELECT 'M6 crash restart preserved exact batch and episode state' AS result;
