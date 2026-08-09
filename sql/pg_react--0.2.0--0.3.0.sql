-- M6 execution maturity. Protocol 2 adds explicit audited batching while
-- protocol 1 and one episode per transaction remain the default.

CREATE TABLE pgreact_internal.batch_declarations (
    rule_version_id uuid NOT NULL,
    event_kind text NOT NULL,
    declared_by name NOT NULL DEFAULT session_user,
    declared_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (rule_version_id, event_kind),
    FOREIGN KEY (rule_version_id, event_kind)
        REFERENCES pgreact_internal.consequence_bindings (rule_version_id, event_kind)
);

CREATE TABLE pgreact_internal.execution_batches (
    batch_id uuid PRIMARY KEY,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    event_kind text NOT NULL CHECK (event_kind IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE')),
    worker_id text NOT NULL CHECK (worker_id <> ''),
    max_items integer NOT NULL CHECK (max_items BETWEEN 2 AND 32),
    function_oid oid NOT NULL,
    function_identity text NOT NULL,
    function_digest bytea NOT NULL,
    dispatcher_oid oid NOT NULL,
    dispatcher_identity text NOT NULL,
    dispatcher_digest bytea NOT NULL,
    execution_role_oid oid NOT NULL,
    execution_role name NOT NULL,
    recheck_policy text NOT NULL CHECK (recheck_policy = 'FRESH'),
    conflict_key_columns name[],
    state text NOT NULL CHECK (state IN ('CLAIMED', 'RUNNING', 'COMPLETED', 'PARTIAL', 'REJECTED')),
    diagnostic_code text,
    diagnostic jsonb NOT NULL DEFAULT '{}'::jsonb,
    claimed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at timestamptz,
    finished_at timestamptz
);

CREATE TABLE pgreact_internal.execution_batch_items (
    batch_id uuid NOT NULL REFERENCES pgreact_internal.execution_batches ON DELETE CASCADE,
    item_order integer NOT NULL CHECK (item_order BETWEEN 1 AND 32),
    episode_id bigint NOT NULL REFERENCES pgreact_internal.agenda,
    lease_token uuid NOT NULL,
    attempt_no integer NOT NULL CHECK (attempt_no > 0),
    outcome text CHECK (outcome IN ('COMPLETED', 'FAILED', 'RETRY_WAIT', 'SKIPPED', 'REJECTED')),
    error_code text,
    error_message text,
    PRIMARY KEY (batch_id, item_order),
    UNIQUE (batch_id, episode_id)
);
CREATE INDEX execution_batch_items_episode_idx
    ON pgreact_internal.execution_batch_items (episode_id, batch_id);

CREATE FUNCTION pgreact_internal.keep_batch_declaration_immutable()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION 'batch-safe declarations are immutable; replace the rule version instead';
END
$$;

CREATE TRIGGER pgreact_batch_declaration_immutable
BEFORE UPDATE OR DELETE ON pgreact_internal.batch_declarations
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.keep_batch_declaration_immutable();

CREATE FUNCTION pgreact.declare_batch_safe(target_version_id uuid, event_kind text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    binding pgreact_internal.consequence_bindings%ROWTYPE;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);
    version_row := pgreact_internal.assert_rule_owner(target_version_id);
    IF event_kind NOT IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE') THEN
        RAISE EXCEPTION 'unsupported lifecycle event %', event_kind;
    END IF;
    SELECT * INTO binding FROM pgreact_internal.consequence_bindings b
    WHERE b.rule_version_id = target_version_id AND b.event_kind = declare_batch_safe.event_kind
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'rule version % has no % consequence binding', target_version_id, event_kind;
    END IF;
    IF binding.consequence_kind <> 'DATABASE_TYPED' OR binding.dispatcher_oid IS NULL THEN
        RAISE EXCEPTION 'only DATABASE_TYPED consequences can be declared batch-safe';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.lifecycle_events e
        WHERE e.rule_version_id = target_version_id AND e.event_kind = declare_batch_safe.event_kind
    ) THEN
        RAISE EXCEPTION 'batch safety must be declared before the first % lifecycle event', event_kind;
    END IF;
    IF pgreact_internal.source_row_signature(version_row.source_view_oid)
       IS DISTINCT FROM version_row.source_row_signature
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.function_oid)
       OR sha256(convert_to(pg_get_functiondef(binding.function_oid), 'UTF8')) <> binding.function_digest
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.dispatcher_oid)
       OR sha256(convert_to(pg_get_functiondef(binding.dispatcher_oid), 'UTF8')) <> binding.dispatcher_digest THEN
        RAISE EXCEPTION 'cannot declare a drifted source or consequence batch-safe';
    END IF;
    INSERT INTO pgreact_internal.batch_declarations (rule_version_id, event_kind)
    VALUES (target_version_id, event_kind);
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'batch safety is already declared for rule version % event %',
        target_version_id, event_kind;
