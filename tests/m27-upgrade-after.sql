\set ON_ERROR_STOP on
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object('state', state, 'candidate', winner_candidate,
                              'result', winner_result)
    INTO actual
    FROM pgreact.decision_winners
    WHERE program_name = 'm27-upgrade' AND subject_key = 77;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'state', 'WINNER', 'candidate', 7701,
        'result', jsonb_build_object('result', 'preserved')) THEN
        RAISE EXCEPTION 'M27 populated upgrade changed: %', actual;
    END IF;
END $$;
SELECT pgreact_api.decision_analysis_status() ->> 'contract_version' AS analysis_contract_version;
