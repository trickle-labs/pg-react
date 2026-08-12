-- M12 database-time deadlines. Candidate streams remain ordinary explicit
-- DIFFERENTIAL streams; the coordinator advances only indexed crossing keys.

ALTER TABLE pgreact_internal.operational_settings
    ADD COLUMN max_deadlines_per_pass integer NOT NULL DEFAULT 100000
        CHECK (max_deadlines_per_pass BETWEEN 1 AND 10000000),
    ADD COLUMN clock_lag_warning interval NOT NULL DEFAULT interval '1 minute'
        CHECK (clock_lag_warning >= interval '1 second');

CREATE TABLE pgreact_internal.clock_frontier (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    frontier timestamptz NOT NULL DEFAULT '-infinity',
    last_sampled_time timestamptz,
    last_advanced_at timestamptz
);
INSERT INTO pgreact_internal.clock_frontier (singleton) VALUES (true);

CREATE TABLE pgreact_internal.deadline_rules (
    rule_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.rule_versions,
    deadline_column name NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.clock_history (
    clock_event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sampled_time timestamptz NOT NULL,
    previous_frontier timestamptz NOT NULL,
    frontier timestamptz NOT NULL,
    affected_rules integer NOT NULL CHECK (affected_rules >= 0),
    affected_keys bigint NOT NULL CHECK (affected_keys >= 0),
    advanced_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (frontier >= previous_frontier)
);

CREATE TABLE pgreact_internal.deadline_lifecycle (
    event_id bigint PRIMARY KEY REFERENCES pgreact_internal.lifecycle_events,
    declared_deadline timestamptz NOT NULL,
    observed_frontier timestamptz NOT NULL
);

CREATE FUNCTION pgreact_internal.validate_deadline_rule(
    condition regclass,
    semantic_key name,
    deadline_column name,
    on_activate regprocedure DEFAULT NULL
)
RETURNS TABLE(
    contract_version integer,
    code text,
    severity text,
    object_identity text,
    message text,
    hint text,
    details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    deadline_attno smallint;
    query_tree text;
    invalid_count bigint;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact.validate_rule(condition, ARRAY[semantic_key], on_activate) base
    WHERE base.severity = 'ERROR'
    ORDER BY base.code
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 2, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint,
            diagnostic.details;
        RETURN;
    END IF;

    SELECT attnum INTO deadline_attno
    FROM pg_catalog.pg_attribute
    WHERE attrelid = condition
      AND attname = deadline_column
      AND atttypid = 'timestamptz'::regtype
      AND attnum > 0
      AND NOT attisdropped;
    IF deadline_attno IS NULL THEN
        RETURN QUERY SELECT 2, 'M12_DEADLINE_TYPE', 'ERROR', condition::text,
            'deadline must name one timestamptz column projected by the condition view',
            'Project one non-null timestamptz deadline column.',
            jsonb_build_object('deadline_column', deadline_column);
        RETURN;
    END IF;

    IF NOT pgreact_internal.view_key_is_direct(condition, deadline_attno) THEN
        RETURN QUERY SELECT 2, 'M12_DEADLINE_NOT_DIRECT', 'ERROR', condition::text,
            'deadline must be one unambiguous direct column, not a computed time expression',
            'Project a stored timestamptz column unchanged from one finite source row.',
            jsonb_build_object('deadline_column', deadline_column);
        RETURN;
    END IF;

    query_tree := pgreact_internal.relation_query_tree(condition);
    IF query_tree ~ E':has(Aggs|WindowFuncs|Recursive|SubLinks)[[:space:]]+true'
       OR query_tree ~ E':jointype[[:space:]]+5'
       OR EXISTS (
           SELECT 1
           FROM pg_catalog.pg_rewrite rewrite
           JOIN pg_catalog.pg_depend dependency
             ON dependency.classid = 'pg_rewrite'::regclass
            AND dependency.objid = rewrite.oid
           JOIN pg_catalog.pg_proc function ON function.oid = dependency.refobjid
           WHERE rewrite.ev_class = condition
             AND dependency.refclassid = 'pg_proc'::regclass
             AND function.provolatile <> 'i'
       )
       OR EXISTS (
           SELECT 1
           FROM pgreact_internal.derived_relation_versions
           WHERE public_view_oid = condition AND state = 'ACTIVE'
       ) THEN
        RETURN QUERY SELECT 2, 'M12_DEADLINE_QUERY_UNSUPPORTED', 'ERROR', condition::text,
            'deadline candidates cannot use volatile, recursive, negative, aggregate, windowed, or derived-program time expressions',
            'Use a finite ordinary condition view with one direct stored deadline.',
            '{}'::jsonb;
        RETURN;
    END IF;

    EXECUTE format(
        'SELECT count(*) FROM %s WHERE %I IS NULL OR NOT isfinite(%I)',
        condition, deadline_column, deadline_column
    ) INTO invalid_count;
    IF invalid_count > 0 THEN
        RETURN QUERY SELECT 2, 'M12_DEADLINE_VALUE', 'ERROR', condition::text,
            'deadline candidates must contain finite non-null timestamptz values',
            'Populate every deadline with one finite PostgreSQL timestamptz value.',
            jsonb_build_object('invalid_rows', invalid_count,
                               'deadline_column', deadline_column);
        RETURN;
    END IF;

    RETURN QUERY SELECT 2, 'OK', 'INFO', condition::text,
        'deadline rule can use the coordinator-owned DIFFERENTIAL path',
        'Deploy it, refresh source changes with run_rule, and let pg-reactd advance database time.',
        jsonb_build_object(
            'semantic_key', semantic_key,
            'deadline_column', deadline_column,
            'predicate', 'clock_frontier >= deadline',
            'refresh_mode', 'DIFFERENTIAL');
END
$$;

CREATE FUNCTION pgreact_internal.mark_deadline_rule(
    target_version_id uuid,
    deadline_column name,
    bootstrap_policy text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    frontier timestamptz;
    due_count bigint;
    index_name text := 'deadline_' || substring(replace(target_version_id::text, '-', ''), 1, 24);
BEGIN
    IF bootstrap_policy NOT IN ('SEED_CURRENT', 'REQUIRE_EMPTY') THEN
        RAISE EXCEPTION 'bootstrap policy must be SEED_CURRENT or REQUIRE_EMPTY';
    END IF;
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;

    INSERT INTO pgreact_internal.deadline_rules (rule_version_id, deadline_column)
    VALUES (target_version_id, deadline_column);
    EXECUTE format('CREATE INDEX %I ON %s (%I, %I)',
        index_name, version_row.match_relid::regclass,
        deadline_column, version_row.key_column);
    EXECUTE format('DROP TRIGGER pgreact_finalize ON %s',
        version_row.match_relid::regclass);
    EXECUTE format(
        'CREATE CONSTRAINT TRIGGER pgreact_finalize '
        'AFTER INSERT OR UPDATE OR DELETE ON %s '
        'DEFERRABLE INITIALLY DEFERRED FOR EACH ROW '
        'EXECUTE FUNCTION pgreact_internal.finalize_deadline_match_delta(%L)',
        version_row.match_relid::regclass, target_version_id::text);
    EXECUTE format('SELECT count(*) FROM %s WHERE %I <= $1',
        version_row.match_relid::regclass, deadline_column)
        INTO due_count USING frontier;
    IF bootstrap_policy = 'REQUIRE_EMPTY' AND due_count > 0 THEN
        RAISE EXCEPTION 'REQUIRE_EMPTY deadline source % currently has % due matches',
            version_row.source_view_name, due_count;
    END IF;
    EXECUTE format(
        'DELETE FROM pgreact_internal.activation_state activation '
        'WHERE activation.rule_version_id = $1 AND NOT EXISTS ('
        'SELECT 1 FROM %s candidate '
        'WHERE (to_jsonb(candidate) ->> %L)::bigint = activation.semantic_key '
        'AND (to_jsonb(candidate) ->> %L)::timestamptz <= $2)',
        version_row.match_relid::regclass,
        version_row.key_column::text,
        deadline_column::text
    ) USING target_version_id, frontier;
    UPDATE pgreact_internal.rule_versions
    SET bootstrap_policy = mark_deadline_rule.bootstrap_policy
    WHERE rule_version_id = target_version_id;
    RETURN target_version_id;
END
$$;

CREATE FUNCTION pgreact.create_deadline_rule(
    name text,
    definition regclass,
    key_columns name[],
    deadline_column name,
    kind text DEFAULT NULL,
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    version_id uuid;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact_internal.validate_deadline_rule(
        definition, key_columns[1], deadline_column, on_activate)
    WHERE severity = 'ERROR'
    ORDER BY code
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react deadline validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    version_id := pgreact.create_rule(
        name, definition, key_columns, kind, on_activate, on_deactivate,
        on_change, 'SEED_CURRENT', change_columns, salience, agenda_group,
        conflict_key_columns, max_attempts, initial_backoff_seconds,
        backoff_multiplier, max_backoff_seconds);
    RETURN pgreact_internal.mark_deadline_rule(
        version_id, deadline_column, bootstrap_policy);
END
$$;

CREATE FUNCTION pgreact_internal.reconcile_deadline_key(
    target_version_id uuid,
    target_key bigint
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    deadline_rule pgreact_internal.deadline_rules%ROWTYPE;
    candidate_count bigint;
    candidate_bindings jsonb;
    declared_deadline timestamptz;
    frontier timestamptz;
    present boolean;
    canonical bytea;
    digest bytea;
    activation uuid;
    prior pgreact_internal.activation_state%ROWTYPE;
    next_generation bigint;
    next_revision bigint;
    new_event_id bigint;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    SELECT * INTO STRICT deadline_rule
    FROM pgreact_internal.deadline_rules
    WHERE rule_version_id = target_version_id;
    IF version_row.state <> 'ACTIVE' THEN
        RETURN 0;
    END IF;
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;
    EXECUTE format(
        'SELECT count(*), min(to_jsonb(candidate)::text)::jsonb, '
        'min((to_jsonb(candidate) ->> %L)::timestamptz) '
        'FROM %s candidate WHERE (to_jsonb(candidate) ->> %L)::bigint = $1',
        deadline_rule.deadline_column::text,
        version_row.match_relid::regclass,
        version_row.key_column::text
    ) INTO candidate_count, candidate_bindings, declared_deadline
      USING target_key;
    IF candidate_count > 1 THEN
        RAISE EXCEPTION 'pg-react duplicate semantic key % in %',
            target_key, version_row.match_name;
    END IF;
    IF candidate_count = 1
       AND (declared_deadline IS NULL OR NOT isfinite(declared_deadline)) THEN
        RAISE EXCEPTION 'M12_DEADLINE_VALUE: %.% must be finite and non-null for key %',
            version_row.source_view_name, deadline_rule.deadline_column, target_key;
    END IF;
    present := candidate_count = 1 AND declared_deadline <= frontier;
    canonical := pgreact_internal.canonical_bigint_v1(target_key);
    digest := pgreact_internal.activation_digest(target_version_id, canonical);
    activation := pgreact_internal.activation_uuid(digest);
    SELECT * INTO prior
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = target_version_id AND activation_id = activation
    FOR UPDATE;
    IF FOUND AND (prior.canonical_key <> canonical OR prior.canonical_key_digest <> digest) THEN
        RAISE EXCEPTION 'pg-react activation UUID collision for semantic key %', target_key;
    END IF;

    IF present AND (prior.activation_id IS NULL OR NOT prior.active) THEN
        next_generation := COALESCE(prior.generation, 0) + 1;
        INSERT INTO pgreact_internal.activation_state (
            rule_version_id, activation_id, semantic_key, canonical_key,
            canonical_key_digest, key_codec_version, active, generation,
            revision, current_bindings, last_active_bindings,
            first_seen_at, last_seen_at
        ) VALUES (
            target_version_id, activation, target_key, canonical, digest, 1,
            true, next_generation, 0, candidate_bindings, candidate_bindings,
            clock_timestamp(), clock_timestamp()
        )
        ON CONFLICT (rule_version_id, activation_id) DO UPDATE SET
            active = true,
            generation = EXCLUDED.generation,
            revision = 0,
            current_bindings = EXCLUDED.current_bindings,
            last_active_bindings = EXCLUDED.last_active_bindings,
            last_seen_at = EXCLUDED.last_seen_at,
            deactivated_at = NULL;
        new_event_id := pgreact_internal.emit_event(
            version_row, activation, next_generation, 0,
            'ACTIVATE', NULL, candidate_bindings);
    ELSIF present AND prior.active THEN
        IF pgreact_internal.watched_changed(
            version_row, prior.current_bindings, candidate_bindings) THEN
            next_revision := prior.revision + 1;
            new_event_id := pgreact_internal.emit_event(
                version_row, activation, prior.generation, next_revision,
                'CHANGE', prior.current_bindings, candidate_bindings);
            UPDATE pgreact_internal.activation_state
            SET revision = next_revision,
                current_bindings = candidate_bindings,
                last_active_bindings = candidate_bindings,
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id
              AND activation_id = activation;
        ELSE
            UPDATE pgreact_internal.activation_state
            SET current_bindings = candidate_bindings,
                last_active_bindings = candidate_bindings,
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id
              AND activation_id = activation;
        END IF;
    ELSIF NOT present AND prior.active THEN
        UPDATE pgreact_internal.activation_state
        SET active = false,
            current_bindings = NULL,
            deactivated_at = clock_timestamp(),
            last_seen_at = clock_timestamp()
        WHERE rule_version_id = target_version_id
          AND activation_id = activation;
        UPDATE pgreact_internal.agenda
        SET state = 'WITHDRAWN',
            completed_at = clock_timestamp(),
            lease_token = NULL,
            worker_id = NULL,
            lease_expires_at = NULL
        WHERE rule_version_id = target_version_id
          AND activation_id = activation
          AND activation_generation = prior.generation
          AND event_kind = 'ACTIVATE'
          AND state IN ('PENDING', 'RETRY_WAIT');
        new_event_id := pgreact_internal.emit_event(
            version_row, activation, prior.generation, 0,
            'DEACTIVATE', prior.last_active_bindings, NULL);
        declared_deadline := COALESCE(
            declared_deadline,
            (prior.last_active_bindings ->> deadline_rule.deadline_column::text)::timestamptz);
    END IF;

    IF new_event_id IS NOT NULL THEN
        INSERT INTO pgreact_internal.deadline_lifecycle (
            event_id, declared_deadline, observed_frontier
        ) VALUES (
            new_event_id, declared_deadline, frontier
        )
        ON CONFLICT (event_id) DO UPDATE SET
            declared_deadline = EXCLUDED.declared_deadline,
            observed_frontier = EXCLUDED.observed_frontier;
        RETURN 1;
    END IF;
    RETURN 0;
END
$$;

CREATE FUNCTION pgreact_internal.finalize_deadline_match_delta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_id uuid := TG_ARGV[0]::uuid;
    buffered record;
BEGIN
    FOR buffered IN
        DELETE FROM pgreact_internal.activation_delta_buffer
        WHERE rule_version_id = version_id
          AND xid = pg_catalog.pg_current_xact_id()
        RETURNING *
    LOOP
        PERFORM pgreact_internal.reconcile_deadline_key(
            version_id, buffered.semantic_key);
    END LOOP;
    RETURN NULL;
END
$$;
CREATE FUNCTION pgreact_internal.reconcile_deadline_rule(target_version_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    candidate record;
    repaired bigint := 0;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pgreact_internal.refresh_rule(target_version_id);
    SET CONSTRAINTS ALL IMMEDIATE;
    FOR candidate IN EXECUTE format(
        'SELECT (to_jsonb(candidate) ->> %L)::bigint AS semantic_key '
        'FROM %s candidate UNION SELECT semantic_key '
        'FROM pgreact_internal.activation_state WHERE rule_version_id = %L::uuid '
        'ORDER BY semantic_key',
        version_row.key_column::text,
        version_row.match_relid::regclass,
        target_version_id::text)
    LOOP
        repaired := repaired + pgreact_internal.reconcile_deadline_key(
            target_version_id, candidate.semantic_key);
    END LOOP;
    RETURN repaired;
END
$$;

CREATE FUNCTION pgreact_internal.reconcile_deadline_state(target_version_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    deadline_rule pgreact_internal.deadline_rules%ROWTYPE;
    frontier timestamptz;
    candidate record;
    candidate_count bigint;
    candidate_bindings jsonb;
    declared_deadline timestamptz;
    present boolean;
    canonical bytea;
    digest bytea;
    activation uuid;
    prior pgreact_internal.activation_state%ROWTYPE;
    repaired bigint := 0;
    audit_id bigint;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id AND state = 'ACTIVE';
    SELECT * INTO STRICT deadline_rule
    FROM pgreact_internal.deadline_rules
    WHERE rule_version_id = target_version_id;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pgreact_internal.refresh_rule(target_version_id);
    SET CONSTRAINTS ALL IMMEDIATE;
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;
    INSERT INTO pgreact_internal.reconciliation_audit (
        rule_version_id, mode, started_at, status, requested_by, reason
    ) VALUES (
        target_version_id, 'STATE_ONLY', clock_timestamp(),
        'RUNNING', session_user, 'OPERATOR'
    ) RETURNING reconciliation_id INTO audit_id;

    FOR candidate IN EXECUTE format(
        'SELECT (to_jsonb(candidate) ->> %L)::bigint AS semantic_key '
        'FROM %s candidate UNION SELECT semantic_key '
        'FROM pgreact_internal.activation_state WHERE rule_version_id = %L::uuid '
        'ORDER BY semantic_key',
        version_row.key_column::text,
        version_row.match_relid::regclass,
        target_version_id::text)
    LOOP
        EXECUTE format(
            'SELECT count(*), min(to_jsonb(candidate)::text)::jsonb, '
            'min((to_jsonb(candidate) ->> %L)::timestamptz) '
            'FROM %s candidate WHERE (to_jsonb(candidate) ->> %L)::bigint = $1',
            deadline_rule.deadline_column::text,
            version_row.match_relid::regclass,
            version_row.key_column::text
        ) INTO candidate_count, candidate_bindings, declared_deadline
          USING candidate.semantic_key;
        IF candidate_count > 1 THEN
            RAISE EXCEPTION 'pg-react duplicate semantic key % in %',
                candidate.semantic_key, version_row.match_name;
        END IF;
        IF candidate_count = 1
           AND (declared_deadline IS NULL OR NOT isfinite(declared_deadline)) THEN
            RAISE EXCEPTION 'M12_DEADLINE_VALUE: %.% must be finite and non-null for key %',
                version_row.source_view_name,
                deadline_rule.deadline_column,
                candidate.semantic_key;
        END IF;
        present := candidate_count = 1 AND declared_deadline <= frontier;
        canonical := pgreact_internal.canonical_bigint_v1(candidate.semantic_key);
        digest := pgreact_internal.activation_digest(target_version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);
        SELECT * INTO prior
        FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id
          AND activation_id = activation
        FOR UPDATE;
        IF present AND (prior.activation_id IS NULL OR NOT prior.active) THEN
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key,
                canonical_key_digest, key_codec_version, active, generation,
                revision, current_bindings, last_active_bindings,
                first_seen_at, last_seen_at
            ) VALUES (
                target_version_id, activation, candidate.semantic_key,
                canonical, digest, 1, true,
                COALESCE(prior.generation, 0) + 1, 0,
                candidate_bindings, candidate_bindings,
                clock_timestamp(), clock_timestamp()
            )
            ON CONFLICT (rule_version_id, activation_id) DO UPDATE SET
                active = true,
                generation = EXCLUDED.generation,
                revision = 0,
                current_bindings = EXCLUDED.current_bindings,
                last_active_bindings = EXCLUDED.last_active_bindings,
                deactivated_at = NULL,
                last_seen_at = EXCLUDED.last_seen_at;
            repaired := repaired + 1;
        ELSIF present AND prior.active
              AND pgreact_internal.watched_changed(
                  version_row, prior.current_bindings, candidate_bindings) THEN
            UPDATE pgreact_internal.activation_state
            SET revision = revision + 1,
                current_bindings = candidate_bindings,
                last_active_bindings = candidate_bindings,
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id
              AND activation_id = activation;
            repaired := repaired + 1;
        ELSIF NOT present AND prior.active THEN
            UPDATE pgreact_internal.activation_state
            SET active = false,
                current_bindings = NULL,
                deactivated_at = clock_timestamp(),
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id
              AND activation_id = activation;
            repaired := repaired + 1;
        END IF;
    END LOOP;
    UPDATE pgreact_internal.reconciliation_audit
    SET completed_at = clock_timestamp(),
        rows_repaired = repaired,
        events_emitted = 0,
        status = 'COMPLETED'
    WHERE reconciliation_id = audit_id;
    RETURN repaired;
END
$$;

CREATE FUNCTION pgreact.begin_deadline_refresh(refresh_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE locked boolean := false;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M12_CLOCK_UNAUTHORIZED: only pgreact_admin may advance database time';
    END IF;
    IF pg_catalog.pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M12_CLOCK_STANDBY: database time cannot advance on a physical standby';
    END IF;
    PERFORM pg_catalog.pg_advisory_lock(5788046901200000);
    locked := true;
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.rule_barriers barrier
        JOIN pgreact_internal.deadline_rules deadline USING (rule_version_id)
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE version.state = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'M12_CLOCK_BARRIER: an active deadline rule already has a claim barrier';
    END IF;
    INSERT INTO pgreact_internal.rule_barriers (
        rule_version_id, reason, refresh_id
    )
    SELECT deadline.rule_version_id, 'REFRESHING', begin_deadline_refresh.refresh_id
    FROM pgreact_internal.deadline_rules deadline
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    WHERE version.state = 'ACTIVE';
EXCEPTION WHEN OTHERS THEN
    IF locked THEN
        PERFORM pg_catalog.pg_advisory_unlock(5788046901200000);
    END IF;
    RAISE;
END
$$;

CREATE FUNCTION pgreact.advance_deadline_clock(
    sampled_time timestamptz DEFAULT clock_timestamp()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    previous_frontier timestamptz;
    next_frontier timestamptz;
    max_keys integer;
    deadline_rule record;
    candidate record;
    rule_keys bigint;
    total_keys bigint := 0;
    changed_rules integer := 0;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'M12_CLOCK_UNAUTHORIZED: only pgreact_admin may advance database time';
    END IF;
    IF sampled_time IS NULL OR NOT isfinite(sampled_time) THEN
        RAISE EXCEPTION 'M12_CLOCK_SAMPLE: sampled database time must be finite and non-null';
    END IF;
    IF pg_catalog.pg_is_in_recovery() THEN
        RAISE EXCEPTION 'M12_CLOCK_STANDBY: database time cannot advance on a physical standby';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.deadline_rules deadline
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE version.state = 'ACTIVE'
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.rule_barriers barrier
              WHERE barrier.rule_version_id = deadline.rule_version_id
                AND barrier.reason = 'REFRESHING'
          )
    ) THEN
        RAISE EXCEPTION 'M12_CLOCK_BARRIER: begin_deadline_refresh must commit before clock advancement';
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT frontier INTO STRICT previous_frontier
    FROM pgreact_internal.clock_frontier
    FOR UPDATE;
    next_frontier := greatest(previous_frontier, sampled_time);
    SELECT max_deadlines_per_pass INTO STRICT max_keys
    FROM pgreact_internal.operational_settings;

    UPDATE pgreact_internal.clock_frontier
    SET frontier = next_frontier,
        last_sampled_time = sampled_time,
        last_advanced_at = clock_timestamp();

    FOR deadline_rule IN
        SELECT deadline.rule_version_id,
               deadline.deadline_column,
               version.match_relid,
               version.key_column
        FROM pgreact_internal.deadline_rules deadline
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE version.state = 'ACTIVE'
        ORDER BY deadline.rule_version_id
    LOOP
        EXECUTE format(
            'SELECT count(*) FROM %s WHERE %I > $1 AND %I <= $2',
            deadline_rule.match_relid::regclass,
            deadline_rule.deadline_column,
            deadline_rule.deadline_column
        ) INTO rule_keys USING previous_frontier, next_frontier;
        total_keys := total_keys + rule_keys;
        IF total_keys > max_keys THEN
            RAISE EXCEPTION 'M12_DEADLINE_LIMIT: clock pass would advance % keys; limit is %',
                total_keys, max_keys;
        END IF;
    END LOOP;

    IF pg_catalog.current_setting('pgreact.test_fail_clock_phase', true) = 'frontier' THEN
        RAISE EXCEPTION 'injected M12 clock failure after frontier update';
    END IF;

    FOR deadline_rule IN
        SELECT deadline.rule_version_id,
               deadline.deadline_column,
               version.match_relid,
               version.key_column
        FROM pgreact_internal.deadline_rules deadline
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE version.state = 'ACTIVE'
        ORDER BY deadline.rule_version_id
    LOOP
        rule_keys := 0;
        FOR candidate IN EXECUTE format(
            'SELECT %I::bigint AS semantic_key FROM %s '
            'WHERE %I > $1 AND %I <= $2 ORDER BY %I, %I',
            deadline_rule.key_column,
            deadline_rule.match_relid::regclass,
            deadline_rule.deadline_column,
            deadline_rule.deadline_column,
            deadline_rule.deadline_column,
            deadline_rule.key_column
        ) USING previous_frontier, next_frontier
        LOOP
            PERFORM pgreact_internal.reconcile_deadline_key(
                deadline_rule.rule_version_id, candidate.semantic_key);
            rule_keys := rule_keys + 1;
        END LOOP;
        IF rule_keys > 0 THEN
            changed_rules := changed_rules + 1;
        END IF;
    END LOOP;

    IF pg_catalog.current_setting('pgreact.test_fail_clock_phase', true) = 'lifecycle' THEN
        RAISE EXCEPTION 'injected M12 clock failure after lifecycle update';
    END IF;

    INSERT INTO pgreact_internal.clock_history (
        sampled_time, previous_frontier, frontier,
        affected_rules, affected_keys
    ) VALUES (
        sampled_time, previous_frontier, next_frontier,
        changed_rules, total_keys
    );
    RETURN jsonb_build_object(
        'sampled_time', sampled_time,
        'previous_frontier', previous_frontier,
        'frontier', next_frontier,
        'affected_rules', changed_rules,
        'affected_keys', total_keys);
END
$$;

CREATE FUNCTION pgreact.finish_deadline_refresh()
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    DELETE FROM pgreact_internal.rule_barriers barrier
    USING pgreact_internal.deadline_rules deadline
    WHERE barrier.rule_version_id = deadline.rule_version_id
      AND barrier.reason = 'REFRESHING';
    RETURN pg_catalog.pg_advisory_unlock(5788046901200000);
END
$$;

CREATE OR REPLACE FUNCTION pgreact.claim(
    worker_id text,
    max_items integer DEFAULT 1,
    lease_for interval DEFAULT interval '60 seconds',
    agenda_groups text[] DEFAULT NULL
)
RETURNS TABLE(
    episode_id bigint,
    lease_token uuid,
    activation_id uuid,
    bindings jsonb,
    event_kind text,
    rule_version_id uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    candidate record;
    claimed record;
    count_claimed integer := 0;
    seconds integer := extract(epoch FROM lease_for)::integer;
    fairness interval;
    claim_limit integer;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    SELECT fairness_window, max_claims INTO fairness, claim_limit
    FROM pgreact_internal.operational_settings;
    IF max_items NOT BETWEEN 1 AND claim_limit THEN
        RAISE EXCEPTION 'max_items must be between 1 and %', claim_limit;
    END IF;
    IF seconds < 1 THEN RAISE EXCEPTION 'lease_for must be at least one second'; END IF;
    FOR candidate IN
        SELECT agenda.rule_version_id
        FROM pgreact_internal.agenda agenda
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE agenda.state IN ('PENDING', 'RETRY_WAIT')
          AND agenda.available_at <= clock_timestamp()
          AND version.state IN ('ACTIVE', 'DRAINING')
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.rule_barriers barrier
              WHERE barrier.rule_version_id = agenda.rule_version_id)
          AND (agenda_groups IS NULL OR agenda.agenda_group = ANY(agenda_groups))
        ORDER BY CASE WHEN agenda.available_at <= clock_timestamp() - fairness THEN 0 ELSE 1 END,
                 agenda.available_at, agenda.salience DESC, agenda.episode_id
    LOOP
        SELECT * INTO claimed
        FROM pgreact.claim_episode(candidate.rule_version_id, worker_id, seconds);
        IF FOUND THEN
            SELECT agenda.event_kind INTO event_kind
            FROM pgreact_internal.agenda agenda
            WHERE agenda.episode_id = claimed.episode_id;
            episode_id := claimed.episode_id;
            lease_token := claimed.lease_token;
            activation_id := claimed.activation_id;
            bindings := claimed.bindings;
            rule_version_id := candidate.rule_version_id;
            RETURN NEXT;
            count_claimed := count_claimed + 1;
            EXIT WHEN count_claimed >= max_items;
        END IF;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.deadline_status(target_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    frontier timestamptz;
    rule_row record;
    candidates jsonb;
    rules jsonb := '[]'::jsonb;
BEGIN
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock;
    FOR rule_row IN
        SELECT rule.rule_name,
               version.rule_version_id,
               version.state,
               version.match_relid,
               version.key_column,
               deadline.deadline_column
        FROM pgreact_internal.rules rule
        JOIN pgreact_internal.rule_versions version USING (rule_id)
        JOIN pgreact_internal.deadline_rules deadline USING (rule_version_id)
        WHERE (target_name IS NULL OR rule.rule_name = target_name)
          AND version.state <> 'REMOVED'
        ORDER BY rule.rule_name, version.created_at
    LOOP
        EXECUTE format(
            'SELECT COALESCE(jsonb_agg(jsonb_build_object('
            '''semantic_key'', candidate.%1$I::bigint, '
            '''deadline'', candidate.%2$I, '
            '''due'', candidate.%2$I <= $1, '
            '''active'', COALESCE(activation.active, false)) '
            'ORDER BY candidate.%2$I, candidate.%1$I), ''[]''::jsonb) '
            'FROM %3$s candidate LEFT JOIN pgreact_internal.activation_state activation '
            'ON activation.rule_version_id = %4$L::uuid '
            'AND activation.semantic_key = candidate.%1$I::bigint',
            rule_row.key_column,
            rule_row.deadline_column,
            rule_row.match_relid::regclass,
            rule_row.rule_version_id::text
        ) INTO candidates USING frontier;
        rules := rules || jsonb_build_array(jsonb_build_object(
            'rule_name', rule_row.rule_name,
            'state', rule_row.state,
            'deadline_column', rule_row.deadline_column,
            'clock_frontier', frontier,
            'candidates', candidates));
    END LOOP;
    RETURN rules;
END
$$;

CREATE FUNCTION pgreact_internal.deadline_history(target_name text)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'rule_name', rule.rule_name,
        'semantic_key', activation.semantic_key,
        'generation', event.generation,
        'revision', event.revision,
        'event_kind', event.event_kind,
        'declared_deadline', deadline.declared_deadline,
        'clock_frontier', deadline.observed_frontier
    ) ORDER BY event.event_id), '[]'::jsonb)
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.lifecycle_events event USING (rule_version_id)
    JOIN pgreact_internal.deadline_lifecycle deadline USING (event_id)
    JOIN pgreact_internal.activation_state activation
      ON activation.rule_version_id = event.rule_version_id
     AND activation.activation_id = event.activation_id
    WHERE rule.rule_name = $1
$$;

CREATE FUNCTION pgreact_api.validate_deadline_rule(
    condition regclass,
    semantic_key name,
    deadline_column name,
    on_activate text DEFAULT NULL
)
RETURNS TABLE(
    contract_version integer,
    code text,
    severity text,
    object_identity text,
    message text,
    hint text,
    details jsonb
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT * FROM pgreact_internal.validate_deadline_rule(
        $1, $2, $3, $4::regprocedure)
$$;

CREATE FUNCTION pgreact_api.author_deadline_rule(
    rule_name text,
    condition regclass,
    semantic_key name,
    deadline_column name,
    kind text DEFAULT NULL,
    on_activate text DEFAULT NULL,
    on_deactivate text DEFAULT NULL,
    on_change text DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS uuid
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pgreact.create_deadline_rule(
        $1, $2, ARRAY[$3], $4, $5, $6::regprocedure, $7::regprocedure,
        $8::regprocedure, $9, $10, $11, $12, $13, $14, $15, $16, $17)
$$;

CREATE FUNCTION pgreact_api.pause_rule(name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = pause_rule.name AND version.state = 'ACTIVE'
    ORDER BY version.created_at DESC LIMIT 1;
    IF version_id IS NULL THEN RAISE EXCEPTION 'M12_RULE_NOT_ACTIVE: %', name; END IF;
    PERFORM pgreact.pause_rule(version_id);
END
$$;

CREATE FUNCTION pgreact_api.resume_rule(name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = resume_rule.name AND version.state = 'PAUSED'
    ORDER BY version.created_at DESC LIMIT 1;
    IF version_id IS NULL THEN RAISE EXCEPTION 'M12_RULE_NOT_PAUSED: %', name; END IF;
    PERFORM pgreact.resume_rule(version_id);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.deadline_rules
        WHERE rule_version_id = version_id
    ) THEN
        PERFORM pgreact_internal.reconcile_deadline_rule(version_id);
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.run_rule(name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_id uuid; rule_state text;
BEGIN
    SELECT version.rule_version_id, version.state
      INTO version_id, rule_state
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = run_rule.name
      AND version.state <> 'REMOVED'
    ORDER BY version.created_at DESC LIMIT 1;
    IF version_id IS NULL THEN RAISE EXCEPTION 'M11_RULE_NOT_FOUND: %', name; END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.deadline_rules
        WHERE rule_version_id = version_id
    ) AND rule_state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'M12_RULE_NOT_ACTIVE: %', name;
    END IF;
    PERFORM pgreact.refresh_rule(version_id);
END
$$;

CREATE FUNCTION pgreact_api.reconcile_rule(name text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.deadline_rules deadline USING (rule_version_id)
    WHERE rule.rule_name = reconcile_rule.name
      AND version.state = 'ACTIVE'
    ORDER BY version.created_at DESC LIMIT 1;
    IF version_id IS NULL THEN RAISE EXCEPTION 'M12_DEADLINE_RULE_NOT_FOUND: %', name; END IF;
    RETURN pgreact_internal.reconcile_deadline_state(version_id);
END
$$;

CREATE FUNCTION pgreact_api.replace_deadline_rule(
    name text,
    condition regclass,
    semantic_key name,
    deadline_column name,
    on_activate text DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    on_deactivate text DEFAULT NULL,
    on_change text DEFAULT NULL,
    old_work_policy text DEFAULT 'DRAIN_OLD'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE prior_version uuid; next_version uuid; diagnostic record;
BEGIN
    SELECT version.rule_version_id INTO prior_version
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.deadline_rules deadline USING (rule_version_id)
    WHERE rule.rule_name = replace_deadline_rule.name
      AND version.state IN ('ACTIVE', 'PAUSED')
    ORDER BY version.created_at DESC LIMIT 1;
    IF prior_version IS NULL THEN RAISE EXCEPTION 'M12_DEADLINE_RULE_NOT_FOUND: %', name; END IF;
    SELECT * INTO diagnostic
    FROM pgreact_internal.validate_deadline_rule(
        condition, semantic_key, deadline_column, on_activate::regprocedure)
    WHERE severity = 'ERROR' ORDER BY code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react deadline validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    next_version := pgreact.replace_rule(
        prior_version, condition, ARRAY[semantic_key], on_activate::regprocedure,
        'SEED_CURRENT', on_deactivate::regprocedure, on_change::regprocedure,
        old_work_policy);
    RETURN pgreact_internal.mark_deadline_rule(
        next_version, deadline_column, bootstrap_policy);
END
$$;

CREATE FUNCTION pgreact_api.remove_rule(name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = remove_rule.name
      AND version.state = 'PAUSED'
    ORDER BY version.created_at DESC LIMIT 1;
    IF version_id IS NULL THEN RAISE EXCEPTION 'M12_RULE_NOT_PAUSED: %', name; END IF;
    PERFORM pgreact.remove_rule(version_id);
END
$$;

CREATE FUNCTION pgreact_api.deadline_history(name text)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 2,
        'rule_name', $1,
        'events', pgreact_internal.deadline_history($1))
$$;

CREATE OR REPLACE FUNCTION pgreact_api.rule_status(name text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 2,
        'rules', COALESCE((
            SELECT jsonb_agg(to_jsonb(rule) ORDER BY rule.rule_name)
            FROM pgreact.rules rule
            WHERE $1 IS NULL OR rule.rule_name = $1), '[]'::jsonb),
        'deadlines', pgreact_internal.deadline_status($1),
        'health', COALESCE((
            SELECT jsonb_agg(to_jsonb(diagnostic)
                             ORDER BY diagnostic.code, diagnostic.object_identity)
            FROM pgreact.health_check() diagnostic), '[]'::jsonb))
$$;

CREATE OR REPLACE FUNCTION pgreact_api.explain_rule(name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_id uuid; result jsonb;
BEGIN
    SELECT version.rule_version_id INTO version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    WHERE rule.rule_name = explain_rule.name
    ORDER BY version.created_at DESC LIMIT 1;
    IF version_id IS NULL THEN RAISE EXCEPTION 'M11_RULE_NOT_FOUND: %', name; END IF;
    result := pgreact.explain_rule(version_id);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.deadline_rules
        WHERE rule_version_id = version_id
    ) THEN
        result := result || jsonb_build_object(
            'deadline', (pgreact_internal.deadline_status(name) -> 0),
            'deadline_history', pgreact_internal.deadline_history(name));
    END IF;
    RETURN result;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.health()
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'contract_version', 2,
        'clock_frontier', clock.frontier,
        'diagnostics', COALESCE((
            SELECT jsonb_agg(diagnostic ORDER BY diagnostic ->> 'code',
                                                  diagnostic ->> 'object_identity')
            FROM (
                SELECT to_jsonb(health) AS diagnostic
                FROM pgreact.health_check() health
                UNION ALL
                SELECT jsonb_build_object(
                    'code', 'M12_CLOCK_LAG',
                    'severity', 'WARNING',
                    'object_identity', 'database_clock',
                    'message', 'durable database-time frontier is behind PostgreSQL time',
                    'hint', 'Run the supported pg-reactd coordinator pass.')
                FROM pgreact_internal.operational_settings settings
                WHERE EXISTS (
                    SELECT 1
                    FROM pgreact_internal.deadline_rules deadline
                    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
                    WHERE version.state = 'ACTIVE')
                  AND (clock.frontier = '-infinity'::timestamptz
                       OR clock_timestamp() - clock.frontier > settings.clock_lag_warning)
            ) diagnostics), '[]'::jsonb))
    FROM pgreact_internal.clock_frontier clock
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    pgreact_internal.derivation_program_graph(jsonb) TO PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M12 database-time deadlines over one durable monotone PostgreSQL clock frontier';