END
$$;

CREATE FUNCTION pgreact.claim_batch(
    target_version_id uuid,
    event_kind text,
    worker_id text,
    max_items integer DEFAULT 32,
    lease_for interval DEFAULT interval '60 seconds'
) RETURNS TABLE(batch_id uuid, item_order integer, episode_id bigint, lease_token uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    binding pgreact_internal.consequence_bindings%ROWTYPE;
    candidate pgreact_internal.agenda%ROWTYPE;
    next_token uuid;
    next_batch uuid := gen_random_uuid();
    claimed integer := 0;
    seconds integer := extract(epoch FROM lease_for)::integer;
    expires_at timestamptz;
    fairness interval;
    lease_limit integer;
    group_limit integer;
    available_slots integer;
BEGIN
    IF worker_id IS NULL OR btrim(worker_id) = '' THEN
        RAISE EXCEPTION 'worker_id must not be empty';
    END IF;
    IF max_items NOT BETWEEN 2 AND 32 THEN
        RAISE EXCEPTION 'max_items must be between 2 and 32';
    END IF;
    SELECT fairness_window, max_lease_seconds INTO fairness, lease_limit
    FROM pgreact_internal.operational_settings;
    IF seconds NOT BETWEEN 1 AND lease_limit OR lease_for <> make_interval(secs => seconds) THEN
        RAISE EXCEPTION 'lease_for must be a whole number of seconds between 1 and %', lease_limit;
    END IF;
    expires_at := clock_timestamp() + lease_for;
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);
    PERFORM pgreact.sweep_expired_leases(target_version_id);
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions v
    WHERE v.rule_version_id = target_version_id;
    SELECT * INTO binding FROM pgreact_internal.consequence_bindings b
    WHERE b.rule_version_id = target_version_id AND b.event_kind = claim_batch.event_kind;
    IF NOT FOUND OR binding.consequence_kind <> 'DATABASE_TYPED' OR binding.dispatcher_oid IS NULL THEN
        RAISE EXCEPTION 'batch claim requires one exact DATABASE_TYPED % binding', event_kind;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_internal.batch_declarations d
        WHERE d.rule_version_id = target_version_id AND d.event_kind = claim_batch.event_kind
    ) THEN
        RAISE EXCEPTION 'batch execution is not declared for rule version % event %',
            target_version_id, event_kind;
    END IF;
    IF version_row.state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'rule version % is not executable in state %', target_version_id, version_row.state;
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers b WHERE b.rule_version_id = target_version_id) THEN
        RAISE EXCEPTION 'pg-react claims are blocked for rule version %', target_version_id;
    END IF;
    IF pgreact_internal.source_row_signature(version_row.source_view_oid)
       IS DISTINCT FROM version_row.source_row_signature
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.function_oid)
       OR sha256(convert_to(pg_get_functiondef(binding.function_oid), 'UTF8')) <> binding.function_digest
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.dispatcher_oid)
       OR sha256(convert_to(pg_get_functiondef(binding.dispatcher_oid), 'UTF8')) <> binding.dispatcher_digest THEN
        RAISE EXCEPTION 'pg-react source, consequence, or dispatcher drift for rule version %', target_version_id;
    END IF;
    SELECT max_leases INTO group_limit FROM pgreact_internal.agenda_group_limits
    WHERE agenda_group = version_row.agenda_group;
    IF group_limit IS NOT NULL THEN
        available_slots := group_limit - (SELECT count(*) FROM pgreact_internal.agenda a
            WHERE a.agenda_group = version_row.agenda_group AND a.state = 'LEASED'
              AND a.lease_expires_at > clock_timestamp());
        IF available_slots < 2 THEN RETURN; END IF;
        max_items := LEAST(max_items, available_slots);
    END IF;
    INSERT INTO pgreact_internal.execution_batches (
        batch_id, rule_version_id, event_kind, worker_id, max_items,
        function_oid, function_identity, function_digest,
        dispatcher_oid, dispatcher_identity, dispatcher_digest,
        execution_role_oid, execution_role, recheck_policy, conflict_key_columns, state
    ) VALUES (
        next_batch, target_version_id, event_kind, worker_id, max_items,
        binding.function_oid, binding.function_identity, binding.function_digest,
        binding.dispatcher_oid, binding.dispatcher_identity, binding.dispatcher_digest,
        version_row.owner_oid, pg_get_userbyid(version_row.owner_oid), 'FRESH',
        version_row.conflict_key_columns, 'CLAIMED'
    );
    FOR candidate IN
        SELECT a.* FROM pgreact_internal.agenda a
        WHERE a.rule_version_id = target_version_id
          AND a.event_kind = claim_batch.event_kind
          AND a.consequence_kind = 'DATABASE_TYPED'
          AND a.state IN ('PENDING', 'RETRY_WAIT')
          AND a.available_at <= clock_timestamp()
          AND (a.conflict_key IS NULL OR NOT EXISTS (
              SELECT 1 FROM pgreact_internal.conflict_leases l
              WHERE l.rule_version_id = a.rule_version_id
                AND l.conflict_key = a.conflict_key
                AND l.lease_expires_at > clock_timestamp()
          ))
        ORDER BY CASE WHEN a.available_at <= clock_timestamp() - fairness THEN 0 ELSE 1 END,
                 a.available_at, a.salience DESC, a.episode_id
        LIMIT max_items
        FOR UPDATE SKIP LOCKED
    LOOP
        next_token := gen_random_uuid();
        IF candidate.conflict_key IS NOT NULL THEN
            BEGIN
                INSERT INTO pgreact_internal.conflict_leases (
                    rule_version_id, conflict_key, episode_id, lease_token, lease_expires_at
                ) VALUES (
                    candidate.rule_version_id, candidate.conflict_key,
                    candidate.episode_id, next_token, expires_at
                );
            EXCEPTION WHEN unique_violation THEN
                CONTINUE;
            END;
        END IF;
        claimed := claimed + 1;
        UPDATE pgreact_internal.agenda a
        SET state = 'LEASED', lease_token = next_token, worker_id = claim_batch.worker_id,
            claimed_at = clock_timestamp(), lease_expires_at = expires_at,
            attempt_count = attempt_count + 1
        WHERE a.episode_id = candidate.episode_id;
        INSERT INTO pgreact_internal.execution_batch_items (
            batch_id, item_order, episode_id, lease_token, attempt_no
        ) VALUES (next_batch, claimed, candidate.episode_id, next_token, candidate.attempt_count + 1);
    END LOOP;
    IF claimed < 2 THEN
        DELETE FROM pgreact_internal.conflict_leases l
        USING pgreact_internal.execution_batch_items i
        WHERE i.batch_id = next_batch AND l.episode_id = i.episode_id
          AND l.lease_token = i.lease_token;
        UPDATE pgreact_internal.agenda a
        SET state = 'PENDING', lease_token = NULL, worker_id = NULL,
            claimed_at = NULL, lease_expires_at = NULL,
            attempt_count = attempt_count - 1
        FROM pgreact_internal.execution_batch_items i
        WHERE i.batch_id = next_batch AND a.episode_id = i.episode_id
          AND a.lease_token = i.lease_token;
        DELETE FROM pgreact_internal.execution_batches b WHERE b.batch_id = next_batch;
        RETURN;
    END IF;
    RETURN QUERY
    SELECT i.batch_id, i.item_order, i.episode_id, i.lease_token
    FROM pgreact_internal.execution_batch_items i
    WHERE i.batch_id = next_batch ORDER BY i.item_order;
