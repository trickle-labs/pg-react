\set ON_ERROR_STOP on
\o /dev/null
SET TIME ZONE 'UTC';
SET client_min_messages = error;

\if :worker_loss
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.doctor();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 6, 'status', 'attention',
        'diagnostics', jsonb_build_array(jsonb_build_object(
            'code', 'M15_MANAGED_PROCESS', 'severity', 'ERROR',
            'object_identity', current_database(),
            'message', 'managed worker heartbeat is stale',
            'hint', format(
                'Restart the pg-react managed worker for database %L; then run SELECT pgreact_api.doctor().',
                current_database())))) THEN
        RAISE EXCEPTION 'M18 worker-loss diagnosis changed: %', actual;
    END IF;
END
$$;
\o
SELECT 'M18 public worker-loss diagnosis passed';
\else
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'effects', (SELECT jsonb_agg(id ORDER BY id) FROM m18_day2.effects),
        'job', (pgreact_api.jobs('day2.slow-command') #> '{jobs,0}') -
            ARRAY['job_id','available_at','claimed_at','completed_at','idempotency_key'])
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'effects', jsonb_build_array(1),
        'job', jsonb_build_object(
            'rule', 'day2.slow-command', 'action', 'activate',
            'state', 'completed', 'key', 1)) THEN
        RAISE EXCEPTION 'M18 queued command recovery changed: %', actual;
    END IF;
END
$$;
INSERT INTO m17_reference.items VALUES (19,7,1,'1970-01-01T00:45:00Z');
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run('2030-01-04T00:00:20Z');
SELECT pgreact_api.request_watermark(
    'm17.reference', 'm17_reference.item_source', 'occurred_at',
    '1970-01-01T01:15:00Z');
SELECT pgreact_api.run('2030-01-04T00:00:21Z');
SELECT pgreact_api.run('2030-01-04T00:00:22Z');
RESET SESSION AUTHORIZATION;
INSERT INTO m17_reference.items VALUES (20,7,100,'1970-01-01T00:50:00Z');
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.run('2030-01-04T00:00:23Z');
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    actual := pgreact_api.doctor();
    IF actual IS DISTINCT FROM jsonb_build_object(
        'contract_version', 6, 'status', 'attention',
        'diagnostics', jsonb_build_array(jsonb_build_object(
            'code', 'M17_LATE_INPUT_BARRIER', 'severity', 'ERROR',
            'object_identity', 'm17.reference',
            'message', 'program is blocked by input beyond a finalized window',
            'hint', 'Restore the authoritative input and call pgreact_api.reconcile_program.'))) THEN
        RAISE EXCEPTION 'M18 state-drift diagnosis changed: %', actual;
    END IF;
END
$$;
DELETE FROM m17_reference.items WHERE item_id = 20;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.reconcile_program('m17.reference');
RESET SESSION AUTHORIZATION;
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'doctor', pgreact_api.doctor(),
        'sum', (SELECT jsonb_build_object(
            'key', public_window_key, 'value', exact_value,
            'truth', truth_result, 'generation', support_generation,
            'final', is_final)
            FROM pgreact.window_evidence
            WHERE program_name = 'm17.reference' AND rule_name = 'm17.sum_amount'
              AND public_window_key = '[7,0]'::jsonb),
        'watermark', (SELECT to_jsonb(row_value)
            FROM pgreact_api.watermark_status('m17.reference') row_value))
    INTO actual;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'doctor', jsonb_build_object(
            'contract_version', 6, 'status', 'ready', 'diagnostics', '[]'::jsonb),
        'sum', jsonb_build_object(
            'key', jsonb_build_array(7,0), 'value', '13',
            'truth', true, 'generation', 1, 'final', true),
        'watermark', jsonb_build_object(
            'input_relation', 'm17_reference.item_source',
            'event_time_column', 'occurred_at',
            'requested_watermark', '1970-01-01T01:15:00+00:00',
            'complete_watermark', '1970-01-01T01:15:00+00:00',
            'history_floor', '-infinity', 'status', 'complete', 'barrier', NULL)) THEN
        RAISE EXCEPTION 'M18 day-2 continued transcript changed: %', actual;
    END IF;
END
$$;
SET SESSION AUTHORIZATION m17_operator;
SELECT pgreact_api.pause_rule('day2.slow-command');
SELECT pgreact_api.remove_rule('day2.slow-command');
RESET SESSION AUTHORIZATION;
DROP SCHEMA m18_day2 CASCADE;
\o
SELECT 'M18 state-drift reconciliation and continued execution passed';
\endif
