\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
CREATE SCHEMA cycle_bound32;
CREATE TABLE cycle_bound32.source(id bigint PRIMARY KEY, deadline timestamptz NOT NULL);
INSERT INTO cycle_bound32.source
SELECT id, '2000-01-01 00:00:00+00'::timestamptz + (id - 1) * interval '1 day'
FROM generate_series(1, current_setting('pg_react.batch_size')::integer + 1) AS due(id);
INSERT INTO cycle_bound32.source VALUES
    (current_setting('pg_react.batch_size')::integer + 2, '2100-01-01 00:00:00+00');
CREATE TABLE cycle_bound32.actions(LIKE cycle_bound32.source INCLUDING ALL);
CREATE VIEW cycle_bound32.candidate AS SELECT * FROM cycle_bound32.source;
CREATE FUNCTION cycle_bound32.deliver(
    context pgreact.activation_context, candidate cycle_bound32.candidate
) RETURNS void LANGUAGE SQL AS $callback$
    INSERT INTO cycle_bound32.actions VALUES (($2).id,($2).deadline)
$callback$;
SELECT pgreact_api.author_deadline_rule(
    'cycle-bound32','cycle_bound32.candidate'::regclass,'id','deadline','COMMAND',
    'cycle_bound32.deliver(pgreact.activation_context,cycle_bound32.candidate)');

CREATE FUNCTION cycle_bound32.state() RETURNS jsonb LANGUAGE SQL AS $state$
    SELECT jsonb_build_object(
        'actions',(SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY id),'[]') FROM cycle_bound32.actions a),
        'work',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',(a.new_bindings->>'id')::bigint,'state',a.state,
            'claimable',w.claimable) ORDER BY (a.new_bindings->>'id')::bigint),'[]')
            FROM pgreact_internal.agenda a JOIN pgreact.work w ON w.work_id=a.episode_id::text
            WHERE w.name='cycle-bound32'),
        'attempts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',(a.new_bindings->>'id')::bigint,'attempt_no',e.attempt_no,
            'status',e.status,'error_code',e.error_code) ORDER BY (a.new_bindings->>'id')::bigint),'[]')
            FROM pgreact_internal.agenda a JOIN pgreact.attempts e USING(episode_id)
            WHERE e.name='cycle-bound32'))
$state$;

CREATE FUNCTION cycle_bound32.expected_state(processed_through integer, due_total integer)
RETURNS jsonb LANGUAGE SQL IMMUTABLE AS $expected$
    SELECT jsonb_build_object(
        'actions',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',id,'deadline','2000-01-01 00:00:00+00'::timestamptz + (id - 1) * interval '1 day'
        ) ORDER BY id),'[]') FROM generate_series(1,processed_through) AS rows(id)),
        'work',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',id,'state',CASE WHEN id <= processed_through THEN 'COMPLETED' ELSE 'PENDING' END,
            'claimable',id > processed_through) ORDER BY id),'[]')
            FROM generate_series(1,due_total) AS rows(id)),
        'attempts',(SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',id,'attempt_no',1,'status','COMPLETED','error_code',NULL
        ) ORDER BY id),'[]') FROM generate_series(1,processed_through) AS rows(id)))
$expected$;

CREATE TABLE cycle_bound32.evidence(cycle integer PRIMARY KEY, result jsonb, state jsonb);
DO $cycles$
DECLARE batch_limit integer := current_setting('pg_react.batch_size')::integer;
    due_total integer := batch_limit + 1;
    result jsonb;
    actual jsonb;
    expected_source jsonb;
BEGIN
    IF batch_limit <> 32 THEN
        RAISE EXCEPTION 'qualification requires batch_size=32, got %', batch_limit;
    END IF;
    SELECT jsonb_agg(to_jsonb(source_row) ORDER BY source_row.id) INTO expected_source
    FROM cycle_bound32.source AS source_row;

    result := pgreact_api.managed_cycle();
    actual := cycle_bound32.state();
    IF actual IS DISTINCT FROM cycle_bound32.expected_state(batch_limit,due_total)
       OR (result-'run'-'runtime_state') IS DISTINCT FROM
          '{"state":"ready","processed_jobs":32,"pending_jobs":1}'::jsonb THEN
        RAISE EXCEPTION 'first managed cycle did not process exactly the 32-item prefix and preserve the 33rd item: % / %', result,actual;
    END IF;
    INSERT INTO cycle_bound32.evidence VALUES (1,result,actual);

    result := pgreact_api.managed_cycle();
    actual := cycle_bound32.state();
    IF actual IS DISTINCT FROM cycle_bound32.expected_state(due_total,due_total)
       OR (result-'run'-'runtime_state') IS DISTINCT FROM
          '{"state":"ready","processed_jobs":1,"pending_jobs":0}'::jsonb THEN
        RAISE EXCEPTION 'second managed cycle did not deliver the exact remaining item: % / %', result,actual;
    END IF;
    INSERT INTO cycle_bound32.evidence VALUES (2,result,actual);

    result := pgreact_api.managed_cycle();
    actual := cycle_bound32.state();
    IF actual IS DISTINCT FROM cycle_bound32.expected_state(due_total,due_total)
       OR (result-'run'-'runtime_state') IS DISTINCT FROM
          '{"state":"ready","processed_jobs":0,"pending_jobs":0}'::jsonb
       OR (SELECT jsonb_agg(to_jsonb(source_row) ORDER BY source_row.id)
           FROM cycle_bound32.source AS source_row) IS DISTINCT FROM expected_source THEN
        RAISE EXCEPTION 'later managed cycle replayed work, admitted the future item, or changed source rows: % / %',result,actual;
    END IF;
    INSERT INTO cycle_bound32.evidence VALUES (3,result,actual);
END
$cycles$;
SELECT 'managed cycle 32-claim admission vectors passed';
