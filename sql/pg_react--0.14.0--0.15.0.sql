-- M18 changes no engine semantics. The release diagnostic recognizes 0.15.0.
CREATE OR REPLACE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH raw_inherited AS (
        SELECT diagnostic
        FROM jsonb_array_elements(pgreact_internal.doctor_m16() -> 'diagnostics') diagnostic
        WHERE diagnostic ->> 'code' <> 'M16_EXTENSION_VERSION'
          AND NOT (diagnostic ->> 'code' = 'M15_MANAGED_PROCESS'
                   AND EXISTS (
                       SELECT 1 FROM pgreact_internal.managed_processes
                       WHERE database_oid = (SELECT oid FROM pg_database
                                              WHERE datname = current_database())
                         AND state = 'ready'
                         AND heartbeat_at >= clock_timestamp() -
                             (current_setting('pg_react.poll_interval_ms')::interval +
                              interval '10 seconds')))
          AND NOT (diagnostic ->> 'code' IN ('SOURCE_DRIFT', 'CONSEQUENCE_DRIFT')
                   AND EXISTS (
                       SELECT 1
                       FROM pgreact.rules stale
                       JOIN pgreact.rules active
                         ON active.rule_name = stale.rule_name
                        AND active.state = 'ACTIVE'
                        AND active.rule_version_id <> stale.rule_version_id
                       WHERE stale.rule_version_id::text =
                             diagnostic ->> 'object_identity'))
    ), resolved AS (
        SELECT diagnostic,
               COALESCE(
                   (SELECT program.program_name
                    FROM pgreact_internal.derivation_program_rules member
                    JOIN pgreact.derivation_programs program USING (program_version_id)
                    WHERE member.rule_version_id::text = diagnostic ->> 'object_identity'),
                   (SELECT rule_name FROM pgreact.rules
                    WHERE rule_version_id::text = diagnostic ->> 'object_identity'),
                   (SELECT program_name FROM pgreact.derivation_programs
                    WHERE program_version_id::text = diagnostic ->> 'object_identity'),
                   diagnostic ->> 'object_identity') AS public_name,
               EXISTS (SELECT 1 FROM pgreact.rules
                       WHERE rule_version_id::text = diagnostic ->> 'object_identity')
               AND NOT EXISTS (
                   SELECT 1 FROM pgreact_internal.derivation_program_rules
                   WHERE rule_version_id::text = diagnostic ->> 'object_identity') AS is_rule
        FROM raw_inherited
    ), inherited AS (
        SELECT diagnostic || jsonb_build_object(
            'object_identity', public_name,
            'message', CASE WHEN diagnostic ->> 'code' = 'M15_MANAGED_PROCESS'
                                  AND EXISTS (
                    SELECT 1 FROM pgreact_internal.managed_processes
                    WHERE database_oid = (SELECT oid FROM pg_database
                                           WHERE datname = current_database())
                      AND heartbeat_at < clock_timestamp() -
                          (current_setting('pg_react.poll_interval_ms')::interval +
                           interval '10 seconds'))
                THEN 'managed worker heartbeat is stale'
                ELSE diagnostic ->> 'message' END,
            'hint', CASE diagnostic ->> 'code'
                WHEN 'SOURCE_DRIFT' THEN CASE WHEN is_rule
                    THEN format('Run SELECT pgreact_api.pause_rule(%L); then replace the rule through pgreact_api.replace_rule.', public_name)
                    ELSE format('Preview and deploy the corrected next version of %L through pgreact_api.preview_program and pgreact_api.deploy_program.', public_name) END
                WHEN 'CONSEQUENCE_DRIFT' THEN
                    format('Run SELECT pgreact_api.pause_rule(%L); then replace the rule through pgreact_api.replace_rule.', public_name)
                WHEN 'M15_MANAGED_PROCESS' THEN
                    format('Restart the pg-react managed worker for database %L; then run SELECT pgreact_api.doctor().', public_name)
                ELSE diagnostic ->> 'hint' END)
            AS diagnostic
        FROM resolved
    ), diagnostics AS (
        SELECT diagnostic FROM inherited
        UNION ALL
        SELECT jsonb_build_object(
            'code','M18_EXTENSION_VERSION','severity','ERROR','object_identity','pg_react',
            'message','pg_react extension version is not 0.15.0',
            'hint','Install matching files and run ALTER EXTENSION pg_react UPDATE.')
        WHERE NOT EXISTS (SELECT 1 FROM pg_extension
                          WHERE extname = 'pg_react' AND extversion = '0.15.0')
        UNION ALL
        SELECT jsonb_build_object(
            'code','M17_LATE_INPUT_BARRIER','severity','ERROR',
            'object_identity',program_name,
            'message','program is blocked by input beyond a finalized window',
            'hint','Restore the authoritative input and call pgreact_api.reconcile_program.')
        FROM pgreact_internal.window_programs WHERE active AND barrier = 'LATE_INPUT'
    ), ordered AS (
        SELECT diagnostic FROM diagnostics
        ORDER BY CASE diagnostic ->> 'severity' WHEN 'ERROR' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
                 diagnostic ->> 'code',diagnostic ->> 'object_identity'
    )
    SELECT jsonb_build_object(
        'contract_version',CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.window_programs WHERE active) THEN 6 ELSE 5 END,
        'status',CASE WHEN EXISTS (SELECT 1 FROM ordered
                                  WHERE diagnostic ->> 'severity' = 'ERROR')
                      THEN 'attention' ELSE 'ready' END,
        'diagnostics',COALESCE((SELECT jsonb_agg(diagnostic) FROM ordered),'[]'::jsonb))
