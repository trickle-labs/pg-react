\set ON_ERROR_STOP on
SELECT pgreact_api.author_decision_program(
    'm26-upgrade', 'm26_upgrade.candidates'::regclass,
    'subject', 'candidate', 'priority', ARRAY['result']::name[],
    clock_timestamp(), NULL, 10) AS version_id \gset
DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object('state', state, 'candidate', winner_candidate,
                              'result', winner_result)
    INTO actual
    FROM pgreact.decision_winners
    WHERE program_name = 'm26-upgrade' AND subject_key = 77;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'state', 'WINNER', 'candidate', 7701,
        'result', jsonb_build_object('result', 'preserved')) THEN
        RAISE EXCEPTION 'M26 populated upgrade changed: %', actual;
    END IF;
END
$$;