END
$$;

CREATE FUNCTION pgreact.execute_claimed_batch(
    target_batch_id uuid,
    expected_worker_id text
) RETURNS TABLE(episode_id bigint, status text, error_code text, error_message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    batch_row pgreact_internal.execution_batches%ROWTYPE;
    item_row record;
    episode pgreact_internal.agenda%ROWTYPE;
    version_row pgreact_internal.rule_versions%ROWTYPE;
    binding pgreact_internal.consequence_bindings%ROWTYPE;
    item_status text;
    rejection_code text;
    rejection_detail jsonb := '{}'::jsonb;
    duplicate_conflict text;
    total_items integer;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);
    SELECT * INTO STRICT batch_row FROM pgreact_internal.execution_batches b
    WHERE b.batch_id = target_batch_id FOR UPDATE;
    IF batch_row.worker_id <> expected_worker_id THEN
        RAISE EXCEPTION 'batch % is owned by worker %, not %',
            target_batch_id, batch_row.worker_id, expected_worker_id;
    END IF;
    IF batch_row.state <> 'CLAIMED' THEN
        RAISE EXCEPTION 'batch % is not claimable in state %', target_batch_id, batch_row.state;
    END IF;
    SELECT count(*) INTO total_items FROM pgreact_internal.execution_batch_items i
    WHERE i.batch_id = target_batch_id;
    IF total_items NOT BETWEEN 2 AND 32 OR total_items > batch_row.max_items THEN
        rejection_code := 'OVERSIZED_OR_EMPTY';
        rejection_detail := jsonb_build_object('items', total_items, 'max_items', batch_row.max_items);
    END IF;
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions v
    WHERE v.rule_version_id = batch_row.rule_version_id FOR SHARE;
    SELECT * INTO binding FROM pgreact_internal.consequence_bindings b
    WHERE b.rule_version_id = batch_row.rule_version_id AND b.event_kind = batch_row.event_kind
    FOR SHARE;
    IF rejection_code IS NULL AND (
        NOT FOUND OR binding.consequence_kind <> 'DATABASE_TYPED' OR binding.dispatcher_oid IS NULL
        OR binding.function_oid <> batch_row.function_oid
        OR binding.function_digest <> batch_row.function_digest
        OR binding.dispatcher_oid <> batch_row.dispatcher_oid
        OR binding.dispatcher_digest <> batch_row.dispatcher_digest
    ) THEN
        rejection_code := 'MIXED_BINDING';
    END IF;
    IF rejection_code IS NULL AND version_row.owner_oid <> batch_row.execution_role_oid THEN
        rejection_code := 'MIXED_ROLE';
    END IF;
    IF rejection_code IS NULL
       AND version_row.conflict_key_columns IS DISTINCT FROM batch_row.conflict_key_columns THEN
        rejection_code := 'MIXED_CONFLICT_SCOPE';
    END IF;
    IF rejection_code IS NULL AND batch_row.recheck_policy <> 'FRESH' THEN
        rejection_code := 'MIXED_POLICY';
    END IF;
    IF rejection_code IS NULL AND NOT EXISTS (
        SELECT 1 FROM pgreact_internal.batch_declarations d
        WHERE d.rule_version_id = batch_row.rule_version_id AND d.event_kind = batch_row.event_kind
    ) THEN
        rejection_code := 'UNDECLARED';
    END IF;
    IF rejection_code IS NULL AND version_row.state = 'DRAINING' THEN
        rejection_code := 'REPLACED';
    ELSIF rejection_code IS NULL AND version_row.state <> 'ACTIVE' THEN
        rejection_code := 'INELIGIBLE_RULE_STATE';
        rejection_detail := jsonb_build_object('state', version_row.state);
    END IF;
    IF rejection_code IS NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.rule_barriers b
        WHERE b.rule_version_id = batch_row.rule_version_id
    ) THEN
        rejection_code := 'BARRIER';
    END IF;
    IF rejection_code IS NULL THEN
        EXECUTE format('LOCK TABLE %s IN ACCESS SHARE MODE', version_row.source_view_oid::regclass);
    END IF;
    IF rejection_code IS NULL AND (
        pgreact_internal.source_row_signature(version_row.source_view_oid)
            IS DISTINCT FROM version_row.source_row_signature
        OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.function_oid)
        OR sha256(convert_to(pg_get_functiondef(binding.function_oid), 'UTF8')) <> binding.function_digest
        OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.dispatcher_oid)
        OR sha256(convert_to(pg_get_functiondef(binding.dispatcher_oid), 'UTF8')) <> binding.dispatcher_digest
    ) THEN
        rejection_code := 'DRIFT';
    END IF;
    IF rejection_code IS NULL THEN
        SELECT a.conflict_key INTO duplicate_conflict
        FROM pgreact_internal.execution_batch_items i
        JOIN pgreact_internal.agenda a USING (episode_id)
        WHERE i.batch_id = target_batch_id AND a.conflict_key IS NOT NULL
        GROUP BY a.conflict_key HAVING count(*) > 1
        ORDER BY a.conflict_key LIMIT 1;
        IF FOUND THEN
            rejection_code := 'INCOMPATIBLE_CONFLICT';
            rejection_detail := jsonb_build_object('conflict_key', duplicate_conflict);
        END IF;
    END IF;
    FOR item_row IN
        SELECT i.item_order, i.episode_id, i.lease_token
        FROM pgreact_internal.execution_batch_items i
        WHERE i.batch_id = target_batch_id ORDER BY i.item_order
    LOOP
        EXIT WHEN rejection_code IS NOT NULL;
        SELECT * INTO STRICT episode FROM pgreact_internal.agenda a
        WHERE a.episode_id = item_row.episode_id FOR UPDATE;
        IF episode.rule_version_id <> batch_row.rule_version_id THEN
            rejection_code := 'MIXED_VERSION';
        ELSIF episode.event_kind <> batch_row.event_kind THEN
            rejection_code := 'MIXED_EVENT';
        ELSIF episode.consequence_kind <> 'DATABASE_TYPED' THEN
            rejection_code := 'MIXED_BINDING';
        ELSIF episode.state <> 'LEASED'
           OR episode.worker_id <> expected_worker_id
           OR episode.lease_token <> item_row.lease_token
           OR episode.lease_expires_at <= clock_timestamp() THEN
            rejection_code := 'STALE_LEASE';
        ELSIF NOT (CASE episode.event_kind
            WHEN 'ACTIVATE' THEN EXISTS (
                SELECT 1 FROM pgreact_internal.activation_state s
                WHERE s.rule_version_id = episode.rule_version_id
                  AND s.activation_id = episode.activation_id AND s.active
                  AND s.generation = episode.activation_generation
            )
            WHEN 'CHANGE' THEN EXISTS (
                SELECT 1 FROM pgreact_internal.activation_state s
                WHERE s.rule_version_id = episode.rule_version_id
                  AND s.activation_id = episode.activation_id AND s.active
                  AND s.generation = episode.activation_generation
                  AND s.revision = episode.activation_revision
            )
            ELSE NOT EXISTS (
                SELECT 1 FROM pgreact_internal.activation_state s
                WHERE s.rule_version_id = episode.rule_version_id
                  AND s.activation_id = episode.activation_id AND s.active
                  AND s.generation > episode.activation_generation
            )
        END) THEN
            rejection_code := 'INELIGIBLE_EPISODE';
        END IF;
        IF rejection_code IS NOT NULL THEN
            rejection_detail := jsonb_build_object(
                'item_order', item_row.item_order, 'episode_id', item_row.episode_id
            );
        END IF;
    END LOOP;
    IF rejection_code IS NOT NULL THEN
        UPDATE pgreact_internal.execution_batches b
        SET state = 'REJECTED', diagnostic_code = rejection_code,
            diagnostic = rejection_detail || jsonb_build_object(
                'code', rejection_code, 'message', 'batch rejected before consequence invocation'
            ), finished_at = clock_timestamp()
        WHERE b.batch_id = target_batch_id;
        UPDATE pgreact_internal.execution_batch_items i
        SET outcome = 'REJECTED', error_code = rejection_code,
            error_message = 'batch rejected before consequence invocation'
        WHERE i.batch_id = target_batch_id;
        RETURN QUERY
        SELECT i.episode_id, i.outcome, i.error_code, i.error_message
        FROM pgreact_internal.execution_batch_items i
        WHERE i.batch_id = target_batch_id ORDER BY i.item_order;
        RETURN;
    END IF;
    UPDATE pgreact_internal.execution_batches b
    SET state = 'RUNNING', started_at = clock_timestamp()
    WHERE b.batch_id = target_batch_id;
    FOR item_row IN
        SELECT i.item_order, i.episode_id, i.lease_token
        FROM pgreact_internal.execution_batch_items i
        WHERE i.batch_id = target_batch_id ORDER BY i.item_order
    LOOP
        SELECT pgreact.execute_claimed_episode(
            item_row.episode_id, expected_worker_id, item_row.lease_token
        ) INTO STRICT item_status;
        UPDATE pgreact_internal.execution_batch_items i
        SET outcome = item_status,
            error_code = CASE WHEN item_status IN ('FAILED', 'RETRY_WAIT')
                THEN a.last_error ->> 'code' END,
            error_message = CASE WHEN item_status IN ('FAILED', 'RETRY_WAIT')
                THEN a.last_error ->> 'message' END
        FROM pgreact_internal.agenda a
        WHERE i.batch_id = target_batch_id AND i.episode_id = item_row.episode_id
          AND a.episode_id = i.episode_id;
    END LOOP;
    UPDATE pgreact_internal.execution_batches b
    SET state = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.execution_batch_items i
            WHERE i.batch_id = target_batch_id AND i.outcome IN ('FAILED', 'RETRY_WAIT')
        ) THEN 'PARTIAL' ELSE 'COMPLETED' END,
        diagnostic_code = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.execution_batch_items i
            WHERE i.batch_id = target_batch_id AND i.outcome IN ('FAILED', 'RETRY_WAIT')
        ) THEN 'ITEM_FAILURE' END,
        diagnostic = jsonb_build_object('items', (
            SELECT jsonb_agg(jsonb_build_object(
                'item_order', i.item_order, 'episode_id', i.episode_id,
                'outcome', i.outcome, 'error_code', i.error_code
            ) ORDER BY i.item_order)
            FROM pgreact_internal.execution_batch_items i WHERE i.batch_id = target_batch_id
        )),
        finished_at = clock_timestamp()
    WHERE b.batch_id = target_batch_id;
    RETURN QUERY
    SELECT i.episode_id, i.outcome, i.error_code, i.error_message
    FROM pgreact_internal.execution_batch_items i
    WHERE i.batch_id = target_batch_id ORDER BY i.item_order;
