\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';
SET client_min_messages = warning;

CREATE SCHEMA m55_bench;
CREATE TABLE m55_bench.source(
    id bigint PRIMARY KEY,
    state text NOT NULL,
    conflict_key integer NOT NULL DEFAULT 1
);
CREATE VIEW m55_bench.source_view AS
SELECT id, state, conflict_key FROM m55_bench.source;
CREATE TABLE m55_bench.proposed_source(
    id bigint PRIMARY KEY,
    state text NOT NULL,
    conflict_key integer NOT NULL DEFAULT 1
);
CREATE VIEW m55_bench.proposed_view AS
SELECT id, state, conflict_key FROM m55_bench.proposed_source;
CREATE TABLE m55_bench.subjects(id bigint PRIMARY KEY);
CREATE TABLE m55_bench.effects(episode_id bigint PRIMARY KEY, source_id bigint NOT NULL);
CREATE TABLE m55_bench.unrelated_history(id bigint PRIMARY KEY, recorded_at timestamptz NOT NULL);
CREATE TABLE m55_bench.measurement(
    elapsed_ms numeric NOT NULL,
    correctness boolean NOT NULL,
    state_hash text NOT NULL,
    wal_before bigint NOT NULL,
    wal_after bigint NOT NULL,
    result jsonb NOT NULL,
    details jsonb NOT NULL
);

CREATE FUNCTION m55_bench.activate(
    context pgreact.activation_context,
    row_value m55_bench.source_view
)
RETURNS void LANGUAGE SQL AS $m55bench$
    INSERT INTO m55_bench.effects(episode_id, source_id)
    VALUES (($1).episode_id, ($2).id)
    ON CONFLICT (episode_id) DO NOTHING
$m55bench$;

CREATE FUNCTION m55_bench.wal_bytes()
RETURNS bigint LANGUAGE SQL STABLE AS $m55bench$
    SELECT wal_bytes::bigint FROM pg_stat_wal
$m55bench$;

CREATE FUNCTION m55_bench.pending_count()
RETURNS bigint LANGUAGE SQL STABLE AS $m55bench$
    SELECT count(*)
    FROM pgreact_internal.agenda
    WHERE state IN ('PENDING', 'LEASED', 'RETRY_WAIT')
$m55bench$;

CREATE FUNCTION m55_bench.state_hash()
RETURNS text LANGUAGE SQL STABLE AS $m55bench$
    SELECT md5(jsonb_build_object(
        'source', (SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.id), '[]'::jsonb)
                   FROM m55_bench.source row_data),
        'proposed', (SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.id), '[]'::jsonb)
                     FROM m55_bench.proposed_source row_data),
        'effects', (SELECT COALESCE(jsonb_agg(to_jsonb(row_data) ORDER BY row_data.episode_id), '[]'::jsonb)
                    FROM m55_bench.effects row_data),
        'pending', m55_bench.pending_count())::text)
$m55bench$;

CREATE FUNCTION m55_bench.record(
    elapsed_ms numeric,
    correctness boolean,
    state_hash text,
    wal_before bigint,
    wal_after bigint,
    result jsonb,
    details jsonb
)
RETURNS void LANGUAGE SQL AS $m55bench$
    INSERT INTO m55_bench.measurement
    VALUES ($1, $2, $3, $4, $5, $6, $7)
$m55bench$;

CREATE FUNCTION m55_bench.deploy_command(rule_name text, lease_seconds integer)
RETURNS void LANGUAGE plpgsql AS $m55bench$
DECLARE declaration pgreact_api.declaration;
    preview jsonb;
BEGIN
    declaration := pgreact.rule(
        rule_name, 'm55_bench.source_view'::regclass, 'id', 'COMMAND',
        'm55_bench.activate(pgreact.activation_context,m55_bench.source_view)'::regprocedure,
        NULL, NULL, 'SEED_CURRENT', ARRAY['state']::name[], 5, 'hot',
        ARRAY['conflict_key']::name[], 2, 1, 2, lease_seconds);
    preview := pgreact.preview(declaration);
    PERFORM pgreact.deploy(declaration, pgreact.review_token(preview));
    PERFORM pgreact_api.run_rule(rule_name);
