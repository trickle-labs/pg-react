\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

SELECT pgreact_api.run('2026-01-01 00:00:00+00'::timestamptz);
SELECT frontier AS base_time FROM pgreact_internal.clock_frontier \gset

CREATE SCHEMA m26_reference;
CREATE TABLE m26_reference.candidates (
    subject bigint NOT NULL,
    candidate bigint NOT NULL,
    priority bigint NOT NULL,
    result text NOT NULL,
    PRIMARY KEY (subject, candidate)
);
INSERT INTO m26_reference.candidates VALUES
    (1, 101, 20, 'fallback'), (1, 102, 10, 'preferred'),
    (2, 201, 5, 'left'), (2, 202, 5, 'right'),
    (3, 301, 1, 'temporary');

CREATE TABLE m26_reference.bad_result (
    subject bigint NOT NULL,
    candidate bigint NOT NULL,
    priority bigint NOT NULL,
    payload jsonb NOT NULL,
    PRIMARY KEY (subject, candidate)
);
CREATE TABLE m26_reference.bad_duplicates (
    subject bigint NOT NULL,
    candidate bigint NOT NULL,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m26_reference.bad_duplicates VALUES (1, 1, 1, 'a'), (1, 1, 2, 'b');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('code', code, 'severity', severity)
                     ORDER BY code)
    INTO actual
    FROM pgreact_api.validate_decision_program(
        'm26-bad-result', 'm26_reference.bad_result'::regclass,
        'subject', 'candidate', 'priority', ARRAY['payload']::name[])
    WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('code', 'M26_RESULT_TYPE', 'severity', 'ERROR')) THEN
        RAISE EXCEPTION 'M26 invalid result declaration changed: %', actual;
    END IF;
END
$$;

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(code ORDER BY code)
    INTO actual
    FROM pgreact_api.validate_decision_program(
        'm26-bad-duplicates', 'm26_reference.bad_duplicates'::regclass,
        'subject', 'candidate', 'priority', ARRAY['result']::name[])
    WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM jsonb_build_array('M26_CANDIDATE_UNIQUE') THEN
        RAISE EXCEPTION 'M26 duplicate candidate validation changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.author_decision_program(
    'm26-orders', 'm26_reference.candidates'::regclass,
    'subject', 'candidate', 'priority', ARRAY['result']::name[],
    :'base_time'::timestamptz, NULL, 10) AS version_id \gset

DO $$
DECLARE actual jsonb;
    expected jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'subject', subject_key,
        'state', state,
        'candidate', winner_candidate,
        'priority', winner_priority,
        'result', winner_result,
        'claimable', claimable,
        'generation', generation,
        'revision', revision,
        'competitors', competitors)
        ORDER BY subject_key)
    INTO actual
    FROM pgreact.decision_winners
    WHERE program_name = 'm26-orders';
    expected := jsonb_build_array(
        jsonb_build_object('subject', 1, 'state', 'WINNER', 'candidate', 102,
            'priority', 10, 'result', jsonb_build_object('result', 'preferred'),
            'claimable', true, 'generation', 1, 'revision', 0,
            'competitors', jsonb_build_array(
                jsonb_build_object('candidate', 102, 'priority', 10,
                    'result', jsonb_build_object('result', 'preferred')),
                jsonb_build_object('candidate', 101, 'priority', 20,
                    'result', jsonb_build_object('result', 'fallback')))),
        jsonb_build_object('subject', 2, 'state', 'AMBIGUOUS', 'candidate', NULL,
            'priority', 5, 'result', NULL, 'claimable', false,
            'generation', 0, 'revision', 0,
            'competitors', jsonb_build_array(
                jsonb_build_object('candidate', 201, 'priority', 5,
                    'result', jsonb_build_object('result', 'left')),
                jsonb_build_object('candidate', 202, 'priority', 5,
                    'result', jsonb_build_object('result', 'right')))),
        jsonb_build_object('subject', 3, 'state', 'WINNER', 'candidate', 301,
            'priority', 1, 'result', jsonb_build_object('result', 'temporary'),
            'claimable', true, 'generation', 1, 'revision', 0,
            'competitors', jsonb_build_array(
                jsonb_build_object('candidate', 301, 'priority', 1,
                    'result', jsonb_build_object('result', 'temporary')))));
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M26 initial winner matrix changed: actual %, expected %', actual, expected;
    END IF;
END
$$;

