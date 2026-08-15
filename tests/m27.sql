\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

SELECT pgreact_api.run('2026-01-01 00:00:00+00'::timestamptz);
SELECT frontier AS base_time FROM pgreact_internal.clock_frontier \gset

CREATE SCHEMA m27_reference;
CREATE TABLE m27_reference.population (subject bigint PRIMARY KEY);
INSERT INTO m27_reference.population SELECT generate_series(1, 6);
CREATE TABLE m27_reference.catalog (
    candidate bigint PRIMARY KEY,
    required_default boolean NOT NULL
);
INSERT INTO m27_reference.catalog
VALUES (101, false), (102, false), (103, false), (104, false),
       (105, false), (106, false), (107, false), (108, false);

CREATE TABLE m27_reference.current_candidates (
    subject bigint NOT NULL, candidate bigint NOT NULL, priority bigint NOT NULL,
    result text NOT NULL, PRIMARY KEY (subject, candidate)
);
INSERT INTO m27_reference.current_candidates
SELECT subject, 100 + subject, 1, 'current-' || subject FROM m27_reference.population;

CREATE TABLE m27_reference.bad_candidates (
    subject bigint NOT NULL, candidate bigint NOT NULL, priority bigint NOT NULL,
    result text NOT NULL, PRIMARY KEY (subject, candidate)
);
INSERT INTO m27_reference.bad_candidates VALUES
    (1, 101, 1, 'same'), (1, 107, 1, 'tie'),
    (2, 102, 1, 'same'), (2, 103, 2, 'overlap'),
    (3, 104, 1, 'changed'), (4, 105, 1, 'changed'),
    (5, 106, 1, 'changed');

CREATE TABLE m27_reference.pass_candidates (
    subject bigint NOT NULL, candidate bigint NOT NULL, priority bigint NOT NULL,
    result text NOT NULL, PRIMARY KEY (subject, candidate)
);
INSERT INTO m27_reference.pass_candidates
SELECT subject, 100 + subject, 1, 'current-' || subject FROM m27_reference.population;
CREATE TABLE m27_reference.pass_catalog (
    candidate bigint PRIMARY KEY,
    required_default boolean NOT NULL
);
INSERT INTO m27_reference.pass_catalog
SELECT candidate, false FROM m27_reference.catalog WHERE candidate < 107;

SELECT pgreact_api.author_decision_program(
    'm27-orders', 'm27_reference.current_candidates'::regclass,
    'subject', 'candidate', 'priority', ARRAY['result']::name[],
    :'base_time'::timestamptz, :'base_time'::timestamptz + interval '10 minutes', 20) AS current_id \gset
SELECT pgreact_api.author_decision_program(
    'm27-orders', 'm27_reference.bad_candidates'::regclass,
    'subject', 'candidate', 'priority', ARRAY['result']::name[],
    :'base_time'::timestamptz + interval '10 minutes',
    :'base_time'::timestamptz + interval '20 minutes', 20) AS bad_id \gset
SELECT pgreact_api.author_decision_program(
    'm27-orders', 'm27_reference.pass_candidates'::regclass,
    'subject', 'candidate', 'priority', ARRAY['result']::name[],
    :'base_time'::timestamptz + interval '20 minutes', NULL, 20) AS pass_id \gset

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT COALESCE(jsonb_agg(code ORDER BY code), '[]'::jsonb) INTO actual
    FROM pgreact_api.validate_decision_analysis(
        'm27-orders', (SELECT version_id FROM pgreact_internal.decision_program_versions
                       WHERE program_id = (SELECT program_id FROM pgreact_internal.decision_programs
                                           WHERE program_name = 'm27-orders') AND version_no = 1),
        (SELECT version_id FROM pgreact_internal.decision_program_versions
         WHERE program_id = (SELECT program_id FROM pgreact_internal.decision_programs
                             WHERE program_name = 'm27-orders') AND version_no = 2),
        'm27_reference.population'::regclass, 'subject',
        'm27_reference.catalog'::regclass, 'candidate', 'required_default')
    WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'valid M27 declaration rejected: %', actual;
    END IF;
END $$;

SELECT pgreact_api.author_decision_analysis(
    'm27-bad', 'm27-orders', :'current_id'::uuid, :'bad_id'::uuid,
    'm27_reference.population'::regclass, 'subject',
    'm27_reference.catalog'::regclass, 'candidate', 'required_default',
    true, true, 0, NULL, 25, 100) AS bad_analysis_id \gset