END
$m55bench$;

CREATE FUNCTION m55_bench.drain(worker text, rule_name text)
RETURNS bigint LANGUAGE plpgsql AS $m55bench$
DECLARE claimed record;
    version_id uuid;
    processed integer;
    total bigint := 0;
BEGIN
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = drain.rule_name
      AND version.state IN ('ACTIVE', 'DRAINING')
    ORDER BY version.created_at DESC
    LIMIT 1;
    LOOP
        SELECT * INTO claimed FROM pgreact.claim_episode(version_id, worker, 60);
        EXIT WHEN NOT FOUND;
        PERFORM pgreact.execute_claimed_episode(claimed.episode_id, worker, claimed.lease_token);
        total := total + 1;
    END LOOP;
    RETURN total;
END
$m55bench$;

SELECT set_config('m55_bench.matches', :'matches', false) AS configured_matches,
       set_config('m55_bench.history_rows', :'history_rows', false) AS configured_history
\gset

SELECT :'case_name' = 'comparison.fixed_target.unrelated_history' AS is_fixed,
       :'case_name' = 'comparison.shared_source.validation' AS is_shared,
       :'case_name' = 'runtime.empty_queue' AS is_empty,
       :'case_name' = 'runtime.sustained_backlog_hot_conflict' AS is_backlog,
       :'case_name' = 'recovery.worker_loss_expired_leases' AS is_recovery,
       :'case_name' = 'review.evidence_limit_1_and_100' AS is_review,
       :'case_name' = 'packages.layered_dag_61_nodes' AS is_package
\gset

\if :is_fixed
DO $m55bench$
DECLARE current_declaration pgreact_api.declaration;
    proposed_declaration pgreact_api.declaration;
    preview jsonb;
    comparison jsonb;
    started timestamptz;
    elapsed numeric;
    wal_before bigint;
    wal_after bigint;
BEGIN
    INSERT INTO m55_bench.source
    SELECT id, CASE WHEN id % 2 = 0 THEN 'open' ELSE 'review' END, 1
    FROM generate_series(1, 10) id;
    INSERT INTO m55_bench.proposed_source
    SELECT id, CASE WHEN id % 2 = 0 THEN 'approved' ELSE 'review' END, 1
    FROM generate_series(1, 10) id;
    INSERT INTO m55_bench.unrelated_history
    SELECT id, '2026-01-01 UTC'::timestamptz + id * interval '1 second'
    FROM generate_series(1, current_setting('m55_bench.history_rows')::integer) id;
    current_declaration := pgreact.rule(
        'm55-fixed-target', 'm55_bench.source_view'::regclass, 'id', 'CONSTRAINT');
    preview := pgreact.preview(current_declaration);
    PERFORM pgreact.deploy(current_declaration, pgreact.review_token(preview));
    PERFORM pgreact.run('2026-01-01 00:00:00 UTC');
    proposed_declaration := pgreact.rule(
        'm55-fixed-target', 'm55_bench.proposed_view'::regclass, 'id', 'CONSTRAINT');
    wal_before := m55_bench.wal_bytes();
    started := clock_timestamp();
    comparison := pgreact.compare(
        proposed_declaration, pgreact_api.target('rule', 'm55-fixed-target'),
        jsonb_build_object('evidence_limit', 100));
    elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
    wal_after := m55_bench.wal_bytes();
    PERFORM m55_bench.record(
        elapsed,
        comparison ->> 'state' = 'ready'
            AND comparison -> 'cost' ->> 'elapsed_ms' IS NOT NULL
            AND comparison -> 'evidence' ->> 'authoritative_checksum_before'
                = comparison -> 'evidence' ->> 'authoritative_checksum_after',
        m55_bench.state_hash(), wal_before, wal_after, comparison,
        jsonb_build_object(
            'unrelated_history_rows', current_setting('m55_bench.history_rows')::integer,
            'target_rows', 10,
            'provenance_scope', comparison -> 'evidence' -> 'provenance' ->> 'scope',
            'rows_considered', comparison -> 'cost' ->> 'rows_considered'));