DO $$
DECLARE preview jsonb;
    explanation jsonb;
BEGIN
    preview := pgreact_api.decision_preview('m26-orders');
    explanation := pgreact_api.decision_explain('m26-orders', 1);
    IF preview ->> 'contract_version' <> '14'
       OR preview ->> 'side_effect_free' <> 'true'
       OR jsonb_array_length(preview -> 'subjects') <> 3
       OR explanation -> 'current' ->> 'state' <> 'WINNER'
       OR explanation -> 'current' ->> 'winner_candidate' <> '102'
       OR jsonb_array_length(explanation -> 'lifecycle') <> 1 THEN
        RAISE EXCEPTION 'M26 preview or explanation changed: %, %', preview, explanation;
    END IF;
END
$$;

UPDATE m26_reference.candidates SET priority = 0 WHERE subject = 1 AND candidate = 101;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '1 minute');
UPDATE m26_reference.candidates SET result = 'revised' WHERE subject = 1 AND candidate = 101;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '2 minutes');
DELETE FROM m26_reference.candidates WHERE subject = 2 AND candidate = 202;
DELETE FROM m26_reference.candidates WHERE subject = 3;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '3 minutes');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object(
        'subject', subject_key, 'state', state, 'candidate', winner_candidate,
        'priority', winner_priority, 'result', winner_result,
        'generation', generation, 'revision', revision, 'claimable', claimable)
        ORDER BY subject_key)
    INTO actual
    FROM pgreact.decision_winners WHERE program_name = 'm26-orders';
    IF actual IS DISTINCT FROM jsonb_build_array(
        jsonb_build_object('subject', 1, 'state', 'WINNER', 'candidate', 101,
            'priority', 0, 'result', jsonb_build_object('result', 'revised'),
            'generation', 2, 'revision', 1, 'claimable', true),
        jsonb_build_object('subject', 2, 'state', 'WINNER', 'candidate', 201,
            'priority', 5, 'result', jsonb_build_object('result', 'left'),
            'generation', 1, 'revision', 0, 'claimable', true),
        jsonb_build_object('subject', 3, 'state', 'NO_CANDIDATE', 'candidate', NULL,
            'priority', NULL, 'result', NULL, 'generation', 1, 'revision', 0,
            'claimable', false)) THEN
        RAISE EXCEPTION 'M26 transition matrix changed: %', actual;
    END IF;
END
$$;

INSERT INTO m26_reference.candidates VALUES (3, 301, 1, 'restored');
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '4 minutes');

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(event_kind ORDER BY event_id)
    INTO actual
    FROM pgreact.decision_history WHERE program_name = 'm26-orders';
    IF actual IS DISTINCT FROM jsonb_build_array(
        'WINNER_IN', 'AMBIGUITY_ENTER', 'WINNER_IN',
        'WINNER_OUT', 'WINNER_IN', 'WINNER_REVISION',
        'AMBIGUITY_EXIT', 'WINNER_IN', 'WINNER_OUT', 'NO_CANDIDATE', 'WINNER_IN') THEN
        RAISE EXCEPTION 'M26 lifecycle history changed: %', actual;
    END IF;
END
$$;

SELECT pgreact_api.pause_decision_program('m26-orders');
UPDATE m26_reference.candidates SET priority = 99 WHERE subject = 1 AND candidate = 101;
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '5 minutes');
DO $$
BEGIN
    IF (SELECT winner_priority FROM pgreact.decision_winners
        WHERE program_name = 'm26-orders' AND subject_key = 1) <> 0 THEN
        RAISE EXCEPTION 'M26 pause allowed a winner change';
    END IF;
END
$$;
SELECT pgreact_api.resume_decision_program('m26-orders');
SELECT pgreact_api.run(:'base_time'::timestamptz + interval '6 minutes');

DO $$
DECLARE status jsonb;
    doctor jsonb;
BEGIN
    status := pgreact_api.decision_status('m26-orders');
    doctor := pgreact_api.decision_doctor();
    IF status ->> 'contract_version' <> '14'
       OR (status -> 'programs' -> 0 ->> 'program_name') <> 'm26-orders'
       OR (doctor ->> 'status') <> 'ready'
       OR jsonb_array_length(doctor -> 'diagnostics') <> 0 THEN
        RAISE EXCEPTION 'M26 status or doctor changed: %, %', status, doctor;
    END IF;
END
$$;
