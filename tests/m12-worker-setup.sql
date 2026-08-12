\set ON_ERROR_STOP on
CREATE SCHEMA m12_worker;
CREATE TABLE m12_worker.source (
    id bigint PRIMARY KEY,
    deadline timestamptz NOT NULL
);
CREATE VIEW m12_worker.candidate AS
SELECT id, deadline FROM m12_worker.source;
CREATE FUNCTION m12_worker.activate(
    context pgreact.activation_context,
    candidate m12_worker.candidate
)
RETURNS void LANGUAGE SQL AS $$ SELECT $$;
INSERT INTO m12_worker.source VALUES (1, '2000-01-01 00:00:00+00');
SELECT pgreact_api.author_deadline_rule(
    'worker-deadline', 'm12_worker.candidate'::regclass,
    'id', 'deadline', 'COMMAND',
    'm12_worker.activate(pgreact.activation_context,m12_worker.candidate)');