END
$m55bench$;
\elif :is_shared
DO $m55bench$
DECLARE members pgreact_api.declaration[] := ARRAY[]::pgreact_api.declaration[];
    support pgreact_api.declaration;
    package pgreact_api.declaration;
    dependencies jsonb := '[]'::jsonb;
    result jsonb;
    started timestamptz;
    elapsed numeric;
    wal_before bigint;
    wal_after bigint;
    rule_name text;
    n integer;
BEGIN
    INSERT INTO m55_bench.source
    SELECT id, 'open', 1 FROM generate_series(1, 100) id;
    INSERT INTO m55_bench.subjects SELECT id FROM generate_series(1, 100) id;
    support := pgreact.shared_condition(
        'm55-shared-source', 'm55_bench.source_view'::regclass, ARRAY['id']::name[]);
    FOR n IN 1..10 LOOP
        rule_name := format('m55-shared-rule-%s', n);
        members := array_append(members, pgreact.rule(
            rule_name, 'm55_bench.source_view'::regclass, 'id', 'CONSTRAINT'));
        dependencies := dependencies || jsonb_build_array(jsonb_build_object(
            'from', jsonb_build_object('kind', 'rule', 'name', rule_name, 'version', '1'),
            'on', jsonb_build_object('kind', 'shared_condition',
                                     'name', 'm55-shared-source', 'version', '1')));
    END LOOP;
    package := pgreact.policy_set(
        'm55-shared-package', '1', members, 'm55_bench.subjects'::regclass,
        ARRAY['id']::name[], ARRAY[support], dependencies,
        '2026-01-01 00:00:00 UTC', NULL, 100);
    wal_before := m55_bench.wal_bytes();
    started := clock_timestamp();
    result := pgreact.validate(package);
    elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
    wal_after := m55_bench.wal_bytes();
    PERFORM m55_bench.record(
        elapsed, result ->> 'state' = 'ready',
        md5(jsonb_build_object('state', result ->> 'state',
                               'kind', result -> 'target')::text),
        wal_before, wal_after, result,
        jsonb_build_object('rules', 10, 'shared_sources', 1, 'source_rows', 100,
                           'dependency_edges', jsonb_array_length(dependencies)));
END
$m55bench$;
\elif :is_empty
DO $m55bench$
DECLARE result jsonb;
    started timestamptz;
    elapsed numeric;
    wal_before bigint;
    wal_after bigint;
    pending bigint;
BEGIN
    PERFORM m55_bench.deploy_command('m55-empty-queue', 60);
    wal_before := m55_bench.wal_bytes();
    started := clock_timestamp();
    result := pgreact.run('2026-01-01 00:00:00 UTC');
    elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
    wal_after := m55_bench.wal_bytes();
    pending := m55_bench.pending_count();
    PERFORM m55_bench.record(
        elapsed, pending = 0, m55_bench.state_hash(), wal_before, wal_after,
        COALESCE(result, '{}'::jsonb), jsonb_build_object('pending', pending));
END
$m55bench$;
\elif :is_backlog
DO $m55bench$
DECLARE processed bigint;
    pending_before bigint;
    pending_after bigint;
    started timestamptz;
    elapsed numeric;
    wal_before bigint;
    wal_after bigint;