SELECT pgreact_api.analyze_decision_analysis(:'bad_analysis_id'::uuid) AS bad_report \gset

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_agg(code ORDER BY code) INTO actual
    FROM pgreact.decision_analysis_findings
    WHERE analysis_id = (SELECT analysis_id FROM pgreact_internal.decision_analyses
                         WHERE analysis_name = 'm27-bad') AND affected_count > 0;
    IF actual IS DISTINCT FROM jsonb_build_array(
        'M27_FORBIDDEN_OVERLAP', 'M27_MISSING_REQUIRED_DEFAULT',
        'M27_TIED_BEST_CANDIDATE', 'M27_UNCOVERED_POPULATION',
        'M27_UNREACHABLE_CANDIDATE', 'M27_WINNER_DISTRIBUTION') THEN
        RAISE EXCEPTION 'M27 finding codes changed: %', actual;
    END IF;
    IF (SELECT count(*) FROM pgreact.decision_analysis_findings
        WHERE analysis_id = (SELECT analysis_id FROM pgreact_internal.decision_analyses
                             WHERE analysis_name = 'm27-bad') AND truncated) <> 0 THEN
        RAISE EXCEPTION 'M27 evidence unexpectedly truncated';
    END IF;
END $$;

DO $$
BEGIN
    BEGIN
        PERFORM pgreact_api.admit_decision_version(
            'm27-orders', (SELECT proposed_version_id FROM pgreact_internal.decision_analyses
                           WHERE analysis_name = 'm27-bad'),
            (SELECT analysis_id FROM pgreact_internal.decision_analyses
             WHERE analysis_name = 'm27-bad'));
        RAISE EXCEPTION 'blocked M27 analysis was admitted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%M27_%' THEN RAISE; END IF;
    END;
END $$;

SELECT pgreact_api.author_decision_analysis(
    'm27-pass', 'm27-orders', :'current_id'::uuid, :'pass_id'::uuid,
    'm27_reference.population'::regclass, 'subject',
    'm27_reference.pass_catalog'::regclass, 'candidate', 'required_default',
    false, true, 0, NULL, 25, 100) AS pass_analysis_id \gset

DO $$
DECLARE first_report jsonb; second_report jsonb;
BEGIN
    first_report := pgreact_api.analyze_decision_analysis(
        (SELECT analysis_id FROM pgreact_internal.decision_analyses
         WHERE analysis_name = 'm27-pass'));
    second_report := pgreact_api.analyze_decision_analysis(
        (SELECT analysis_id FROM pgreact_internal.decision_analyses
         WHERE analysis_name = 'm27-pass'));
    IF first_report IS DISTINCT FROM second_report
       OR first_report ->> 'state' <> 'PASS'
       OR jsonb_array_length(first_report -> 'findings') <> 0
       OR (SELECT count(*) FROM pgreact.decision_analysis_findings
           WHERE analysis_id = (SELECT analysis_id FROM pgreact_internal.decision_analyses
                                WHERE analysis_name = 'm27-pass') AND affected_count > 0) <> 0 THEN
        RAISE EXCEPTION 'M27 pass or determinism changed: %, %', first_report, second_report;
    END IF;
END $$;

DO $$
BEGIN
    IF (pgreact_api.decision_analysis_status('m27-orders') ->> 'contract_version') <> '15'
       OR jsonb_array_length(pgreact_api.decision_analysis_history(
           (SELECT analysis_id FROM pgreact_internal.decision_analyses
            WHERE analysis_name = 'm27-pass')) -> 'events') <> 2 THEN
        RAISE EXCEPTION 'M27 status/history changed';
    END IF;
END $$;

INSERT INTO m27_reference.population VALUES (7);
DO $$
BEGIN
    BEGIN
        PERFORM pgreact_api.admit_decision_version(
            'm27-orders', (SELECT proposed_version_id FROM pgreact_internal.decision_analyses
                           WHERE analysis_name = 'm27-pass'),
            (SELECT analysis_id FROM pgreact_internal.decision_analyses
             WHERE analysis_name = 'm27-pass'));
        RAISE EXCEPTION 'stale M27 analysis was admitted';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT LIKE '%M27_%' THEN RAISE; END IF;
    END;
END $$;

SELECT 'M27 SQL evidence passed' AS result;