END
$$;

CREATE FUNCTION pgreact.batch_history(target_batch_id uuid DEFAULT NULL)
RETURNS TABLE(
    batch_id uuid,
    rule_version_id uuid,
    event_kind text,
    worker_id text,
    signature jsonb,
    state text,
    diagnostic_code text,
    diagnostic jsonb,
    claimed_at timestamptz,
    started_at timestamptz,
    finished_at timestamptz,
    items jsonb
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT b.batch_id, b.rule_version_id, b.event_kind, b.worker_id,
           jsonb_build_object(
               'max_items', b.max_items,
               'consequence_identity', b.function_identity,
               'consequence_digest', encode(b.function_digest, 'hex'),
               'dispatcher_identity', b.dispatcher_identity,
               'dispatcher_digest', encode(b.dispatcher_digest, 'hex'),
               'execution_role', b.execution_role,
               'recheck_policy', b.recheck_policy,
               'conflict_key_columns', to_jsonb(b.conflict_key_columns)
           ), b.state,
           b.diagnostic_code, b.diagnostic, b.claimed_at, b.started_at, b.finished_at,
           COALESCE(jsonb_agg(jsonb_build_object(
               'item_order', i.item_order, 'episode_id', i.episode_id,
               'attempt_no', i.attempt_no,
               'outcome', i.outcome, 'error_code', i.error_code,
               'error_message', i.error_message
           ) ORDER BY i.item_order) FILTER (WHERE i.item_order IS NOT NULL), '[]'::jsonb)
    FROM pgreact_internal.execution_batches b
    LEFT JOIN pgreact_internal.execution_batch_items i USING (batch_id)
    WHERE target_batch_id IS NULL OR b.batch_id = target_batch_id
    GROUP BY b.batch_id ORDER BY b.claimed_at, b.batch_id
$$;

CREATE OR REPLACE FUNCTION pgreact.explain_episode(target_episode_id bigint)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'episode', to_jsonb(e),
        'attempts', COALESCE((
            SELECT jsonb_agg(to_jsonb(a) ORDER BY a.attempt_no)
            FROM pgreact.attempts a WHERE a.episode_id = e.episode_id
        ), '[]'::jsonb),
        'batches', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'batch_id', b.batch_id, 'item_order', i.item_order,
                'state', b.state, 'diagnostic_code', b.diagnostic_code,
                'outcome', i.outcome, 'error_code', i.error_code
            ) ORDER BY b.claimed_at, i.item_order)
            FROM pgreact_internal.execution_batch_items i
            JOIN pgreact_internal.execution_batches b USING (batch_id)
            WHERE i.episode_id = e.episode_id
        ), '[]'::jsonb)
    )
    FROM pgreact.episodes e WHERE e.episode_id = target_episode_id