BEGIN
    PERFORM m55_bench.deploy_command('m55-hot-backlog', 60);
    INSERT INTO m55_bench.source
    SELECT id, 'open', 1 FROM generate_series(1, current_setting('m55_bench.matches')::integer) id;
    PERFORM pgreact_api.run_rule('m55-hot-backlog');
    PERFORM pgreact.run('2030-01-01 00:00:00 UTC');
    pending_before := m55_bench.pending_count();
    wal_before := m55_bench.wal_bytes();
    started := clock_timestamp();
    processed := m55_bench.drain('m55-hot-worker', 'm55-hot-backlog');
    elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
    wal_after := m55_bench.wal_bytes();
    pending_after := m55_bench.pending_count();
    PERFORM m55_bench.record(
        elapsed, processed = current_setting('m55_bench.matches')::bigint AND pending_after = 0,
        m55_bench.state_hash(), wal_before, wal_after,
        jsonb_build_object('processed', processed),
        jsonb_build_object('matches', current_setting('m55_bench.matches')::integer, 'hot_conflict_key', 1,
                           'pending_before', pending_before, 'pending_after', pending_after));
END
$m55bench$;
\elif :is_recovery
DO $m55bench$
DECLARE claimed bigint;
    claimed_row record;
    version_id uuid;
    recovered bigint;
    pending bigint;
    started timestamptz;
    elapsed numeric;
    wal_before bigint;
    wal_after bigint;
BEGIN
    PERFORM m55_bench.deploy_command('m55-recovery', 1);
    INSERT INTO m55_bench.source VALUES (1, 'open', 1);
    PERFORM pgreact_api.run_rule('m55-recovery');
    PERFORM pgreact.run('2026-01-01 00:00:00 UTC');
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = 'm55-recovery'
      AND version.state IN ('ACTIVE', 'DRAINING')
    ORDER BY version.created_at DESC
    LIMIT 1;
    wal_before := m55_bench.wal_bytes();
    started := clock_timestamp();
    SELECT * INTO claimed_row
    FROM pgreact.claim_episode(version_id, 'm55-lost-worker', 1);
    claimed := CASE WHEN FOUND THEN 1 ELSE 0 END;
    PERFORM pg_sleep(1.1);
    recovered := pgreact.sweep_expired_leases('m55-recovery');
    elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
    wal_after := m55_bench.wal_bytes();
    pending := m55_bench.pending_count();
    PERFORM m55_bench.record(
        elapsed, claimed > 0 AND recovered > 0 AND pending > 0,
        m55_bench.state_hash(), wal_before, wal_after,
        jsonb_build_object('claimed', claimed, 'recovered', recovered),
        jsonb_build_object('lease_seconds', 1,
                           'worker_loss_simulation', 'abandoned lease',
                           'pending', pending));
END
$m55bench$;
\elif :is_review
DO $m55bench$
DECLARE current_declaration pgreact_api.declaration;
    proposed_declaration pgreact_api.declaration;
    preview jsonb;
    limited jsonb;
    complete jsonb;
    started timestamptz;
    elapsed numeric;
    wal_before bigint;
    wal_after bigint;
BEGIN
    INSERT INTO m55_bench.source
    SELECT id, 'review', 1 FROM generate_series(1, 100) id;
    INSERT INTO m55_bench.proposed_source
    SELECT id, CASE WHEN id % 2 = 0 THEN 'approved' ELSE 'review' END, 1
    FROM generate_series(1, 100) id;
    current_declaration := pgreact.rule(
        'm55-review-target', 'm55_bench.source_view'::regclass, 'id', 'CONSTRAINT');
    preview := pgreact.preview(current_declaration);
    PERFORM pgreact.deploy(current_declaration, pgreact.review_token(preview));
    PERFORM pgreact.run('2026-01-01 00:00:00 UTC');
    proposed_declaration := pgreact.rule(
        'm55-review-target', 'm55_bench.proposed_view'::regclass, 'id', 'CONSTRAINT');
    wal_before := m55_bench.wal_bytes();
    started := clock_timestamp();
    limited := pgreact.compare(
        proposed_declaration, pgreact_api.target('rule', 'm55-review-target'),
        jsonb_build_object('evidence_limit', 1));
    complete := pgreact.compare(
        proposed_declaration, pgreact_api.target('rule', 'm55-review-target'),
        jsonb_build_object('evidence_limit', 100));
    elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
    wal_after := m55_bench.wal_bytes();
    PERFORM m55_bench.record(
        elapsed,
        limited ->> 'state' = 'partial'
            AND limited ->> 'truncated' = 'true'
            AND complete ->> 'state' = 'ready'
            AND complete -> 'summary' ->> 'counts_exact' = 'true',
        m55_bench.state_hash(), wal_before, wal_after,
        jsonb_build_object('evidence_limit_1', limited, 'evidence_limit_100', complete),
        jsonb_build_object('target_rows', 100, 'limits', jsonb_build_array(1, 100)));