$$;

-- Maintenance may use the 1,000-row supported batch while public job claims
-- retain their inherited 100-item protocol limit.
CREATE OR REPLACE FUNCTION pgreact_internal.managed_cycle(process_pid integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    worker text := format('pg-react-managed/%s/%s', current_database(), process_pid);
    batch_limit integer := current_setting('pg_react.batch_size')::integer;
    claim_limit integer := least(batch_limit, 100);
    pending_limit integer := current_setting('pg_react.max_pending_jobs')::integer;
    pending bigint;
    processed bigint := 0;
    claimed record;
    runtime_state text := 'ready';
    run_result jsonb;
BEGIN
    SELECT count(*) INTO pending
    FROM pgreact_internal.agenda job
    WHERE job.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    INSERT INTO pgreact_internal.managed_processes (
        database_oid, database_name, backend_pid, state, protocol, pending_jobs)
    VALUES ((SELECT oid FROM pg_database WHERE datname = current_database()),
            current_database(), process_pid, 'ready', 2, pending)
    ON CONFLICT (database_oid) DO UPDATE
    SET database_name = EXCLUDED.database_name, backend_pid = EXCLUDED.backend_pid,
        state = EXCLUDED.state, protocol = EXCLUDED.protocol,
        pending_jobs = EXCLUDED.pending_jobs, started_at = CASE
            WHEN pgreact_internal.managed_processes.backend_pid = EXCLUDED.backend_pid
            THEN pgreact_internal.managed_processes.started_at ELSE clock_timestamp() END,
        heartbeat_at = clock_timestamp(), detail = NULL;

    IF pg_is_in_recovery() THEN
        runtime_state := 'standby';
    ELSIF NOT pgreact.worker_protocol_compatible(2) THEN
        runtime_state := 'error';
        UPDATE pgreact_internal.managed_processes
        SET state = runtime_state, detail = 'worker protocol 2 is incompatible',
            heartbeat_at = clock_timestamp()
        WHERE database_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
        RETURN jsonb_build_object(
            'state', runtime_state, 'pending_jobs', pending, 'processed_jobs', 0);
    ELSE
        IF pending >= pending_limit THEN
            runtime_state := 'backpressure';
        ELSE
            run_result := pgreact_api.run();
        END IF;
        FOR claimed IN
            SELECT * FROM pgreact_api.claim(worker, claim_limit, interval '60 seconds')
        LOOP
            PERFORM pgreact_api.execute(
                claimed.episode_id, worker, claimed.lease_token);
            processed := processed + 1;
        END LOOP;
    END IF;
    SELECT count(*) INTO pending
    FROM pgreact_internal.agenda job
    WHERE job.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    UPDATE pgreact_internal.managed_processes
    SET state = runtime_state, pending_jobs = pending,
        processed_jobs = processed_jobs + processed,
        heartbeat_at = clock_timestamp(), detail = NULL
    WHERE database_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
    RETURN jsonb_build_object(
        'state', runtime_state, 'pending_jobs', pending, 'processed_jobs', processed,
        'run', run_result);
EXCEPTION WHEN OTHERS THEN
    INSERT INTO pgreact_internal.managed_processes (
        database_oid, database_name, backend_pid, state, protocol, detail)
    VALUES ((SELECT oid FROM pg_database WHERE datname = current_database()),
            current_database(), process_pid, 'error', 2, SQLSTATE || ': ' || SQLERRM)
    ON CONFLICT (database_oid) DO UPDATE
    SET backend_pid = EXCLUDED.backend_pid, state = 'error',
        heartbeat_at = clock_timestamp(), detail = EXCLUDED.detail;
    RETURN jsonb_build_object(
        'state', 'error', 'sqlstate', SQLSTATE, 'message', SQLERRM);
END
$$;

-- Program names now receive the same name-first status entry point as rules.
-- Existing rule and all-rules transcripts remain byte-for-byte compatible.
CREATE OR REPLACE FUNCTION pgreact_api.status(name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 5,
        'rules', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'rule', rule.rule_name,
                'condition', COALESCE(spec.public_condition::regclass::text,
                                      rule.source_view_name),
                'key', CASE WHEN spec.rule_version_id IS NULL THEN to_jsonb(rule.key_column)
                            WHEN cardinality(spec.key_columns) = 1 THEN to_jsonb(spec.key_columns[1])
                            ELSE to_jsonb(spec.key_columns) END,
                'state', lower(rule.state),
                'actions', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'action', lower(binding.event_kind),
                        'function', COALESCE(proxy.action_oid::regprocedure::text,
                                             binding.function_identity))
                        ORDER BY binding.event_kind)
                    FROM pgreact_internal.consequence_bindings binding
                    LEFT JOIN pgreact_internal.action_proxies proxy
                      ON proxy.proxy_oid = binding.function_oid
                    WHERE binding.rule_version_id = rule.rule_version_id
                ), '[]'::jsonb)) ORDER BY rule.rule_name)
            FROM pgreact.rules rule
            LEFT JOIN pgreact_internal.keyed_rule_versions spec USING (rule_version_id)
            WHERE $1 IS NULL OR rule.rule_name = $1
        ), '[]'::jsonb)
    ) || CASE WHEN $1 IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact.derivation_programs WHERE program_name = $1
    ) THEN jsonb_build_object('programs', (
        SELECT jsonb_agg(jsonb_build_object(
            'program', program.program_name,
            'version', program.program_version,
            'state', lower(program.state),
            'frontier', program.frontier,
            'max_iterations', program.max_iterations,
            'max_facts', program.max_facts,
            'last_run', (
                SELECT jsonb_build_object(
                    'status', lower(run.status),
                    'frontier', run.committed_frontier)
                FROM pgreact.derivation_program_runs run
                WHERE run.program_version_id = program.program_version_id
                ORDER BY run.run_id DESC LIMIT 1),
            'watermark', (
                SELECT to_jsonb(watermark)
                FROM pgreact_api.watermark_status(program.program_name) watermark))
            ORDER BY program.program_version)
        FROM pgreact.derivation_programs program
        WHERE program.program_name = $1
    )) ELSE '{}'::jsonb END
$$;