$$;

CREATE FUNCTION pgreact_internal.reject_expired_batch_lease()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    rejected_batches uuid[];
BEGIN
    WITH rejected AS (
        UPDATE pgreact_internal.execution_batches b
        SET state = 'REJECTED', diagnostic_code = 'LEASE_EXPIRED',
            diagnostic = jsonb_build_object(
                'code', 'LEASE_EXPIRED',
                'message', 'batch lease expired before completion',
                'episode_ids', (
                    SELECT to_jsonb(array_agg(i.episode_id ORDER BY i.episode_id))
                    FROM pgreact_internal.execution_batch_items i
                    JOIN pgreact_internal.agenda a USING (episode_id)
                    WHERE i.batch_id = b.batch_id AND (
                        i.episode_id = NEW.episode_id
                        OR (a.state = 'LEASED' AND a.lease_expires_at <= clock_timestamp())
                    )
                )
            ), finished_at = clock_timestamp()
        WHERE b.state = 'CLAIMED' AND EXISTS (
            SELECT 1 FROM pgreact_internal.execution_batch_items i
            WHERE i.batch_id = b.batch_id AND i.episode_id = NEW.episode_id
        ) RETURNING batch_id
    ) SELECT array_agg(batch_id ORDER BY batch_id) INTO rejected_batches FROM rejected;
    IF rejected_batches IS NOT NULL THEN
        UPDATE pgreact_internal.execution_batch_items i
        SET outcome = 'REJECTED', error_code = 'LEASE_EXPIRED',
            error_message = 'batch lease expired before completion'
        WHERE i.batch_id = ANY(rejected_batches);
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_reject_expired_batch_lease
AFTER UPDATE ON pgreact_internal.agenda
FOR EACH ROW
WHEN (
    OLD.state = 'LEASED' AND NEW.state = 'PENDING'
    AND OLD.lease_expires_at <= clock_timestamp()
)
EXECUTE FUNCTION pgreact_internal.reject_expired_batch_lease();

CREATE OR REPLACE FUNCTION pgreact.prepare_recovery()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    barriers bigint;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'only pgreact_admin may prepare recovery';
    END IF;
    IF pg_catalog.pg_is_in_recovery() THEN
        RAISE EXCEPTION 'pg-react workers must not run on a physical standby';
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    INSERT INTO pgreact_internal.rule_barriers (rule_version_id, reason)
    SELECT rule_version_id, 'RECONCILING'
    FROM pgreact_internal.rule_versions
    WHERE state IN ('ACTIVE', 'DRAINING', 'PAUSED')
    ON CONFLICT (rule_version_id) DO UPDATE
    SET reason = 'RECONCILING', created_at = clock_timestamp();
    GET DIAGNOSTICS barriers = ROW_COUNT;
    PERFORM pgreact_internal.record_runtime_event(
        'INFO', 'RECOVERY_PREPARED', NULL, NULL, NULL,
        jsonb_build_object('barriers', barriers)
    );
    RETURN barriers;
END
$$;

UPDATE pgreact_internal.operational_settings SET worker_protocol_max = 2;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M6 audited batch execution with protocol-1 default compatibility';