END
$m55bench$;
\elif :is_package
DO $m55bench$
DECLARE members pgreact_api.declaration[] := ARRAY[]::pgreact_api.declaration[];
    supports pgreact_api.declaration[] := ARRAY[]::pgreact_api.declaration[];
    package pgreact_api.declaration;
    dependencies jsonb := '[]'::jsonb;
    result jsonb;
    started timestamptz;
    elapsed numeric;
    wal_before bigint;
    wal_after bigint;
    rule_name text;
    support_name text;
    n integer;
BEGIN
    INSERT INTO m55_bench.source
    SELECT id, 'open', 1 FROM generate_series(1, 31) id;
    INSERT INTO m55_bench.subjects SELECT id FROM generate_series(1, 31) id;
    FOR n IN 1..30 LOOP
        support_name := format('m55-layer-support-%s', n);
        supports := array_append(supports, pgreact.shared_condition(
            support_name, 'm55_bench.source_view'::regclass, ARRAY['id']::name[]));
    END LOOP;
    FOR n IN 1..31 LOOP
        rule_name := format('m55-layer-rule-%s', n);
        members := array_append(members, pgreact.rule(
            rule_name, 'm55_bench.source_view'::regclass, 'id', 'CONSTRAINT'));
        support_name := format('m55-layer-support-%s', least(n, 30));
        dependencies := dependencies || jsonb_build_array(jsonb_build_object(
            'from', jsonb_build_object('kind', 'rule', 'name', rule_name, 'version', '1'),
            'on', jsonb_build_object('kind', 'shared_condition',
                                     'name', support_name, 'version', '1')));
    END LOOP;
    package := pgreact.policy_set(
        'm55-layered-package', '1', members, 'm55_bench.subjects'::regclass,
        ARRAY['id']::name[], supports, dependencies,
        '2026-01-01 00:00:00 UTC', NULL, 100);
    wal_before := m55_bench.wal_bytes();
    started := clock_timestamp();
    result := pgreact.validate(package);
    elapsed := extract(epoch FROM clock_timestamp() - started) * 1000;
    wal_after := m55_bench.wal_bytes();
    PERFORM m55_bench.record(
        elapsed, result ->> 'state' = 'ready',
        md5(jsonb_build_object('state', result ->> 'state',
                               'kind', result -> 'target')::text),
        wal_before, wal_after, result,
        jsonb_build_object('nodes', 61, 'members', 31, 'supports', 30,
                           'dependency_edges', jsonb_array_length(dependencies)));
END
$m55bench$;
\endif

SELECT jsonb_build_object(
    'name', :'case_name',
    'correctness', correctness,
    'state_hash', state_hash,
    'elapsed_ms', elapsed_ms,
    'wal_bytes', GREATEST(wal_after - wal_before, 0),
    'database_bytes', pg_database_size(current_database()),
    'peak_memory_bytes', NULL,
    'peak_memory_status', 'unavailable',
    'result', result,
    'details', details
)::text
FROM m55_bench.measurement;
