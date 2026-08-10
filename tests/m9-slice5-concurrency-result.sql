\set ON_ERROR_STOP on
\o /dev/null

DO $$
DECLARE failure jsonb;
BEGIN
    IF m9_slice5.state() IS DISTINCT FROM m9_slice5.expected_v3() THEN
        RAISE EXCEPTION 'M9 slice 5 concurrent work changed V3: %',
            m9_slice5.state();
    END IF;
    SELECT jsonb_build_object(
        'prior_frontier', prior_frontier,
        'committed_frontier', committed_frontier,
        'iterations', iterations,
        'fact_count', fact_count,
        'support_count', support_count,
        'status', status,
        'sqlstate', error_sqlstate,
        'message', error_message,
        'detail', error_detail,
        'hint', error_hint,
        'requested_by', requested_by)
    INTO failure
    FROM pgreact.derivation_program_runs
    WHERE program_version_id = (
        SELECT program_version_id FROM m9_slice5.concurrent_control)
      AND status = 'FAILED'
    ORDER BY run_id DESC LIMIT 1;
    IF failure IS DISTINCT FROM jsonb_build_object(
        'prior_frontier', 1,
        'committed_frontier', 1,
        'iterations', 0,
        'fact_count', NULL,
        'support_count', NULL,
        'status', 'FAILED',
        'sqlstate', '55P03',
        'message', 'canceling statement due to lock timeout',
        'detail', NULL,
        'hint', NULL,
        'requested_by', current_user) THEN
        RAISE EXCEPTION 'M9 slice 5 concurrent failure changed: %', failure;
    END IF;
END
$$;

\o
SELECT 'M9 slice 5 concurrent refresh and DDL gate passed' AS result;
