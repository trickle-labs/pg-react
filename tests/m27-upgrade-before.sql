\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SELECT pgreact_api.run('2026-01-01 00:00:00+00'::timestamptz);
CREATE SCHEMA m27_upgrade;
CREATE TABLE m27_upgrade.candidates (
    subject bigint NOT NULL, candidate bigint NOT NULL, priority bigint NOT NULL,
    result text NOT NULL, PRIMARY KEY (subject, candidate)
);
INSERT INTO m27_upgrade.candidates VALUES (77, 7701, 1, 'preserved');
SELECT pgreact_api.author_decision_program(
    'm27-upgrade', 'm27_upgrade.candidates'::regclass,
    'subject', 'candidate', 'priority', ARRAY['result']::name[],
    (SELECT frontier FROM pgreact_internal.clock_frontier), NULL, 10);
