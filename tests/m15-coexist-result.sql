\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

SET SESSION AUTHORIZATION m15_worker;
SELECT pgreact_api.managed_cycle();
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg((attempt - ARRAY['started_at', 'finished_at', 'worker', 'job_id']) ||
        jsonb_build_object('worker_path', CASE
            WHEN attempt ->> 'worker' = 'transition-worker' THEN 'external'
            WHEN attempt ->> 'worker' LIKE 'pg-react-managed/%' THEN 'managed'
            ELSE attempt ->> 'worker' END)
        ORDER BY attempt ->> 'attempt')
    INTO actual
    FROM jsonb_array_elements(pgreact_api.attempts('m15.retry') -> 'attempts') attempt
    WHERE attempt -> 'key' = jsonb_build_array(
        'coexist', '123e4567-e89b-12d3-a456-426614174024');
    IF actual IS DISTINCT FROM jsonb_build_array(jsonb_build_object(
            'attempt', 1, 'status', 'completed', 'error_code', NULL,
            'error_message', NULL,
            'key', jsonb_build_array('coexist', '123e4567-e89b-12d3-a456-426614174024'),
            'worker_path', CASE WHEN actual #>> '{0,worker_path}' IN ('external', 'managed')
                                THEN actual #>> '{0,worker_path}' ELSE 'invalid' END))
       OR (SELECT count(*) FROM m15_lifecycle.retry_effects WHERE public_key =
            jsonb_build_array('coexist', '123e4567-e89b-12d3-a456-426614174024')) <> 1
       OR pgreact_api.jobs('m15.retry') #> '{jobs,1,state}' IS DISTINCT FROM '"completed"'::jsonb THEN
        RAISE EXCEPTION 'M15 managed/external claim fencing changed: %', actual;
    END IF;
END
$$;

SELECT 'M15 managed/external single-lease coexistence passed';
