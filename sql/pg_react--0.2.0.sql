CREATE SCHEMA pgreact;
CREATE SCHEMA pgreact_internal;
CREATE SCHEMA pgreact_runtime;

REVOKE ALL ON SCHEMA pgreact_internal, pgreact_runtime FROM PUBLIC;

CREATE TYPE pgreact.activation_context AS (
    activation_id uuid,
    episode_id bigint,
    rule_id uuid,
    rule_version_id uuid,
    generation bigint,
    revision bigint,
    event_kind text,
    attempt_no integer,
    event_at timestamptz,
    worker_id text,
    idempotency_key text
);

CREATE TABLE pgreact_internal.rules (
    rule_id uuid PRIMARY KEY,
    rule_name text NOT NULL,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.rule_versions (
    rule_version_id uuid PRIMARY KEY,
    rule_id uuid NOT NULL REFERENCES pgreact_internal.rules,
    owner_oid oid NOT NULL,
    source_view_oid oid NOT NULL,
    source_view_name text NOT NULL,
    source_definition text NOT NULL,
    source_definition_digest bytea NOT NULL,
    source_row_signature bytea NOT NULL,
    key_column name NOT NULL,
    match_relid oid,
    match_name text NOT NULL UNIQUE,
    consequence_oid oid,
    consequence_identity text,
    consequence_digest bytea,
    dispatcher_oid oid,
    dispatcher_identity text,
    dispatcher_digest bytea,
    bootstrap_policy text NOT NULL CHECK (bootstrap_policy IN ('SEED_CURRENT', 'REQUIRE_EMPTY')),
    refresh_mode text NOT NULL CHECK (refresh_mode = 'DIFFERENTIAL'),
    isolation_level text NOT NULL CHECK (isolation_level = 'read committed'),
    state text NOT NULL CHECK (state IN ('INITIALIZING', 'ACTIVE', 'PAUSED', 'REMOVED', 'ERROR')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.activation_state (
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    activation_id uuid NOT NULL,
    semantic_key bigint NOT NULL,
    canonical_key bytea NOT NULL,
    canonical_key_digest bytea NOT NULL,
    key_codec_version integer NOT NULL CHECK (key_codec_version = 1),
    active boolean NOT NULL,
    generation bigint NOT NULL CHECK (generation > 0),
    current_bindings jsonb,
    last_active_bindings jsonb,
    first_seen_at timestamptz NOT NULL,
    last_seen_at timestamptz NOT NULL,
    deactivated_at timestamptz,
    PRIMARY KEY (rule_version_id, activation_id),
    UNIQUE (rule_version_id, semantic_key)
);

CREATE TABLE pgreact_internal.lifecycle_events (
    event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id uuid NOT NULL REFERENCES pgreact_internal.rules,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    activation_id uuid NOT NULL,
    generation bigint NOT NULL,
    event_kind text NOT NULL CHECK (event_kind IN ('ACTIVATE', 'DEACTIVATE')),
    transitioned_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    transition_xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
    old_bindings jsonb,
    new_bindings jsonb,
    idempotency_key text NOT NULL UNIQUE,
    UNIQUE (rule_version_id, activation_id, generation, event_kind)
);

CREATE TABLE pgreact_internal.agenda (
    episode_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id bigint NOT NULL UNIQUE REFERENCES pgreact_internal.lifecycle_events,
    rule_id uuid NOT NULL REFERENCES pgreact_internal.rules,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    activation_id uuid NOT NULL,
    activation_generation bigint NOT NULL,
    state text NOT NULL CHECK (state IN ('PENDING', 'LEASED', 'COMPLETED', 'FAILED', 'SKIPPED')),
    new_bindings jsonb NOT NULL,
    available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_token uuid,
    worker_id text,
    claimed_at timestamptz,
    lease_expires_at timestamptz,
    completed_at timestamptz,
    idempotency_key text NOT NULL UNIQUE
);

CREATE INDEX agenda_claim_idx
    ON pgreact_internal.agenda (rule_version_id, state, available_at, episode_id);

CREATE TABLE pgreact_internal.executions (
    execution_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    episode_id bigint NOT NULL REFERENCES pgreact_internal.agenda,
    attempt_no integer NOT NULL,
    worker_id text NOT NULL,
    lease_token uuid NOT NULL,
    started_at timestamptz NOT NULL,
    finished_at timestamptz NOT NULL,
    status text NOT NULL CHECK (status IN ('COMPLETED', 'FAILED', 'SKIPPED')),
    error_message text,
    transaction_id xid8 NOT NULL,
    UNIQUE (episode_id, attempt_no)
);

CREATE TABLE pgreact_internal.rule_barriers (
    rule_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.rule_versions,
    reason text NOT NULL CHECK (reason IN ('REFRESHING', 'RECONCILING', 'INVALID_KEY')),
    refresh_id bigint,
    created_by name NOT NULL DEFAULT current_user,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.activation_delta_buffer (
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    semantic_key bigint NOT NULL,
    xid xid8 NOT NULL,
    saw_insert boolean NOT NULL DEFAULT false,
    saw_update boolean NOT NULL DEFAULT false,
    saw_delete boolean NOT NULL DEFAULT false,
    before_bindings jsonb,
    after_bindings jsonb,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (rule_version_id, semantic_key, xid)
);

CREATE TABLE pgreact_internal.reconciliation_audit (
    reconciliation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    mode text NOT NULL CHECK (mode = 'STATE_ONLY'),
    started_at timestamptz NOT NULL,
    completed_at timestamptz,
    rows_repaired bigint,
    events_emitted bigint NOT NULL DEFAULT 0 CHECK (events_emitted = 0),
    status text NOT NULL CHECK (status IN ('RUNNING', 'COMPLETED'))
);

CREATE FUNCTION pgreact_internal.canonical_bigint_v1(value bigint)
RETURNS bytea
LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT decode('0101', 'hex') || int4send(8) || int8send(value)
$$;

CREATE FUNCTION pgreact_internal.activation_digest(
    rule_version_id uuid,
    canonical_key bytea
)
RETURNS bytea
LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT sha256(uuid_send(rule_version_id) || canonical_key)
$$;

CREATE FUNCTION pgreact_internal.activation_uuid(digest bytea)
RETURNS uuid
LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
DECLARE
    value bytea := substring(digest FROM 1 FOR 16);
    hex text;
BEGIN
    IF length(digest) <> 32 THEN
        RAISE EXCEPTION 'pg-react identity digest must contain 32 bytes';
    END IF;
    value := set_byte(value, 6, (get_byte(value, 6) & 15) | 128);
    value := set_byte(value, 8, (get_byte(value, 8) & 63) | 128);
    hex := encode(value, 'hex');
    RETURN (substring(hex, 1, 8) || '-' || substring(hex, 9, 4) || '-' ||
            substring(hex, 13, 4) || '-' || substring(hex, 17, 4) || '-' ||
            substring(hex, 21, 12))::uuid;
END
$$;

CREATE FUNCTION pgreact_internal.source_row_signature(source_relid oid)
RETURNS bytea
LANGUAGE SQL STABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE oid = $1)
        THEN sha256(convert_to(COALESCE((
            SELECT string_agg(format('%s:%I:%s:%s', a.attnum, a.attname,
                pg_catalog.format_type(a.atttypid, a.atttypmod),
                CASE WHEN c.oid IS NULL THEN '' ELSE format('%I.%I', n.nspname, c.collname) END), ',' ORDER BY a.attnum)
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_collation c ON c.oid = a.attcollation
            LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.collnamespace
            WHERE a.attrelid = $1 AND a.attnum > 0 AND NOT a.attisdropped
        ), ''), 'UTF8'))
    END
$$;

-- Adapter v1: these are the only pg_trickle calls made by pg-react.
CREATE FUNCTION pgreact_internal.assert_m0_compatibility()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF (SELECT extversion FROM pg_catalog.pg_extension WHERE extname = 'pg_trickle') <> '0.81.0' THEN
        RAISE EXCEPTION 'pg-react M0 requires pg_trickle 0.81.0 (source ba41c9c2e2bbf2195917fcdcc89efa8ab3089dcb)';
    END IF;
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'pg-react M0 requires READ COMMITTED';
    END IF;
    IF current_setting('pg_trickle.user_triggers') NOT IN ('auto', 'on') THEN
        RAISE EXCEPTION 'pg-react M0 requires pg_trickle.user_triggers=auto';
    END IF;
    IF current_setting('pg_trickle.enabled') <> 'off' THEN
        RAISE EXCEPTION 'pg-react command rules require pg_trickle.enabled=off so only the coordinator can refresh';
    END IF;
    IF current_setting('pg_trickle.differential_max_change_ratio')::numeric < 1 THEN
        RAISE EXCEPTION 'pg-react command rules require pg_trickle.differential_max_change_ratio=1.0 to forbid adaptive FULL refresh';
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.create_m0_stream(name text, query text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_m0_compatibility();
    PERFORM pgtrickle.create_stream_table(
        name => create_m0_stream.name,
        query => create_m0_stream.query,
        schedule => '1h',
        refresh_mode => 'DIFFERENTIAL',
        initialize => true
    );
END
$$;

CREATE FUNCTION pgreact_internal.refresh_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
BEGIN
    PERFORM pgreact_internal.assert_m0_compatibility();
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id
      AND refresh_mode = 'DIFFERENTIAL'
      AND isolation_level = 'read committed';
    PERFORM pgtrickle.refresh_stream_table(version_row.match_name);
END
$$;

CREATE FUNCTION pgreact_internal.binding_ddl_lock()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    -- ponytail: one global DDL lock is enough for M0's one binding; use a
    -- per-object ProcessUtility hook if binding DDL throughput ever matters.
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
END
$$;

CREATE EVENT TRIGGER pgreact_binding_ddl_lock
    ON ddl_command_start
    WHEN TAG IN ('CREATE FUNCTION', 'ALTER FUNCTION', 'DROP FUNCTION')
    EXECUTE FUNCTION pgreact_internal.binding_ddl_lock();

CREATE FUNCTION pgreact_internal.capture_match_delta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_id uuid := TG_ARGV[0]::uuid;
    key_name name;
    old_bindings jsonb;
    new_bindings jsonb;
    old_key bigint;
    new_key bigint;
    current_xid xid8 := pg_catalog.pg_current_xact_id();
BEGIN
    SELECT key_column INTO STRICT key_name
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = version_id;

    IF TG_OP <> 'INSERT' THEN
        old_bindings := to_jsonb(OLD);
        IF NOT old_bindings ? key_name::text OR old_bindings ->> key_name::text IS NULL THEN
            RAISE EXCEPTION 'pg-react key %.% must be non-null', TG_TABLE_NAME, key_name;
        END IF;
        old_key := (old_bindings ->> key_name::text)::bigint;
        INSERT INTO pgreact_internal.activation_delta_buffer (
            rule_version_id, semantic_key, xid, saw_update, saw_delete, before_bindings
        ) VALUES (
            version_id, old_key, current_xid,
            TG_OP = 'UPDATE' AND (to_jsonb(NEW) ->> key_name::text)::bigint = old_key,
            TG_OP = 'DELETE' OR (to_jsonb(NEW) ->> key_name::text)::bigint IS DISTINCT FROM old_key,
            old_bindings
        )
        ON CONFLICT (rule_version_id, semantic_key, xid) DO UPDATE SET
            saw_update = pgreact_internal.activation_delta_buffer.saw_update OR EXCLUDED.saw_update,
            saw_delete = pgreact_internal.activation_delta_buffer.saw_delete OR EXCLUDED.saw_delete,
            before_bindings = COALESCE(pgreact_internal.activation_delta_buffer.before_bindings,
                                       EXCLUDED.before_bindings);
    END IF;

    IF TG_OP <> 'DELETE' THEN
        new_bindings := to_jsonb(NEW);
        IF NOT new_bindings ? key_name::text OR new_bindings ->> key_name::text IS NULL THEN
            RAISE EXCEPTION 'pg-react key %.% must be non-null', TG_TABLE_NAME, key_name;
        END IF;
        new_key := (new_bindings ->> key_name::text)::bigint;
        INSERT INTO pgreact_internal.activation_delta_buffer (
            rule_version_id, semantic_key, xid, saw_insert, saw_update, after_bindings
        ) VALUES (
            version_id, new_key, current_xid,
            TG_OP = 'INSERT' OR old_key IS DISTINCT FROM new_key,
            TG_OP = 'UPDATE' AND old_key = new_key,
            new_bindings
        )
        ON CONFLICT (rule_version_id, semantic_key, xid) DO UPDATE SET
            saw_insert = pgreact_internal.activation_delta_buffer.saw_insert OR EXCLUDED.saw_insert,
            saw_update = pgreact_internal.activation_delta_buffer.saw_update OR EXCLUDED.saw_update,
            after_bindings = EXCLUDED.after_bindings;
    END IF;
    RETURN NULL;
END
$$;

CREATE FUNCTION pgreact_internal.finalize_match_delta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_id uuid := TG_ARGV[0]::uuid;
    version_row pgreact_internal.rule_versions%ROWTYPE;
    buffered record;
    current_count bigint;
    final_bindings jsonb;
    canonical bytea;
    digest bytea;
    activation uuid;
    prior pgreact_internal.activation_state%ROWTYPE;
    next_generation bigint;
    new_event_id bigint;
    event_key text;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = version_id;

    FOR buffered IN
        DELETE FROM pgreact_internal.activation_delta_buffer
        WHERE rule_version_id = version_id
          AND xid = pg_catalog.pg_current_xact_id()
        RETURNING *
    LOOP
        EXECUTE format(
            'SELECT count(*), min(to_jsonb(m)::text)::jsonb FROM %s AS m '
            'WHERE (to_jsonb(m) ->> %L)::bigint = $1',
            version_row.match_relid::regclass,
            version_row.key_column::text
        ) INTO current_count, final_bindings USING buffered.semantic_key;

        IF current_count > 1 THEN
            RAISE EXCEPTION 'pg-react duplicate semantic key % in %',
                buffered.semantic_key, version_row.match_name;
        END IF;

        canonical := pgreact_internal.canonical_bigint_v1(buffered.semantic_key);
        digest := pgreact_internal.activation_digest(version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);

        SELECT * INTO prior
        FROM pgreact_internal.activation_state
        WHERE rule_version_id = version_id AND activation_id = activation
        FOR UPDATE;

        IF FOUND AND (prior.canonical_key <> canonical OR prior.canonical_key_digest <> digest) THEN
            RAISE EXCEPTION 'pg-react activation UUID collision for semantic key %',
                buffered.semantic_key;
        END IF;

        IF current_count = 1 AND (prior.activation_id IS NULL OR NOT prior.active) THEN
            next_generation := COALESCE(prior.generation, 0) + 1;
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key,
                canonical_key_digest, key_codec_version, active, generation,
                current_bindings, last_active_bindings, first_seen_at, last_seen_at
            ) VALUES (
                version_id, activation, buffered.semantic_key, canonical, digest, 1,
                true, next_generation, final_bindings, final_bindings,
                clock_timestamp(), clock_timestamp()
            )
            ON CONFLICT (rule_version_id, activation_id) DO UPDATE SET
                active = true,
                generation = EXCLUDED.generation,
                current_bindings = EXCLUDED.current_bindings,
                last_active_bindings = EXCLUDED.last_active_bindings,
                last_seen_at = EXCLUDED.last_seen_at,
                deactivated_at = NULL;

            event_key := encode(sha256(convert_to(
                version_id::text || ':' || activation::text || ':' || next_generation || ':ACTIVATE',
                'UTF8')), 'hex');
            INSERT INTO pgreact_internal.lifecycle_events (
                rule_id, rule_version_id, activation_id, generation, event_kind,
                new_bindings, idempotency_key
            ) VALUES (
                version_row.rule_id, version_id, activation, next_generation,
                'ACTIVATE', final_bindings, event_key
            ) RETURNING event_id INTO new_event_id;

            INSERT INTO pgreact_internal.agenda (
                event_id, rule_id, rule_version_id, activation_id,
                activation_generation, state, new_bindings, idempotency_key
            ) SELECT
                new_event_id, version_row.rule_id, version_id, activation,
                next_generation, 'PENDING', final_bindings, event_key
            WHERE version_row.consequence_oid IS NOT NULL;
        ELSIF current_count = 1 AND prior.active THEN
            UPDATE pgreact_internal.activation_state SET
                current_bindings = final_bindings,
                last_active_bindings = final_bindings,
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = version_id AND activation_id = activation;
        ELSIF current_count = 0 AND prior.active THEN
            UPDATE pgreact_internal.activation_state SET
                active = false,
                current_bindings = NULL,
                deactivated_at = clock_timestamp(),
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = version_id AND activation_id = activation;

            event_key := encode(sha256(convert_to(
                version_id::text || ':' || activation::text || ':' || prior.generation || ':DEACTIVATE',
                'UTF8')), 'hex');
            INSERT INTO pgreact_internal.lifecycle_events (
                rule_id, rule_version_id, activation_id, generation, event_kind,
                old_bindings, idempotency_key
            ) VALUES (
                version_row.rule_id, version_id, activation, prior.generation,
                'DEACTIVATE', prior.last_active_bindings, event_key
            );
        END IF;
    END LOOP;
    RETURN NULL;
END
$$;

CREATE FUNCTION pgreact_internal.register_reference_rule(
    rule_name text,
    source_view regclass,
    key_column name,
    consequence regprocedure,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    installer_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    source_row record;
    function_row record;
    rule_id uuid := gen_random_uuid();
    version_id uuid := gen_random_uuid();
    match_table text := 'm0_' || substring(replace(version_id::text, '-', ''), 1, 20);
    match_qualified text;
    source_qualified text;
    function_qualified text;
    function_identity text;
    function_digest bytea;
    source_signature bytea;
    dispatcher_name text := 'dispatch_' || replace(version_id::text, '-', '');
    dispatcher_qualified text;
    dispatcher_proc_oid oid;
    null_count bigint;
    duplicate_count bigint;
    current_count bigint;
    seeded record;
    canonical bytea;
    digest bytea;
BEGIN
    PERFORM pgreact_internal.assert_m0_compatibility();
    IF bootstrap_policy NOT IN ('SEED_CURRENT', 'REQUIRE_EMPTY') THEN
        RAISE EXCEPTION 'bootstrap policy must be SEED_CURRENT or REQUIRE_EMPTY';
    END IF;

    SELECT c.relkind, c.relowner, c.reltype,
           format('%I.%I', n.nspname, c.relname) AS qualified,
           pg_catalog.pg_get_viewdef(c.oid, true) AS definition
    INTO STRICT source_row
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE c.oid = source_view;
    IF source_row.relkind <> 'v' THEN
        RAISE EXCEPTION 'pg-react M0 source % must be a normal view', source_view;
    END IF;
    IF source_row.relowner <> installer_oid THEN
        RAISE EXCEPTION 'rule owner must own source view %', source_view;
    END IF;
    source_qualified := source_row.qualified;
    source_signature := pgreact_internal.source_row_signature(source_view);
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute
        WHERE attrelid = source_view AND attname = key_column
          AND atttypid = 'bigint'::regtype AND attnum > 0 AND NOT attisdropped
    ) THEN
        RAISE EXCEPTION 'key %.% must be bigint', source_view, key_column;
    END IF;

    IF consequence IS NOT NULL THEN
        SELECT p.proowner, p.prorettype, p.pronargs, p.proargtypes,
               format('%I.%I', n.nspname, p.proname) AS qualified,
               p.oid::regprocedure::text AS identity
        INTO STRICT function_row
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE p.oid = consequence;
        IF function_row.proowner <> installer_oid OR function_row.prorettype <> 'void'::regtype
           OR function_row.pronargs <> 2
           OR function_row.proargtypes[0] <> 'pgreact.activation_context'::regtype
           OR function_row.proargtypes[1] <> source_row.reltype THEN
            RAISE EXCEPTION 'consequence % must be owned by the rule owner and have signature (pgreact.activation_context, %) RETURNS void',
                consequence, source_qualified;
        END IF;
        function_qualified := function_row.qualified;
        function_identity := function_row.identity;
        function_digest := sha256(convert_to(pg_catalog.pg_get_functiondef(consequence), 'UTF8'));
    END IF;

    match_qualified := format('%I.%I', 'pgreact_runtime', match_table);
    dispatcher_qualified := format('%I.%I', 'pgreact_runtime', dispatcher_name);

    INSERT INTO pgreact_internal.rules VALUES (rule_id, rule_name, installer_oid, clock_timestamp());
    INSERT INTO pgreact_internal.rule_versions (
        rule_version_id, rule_id, owner_oid, source_view_oid, source_view_name,
        source_definition, source_definition_digest, source_row_signature, key_column, match_name,
        consequence_oid, consequence_identity, consequence_digest,
        bootstrap_policy, refresh_mode, isolation_level, state
    ) VALUES (
        version_id, rule_id, installer_oid, source_view, source_qualified,
        source_row.definition, sha256(convert_to(source_row.definition, 'UTF8')), source_signature,
        key_column, match_qualified, consequence, function_identity, function_digest,
        bootstrap_policy, 'DIFFERENTIAL', 'read committed', 'INITIALIZING'
    );

    PERFORM pgreact_internal.create_m0_stream(
        match_qualified,
        format('SELECT * FROM %s', source_qualified)
    );

    UPDATE pgreact_internal.rule_versions
    SET match_relid = match_qualified::regclass
    WHERE rule_version_id = version_id;

    IF consequence IS NOT NULL THEN
        EXECUTE format(
            'CREATE FUNCTION %s(context pgreact.activation_context, bindings jsonb) '
            'RETURNS void LANGUAGE SQL SECURITY DEFINER '
            'SET search_path = pg_catalog, pg_temp '
            'AS $dispatcher$ SELECT %s($1, pg_catalog.jsonb_populate_record(NULL::%s, $2)) $dispatcher$',
            dispatcher_qualified, function_qualified, source_qualified
        );
        EXECUTE format('ALTER FUNCTION %s(pgreact.activation_context,jsonb) OWNER TO %I',
                       dispatcher_qualified, session_user);
        EXECUTE format('REVOKE ALL ON FUNCTION %s(pgreact.activation_context,jsonb) FROM PUBLIC',
                       dispatcher_qualified);
        dispatcher_proc_oid := to_regprocedure(dispatcher_qualified || '(pgreact.activation_context,jsonb)');

        UPDATE pgreact_internal.rule_versions SET
            dispatcher_oid = dispatcher_proc_oid,
            dispatcher_identity = dispatcher_proc_oid::regprocedure::text,
            dispatcher_digest = sha256(convert_to(pg_catalog.pg_get_functiondef(dispatcher_proc_oid), 'UTF8'))
        WHERE rule_version_id = version_id;
    END IF;

    EXECUTE format(
        'CREATE TRIGGER pgreact_capture AFTER INSERT OR UPDATE OR DELETE ON %s '
        'FOR EACH ROW EXECUTE FUNCTION pgreact_internal.capture_match_delta(%L, %L)',
        match_qualified, version_id::text, key_column::text
    );
    EXECUTE format(
        'CREATE CONSTRAINT TRIGGER pgreact_finalize AFTER INSERT OR UPDATE OR DELETE ON %s '
        'DEFERRABLE INITIALLY DEFERRED FOR EACH ROW '
        'EXECUTE FUNCTION pgreact_internal.finalize_match_delta(%L)',
        match_qualified, version_id::text
    );

    EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NULL', match_qualified, key_column)
        INTO null_count;
    EXECUTE format(
        'SELECT count(*) FROM (SELECT %I FROM %s GROUP BY %I HAVING count(*) > 1) d',
        key_column, match_qualified, key_column
    ) INTO duplicate_count;
    EXECUTE format('SELECT count(*) FROM %s', match_qualified) INTO current_count;
    IF null_count > 0 OR duplicate_count > 0 THEN
        RAISE EXCEPTION 'source % has % null and % duplicate bigint keys',
            source_qualified, null_count, duplicate_count;
    END IF;
    IF bootstrap_policy = 'REQUIRE_EMPTY' AND current_count > 0 THEN
        RAISE EXCEPTION 'REQUIRE_EMPTY source % currently has % matches', source_qualified, current_count;
    END IF;

    IF bootstrap_policy = 'SEED_CURRENT' THEN
        FOR seeded IN EXECUTE format(
            'SELECT %I::bigint AS semantic_key, to_jsonb(m) AS bindings FROM %s m',
            key_column, match_qualified
        ) LOOP
            canonical := pgreact_internal.canonical_bigint_v1(seeded.semantic_key);
            digest := pgreact_internal.activation_digest(version_id, canonical);
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key,
                canonical_key_digest, key_codec_version, active, generation,
                current_bindings, last_active_bindings, first_seen_at, last_seen_at
            ) VALUES (
                version_id, pgreact_internal.activation_uuid(digest), seeded.semantic_key,
                canonical, digest, 1, true, 1, seeded.bindings, seeded.bindings,
                clock_timestamp(), clock_timestamp()
            );
        END LOOP;
    END IF;

    UPDATE pgreact_internal.rule_versions SET state = 'ACTIVE'
    WHERE rule_version_id = version_id;
    RETURN version_id;
END
$$;

CREATE FUNCTION pgreact_internal.begin_refresh(rule_version_id uuid, refresh_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pg_catalog.pg_advisory_lock(5788046901200000);
    INSERT INTO pgreact_internal.rule_barriers (
        rule_version_id, reason, refresh_id
    ) VALUES (rule_version_id, 'REFRESHING', refresh_id)
    ON CONFLICT ON CONSTRAINT rule_barriers_pkey DO UPDATE SET
        reason = 'REFRESHING',
        refresh_id = EXCLUDED.refresh_id,
        created_by = current_user,
        created_at = clock_timestamp();
END
$$;

CREATE FUNCTION pgreact_internal.clear_refresh_barrier(rule_version_id uuid)
RETURNS void
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    DELETE FROM pgreact_internal.rule_barriers
    WHERE rule_version_id = $1 AND reason = 'REFRESHING'
$$;

CREATE FUNCTION pgreact_internal.release_refresh_lock()
RETURNS boolean
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT pg_catalog.pg_advisory_unlock(5788046901200000)
$$;

CREATE FUNCTION pgreact_internal.execute_one(rule_version_id uuid, worker_id text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    episode pgreact_internal.agenda%ROWTYPE;
    event_row pgreact_internal.lifecycle_events%ROWTYPE;
    version_row pgreact_internal.rule_versions%ROWTYPE;
    token uuid := gen_random_uuid();
    started timestamptz := clock_timestamp();
    context pgreact.activation_context;
    dispatcher_call text;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    IF EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers b
               WHERE b.rule_version_id = execute_one.rule_version_id) THEN
        RAISE EXCEPTION 'pg-react claims are blocked for rule version %', rule_version_id;
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);

    SELECT * INTO episode
    FROM pgreact_internal.agenda a
    WHERE a.rule_version_id = execute_one.rule_version_id AND a.state = 'PENDING'
      AND a.available_at <= clock_timestamp()
    ORDER BY a.episode_id
    LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions v
    WHERE v.rule_version_id = execute_one.rule_version_id;
    SELECT * INTO STRICT event_row FROM pgreact_internal.lifecycle_events e
    WHERE e.event_id = episode.event_id;

    IF sha256(convert_to(pg_catalog.pg_get_functiondef(version_row.consequence_oid), 'UTF8'))
           <> version_row.consequence_digest
       OR sha256(convert_to(pg_catalog.pg_get_functiondef(version_row.dispatcher_oid), 'UTF8'))
           <> version_row.dispatcher_digest THEN
        RAISE EXCEPTION 'pg-react consequence or dispatcher drift for rule version %', rule_version_id;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_internal.activation_state s
        WHERE s.rule_version_id = execute_one.rule_version_id
          AND s.activation_id = episode.activation_id
          AND s.active AND s.generation = episode.activation_generation
    ) THEN
        RAISE EXCEPTION 'pg-react episode % is no longer eligible', episode.episode_id;
    END IF;

    UPDATE pgreact_internal.agenda SET
        state = 'LEASED', lease_token = token, worker_id = execute_one.worker_id,
        claimed_at = started
    WHERE episode_id = episode.episode_id;

    context := ROW(
        episode.activation_id, episode.episode_id, episode.rule_id,
        episode.rule_version_id, episode.activation_generation, 0,
        'ACTIVATE', 1, event_row.transitioned_at, worker_id,
        episode.idempotency_key
    )::pgreact.activation_context;
    SELECT format('%I.%I', n.nspname, p.proname) INTO STRICT dispatcher_call
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE p.oid = version_row.dispatcher_oid;
    EXECUTE format('SELECT %s($1, $2)', dispatcher_call)
        USING context, episode.new_bindings;

    INSERT INTO pgreact_internal.executions (
        episode_id, attempt_no, worker_id, lease_token, started_at,
        finished_at, status, transaction_id
    ) VALUES (
        episode.episode_id, 1, worker_id, token, started, clock_timestamp(),
        'COMPLETED', pg_catalog.pg_current_xact_id()
    );
    UPDATE pgreact_internal.agenda SET state = 'COMPLETED', completed_at = clock_timestamp()
    WHERE episode_id = episode.episode_id AND lease_token = token AND state = 'LEASED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg-react lease lost for episode %', episode.episode_id;
    END IF;
    RETURN episode.episode_id;
END
$$;

CREATE FUNCTION pgreact_internal.reconcile_state_only(target_version_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    version_row pgreact_internal.rule_versions%ROWTYPE;
    audit_id bigint;
    repaired bigint := 0;
    null_count bigint;
    duplicate_count bigint;
    match_row record;
    state_row pgreact_internal.activation_state%ROWTYPE;
    current_count bigint;
    canonical bytea;
    digest bytea;
    activation uuid;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions v
    WHERE v.rule_version_id = target_version_id;
    INSERT INTO pgreact_internal.rule_barriers (rule_version_id, reason)
    VALUES (target_version_id, 'RECONCILING')
    ON CONFLICT ON CONSTRAINT rule_barriers_pkey DO UPDATE SET reason = 'RECONCILING';
    INSERT INTO pgreact_internal.reconciliation_audit (
        rule_version_id, mode, started_at, status
    ) VALUES (target_version_id, 'STATE_ONLY', clock_timestamp(), 'RUNNING')
    RETURNING reconciliation_id INTO audit_id;

    EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NULL',
                   version_row.match_relid::regclass, version_row.key_column)
        INTO null_count;
    EXECUTE format(
        'SELECT count(*) FROM (SELECT %I FROM %s GROUP BY %I HAVING count(*) > 1) d',
        version_row.key_column, version_row.match_relid::regclass, version_row.key_column
    ) INTO duplicate_count;
    IF null_count > 0 OR duplicate_count > 0 THEN
        UPDATE pgreact_internal.rule_barriers SET reason = 'INVALID_KEY'
        WHERE rule_version_id = target_version_id;
        RAISE EXCEPTION 'cannot reconcile: % null and % duplicate semantic keys',
            null_count, duplicate_count;
    END IF;

    FOR state_row IN
        SELECT * FROM pgreact_internal.activation_state s
        WHERE s.rule_version_id = target_version_id
        FOR UPDATE
    LOOP
        EXECUTE format('SELECT count(*) FROM %s m WHERE %I = $1',
                       version_row.match_relid::regclass, version_row.key_column)
            INTO current_count USING state_row.semantic_key;
        IF current_count = 0 AND state_row.active THEN
            UPDATE pgreact_internal.activation_state SET active = false,
                current_bindings = NULL, deactivated_at = clock_timestamp(),
                last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id
              AND activation_id = state_row.activation_id;
            repaired := repaired + 1;
        END IF;
    END LOOP;

    FOR match_row IN EXECUTE format(
        'SELECT %I::bigint AS semantic_key, to_jsonb(m) AS bindings FROM %s m',
        version_row.key_column, version_row.match_relid::regclass
    ) LOOP
        canonical := pgreact_internal.canonical_bigint_v1(match_row.semantic_key);
        digest := pgreact_internal.activation_digest(target_version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);
        SELECT * INTO state_row FROM pgreact_internal.activation_state s
        WHERE s.rule_version_id = target_version_id
          AND s.activation_id = activation FOR UPDATE;
        IF NOT FOUND THEN
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key,
                canonical_key_digest, key_codec_version, active, generation,
                current_bindings, last_active_bindings, first_seen_at, last_seen_at
            ) VALUES (
                target_version_id, activation, match_row.semantic_key, canonical, digest,
                1, true, 1, match_row.bindings, match_row.bindings,
                clock_timestamp(), clock_timestamp()
            );
            repaired := repaired + 1;
        ELSIF NOT state_row.active OR state_row.current_bindings IS DISTINCT FROM match_row.bindings THEN
            UPDATE pgreact_internal.activation_state SET
                active = true,
                generation = CASE WHEN state_row.active THEN state_row.generation
                                  ELSE state_row.generation + 1 END,
                current_bindings = match_row.bindings,
                last_active_bindings = match_row.bindings,
                last_seen_at = clock_timestamp(), deactivated_at = NULL
            WHERE rule_version_id = target_version_id
              AND activation_id = activation;
            repaired := repaired + 1;
        END IF;
    END LOOP;

    DELETE FROM pgreact_internal.rule_barriers
    WHERE rule_version_id = target_version_id;
    UPDATE pgreact_internal.reconciliation_audit SET
        completed_at = clock_timestamp(), rows_repaired = repaired, status = 'COMPLETED'
    WHERE reconciliation_id = audit_id;
    RETURN repaired;
END
$$;

-- M1 public alpha API.  It intentionally delegates to the M0 coordinator path
-- and never exposes the private catalog or generated match relations.
CREATE FUNCTION pgreact_internal.assert_rule_owner(target_version_id uuid)
RETURNS pgreact_internal.rule_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    IF version_row.owner_oid <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
        RAISE EXCEPTION 'only the rule owner may manage rule version %', target_version_id;
    END IF;
    RETURN version_row;
END
$$;

CREATE FUNCTION pgreact.validate_rule(
    definition regclass,
    key_columns name[],
    on_activate regprocedure DEFAULT NULL
)
RETURNS TABLE(contract_version integer, code text, severity text, object_identity text, message text, hint text, details jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE source_row record; key_column name; function_row record;
BEGIN
    SELECT c.relkind, c.relowner, c.reltype, format('%I.%I', n.nspname, c.relname) AS identity
      INTO source_row
      FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = definition;
    IF NOT FOUND OR source_row.relkind <> 'v' THEN
        RETURN QUERY SELECT 1, 'SOURCE_NOT_VIEW', 'ERROR', definition::text,
            'definition must be a normal PostgreSQL view', 'Create a view and pass its regclass.', '{}'::jsonb;
        RETURN;
    END IF;
    IF source_row.relowner <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
        RETURN QUERY SELECT 1, 'SOURCE_NOT_OWNED', 'ERROR', source_row.identity,
            'rule owner must own the source view', 'Create the rule as the view owner.', '{}'::jsonb;
    END IF;
    IF cardinality(key_columns) <> 1 THEN
        RETURN QUERY SELECT 1, 'KEY_CODEC_UNSUPPORTED', 'ERROR', source_row.identity,
            'M1 supports exactly one semantic key column', 'Use one non-null bigint key column.', jsonb_build_object('key_columns', key_columns);
        RETURN;
    END IF;
    key_column := key_columns[1];
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute
         WHERE attrelid = definition AND attname = key_column AND atttypid = 'bigint'::regtype
           AND attnum > 0 AND NOT attisdropped
    ) THEN
        RETURN QUERY SELECT 1, 'KEY_NOT_BIGINT', 'ERROR', source_row.identity,
            'M1 semantic keys must be non-null bigint codec v1', 'Project one bigint key column from the view.', jsonb_build_object('key_column', key_column);
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_rewrite rw
        JOIN pg_catalog.pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
        JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
        WHERE rw.ev_class = definition AND (c.relrowsecurity OR c.relforcerowsecurity)
    ) THEN
        RETURN QUERY SELECT 1, 'RLS_UNSUPPORTED', 'ERROR', source_row.identity,
            'RLS-protected sources are unsupported in M1', 'Use a non-RLS source or wait for the tested evaluation-role contract.', '{}'::jsonb;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_rewrite rw
        JOIN pg_catalog.pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
        JOIN pg_catalog.pg_proc p ON p.oid = d.refobjid
        WHERE rw.ev_class = definition AND p.pronamespace <> 'pg_catalog'::regnamespace
    ) THEN
        RETURN QUERY SELECT 1, 'CONDITION_DEPENDENCY_UNSUPPORTED', 'ERROR', source_row.identity,
            'M1 condition views may use only pinned built-in executable dependencies',
            'Inline the operation with built-ins or wait for the dependency-DDL contract.', '{}'::jsonb;
        RETURN;
    END IF;
    IF on_activate IS NOT NULL THEN
        SELECT p.proowner, p.prorettype, p.pronargs, p.proargtypes INTO function_row
          FROM pg_catalog.pg_proc p WHERE p.oid = on_activate;
        IF NOT FOUND OR function_row.proowner <> source_row.relowner OR function_row.prorettype <> 'void'::regtype
           OR function_row.pronargs <> 2 OR function_row.proargtypes[0] <> 'pgreact.activation_context'::regtype
           OR function_row.proargtypes[1] <> source_row.reltype THEN
            RETURN QUERY SELECT 1, 'CONSEQUENCE_SIGNATURE', 'ERROR', on_activate::text,
                'activation consequence must be owned by the view owner and accept (pgreact.activation_context, view_row)',
                'Create a RETURNS void function with the exact view row type.', '{}'::jsonb;
            RETURN;
        END IF;
    END IF;
    RETURN QUERY SELECT 1, 'OK', 'INFO', source_row.identity,
        'rule can use the M1 coordinator-owned DIFFERENTIAL path',
        'Run create_rule with SEED_CURRENT or REQUIRE_EMPTY.',
        jsonb_build_object('key_codec', 'bigint-v1', 'refresh_mode', 'DIFFERENTIAL', 'bootstrap_default', 'SEED_CURRENT');
END
$$;

CREATE FUNCTION pgreact.create_rule(
    name text,
    definition regclass,
    key_columns name[],
    kind text DEFAULT NULL,
    on_activate regprocedure DEFAULT NULL,
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE diagnostic record;
BEGIN
    IF kind IS NOT NULL AND kind NOT IN ('COMMAND', 'CONSTRAINT') THEN
        RAISE EXCEPTION 'M1 kind must be COMMAND or CONSTRAINT';
    END IF;
    IF on_deactivate IS NOT NULL OR on_change IS NOT NULL THEN
        RAISE EXCEPTION 'M1 supports activate-only command rules; CHANGE and DEACTIVATE consequences begin in M2';
    END IF;
    IF kind = 'CONSTRAINT' AND on_activate IS NOT NULL THEN
        RAISE EXCEPTION 'constraint rules cannot have an activation consequence';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = name AND v.state <> 'REMOVED'
    ) THEN
        RAISE EXCEPTION 'a non-removed rule named % already exists', name;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_rule(definition, key_columns, on_activate)
    WHERE severity = 'ERROR' LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react validation % for %: %', diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    RETURN pgreact_internal.register_reference_rule(name, definition, key_columns[1], on_activate, bootstrap_policy);
END
$$;

CREATE FUNCTION pgreact.pause_rule(target_version_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    UPDATE pgreact_internal.rule_versions SET state = 'PAUSED' WHERE rule_version_id = target_version_id;
END $$;

CREATE FUNCTION pgreact.resume_rule(target_version_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    IF EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers WHERE rule_version_id = target_version_id) THEN
        RAISE EXCEPTION 'cannot resume rule version % while its claim barrier is present', target_version_id;
    END IF;
    UPDATE pgreact_internal.rule_versions SET state = 'ACTIVE' WHERE rule_version_id = target_version_id AND state = 'PAUSED';
    IF NOT FOUND THEN RAISE EXCEPTION 'rule version % is not paused', target_version_id; END IF;
END $$;

CREATE FUNCTION pgreact.replace_rule(
    target_version_id uuid, definition regclass, key_columns name[], on_activate regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE prior pgreact_internal.rule_versions%ROWTYPE;
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    IF prior.state <> 'PAUSED' OR EXISTS (
        SELECT 1 FROM pgreact_internal.agenda WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'LEASED')
    ) THEN
        RAISE EXCEPTION 'replacement requires a paused rule with no pending or leased episodes';
    END IF;
    UPDATE pgreact_internal.rule_versions SET state = 'REMOVED' WHERE rule_version_id = target_version_id;
    RETURN pgreact.create_rule(name => (SELECT rule_name FROM pgreact_internal.rules WHERE rule_id = prior.rule_id),
        definition => definition, key_columns => key_columns, on_activate => on_activate, bootstrap_policy => bootstrap_policy);
END $$;

CREATE FUNCTION pgreact.remove_rule(target_version_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; dispatcher_name text;
BEGIN
    version_row := pgreact_internal.assert_rule_owner(target_version_id);
    IF version_row.state <> 'PAUSED' OR EXISTS (
        SELECT 1 FROM pgreact_internal.agenda WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'LEASED')
    ) THEN
        RAISE EXCEPTION 'removal requires a paused rule with no pending or leased episodes';
    END IF;
    PERFORM pgtrickle.drop_stream_table(version_row.match_name, true);
    IF version_row.dispatcher_oid IS NOT NULL THEN
        SELECT format('%I.%I', n.nspname, p.proname) INTO dispatcher_name
        FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE p.oid = version_row.dispatcher_oid;
        IF dispatcher_name IS NOT NULL THEN
            EXECUTE format('DROP FUNCTION IF EXISTS %s(pgreact.activation_context, jsonb)', dispatcher_name);
        END IF;
    END IF;
    UPDATE pgreact_internal.rule_versions SET state = 'REMOVED', match_relid = NULL WHERE rule_version_id = target_version_id;
END $$;

CREATE FUNCTION pgreact.preview_rule(definition regclass, key_columns name[])
RETURNS TABLE(snapshot_at timestamptz, semantic_key bigint, bindings jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE key_column name;
BEGIN
    IF cardinality(key_columns) <> 1 THEN RAISE EXCEPTION 'M1 preview requires exactly one key column'; END IF;
    key_column := key_columns[1];
    RETURN QUERY EXECUTE format('SELECT clock_timestamp(), (%1$I)::bigint, to_jsonb(v) FROM %2$s v ORDER BY %1$I', key_column, definition);
END $$;

CREATE FUNCTION pgreact.preview_rule(definition regclass, key_columns name[], bootstrap_policy text)
RETURNS TABLE(snapshot_at timestamptz, semantic_key bigint, bindings jsonb)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT * FROM pgreact.preview_rule($1, $2)
$$;

CREATE FUNCTION pgreact.reconcile_rule(target_version_id uuid)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    RETURN pgreact_internal.reconcile_state_only(target_version_id);
END $$;

CREATE FUNCTION pgreact.begin_refresh(target_version_id uuid, refresh_id bigint) RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT pgreact_internal.begin_refresh($1, $2) $$;
CREATE FUNCTION pgreact.refresh_rule(target_version_id uuid) RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT pgreact_internal.refresh_rule($1) $$;
CREATE FUNCTION pgreact.clear_refresh_barrier(target_version_id uuid) RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT pgreact_internal.clear_refresh_barrier($1) $$;
CREATE FUNCTION pgreact.release_refresh_lock() RETURNS boolean
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT pgreact_internal.release_refresh_lock() $$;

CREATE FUNCTION pgreact.claim_episode(target_version_id uuid, worker_id text, lease_seconds integer DEFAULT 60)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE; token uuid := gen_random_uuid();
BEGIN
    IF lease_seconds NOT BETWEEN 1 AND 3600 THEN RAISE EXCEPTION 'lease_seconds must be between 1 and 3600'; END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    IF EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers WHERE rule_version_id = target_version_id) THEN
        RAISE EXCEPTION 'pg-react claims are blocked for rule version %', target_version_id;
    END IF;
    SELECT * INTO episode FROM pgreact_internal.agenda
     WHERE rule_version_id = target_version_id AND state = 'PENDING' AND available_at <= clock_timestamp()
     ORDER BY episode_id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN RETURN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pgreact_internal.rule_versions WHERE rule_version_id = target_version_id AND state = 'ACTIVE') THEN
        RAISE EXCEPTION 'rule version % is not active', target_version_id;
    END IF;
    UPDATE pgreact_internal.agenda SET state = 'LEASED', lease_token = token, worker_id = claim_episode.worker_id,
        claimed_at = clock_timestamp(), lease_expires_at = clock_timestamp() + make_interval(secs => lease_seconds)
     WHERE agenda.episode_id = episode.episode_id;
    RETURN QUERY SELECT episode.episode_id, token, episode.activation_id, episode.new_bindings;
END $$;

CREATE FUNCTION pgreact.sweep_expired_leases(target_version_id uuid)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE recovered bigint;
BEGIN
    UPDATE pgreact_internal.agenda SET state = 'PENDING', lease_token = NULL, worker_id = NULL,
        claimed_at = NULL, lease_expires_at = NULL
     WHERE rule_version_id = target_version_id AND state = 'LEASED' AND lease_expires_at < clock_timestamp();
    GET DIAGNOSTICS recovered = ROW_COUNT;
    RETURN recovered;
END $$;

CREATE FUNCTION pgreact.requeue_episode(target_episode_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE;
BEGIN
    SELECT * INTO STRICT episode FROM pgreact_internal.agenda WHERE episode_id = target_episode_id FOR UPDATE;
    PERFORM pgreact_internal.assert_rule_owner(episode.rule_version_id);
    IF episode.state <> 'FAILED' THEN RAISE EXCEPTION 'only failed episodes can be manually requeued'; END IF;
    UPDATE pgreact_internal.agenda SET state = 'PENDING', lease_token = NULL, worker_id = NULL,
      claimed_at = NULL, lease_expires_at = NULL, available_at = clock_timestamp() WHERE episode_id = target_episode_id;
END $$;

CREATE FUNCTION pgreact.execute_claimed_episode(target_episode_id bigint, expected_worker_id text, expected_lease_token uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE; event_row pgreact_internal.lifecycle_events%ROWTYPE;
    version_row pgreact_internal.rule_versions%ROWTYPE; context pgreact.activation_context; dispatcher_call text;
    attempt integer; started timestamptz := clock_timestamp(); failure text;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);
    SELECT * INTO STRICT episode FROM pgreact_internal.agenda WHERE episode_id = target_episode_id FOR UPDATE;
    IF episode.state <> 'LEASED' OR episode.worker_id <> expected_worker_id OR episode.lease_token <> expected_lease_token
       OR episode.lease_expires_at < clock_timestamp() THEN
        RAISE EXCEPTION 'lease is no longer valid for episode %', target_episode_id;
    END IF;
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions WHERE rule_version_id = episode.rule_version_id;
    SELECT * INTO STRICT event_row FROM pgreact_internal.lifecycle_events WHERE event_id = episode.event_id;
    attempt := COALESCE((SELECT max(attempt_no) + 1 FROM pgreact_internal.executions WHERE episode_id = target_episode_id), 1);
    IF EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers WHERE rule_version_id = episode.rule_version_id)
       OR version_row.state <> 'ACTIVE'
       OR NOT EXISTS (SELECT 1 FROM pgreact_internal.activation_state WHERE rule_version_id = episode.rule_version_id
                       AND activation_id = episode.activation_id AND active AND generation = episode.activation_generation) THEN
        INSERT INTO pgreact_internal.executions (episode_id, attempt_no, worker_id, lease_token, started_at, finished_at, status, transaction_id)
        VALUES (target_episode_id, attempt, expected_worker_id, expected_lease_token, started, clock_timestamp(), 'SKIPPED', pg_current_xact_id());
        UPDATE pgreact_internal.agenda SET state = 'SKIPPED', completed_at = clock_timestamp() WHERE episode_id = target_episode_id;
        RETURN 'SKIPPED';
    END IF;
    IF pgreact_internal.source_row_signature(version_row.source_view_oid) IS DISTINCT FROM version_row.source_row_signature THEN
        RAISE EXCEPTION 'pg-react source row signature drift for rule version %; pause, drain, and replace it', episode.rule_version_id;
    END IF;
    IF version_row.consequence_oid IS NULL OR version_row.dispatcher_oid IS NULL
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = version_row.consequence_oid AND proowner = version_row.owner_oid)
       OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = version_row.dispatcher_oid AND proowner = version_row.owner_oid)
       OR sha256(convert_to(pg_get_functiondef(version_row.consequence_oid), 'UTF8')) <> version_row.consequence_digest
       OR sha256(convert_to(pg_get_functiondef(version_row.dispatcher_oid), 'UTF8')) <> version_row.dispatcher_digest THEN
        RAISE EXCEPTION 'pg-react consequence or dispatcher drift for rule version %', episode.rule_version_id;
    END IF;
    context := ROW(episode.activation_id, episode.episode_id, episode.rule_id, episode.rule_version_id,
        episode.activation_generation, 0, 'ACTIVATE', attempt, event_row.transitioned_at, expected_worker_id,
        episode.idempotency_key)::pgreact.activation_context;
    SELECT format('%I.%I', n.nspname, p.proname) INTO STRICT dispatcher_call FROM pg_catalog.pg_proc p
      JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE p.oid = version_row.dispatcher_oid;
    BEGIN
        EXECUTE format('SELECT %s($1, $2)', dispatcher_call) USING context, episode.new_bindings;
    EXCEPTION WHEN OTHERS THEN
        failure := SQLERRM;
        INSERT INTO pgreact_internal.executions (episode_id, attempt_no, worker_id, lease_token, started_at, finished_at, status, error_message, transaction_id)
        VALUES (target_episode_id, attempt, expected_worker_id, expected_lease_token, started, clock_timestamp(), 'FAILED', failure, pg_current_xact_id());
        UPDATE pgreact_internal.agenda SET state = 'FAILED', completed_at = clock_timestamp() WHERE episode_id = target_episode_id;
        RETURN 'FAILED';
    END;
    INSERT INTO pgreact_internal.executions (episode_id, attempt_no, worker_id, lease_token, started_at, finished_at, status, transaction_id)
    VALUES (target_episode_id, attempt, expected_worker_id, expected_lease_token, started, clock_timestamp(), 'COMPLETED', pg_current_xact_id());
    UPDATE pgreact_internal.agenda SET state = 'COMPLETED', completed_at = clock_timestamp() WHERE episode_id = target_episode_id
      AND lease_token = expected_lease_token AND state = 'LEASED';
    IF NOT FOUND THEN RAISE EXCEPTION 'lease lost for episode %', target_episode_id; END IF;
    RETURN 'COMPLETED';
END $$;

CREATE VIEW pgreact.rules AS
SELECT r.rule_id, r.rule_name, v.rule_version_id, pg_get_userbyid(v.owner_oid) AS owner,
       v.source_view_name, v.key_column, v.consequence_identity, v.bootstrap_policy, v.state, v.created_at
FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
WHERE v.state <> 'REMOVED';
CREATE VIEW pgreact.activations AS
SELECT rule_version_id, activation_id, semantic_key, current_bindings, active, generation, first_seen_at, last_seen_at, deactivated_at
FROM pgreact_internal.activation_state;
CREATE VIEW pgreact.episodes AS
SELECT episode_id, rule_id, rule_version_id, activation_id, activation_generation, state, worker_id, claimed_at,
       lease_expires_at, completed_at, idempotency_key FROM pgreact_internal.agenda;
CREATE VIEW pgreact.attempts AS
SELECT execution_id, episode_id, attempt_no, worker_id, started_at, finished_at, status, error_message
FROM pgreact_internal.executions;

CREATE FUNCTION pgreact.current_matches(target_rule_name text)
RETURNS TABLE(activation_id uuid, activation_key bigint, bindings jsonb, active_since timestamptz)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT a.activation_id, a.semantic_key, a.current_bindings, a.first_seen_at
 FROM pgreact.activations a JOIN pgreact.rules r USING (rule_version_id)
 WHERE r.rule_name = $1 AND a.active
$$;
CREATE FUNCTION pgreact.rule_status() RETURNS SETOF pgreact.rules
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT * FROM pgreact.rules $$;
CREATE FUNCTION pgreact.agenda_status() RETURNS SETOF pgreact.episodes
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT * FROM pgreact.episodes $$;
CREATE FUNCTION pgreact.execution_history() RETURNS SETOF pgreact.attempts
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$ SELECT * FROM pgreact.attempts $$;
CREATE FUNCTION pgreact.source_drift()
RETURNS TABLE(rule_version_id uuid, source_view_name text, status text)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT v.rule_version_id, v.source_view_name,
   CASE
     WHEN NOT EXISTS (SELECT 1 FROM pg_catalog.pg_class WHERE oid = v.source_view_oid) THEN 'INCOMPATIBLE'
     WHEN pgreact_internal.source_row_signature(v.source_view_oid) IS DISTINCT FROM v.source_row_signature THEN 'INCOMPATIBLE'
     WHEN pg_get_viewdef(v.source_view_oid, true) IS DISTINCT FROM v.source_definition THEN 'DRIFTED_COMPATIBLE'
     ELSE 'CURRENT'
   END
 FROM pgreact_internal.rule_versions v WHERE v.state <> 'REMOVED'
$$;

CREATE FUNCTION pgreact.pause_rule(target_rule_name text) RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT pgreact.pause_rule((SELECT rule_version_id FROM pgreact.rules WHERE rule_name = $1 ORDER BY created_at DESC LIMIT 1))
$$;
CREATE FUNCTION pgreact.resume_rule(target_rule_name text) RETURNS void
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT pgreact.resume_rule((SELECT rule_version_id FROM pgreact.rules WHERE rule_name = $1 ORDER BY created_at DESC LIMIT 1))
$$;

CREATE FUNCTION pgreact.claim(worker_id text, max_items integer DEFAULT 1, lease_for interval DEFAULT interval '60 seconds')
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_id uuid;
BEGIN
    IF max_items <> 1 THEN RAISE EXCEPTION 'M1 workers claim exactly one episode'; END IF;
    SELECT a.rule_version_id INTO version_id FROM pgreact_internal.agenda a
      JOIN pgreact_internal.rule_versions v USING (rule_version_id)
     WHERE a.state = 'PENDING' AND v.state = 'ACTIVE' ORDER BY a.episode_id LIMIT 1;
    IF NOT FOUND THEN RETURN; END IF;
    RETURN QUERY SELECT * FROM pgreact.claim_episode(version_id, worker_id, greatest(1, extract(epoch FROM lease_for)::integer));
END $$;

GRANT SELECT ON pgreact.rules, pgreact.activations, pgreact.episodes, pgreact.attempts TO PUBLIC;

CREATE FUNCTION pgreact.explain_rule(target_version_id uuid) RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT jsonb_build_object('rule', to_jsonb(r), 'barrier', (SELECT to_jsonb(b) FROM pgreact_internal.rule_barriers b WHERE b.rule_version_id = r.rule_version_id))
 FROM pgreact.rules r WHERE r.rule_version_id = $1
$$;
CREATE FUNCTION pgreact.explain_activation(target_version_id uuid, target_activation_id uuid) RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT jsonb_build_object('activation', to_jsonb(a), 'events', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.event_id) FROM pgreact_internal.lifecycle_events e WHERE e.rule_version_id = $1 AND e.activation_id = $2), '[]'::jsonb))
 FROM pgreact.activations a WHERE a.rule_version_id = $1 AND a.activation_id = $2
$$;
CREATE FUNCTION pgreact.explain_episode(target_episode_id bigint) RETURNS jsonb
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT jsonb_build_object('episode', to_jsonb(e), 'attempts', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.attempt_no) FROM pgreact.attempts a WHERE a.episode_id = e.episode_id), '[]'::jsonb))
 FROM pgreact.episodes e WHERE e.episode_id = $1
$$;
CREATE FUNCTION pgreact.health_check()
RETURNS TABLE(code text, severity text, object_identity text, message text, hint text)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT 'BARRIER', 'ERROR', b.rule_version_id::text, 'claims are blocked', 'Repair the reported condition and reconcile or refresh through pg-reactd.' FROM pgreact_internal.rule_barriers b
 UNION ALL SELECT 'SOURCE_DRIFT', CASE WHEN d.status = 'INCOMPATIBLE' THEN 'ERROR' ELSE 'WARNING' END,
   d.rule_version_id::text, 'source view differs from the deployed snapshot',
   CASE WHEN d.status = 'INCOMPATIBLE' THEN 'Claims are blocked; pause, drain, and replace the rule.' ELSE 'Pause, drain, and replace the rule to adopt the changed view.' END
 FROM pgreact.source_drift() d WHERE d.status <> 'CURRENT'
 UNION ALL SELECT 'CONSEQUENCE_DRIFT', 'ERROR', v.rule_version_id::text,
   'consequence or dispatcher is missing, changed, or no longer owned by the rule owner',
   'Pause, drain, and replace the rule with an exact valid consequence binding.'
 FROM pgreact_internal.rule_versions v
 LEFT JOIN pg_catalog.pg_proc c ON c.oid = v.consequence_oid
 LEFT JOIN pg_catalog.pg_proc d ON d.oid = v.dispatcher_oid
 WHERE v.state <> 'REMOVED' AND v.consequence_oid IS NOT NULL AND (
   c.oid IS NULL OR d.oid IS NULL OR c.proowner <> v.owner_oid OR d.proowner <> v.owner_oid
   OR (c.oid IS NOT NULL AND sha256(convert_to(pg_get_functiondef(c.oid), 'UTF8')) <> v.consequence_digest)
   OR (d.oid IS NOT NULL AND sha256(convert_to(pg_get_functiondef(d.oid), 'UTF8')) <> v.dispatcher_digest)
 )
 UNION ALL SELECT 'FAILED_EPISODE', 'ERROR', a.episode_id::text, 'episode requires audited manual requeue', 'Inspect it with pgreact.explain_episode, then call pgreact.requeue_episode.'
 FROM pgreact_internal.agenda a WHERE a.state = 'FAILED'
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;

-- M2 reliability beta.  This deliberately extends the M1 catalog in place:
-- the pinned coordinator-owned refresh boundary remains unchanged.
ALTER TABLE pgreact_internal.rule_versions
    ADD COLUMN change_columns name[],
    ADD COLUMN salience integer NOT NULL DEFAULT 0,
    ADD COLUMN agenda_group text NOT NULL DEFAULT 'default',
    ADD COLUMN conflict_key_columns name[];
ALTER TABLE pgreact_internal.rule_versions
    DROP CONSTRAINT rule_versions_state_check,
    ADD CONSTRAINT rule_versions_state_check CHECK (state IN (
        'INITIALIZING', 'ACTIVE', 'PAUSED', 'DRAINING', 'REMOVED', 'ERROR'
    ));

ALTER TABLE pgreact_internal.activation_state
    ADD COLUMN revision bigint NOT NULL DEFAULT 0;

ALTER TABLE pgreact_internal.lifecycle_events
    ADD COLUMN revision bigint NOT NULL DEFAULT 0;
ALTER TABLE pgreact_internal.lifecycle_events
    DROP CONSTRAINT lifecycle_events_event_kind_check,
    ADD CONSTRAINT lifecycle_events_event_kind_check
        CHECK (event_kind IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE')),
    DROP CONSTRAINT lifecycle_events_rule_version_id_activation_id_generation_e_key,
    ADD CONSTRAINT lifecycle_events_identity_key
        UNIQUE (rule_version_id, activation_id, generation, event_kind, revision);

ALTER TABLE pgreact_internal.agenda
    ALTER COLUMN new_bindings DROP NOT NULL,
    ADD COLUMN event_kind text NOT NULL DEFAULT 'ACTIVATE',
    ADD COLUMN activation_revision bigint NOT NULL DEFAULT 0,
    ADD COLUMN old_bindings jsonb,
    ADD COLUMN consequence_kind text NOT NULL DEFAULT 'DATABASE_TYPED',
    ADD COLUMN agenda_group text NOT NULL DEFAULT 'default',
    ADD COLUMN salience integer NOT NULL DEFAULT 0,
    ADD COLUMN conflict_key text,
    ADD COLUMN attempt_count integer NOT NULL DEFAULT 0,
    ADD COLUMN max_attempts integer NOT NULL DEFAULT 3,
    ADD COLUMN retry_initial_seconds integer NOT NULL DEFAULT 1,
    ADD COLUMN retry_multiplier numeric NOT NULL DEFAULT 2,
    ADD COLUMN retry_max_seconds integer NOT NULL DEFAULT 60,
    ADD COLUMN last_error jsonb;
ALTER TABLE pgreact_internal.agenda
    DROP CONSTRAINT agenda_state_check,
    ADD CONSTRAINT agenda_state_check CHECK (state IN (
        'PENDING', 'LEASED', 'RETRY_WAIT', 'COMPLETED', 'FAILED', 'SKIPPED',
        'WITHDRAWN', 'CANCELLED', 'SUPERSEDED'
    ));
CREATE INDEX agenda_m2_claim_idx ON pgreact_internal.agenda
    (state, available_at, agenda_group, salience DESC, episode_id);

ALTER TABLE pgreact_internal.executions
    DROP CONSTRAINT executions_status_check,
    ADD CONSTRAINT executions_status_check
        CHECK (status IN ('COMPLETED', 'FAILED', 'RETRY_WAIT', 'SKIPPED')),
    ADD COLUMN event_kind text NOT NULL DEFAULT 'ACTIVATE',
    ADD COLUMN error_code text;

ALTER TABLE pgreact_internal.reconciliation_audit
    DROP CONSTRAINT reconciliation_audit_mode_check,
    ADD CONSTRAINT reconciliation_audit_mode_check CHECK (mode IN ('STATE_ONLY', 'EMIT_MISSING_EVENTS')),
    DROP CONSTRAINT reconciliation_audit_events_emitted_check,
    ADD COLUMN requested_by name NOT NULL DEFAULT current_user,
    ADD COLUMN reason text NOT NULL DEFAULT 'OPERATOR';

CREATE TABLE pgreact_internal.consequence_bindings (
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    event_kind text NOT NULL CHECK (event_kind IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE')),
    consequence_kind text NOT NULL CHECK (consequence_kind IN ('DATABASE_TYPED', 'OUTBOX')),
    function_oid oid NOT NULL,
    function_digest bytea NOT NULL,
    dispatcher_oid oid,
    dispatcher_digest bytea,
    max_attempts integer NOT NULL DEFAULT 3 CHECK (max_attempts BETWEEN 1 AND 100),
    initial_backoff_seconds integer NOT NULL DEFAULT 1 CHECK (initial_backoff_seconds BETWEEN 1 AND 3600),
    backoff_multiplier numeric NOT NULL DEFAULT 2 CHECK (backoff_multiplier >= 1),
    max_backoff_seconds integer NOT NULL DEFAULT 60 CHECK (max_backoff_seconds BETWEEN 1 AND 86400),
    PRIMARY KEY (rule_version_id, event_kind)
);

CREATE TABLE pgreact_internal.conflict_leases (
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    conflict_key text NOT NULL,
    episode_id bigint NOT NULL REFERENCES pgreact_internal.agenda,
    lease_token uuid NOT NULL,
    lease_expires_at timestamptz NOT NULL,
    PRIMARY KEY (rule_version_id, conflict_key)
);

CREATE FUNCTION pgreact_internal.watched_changed(
    version_row pgreact_internal.rule_versions, previous jsonb, current jsonb
) RETURNS boolean
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE column_name name; result boolean;
BEGIN
    IF previous IS NULL THEN RETURN true; END IF;
    IF version_row.change_columns IS NULL OR cardinality(version_row.change_columns) = 0 THEN RETURN false; END IF;
    FOREACH column_name IN ARRAY version_row.change_columns LOOP
        EXECUTE format(
            'SELECT (jsonb_populate_record(NULL::%1$s, $1)).%2$I IS DISTINCT FROM '
            '(jsonb_populate_record(NULL::%1$s, $2)).%2$I',
            version_row.source_view_name, column_name
        ) USING previous, current INTO STRICT result;
        IF result THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
END $$;

CREATE FUNCTION pgreact_internal.conflict_key(columns name[], bindings jsonb)
RETURNS text LANGUAGE SQL IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT CASE WHEN cardinality($1) IS NULL OR cardinality($1) = 0 THEN NULL
                ELSE (SELECT jsonb_agg($2 -> column_name ORDER BY ordinal)::text
                      FROM unnest($1) WITH ORDINALITY AS c(column_name, ordinal)) END
$$;

CREATE FUNCTION pgreact_internal.emit_event(
    version_row pgreact_internal.rule_versions, activation uuid, generation bigint,
    revision bigint, kind text, old_value jsonb, new_value jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE event_id bigint; event_key text; binding pgreact_internal.consequence_bindings%ROWTYPE;
BEGIN
    event_key := encode(sha256(convert_to(
        version_row.rule_version_id::text || ':' || activation::text || ':' || generation || ':' || kind || ':' || revision,
        'UTF8')), 'hex');
    INSERT INTO pgreact_internal.lifecycle_events (
        rule_id, rule_version_id, activation_id, generation, revision, event_kind,
        old_bindings, new_bindings, idempotency_key
    ) VALUES (
        version_row.rule_id, version_row.rule_version_id, activation, $3, $4, $5,
        old_value, new_value, event_key
    ) ON CONFLICT ON CONSTRAINT lifecycle_events_identity_key DO NOTHING
    RETURNING lifecycle_events.event_id INTO event_id;
    IF event_id IS NULL THEN
        SELECT e.event_id INTO event_id FROM pgreact_internal.lifecycle_events e
        WHERE e.rule_version_id = version_row.rule_version_id AND e.activation_id = activation
          AND e.generation = $3 AND e.event_kind = $5 AND e.revision = $4;
        RETURN event_id;
    END IF;
    SELECT * INTO binding FROM pgreact_internal.consequence_bindings
    WHERE rule_version_id = version_row.rule_version_id AND event_kind = kind;
    IF FOUND OR (kind = 'ACTIVATE' AND version_row.consequence_oid IS NOT NULL) THEN
        INSERT INTO pgreact_internal.agenda (
            event_id, rule_id, rule_version_id, activation_id, activation_generation,
            activation_revision, event_kind, state, old_bindings, new_bindings,
            consequence_kind, agenda_group, salience, conflict_key, max_attempts,
            retry_initial_seconds, retry_multiplier, retry_max_seconds, idempotency_key
        ) VALUES (
            event_id, version_row.rule_id, version_row.rule_version_id, activation, generation,
            revision, kind, 'PENDING', old_value, new_value,
            COALESCE(binding.consequence_kind, 'DATABASE_TYPED'), version_row.agenda_group, version_row.salience,
            pgreact_internal.conflict_key(version_row.conflict_key_columns, COALESCE(new_value, old_value)),
            COALESCE(binding.max_attempts, 3), COALESCE(binding.initial_backoff_seconds, 1),
            COALESCE(binding.backoff_multiplier, 2), COALESCE(binding.max_backoff_seconds, 60), event_key
        );
    END IF;
    RETURN event_id;
END $$;

CREATE OR REPLACE FUNCTION pgreact_internal.finalize_match_delta()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    version_id uuid := TG_ARGV[0]::uuid;
    version_row pgreact_internal.rule_versions%ROWTYPE; buffered record; current_count bigint;
    final_bindings jsonb; canonical bytea; digest bytea; activation uuid;
    prior pgreact_internal.activation_state%ROWTYPE; next_generation bigint; next_revision bigint;
BEGIN
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions WHERE rule_version_id = version_id;
    FOR buffered IN DELETE FROM pgreact_internal.activation_delta_buffer
        WHERE rule_version_id = version_id AND xid = pg_catalog.pg_current_xact_id() RETURNING *
    LOOP
        EXECUTE format('SELECT count(*), min(to_jsonb(m)::text)::jsonb FROM %s m WHERE (to_jsonb(m) ->> %L)::bigint = $1',
            version_row.match_relid::regclass, version_row.key_column::text)
            INTO current_count, final_bindings USING buffered.semantic_key;
        IF current_count > 1 THEN RAISE EXCEPTION 'pg-react duplicate semantic key % in %', buffered.semantic_key, version_row.match_name; END IF;
        canonical := pgreact_internal.canonical_bigint_v1(buffered.semantic_key);
        digest := pgreact_internal.activation_digest(version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);
        SELECT * INTO prior FROM pgreact_internal.activation_state
        WHERE rule_version_id = version_id AND activation_id = activation FOR UPDATE;
        IF FOUND AND (prior.canonical_key <> canonical OR prior.canonical_key_digest <> digest) THEN
            RAISE EXCEPTION 'pg-react activation UUID collision for semantic key %', buffered.semantic_key;
        END IF;
        IF current_count = 1 AND (prior.activation_id IS NULL OR NOT prior.active) THEN
            next_generation := COALESCE(prior.generation, 0) + 1;
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key, canonical_key_digest,
                key_codec_version, active, generation, revision, current_bindings, last_active_bindings,
                first_seen_at, last_seen_at
            ) VALUES (version_id, activation, buffered.semantic_key, canonical, digest, 1, true,
                next_generation, 0, final_bindings, final_bindings, clock_timestamp(), clock_timestamp())
            ON CONFLICT (rule_version_id, activation_id) DO UPDATE SET active = true,
                generation = EXCLUDED.generation, revision = 0, current_bindings = EXCLUDED.current_bindings,
                last_active_bindings = EXCLUDED.last_active_bindings, last_seen_at = EXCLUDED.last_seen_at,
                deactivated_at = NULL;
            PERFORM pgreact_internal.emit_event(version_row, activation, next_generation, 0, 'ACTIVATE', NULL, final_bindings);
        ELSIF current_count = 1 AND prior.active THEN
            IF pgreact_internal.watched_changed(version_row, prior.current_bindings, final_bindings) THEN
                next_revision := prior.revision + 1;
                PERFORM pgreact_internal.emit_event(version_row, activation, prior.generation, next_revision,
                    'CHANGE', prior.current_bindings, final_bindings);
                UPDATE pgreact_internal.activation_state SET revision = next_revision, current_bindings = final_bindings,
                    last_active_bindings = final_bindings, last_seen_at = clock_timestamp()
                WHERE rule_version_id = version_id AND activation_id = activation;
            ELSE
                UPDATE pgreact_internal.activation_state SET current_bindings = final_bindings,
                    last_active_bindings = final_bindings, last_seen_at = clock_timestamp()
                WHERE rule_version_id = version_id AND activation_id = activation;
            END IF;
        ELSIF current_count = 0 AND prior.active THEN
            UPDATE pgreact_internal.activation_state SET active = false, current_bindings = NULL,
                deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
            WHERE rule_version_id = version_id AND activation_id = activation;
            UPDATE pgreact_internal.agenda SET state = 'WITHDRAWN', completed_at = clock_timestamp(),
                lease_token = NULL, worker_id = NULL, lease_expires_at = NULL
            WHERE rule_version_id = version_id AND activation_id = activation
              AND activation_generation = prior.generation AND event_kind = 'ACTIVATE'
              AND state IN ('PENDING', 'RETRY_WAIT');
            PERFORM pgreact_internal.emit_event(version_row, activation, prior.generation, 0,
                'DEACTIVATE', prior.last_active_bindings, NULL);
        END IF;
    END LOOP;
    RETURN NULL;
END $$;

CREATE FUNCTION pgreact_internal.assert_typed_consequence(
    version_id uuid, kind text, consequence regprocedure
) RETURNS void
LANGUAGE plpgsql STABLE SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; source_type oid; proc record; expected_args integer;
BEGIN
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions WHERE rule_version_id = version_id;
    SELECT reltype INTO STRICT source_type FROM pg_catalog.pg_class WHERE oid = version_row.source_view_oid;
    SELECT proowner, prorettype, pronargs, proargtypes INTO STRICT proc FROM pg_catalog.pg_proc WHERE oid = consequence;
    expected_args := CASE WHEN kind = 'CHANGE' THEN 3 ELSE 2 END;
    IF proc.proowner <> version_row.owner_oid OR proc.prorettype <> 'void'::regtype OR proc.pronargs <> expected_args
       OR proc.proargtypes[0] <> 'pgreact.activation_context'::regtype
       OR proc.proargtypes[1] <> source_type
       OR (kind = 'CHANGE' AND proc.proargtypes[2] <> source_type) THEN
        RAISE EXCEPTION '% consequence % must be owned by the rule owner and have the exact typed % signature',
            kind, consequence, version_row.source_view_name;
    END IF;
END $$;

CREATE FUNCTION pgreact_internal.add_typed_binding(version_id uuid, kind text, consequence regprocedure,
    max_attempts integer DEFAULT 1, initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2, max_backoff_seconds integer DEFAULT 60)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; dispatcher_name text; dispatcher_qualified text;
    consequence_qualified text; dispatcher_oid oid;
BEGIN
    IF kind NOT IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE') THEN RAISE EXCEPTION 'unsupported lifecycle event %', kind; END IF;
    PERFORM pgreact_internal.assert_typed_consequence(version_id, kind, consequence);
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions WHERE rule_version_id = version_id;
    SELECT format('%I.%I', n.nspname, p.proname) INTO STRICT consequence_qualified
      FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE p.oid = consequence;
    dispatcher_name := format('dispatch_m2_%s_%s', replace(version_id::text, '-', ''), lower(kind));
    dispatcher_qualified := format('%I.%I', 'pgreact_runtime', dispatcher_name);
    IF kind = 'CHANGE' THEN
        EXECUTE format(
            'CREATE FUNCTION %s(context pgreact.activation_context, old_bindings jsonb, new_bindings jsonb) '
            'RETURNS void LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp '
            'AS $f$ SELECT %s($1, jsonb_populate_record(NULL::%s, $2), jsonb_populate_record(NULL::%s, $3)) $f$',
            dispatcher_qualified, consequence_qualified, version_row.source_view_name, version_row.source_view_name);
    ELSE
        EXECUTE format(
            'CREATE FUNCTION %s(context pgreact.activation_context, old_bindings jsonb, new_bindings jsonb) '
            'RETURNS void LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp '
            'AS $f$ SELECT %s($1, jsonb_populate_record(NULL::%s, $%s)) $f$',
            dispatcher_qualified, consequence_qualified, version_row.source_view_name,
            CASE WHEN kind = 'ACTIVATE' THEN '3' ELSE '2' END);
    END IF;
    EXECUTE format('ALTER FUNCTION %s(pgreact.activation_context,jsonb,jsonb) OWNER TO %I', dispatcher_qualified, session_user);
    EXECUTE format('REVOKE ALL ON FUNCTION %s(pgreact.activation_context,jsonb,jsonb) FROM PUBLIC', dispatcher_qualified);
    dispatcher_oid := to_regprocedure(dispatcher_qualified || '(pgreact.activation_context,jsonb,jsonb)');
    INSERT INTO pgreact_internal.consequence_bindings (
        rule_version_id, event_kind, consequence_kind, function_oid, function_digest,
        dispatcher_oid, dispatcher_digest, max_attempts, initial_backoff_seconds,
        backoff_multiplier, max_backoff_seconds
    ) VALUES (
        version_id, kind, 'DATABASE_TYPED', consequence,
        sha256(convert_to(pg_get_functiondef(consequence), 'UTF8')), dispatcher_oid,
        sha256(convert_to(pg_get_functiondef(dispatcher_oid), 'UTF8')), max_attempts,
        initial_backoff_seconds, backoff_multiplier, max_backoff_seconds
    );
END $$;

DROP FUNCTION pgreact.create_rule(text, regclass, name[], text, regprocedure, regprocedure, regprocedure, text);
CREATE FUNCTION pgreact.create_rule(
    name text, definition regclass, key_columns name[], kind text DEFAULT NULL,
    on_activate regprocedure DEFAULT NULL, on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL, bootstrap_policy text DEFAULT 'SEED_CURRENT',
    change_columns name[] DEFAULT NULL, salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default', conflict_key_columns name[] DEFAULT NULL,
    max_attempts integer DEFAULT 1, initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2, max_backoff_seconds integer DEFAULT 60
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE diagnostic record; version_id uuid; watched name[]; source_type oid;
BEGIN
    IF kind IS NOT NULL AND kind NOT IN ('COMMAND', 'CONSTRAINT') THEN RAISE EXCEPTION 'kind must be COMMAND or CONSTRAINT'; END IF;
    IF kind = 'CONSTRAINT' AND (on_activate IS NOT NULL OR on_deactivate IS NOT NULL OR on_change IS NOT NULL) THEN
        RAISE EXCEPTION 'constraint rules cannot have consequences';
    END IF;
    IF agenda_group = '' THEN RAISE EXCEPTION 'agenda_group must not be empty'; END IF;
    IF max_attempts NOT BETWEEN 1 AND 100 OR initial_backoff_seconds NOT BETWEEN 1 AND 3600
       OR max_backoff_seconds NOT BETWEEN 1 AND 86400 OR backoff_multiplier < 1 THEN
        RAISE EXCEPTION 'invalid retry policy';
    END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
               WHERE r.rule_name = name AND v.state <> 'REMOVED') THEN
        RAISE EXCEPTION 'a non-removed rule named % already exists', name;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_rule(definition, key_columns, on_activate)
    WHERE severity = 'ERROR' LIMIT 1;
    IF FOUND THEN RAISE EXCEPTION 'pg-react validation % for %: %', diagnostic.code, diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint; END IF;
    version_id := pgreact_internal.register_reference_rule(name, definition, key_columns[1], on_activate, bootstrap_policy);
    IF change_columns IS NULL THEN
        SELECT array_agg(a.attname ORDER BY a.attnum) INTO watched
        FROM pg_catalog.pg_attribute a WHERE a.attrelid = definition AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> key_columns[1];
    ELSE
        watched := change_columns;
    END IF;
    IF on_change IS NOT NULL AND (cardinality(watched) IS NULL OR cardinality(watched) = 0) THEN
        RAISE EXCEPTION 'on_change requires at least one watched change column';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(watched) c WHERE NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_operator o
          ON o.oprname = '=' AND o.oprleft = a.atttypid AND o.oprright = a.atttypid
        WHERE a.attrelid = definition AND a.attname = c AND a.attnum > 0 AND NOT a.attisdropped
    )) THEN RAISE EXCEPTION 'watched columns must have PostgreSQL equality semantics'; END IF;
    IF EXISTS (SELECT 1 FROM unnest(COALESCE(conflict_key_columns, ARRAY[]::name[])) c WHERE NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute a WHERE a.attrelid = definition AND a.attname = c AND a.attnum > 0 AND NOT a.attisdropped
    )) THEN RAISE EXCEPTION 'conflict key columns must be projected by the source view'; END IF;
    UPDATE pgreact_internal.rule_versions SET change_columns = watched, salience = create_rule.salience,
        agenda_group = create_rule.agenda_group, conflict_key_columns = create_rule.conflict_key_columns
    WHERE rule_version_id = version_id;
    IF on_activate IS NOT NULL THEN
        PERFORM pgreact_internal.add_typed_binding(version_id, 'ACTIVATE', on_activate, max_attempts,
            initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
    END IF;
    IF on_deactivate IS NOT NULL THEN
        PERFORM pgreact_internal.add_typed_binding(version_id, 'DEACTIVATE', on_deactivate, max_attempts,
            initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
    END IF;
    IF on_change IS NOT NULL THEN
        PERFORM pgreact_internal.add_typed_binding(version_id, 'CHANGE', on_change, max_attempts,
            initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
    END IF;
    RETURN version_id;
END $$;

CREATE FUNCTION pgreact.register_outbox_sink(sink regprocedure) RETURNS regprocedure
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE p record;
BEGIN
    SELECT prorettype, pronargs, proargtypes INTO STRICT p FROM pg_catalog.pg_proc WHERE oid = sink;
    IF p.prorettype <> 'void'::regtype OR p.pronargs <> 2
       OR p.proargtypes[0] <> 'pgreact.activation_context'::regtype OR p.proargtypes[1] <> 'jsonb'::regtype THEN
        RAISE EXCEPTION 'outbox sink % must have signature (pgreact.activation_context, jsonb) RETURNS void', sink;
    END IF;
    RETURN sink;
END $$;

CREATE FUNCTION pgreact.bind_outbox_consequence(target_version_id uuid, kind text, sink regprocedure,
    max_attempts integer DEFAULT 3, initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2, max_backoff_seconds integer DEFAULT 60)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    IF kind NOT IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE') THEN RAISE EXCEPTION 'unsupported lifecycle event %', kind; END IF;
    IF EXISTS (SELECT 1 FROM pgreact_internal.consequence_bindings WHERE rule_version_id = target_version_id AND event_kind = kind) THEN
        RAISE EXCEPTION 'rule version % already has a % consequence', target_version_id, kind;
    END IF;
    PERFORM pgreact.register_outbox_sink(sink);
    INSERT INTO pgreact_internal.consequence_bindings (
        rule_version_id, event_kind, consequence_kind, function_oid, function_digest,
        max_attempts, initial_backoff_seconds, backoff_multiplier, max_backoff_seconds
    ) VALUES (target_version_id, kind, 'OUTBOX', sink, sha256(convert_to(pg_get_functiondef(sink), 'UTF8')),
        max_attempts, initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
END $$;

CREATE OR REPLACE FUNCTION pgreact.claim_episode(target_version_id uuid, worker_id text, lease_seconds integer DEFAULT 60)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE; token uuid := gen_random_uuid(); expires_at timestamptz := clock_timestamp() + make_interval(secs => lease_seconds);
BEGIN
    IF lease_seconds NOT BETWEEN 1 AND 3600 THEN RAISE EXCEPTION 'lease_seconds must be between 1 and 3600'; END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    IF EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers WHERE rule_version_id = target_version_id) THEN
        RAISE EXCEPTION 'pg-react claims are blocked for rule version %', target_version_id;
    END IF;
    SELECT a.* INTO episode FROM pgreact_internal.agenda a JOIN pgreact_internal.rule_versions v USING (rule_version_id)
    WHERE a.rule_version_id = target_version_id AND a.state IN ('PENDING', 'RETRY_WAIT') AND a.available_at <= clock_timestamp()
      AND v.state IN ('ACTIVE', 'DRAINING')
      AND (a.conflict_key IS NULL OR NOT EXISTS (SELECT 1 FROM pgreact_internal.conflict_leases l
          WHERE l.rule_version_id = a.rule_version_id AND l.conflict_key = a.conflict_key AND l.lease_expires_at > clock_timestamp()))
    ORDER BY a.salience DESC, a.available_at, a.episode_id LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN RETURN; END IF;
    IF episode.conflict_key IS NOT NULL THEN
        BEGIN
            INSERT INTO pgreact_internal.conflict_leases VALUES (episode.rule_version_id, episode.conflict_key, episode.episode_id, token, expires_at);
        EXCEPTION WHEN unique_violation THEN RETURN;
        END;
    END IF;
    UPDATE pgreact_internal.agenda SET state = 'LEASED', lease_token = token, worker_id = claim_episode.worker_id,
        claimed_at = clock_timestamp(), lease_expires_at = expires_at, attempt_count = attempt_count + 1
    WHERE agenda.episode_id = episode.episode_id;
    RETURN QUERY SELECT episode.episode_id, token, episode.activation_id, COALESCE(episode.new_bindings, episode.old_bindings);
END $$;

DROP FUNCTION pgreact.claim(text, integer, interval);
CREATE FUNCTION pgreact.claim(worker_id text, max_items integer DEFAULT 1, lease_for interval DEFAULT interval '60 seconds',
    agenda_groups text[] DEFAULT NULL)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb, event_kind text, rule_version_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE candidate record; claimed record; count_claimed integer := 0; seconds integer := extract(epoch FROM lease_for)::integer;
BEGIN
    IF max_items NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'max_items must be between 1 and 100'; END IF;
    IF seconds NOT BETWEEN 1 AND 3600 THEN RAISE EXCEPTION 'lease_for must be between 1 second and 1 hour'; END IF;
    FOR candidate IN
        SELECT a.rule_version_id FROM pgreact_internal.agenda a JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE a.state IN ('PENDING', 'RETRY_WAIT') AND a.available_at <= clock_timestamp()
          AND v.state IN ('ACTIVE', 'DRAINING')
          AND NOT EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers b WHERE b.rule_version_id = a.rule_version_id)
          AND (agenda_groups IS NULL OR a.agenda_group = ANY(agenda_groups))
        ORDER BY a.salience DESC, a.available_at, a.episode_id
    LOOP
        SELECT * INTO claimed FROM pgreact.claim_episode(candidate.rule_version_id, worker_id, seconds);
        IF FOUND THEN
            SELECT a.event_kind INTO event_kind FROM pgreact_internal.agenda a WHERE a.episode_id = claimed.episode_id;
            episode_id := claimed.episode_id; lease_token := claimed.lease_token; activation_id := claimed.activation_id;
            bindings := claimed.bindings; rule_version_id := candidate.rule_version_id;
            RETURN NEXT; count_claimed := count_claimed + 1;
            EXIT WHEN count_claimed >= max_items;
        END IF;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION pgreact.sweep_expired_leases(target_version_id uuid)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE recovered bigint;
BEGIN
    WITH expired AS (
        UPDATE pgreact_internal.agenda SET state = 'PENDING', lease_token = NULL, worker_id = NULL,
            claimed_at = NULL, lease_expires_at = NULL, available_at = clock_timestamp()
        WHERE rule_version_id = target_version_id AND state = 'LEASED' AND lease_expires_at <= clock_timestamp()
        RETURNING episode_id
    ), removed AS (
        DELETE FROM pgreact_internal.conflict_leases l USING expired e WHERE l.episode_id = e.episode_id
    ) SELECT count(*) INTO recovered FROM expired;
    RETURN recovered;
END $$;

CREATE FUNCTION pgreact.heartbeat_episode(target_episode_id bigint, expected_worker_id text,
    expected_lease_token uuid, extend_for interval DEFAULT interval '60 seconds')
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE expires_at timestamptz := clock_timestamp() + extend_for;
BEGIN
    IF extract(epoch FROM extend_for) NOT BETWEEN 1 AND 3600 THEN RAISE EXCEPTION 'extend_for must be between 1 second and 1 hour'; END IF;
    UPDATE pgreact_internal.agenda SET lease_expires_at = expires_at
    WHERE episode_id = target_episode_id AND state = 'LEASED' AND worker_id = expected_worker_id
      AND lease_token = expected_lease_token AND lease_expires_at > clock_timestamp();
    IF NOT FOUND THEN RAISE EXCEPTION 'lease is no longer valid for episode %', target_episode_id; END IF;
    UPDATE pgreact_internal.conflict_leases SET lease_expires_at = expires_at
    WHERE episode_id = target_episode_id AND lease_token = expected_lease_token;
    RETURN expires_at;
END $$;

CREATE OR REPLACE FUNCTION pgreact.requeue_episode(target_episode_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE;
BEGIN
    SELECT * INTO STRICT episode FROM pgreact_internal.agenda WHERE episode_id = target_episode_id FOR UPDATE;
    PERFORM pgreact_internal.assert_rule_owner(episode.rule_version_id);
    IF episode.state NOT IN ('FAILED', 'CANCELLED', 'WITHDRAWN') THEN RAISE EXCEPTION 'only terminal episodes can be manually requeued'; END IF;
    UPDATE pgreact_internal.agenda SET state = 'PENDING', lease_token = NULL, worker_id = NULL,
        claimed_at = NULL, lease_expires_at = NULL, available_at = clock_timestamp(), last_error = NULL
    WHERE episode_id = target_episode_id;
END $$;

CREATE FUNCTION pgreact.cancel_episode(target_episode_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE;
BEGIN
    SELECT * INTO STRICT episode FROM pgreact_internal.agenda WHERE episode_id = target_episode_id FOR UPDATE;
    PERFORM pgreact_internal.assert_rule_owner(episode.rule_version_id);
    IF episode.state NOT IN ('PENDING', 'RETRY_WAIT') THEN RAISE EXCEPTION 'only unleased episodes can be cancelled'; END IF;
    UPDATE pgreact_internal.agenda SET state = 'CANCELLED', completed_at = clock_timestamp() WHERE episode_id = target_episode_id;
END $$;

CREATE OR REPLACE FUNCTION pgreact.execute_claimed_episode(target_episode_id bigint, expected_worker_id text, expected_lease_token uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE; event_row pgreact_internal.lifecycle_events%ROWTYPE;
    version_row pgreact_internal.rule_versions%ROWTYPE; binding pgreact_internal.consequence_bindings%ROWTYPE;
    context pgreact.activation_context; attempt integer; started timestamptz := clock_timestamp();
    dispatcher_call text; sink_call text; failure text; failure_code text; retry_seconds integer; eligible boolean;
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200001);
    SELECT * INTO STRICT episode FROM pgreact_internal.agenda WHERE episode_id = target_episode_id FOR UPDATE;
    IF episode.state <> 'LEASED' OR episode.worker_id <> expected_worker_id OR episode.lease_token <> expected_lease_token
       OR episode.lease_expires_at <= clock_timestamp() THEN RAISE EXCEPTION 'lease is no longer valid for episode %', target_episode_id; END IF;
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions WHERE rule_version_id = episode.rule_version_id;
    SELECT * INTO STRICT event_row FROM pgreact_internal.lifecycle_events WHERE event_id = episode.event_id;
    SELECT * INTO binding FROM pgreact_internal.consequence_bindings WHERE rule_version_id = episode.rule_version_id AND event_kind = episode.event_kind;
    attempt := episode.attempt_count;
    eligible := NOT EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers WHERE rule_version_id = episode.rule_version_id)
        AND version_row.state IN ('ACTIVE', 'DRAINING')
        AND CASE episode.event_kind
            WHEN 'ACTIVATE' THEN EXISTS (SELECT 1 FROM pgreact_internal.activation_state s WHERE s.rule_version_id = episode.rule_version_id
                AND s.activation_id = episode.activation_id AND s.active AND s.generation = episode.activation_generation)
            WHEN 'CHANGE' THEN EXISTS (SELECT 1 FROM pgreact_internal.activation_state s WHERE s.rule_version_id = episode.rule_version_id
                AND s.activation_id = episode.activation_id AND s.active AND s.generation = episode.activation_generation
                AND s.revision = episode.activation_revision)
            ELSE NOT EXISTS (SELECT 1 FROM pgreact_internal.activation_state s WHERE s.rule_version_id = episode.rule_version_id
                AND s.activation_id = episode.activation_id AND s.active AND s.generation > episode.activation_generation)
        END;
    IF NOT eligible THEN
        INSERT INTO pgreact_internal.executions (episode_id, attempt_no, worker_id, lease_token, started_at, finished_at, status, event_kind, transaction_id)
        VALUES (target_episode_id, attempt, expected_worker_id, expected_lease_token, started, clock_timestamp(), 'SKIPPED', episode.event_kind, pg_current_xact_id());
        UPDATE pgreact_internal.agenda SET state = 'SKIPPED', completed_at = clock_timestamp() WHERE episode_id = target_episode_id;
        DELETE FROM pgreact_internal.conflict_leases WHERE episode_id = target_episode_id AND lease_token = expected_lease_token;
        RETURN 'SKIPPED';
    END IF;
    IF pgreact_internal.source_row_signature(version_row.source_view_oid) IS DISTINCT FROM version_row.source_row_signature THEN
        RAISE EXCEPTION 'pg-react source row signature drift for rule version %; pause, drain, and replace it', episode.rule_version_id;
    END IF;
    IF NOT FOUND THEN
        -- M1 rows retain their original exact activation binding.
        binding.consequence_kind := 'DATABASE_TYPED'; binding.function_oid := version_row.consequence_oid;
        binding.function_digest := version_row.consequence_digest; binding.dispatcher_oid := version_row.dispatcher_oid;
        binding.dispatcher_digest := version_row.dispatcher_digest;
    END IF;
    IF binding.function_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.function_oid)
       OR sha256(convert_to(pg_get_functiondef(binding.function_oid), 'UTF8')) <> binding.function_digest
       OR (binding.dispatcher_oid IS NOT NULL AND (NOT EXISTS (SELECT 1 FROM pg_catalog.pg_proc WHERE oid = binding.dispatcher_oid)
           OR sha256(convert_to(pg_get_functiondef(binding.dispatcher_oid), 'UTF8')) <> binding.dispatcher_digest)) THEN
        RAISE EXCEPTION 'pg-react consequence or dispatcher drift for rule version %', episode.rule_version_id;
    END IF;
    context := ROW(episode.activation_id, episode.episode_id, episode.rule_id, episode.rule_version_id,
        episode.activation_generation, episode.activation_revision, episode.event_kind, attempt,
        event_row.transitioned_at, expected_worker_id, episode.idempotency_key)::pgreact.activation_context;
    BEGIN
        IF binding.consequence_kind = 'OUTBOX' THEN
            SELECT format('%I.%I', n.nspname, p.proname) INTO STRICT sink_call FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE p.oid = binding.function_oid;
            EXECUTE format('SELECT %s($1, $2)', sink_call) USING context, jsonb_build_object(
                'version', 1, 'rule_id', episode.rule_id, 'rule_version_id', episode.rule_version_id,
                'event_kind', episode.event_kind, 'activation_id', episode.activation_id,
                'generation', episode.activation_generation, 'revision', episode.activation_revision,
                'episode_id', episode.episode_id, 'idempotency_key', episode.idempotency_key,
                'old', episode.old_bindings, 'new', episode.new_bindings);
        ELSIF binding.dispatcher_oid = version_row.dispatcher_oid THEN
            SELECT format('%I.%I', n.nspname, p.proname) INTO STRICT dispatcher_call FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE p.oid = binding.dispatcher_oid;
            EXECUTE format('SELECT %s($1, $2)', dispatcher_call) USING context, episode.new_bindings;
        ELSE
            SELECT format('%I.%I', n.nspname, p.proname) INTO STRICT dispatcher_call FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace WHERE p.oid = binding.dispatcher_oid;
            EXECUTE format('SELECT %s($1, $2, $3)', dispatcher_call) USING context, episode.old_bindings, episode.new_bindings;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS failure = MESSAGE_TEXT, failure_code = RETURNED_SQLSTATE;
        IF failure_code !~ '^(28|42)' AND attempt < episode.max_attempts THEN
            retry_seconds := LEAST(episode.retry_max_seconds,
                (episode.retry_initial_seconds * power(episode.retry_multiplier, attempt - 1))::integer);
            INSERT INTO pgreact_internal.executions (episode_id, attempt_no, worker_id, lease_token, started_at, finished_at, status, error_message, error_code, event_kind, transaction_id)
            VALUES (target_episode_id, attempt, expected_worker_id, expected_lease_token, started, clock_timestamp(), 'RETRY_WAIT', failure, failure_code, episode.event_kind, pg_current_xact_id());
            UPDATE pgreact_internal.agenda SET state = 'RETRY_WAIT', available_at = clock_timestamp() + make_interval(secs => retry_seconds),
                lease_token = NULL, worker_id = NULL, lease_expires_at = NULL,
                last_error = jsonb_build_object('code', failure_code, 'message', failure)
            WHERE episode_id = target_episode_id;
            DELETE FROM pgreact_internal.conflict_leases WHERE episode_id = target_episode_id AND lease_token = expected_lease_token;
            RETURN 'RETRY_WAIT';
        END IF;
        INSERT INTO pgreact_internal.executions (episode_id, attempt_no, worker_id, lease_token, started_at, finished_at, status, error_message, error_code, event_kind, transaction_id)
        VALUES (target_episode_id, attempt, expected_worker_id, expected_lease_token, started, clock_timestamp(), 'FAILED', failure, failure_code, episode.event_kind, pg_current_xact_id());
        UPDATE pgreact_internal.agenda SET state = 'FAILED', completed_at = clock_timestamp(),
            last_error = jsonb_build_object('code', failure_code, 'message', failure) WHERE episode_id = target_episode_id;
        DELETE FROM pgreact_internal.conflict_leases WHERE episode_id = target_episode_id AND lease_token = expected_lease_token;
        RETURN 'FAILED';
    END;
    INSERT INTO pgreact_internal.executions (episode_id, attempt_no, worker_id, lease_token, started_at, finished_at, status, event_kind, transaction_id)
    VALUES (target_episode_id, attempt, expected_worker_id, expected_lease_token, started, clock_timestamp(), 'COMPLETED', episode.event_kind, pg_current_xact_id());
    UPDATE pgreact_internal.agenda SET state = 'COMPLETED', completed_at = clock_timestamp() WHERE episode_id = target_episode_id
      AND lease_token = expected_lease_token AND state = 'LEASED';
    IF NOT FOUND THEN RAISE EXCEPTION 'lease lost for episode %', target_episode_id; END IF;
    DELETE FROM pgreact_internal.conflict_leases WHERE episode_id = target_episode_id AND lease_token = expected_lease_token;
    RETURN 'COMPLETED';
END $$;

DROP FUNCTION pgreact.replace_rule(uuid, regclass, name[], regprocedure, text);
CREATE FUNCTION pgreact.replace_rule(
    target_version_id uuid, definition regclass, key_columns name[], on_activate regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT', on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL, old_work_policy text DEFAULT 'DRAIN_OLD'
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE prior pgreact_internal.rule_versions%ROWTYPE; next_version uuid; orphan_rule uuid;
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    IF prior.state NOT IN ('ACTIVE', 'PAUSED') THEN RAISE EXCEPTION 'only active or paused versions can be replaced'; END IF;
    IF old_work_policy NOT IN ('DRAIN_OLD', 'CANCEL_OLD') THEN RAISE EXCEPTION 'old_work_policy must be DRAIN_OLD or CANCEL_OLD'; END IF;
    -- Temporarily retire the old name only while the immutable green version is compiled.
    -- It is restored to DRAINING before this transaction commits.
    UPDATE pgreact_internal.rule_versions SET state = 'REMOVED' WHERE rule_version_id = target_version_id;
    IF old_work_policy = 'CANCEL_OLD' THEN
        UPDATE pgreact_internal.agenda SET state = 'CANCELLED', completed_at = clock_timestamp()
        WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'RETRY_WAIT');
    END IF;
    next_version := pgreact.create_rule((SELECT rule_name FROM pgreact_internal.rules WHERE rule_id = prior.rule_id),
        definition, key_columns, NULL, on_activate, on_deactivate, on_change, bootstrap_policy);
    SELECT rule_id INTO orphan_rule FROM pgreact_internal.rule_versions WHERE rule_version_id = next_version;
    UPDATE pgreact_internal.rule_versions SET rule_id = prior.rule_id WHERE rule_version_id = next_version;
    DELETE FROM pgreact_internal.rules WHERE rule_id = orphan_rule;
    UPDATE pgreact_internal.rule_versions SET state = CASE WHEN EXISTS (
        SELECT 1 FROM pgreact_internal.agenda
        WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'LEASED', 'RETRY_WAIT')
    ) THEN 'DRAINING' ELSE 'REMOVED' END
    WHERE rule_version_id = target_version_id;
    RETURN next_version;
END $$;

DROP FUNCTION pgreact.reconcile_rule(uuid);
CREATE OR REPLACE FUNCTION pgreact.reconcile_rule(target_version_id uuid, emission_mode text DEFAULT 'STATE_ONLY')
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; audit_id bigint; repaired bigint := 0;
    events bigint := 0; match_row record; state_row pgreact_internal.activation_state%ROWTYPE;
    canonical bytea; digest bytea; activation uuid; present boolean;
    null_count bigint; duplicate_count bigint;
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    IF emission_mode NOT IN ('STATE_ONLY', 'EMIT_MISSING_EVENTS') THEN RAISE EXCEPTION 'emission_mode must be STATE_ONLY or EMIT_MISSING_EVENTS'; END IF;
    IF NOT EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers
                   WHERE rule_version_id = target_version_id AND reason = 'RECONCILING') THEN
        RAISE EXCEPTION 'reconciliation requires a committed claim barrier for rule version %', target_version_id
            USING HINT = 'Commit pgreact.begin_reconciliation(version), then retry reconciliation in a new transaction.';
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions WHERE rule_version_id = target_version_id;
    INSERT INTO pgreact_internal.reconciliation_audit (rule_version_id, mode, started_at, status, requested_by, reason)
    VALUES (target_version_id, emission_mode, clock_timestamp(), 'RUNNING', current_user, 'OPERATOR') RETURNING reconciliation_id INTO audit_id;
    EXECUTE format('SELECT count(*) FROM %s WHERE %I IS NULL',
                   version_row.match_relid::regclass, version_row.key_column)
        INTO null_count;
    EXECUTE format(
        'SELECT count(*) FROM (SELECT %I FROM %s GROUP BY %I HAVING count(*) > 1) d',
        version_row.key_column, version_row.match_relid::regclass, version_row.key_column
    ) INTO duplicate_count;
    IF null_count > 0 OR duplicate_count > 0 THEN
        RAISE EXCEPTION 'cannot reconcile: % null and % duplicate semantic keys', null_count, duplicate_count
            USING HINT = 'Correct the match relation, then retry while the reconciliation barrier remains in place.';
    END IF;
    FOR state_row IN SELECT * FROM pgreact_internal.activation_state WHERE rule_version_id = target_version_id FOR UPDATE LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM %s WHERE %I = $1)', version_row.match_relid::regclass, version_row.key_column)
            INTO present USING state_row.semantic_key;
        IF state_row.active AND NOT present THEN
            UPDATE pgreact_internal.activation_state SET active = false, current_bindings = NULL,
                deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp() WHERE rule_version_id = target_version_id AND activation_id = state_row.activation_id;
            IF emission_mode = 'EMIT_MISSING_EVENTS' THEN
                PERFORM pgreact_internal.emit_event(version_row, state_row.activation_id, state_row.generation, 0, 'DEACTIVATE', state_row.last_active_bindings, NULL);
                events := events + 1;
            END IF;
            repaired := repaired + 1;
        END IF;
    END LOOP;
    FOR match_row IN EXECUTE format('SELECT %I::bigint semantic_key, to_jsonb(m) bindings FROM %s m', version_row.key_column, version_row.match_relid::regclass) LOOP
        canonical := pgreact_internal.canonical_bigint_v1(match_row.semantic_key);
        digest := pgreact_internal.activation_digest(target_version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);
        SELECT * INTO state_row FROM pgreact_internal.activation_state WHERE rule_version_id = target_version_id AND activation_id = activation FOR UPDATE;
        IF NOT FOUND OR NOT state_row.active THEN
            INSERT INTO pgreact_internal.activation_state (rule_version_id, activation_id, semantic_key, canonical_key, canonical_key_digest,
                key_codec_version, active, generation, revision, current_bindings, last_active_bindings, first_seen_at, last_seen_at)
            VALUES (target_version_id, activation, match_row.semantic_key, canonical, digest, 1, true,
                COALESCE(state_row.generation, 0) + 1, 0, match_row.bindings, match_row.bindings, clock_timestamp(), clock_timestamp())
            ON CONFLICT (rule_version_id, activation_id) DO UPDATE SET active = true, generation = EXCLUDED.generation,
                revision = 0, current_bindings = EXCLUDED.current_bindings, last_active_bindings = EXCLUDED.last_active_bindings,
                deactivated_at = NULL, last_seen_at = EXCLUDED.last_seen_at;
            IF emission_mode = 'EMIT_MISSING_EVENTS' THEN
                PERFORM pgreact_internal.emit_event(version_row, activation, COALESCE(state_row.generation, 0) + 1, 0, 'ACTIVATE', NULL, match_row.bindings);
                events := events + 1;
            END IF;
            repaired := repaired + 1;
        ELSIF pgreact_internal.watched_changed(version_row, state_row.current_bindings, match_row.bindings) THEN
            UPDATE pgreact_internal.activation_state SET current_bindings = match_row.bindings, last_active_bindings = match_row.bindings,
                revision = revision + 1, last_seen_at = clock_timestamp() WHERE rule_version_id = target_version_id AND activation_id = activation;
            IF emission_mode = 'EMIT_MISSING_EVENTS' THEN
                PERFORM pgreact_internal.emit_event(version_row, activation, state_row.generation, state_row.revision + 1,
                    'CHANGE', state_row.current_bindings, match_row.bindings);
                events := events + 1;
            END IF;
            repaired := repaired + 1;
        END IF;
    END LOOP;
    DELETE FROM pgreact_internal.rule_barriers
    WHERE rule_version_id = target_version_id AND reason = 'RECONCILING';
    UPDATE pgreact_internal.reconciliation_audit SET completed_at = clock_timestamp(), rows_repaired = repaired,
        events_emitted = events, status = 'COMPLETED' WHERE reconciliation_id = audit_id;
    RETURN repaired;
END $$;

CREATE OR REPLACE VIEW pgreact.activations AS
SELECT rule_version_id, activation_id, semantic_key, current_bindings, active, generation,
       first_seen_at, last_seen_at, deactivated_at, revision FROM pgreact_internal.activation_state;
CREATE OR REPLACE VIEW pgreact.episodes AS
SELECT episode_id, rule_id, rule_version_id, activation_id, activation_generation, state, worker_id,
       claimed_at, lease_expires_at, completed_at, idempotency_key, activation_revision, event_kind,
       agenda_group, salience, conflict_key, attempt_count, max_attempts FROM pgreact_internal.agenda;
CREATE OR REPLACE VIEW pgreact.attempts AS
SELECT execution_id, episode_id, attempt_no, worker_id, started_at, finished_at, status, error_message, error_code, event_kind
FROM pgreact_internal.executions;

CREATE OR REPLACE FUNCTION pgreact.health_check()
RETURNS TABLE(code text, severity text, object_identity text, message text, hint text)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT 'BARRIER', 'ERROR', b.rule_version_id::text, 'claims are blocked', 'Repair the reported condition and reconcile or refresh through pg-reactd.' FROM pgreact_internal.rule_barriers b
 UNION ALL SELECT 'SOURCE_DRIFT', CASE WHEN d.status = 'INCOMPATIBLE' THEN 'ERROR' ELSE 'WARNING' END,
   d.rule_version_id::text, 'source view differs from the deployed snapshot',
   CASE WHEN d.status = 'INCOMPATIBLE' THEN 'Claims are blocked; pause, drain, and replace the rule.' ELSE 'Pause, drain, and replace the rule to adopt the changed view.' END
 FROM pgreact.source_drift() d WHERE d.status <> 'CURRENT'
 UNION ALL SELECT 'CONSEQUENCE_DRIFT', 'ERROR', b.rule_version_id::text,
   'consequence or dispatcher is missing, changed, or no longer owned by the rule owner',
   'Pause, drain, and replace the rule with an exact valid consequence binding.'
 FROM pgreact_internal.consequence_bindings b
 LEFT JOIN pg_catalog.pg_proc f ON f.oid = b.function_oid
 LEFT JOIN pg_catalog.pg_proc p ON p.oid = b.dispatcher_oid
 WHERE f.oid IS NULL OR sha256(convert_to(pg_get_functiondef(f.oid), 'UTF8')) <> b.function_digest
    OR (b.dispatcher_oid IS NOT NULL AND (p.oid IS NULL OR sha256(convert_to(pg_get_functiondef(p.oid), 'UTF8')) <> b.dispatcher_digest))
 UNION ALL SELECT 'FAILED_EPISODE', 'ERROR', a.episode_id::text, 'episode reached terminal failure', 'Inspect it with pgreact.explain_episode, then retry or cancel it.'
 FROM pgreact_internal.agenda a WHERE a.state = 'FAILED'
 UNION ALL SELECT 'STALE_LEASE', 'WARNING', a.episode_id::text, 'lease has expired and can be reclaimed', 'Run pgreact.sweep_expired_leases for this rule version.'
 FROM pgreact_internal.agenda a WHERE a.state = 'LEASED' AND a.lease_expires_at <= clock_timestamp()
$$;

COMMENT ON EXTENSION pg_react IS
    'M2 reliability beta: coordinated DIFFERENTIAL lifecycle, durable leases, retries, and transactional outbox sinks';

-- M3 operational release candidate.  The supported execution boundary stays
-- deliberately unchanged: PostgreSQL 18.3, pg_trickle 0.81.0, coordinator
-- owned DIFFERENTIAL refreshes under READ COMMITTED, bigint-v1 keys, and no
-- RLS sources.  These tables make the operational limits durable and visible.
CREATE TABLE pgreact_internal.operational_settings (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    max_claims integer NOT NULL DEFAULT 100 CHECK (max_claims BETWEEN 1 AND 100),
    max_lease_seconds integer NOT NULL DEFAULT 3600 CHECK (max_lease_seconds BETWEEN 1 AND 3600),
    fairness_window interval NOT NULL DEFAULT interval '30 seconds' CHECK (fairness_window >= interval '1 second'),
    max_pending_per_rule integer NOT NULL DEFAULT 10000 CHECK (max_pending_per_rule BETWEEN 1 AND 10000000),
    worker_protocol_min integer NOT NULL DEFAULT 1 CHECK (worker_protocol_min > 0),
    worker_protocol_max integer NOT NULL DEFAULT 1 CHECK (worker_protocol_max >= worker_protocol_min),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by name NOT NULL DEFAULT session_user
);
INSERT INTO pgreact_internal.operational_settings (singleton) VALUES (true);

CREATE TABLE pgreact_internal.agenda_group_limits (
    agenda_group text PRIMARY KEY,
    max_leases integer NOT NULL CHECK (max_leases BETWEEN 1 AND 10000),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_by name NOT NULL DEFAULT session_user
);

CREATE TABLE pgreact_internal.runtime_events (
    runtime_event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    severity text NOT NULL CHECK (severity IN ('INFO', 'WARNING', 'ERROR')),
    event_type text NOT NULL,
    rule_version_id uuid REFERENCES pgreact_internal.rule_versions,
    episode_id bigint REFERENCES pgreact_internal.agenda,
    worker_id text,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX runtime_events_recent_idx ON pgreact_internal.runtime_events (occurred_at DESC);

CREATE TABLE pgreact_internal.retention_audits (
    retention_audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    requested_by name NOT NULL DEFAULT session_user,
    payload_before timestamptz NOT NULL,
    lifecycle_payloads_cleared bigint NOT NULL,
    agenda_payloads_cleared bigint NOT NULL
);

CREATE TABLE pgreact_internal.metadata_rebuild_audits (
    metadata_rebuild_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at timestamptz,
    requested_by name NOT NULL DEFAULT session_user,
    rebuilt_rules bigint NOT NULL DEFAULT 0,
    blocked_rules bigint NOT NULL DEFAULT 0,
    status text NOT NULL CHECK (status IN ('RUNNING', 'COMPLETED'))
);

ALTER TABLE pgreact_internal.consequence_bindings
    ADD COLUMN function_identity text,
    ADD COLUMN dispatcher_identity text;
UPDATE pgreact_internal.consequence_bindings
SET function_identity = function_oid::regprocedure::text,
    dispatcher_identity = CASE WHEN dispatcher_oid IS NULL THEN NULL ELSE dispatcher_oid::regprocedure::text END;
ALTER TABLE pgreact_internal.consequence_bindings
    ALTER COLUMN function_identity SET NOT NULL;

CREATE FUNCTION pgreact_internal.capture_binding_identity()
RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    NEW.function_identity := COALESCE(NEW.function_identity, NEW.function_oid::regprocedure::text);
    NEW.dispatcher_identity := CASE WHEN NEW.dispatcher_oid IS NULL THEN NULL
        ELSE COALESCE(NEW.dispatcher_identity, NEW.dispatcher_oid::regprocedure::text) END;
    RETURN NEW;
END $$;
CREATE TRIGGER pgreact_capture_binding_identity
BEFORE INSERT OR UPDATE OF function_oid, dispatcher_oid ON pgreact_internal.consequence_bindings
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.capture_binding_identity();

CREATE FUNCTION pgreact_internal.is_operator_admin()
RETURNS boolean
LANGUAGE SQL STABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user)
        OR (to_regrole('pgreact_admin') IS NOT NULL
            AND pg_catalog.pg_has_role(session_user, 'pgreact_admin', 'member'))
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.assert_rule_owner(target_version_id uuid)
RETURNS pgreact_internal.rule_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    IF version_row.owner_oid <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'only the rule owner or pgreact_admin may manage rule version %', target_version_id;
    END IF;
    RETURN version_row;
END
$$;

CREATE OR REPLACE FUNCTION pgreact.begin_refresh(target_version_id uuid, refresh_id bigint)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    PERFORM pgreact_internal.begin_refresh(target_version_id, refresh_id);
END
$$;

CREATE OR REPLACE FUNCTION pgreact.refresh_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    PERFORM pgreact_internal.refresh_rule(target_version_id);
END
$$;

CREATE OR REPLACE FUNCTION pgreact.clear_refresh_barrier(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    PERFORM pgreact_internal.clear_refresh_barrier(target_version_id);
END
$$;

CREATE FUNCTION pgreact.begin_reconciliation(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    PERFORM pg_catalog.pg_advisory_lock(5788046901200000);
    INSERT INTO pgreact_internal.rule_barriers (
        rule_version_id, reason, refresh_id, created_by, created_at
    ) VALUES (
        target_version_id, 'RECONCILING', NULL, session_user, clock_timestamp()
    ) ON CONFLICT (rule_version_id) DO UPDATE SET
        reason = 'RECONCILING', refresh_id = NULL,
        created_by = session_user, created_at = clock_timestamp();
END
$$;

CREATE FUNCTION pgreact_internal.record_runtime_event(
    target_severity text, target_type text, target_version_id uuid DEFAULT NULL,
    target_episode_id bigint DEFAULT NULL, target_worker_id text DEFAULT NULL,
    target_detail jsonb DEFAULT '{}'::jsonb
) RETURNS void
LANGUAGE SQL SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    INSERT INTO pgreact_internal.runtime_events
        (severity, event_type, rule_version_id, episode_id, worker_id, detail)
    VALUES ($1, $2, $3, $4, $5, COALESCE($6, '{}'::jsonb))
$$;

CREATE FUNCTION pgreact.configure_operations(
    max_claims integer DEFAULT 100,
    max_lease_seconds integer DEFAULT 3600,
    fairness_window interval DEFAULT interval '30 seconds',
    max_pending_per_rule integer DEFAULT 10000
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'only pgreact_admin may configure operational limits';
    END IF;
    UPDATE pgreact_internal.operational_settings
    SET max_claims = $1, max_lease_seconds = $2, fairness_window = $3,
        max_pending_per_rule = $4, updated_at = clock_timestamp(), updated_by = session_user;
END
$$;

CREATE FUNCTION pgreact.configure_agenda_group(target_agenda_group text, max_leases integer)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'only pgreact_admin may configure agenda-group budgets';
    END IF;
    IF target_agenda_group = '' THEN RAISE EXCEPTION 'agenda group must not be empty'; END IF;
    INSERT INTO pgreact_internal.agenda_group_limits (agenda_group, max_leases, updated_at, updated_by)
    VALUES ($1, $2, clock_timestamp(), session_user)
    ON CONFLICT (agenda_group) DO UPDATE SET max_leases = EXCLUDED.max_leases,
        updated_at = EXCLUDED.updated_at, updated_by = EXCLUDED.updated_by;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.emit_event(
    version_row pgreact_internal.rule_versions, activation uuid, generation bigint,
    revision bigint, kind text, old_value jsonb, new_value jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE event_id bigint; event_key text; binding pgreact_internal.consequence_bindings%ROWTYPE;
    max_pending integer;
BEGIN
    event_key := encode(sha256(convert_to(
        version_row.rule_version_id::text || ':' || activation::text || ':' || generation || ':' || kind || ':' || revision,
        'UTF8')), 'hex');
    INSERT INTO pgreact_internal.lifecycle_events (
        rule_id, rule_version_id, activation_id, generation, revision, event_kind,
        old_bindings, new_bindings, idempotency_key
    ) VALUES (
        version_row.rule_id, version_row.rule_version_id, activation, $3, $4, $5,
        old_value, new_value, event_key
    ) ON CONFLICT ON CONSTRAINT lifecycle_events_identity_key DO NOTHING
    RETURNING lifecycle_events.event_id INTO event_id;
    IF event_id IS NULL THEN
        SELECT e.event_id INTO event_id FROM pgreact_internal.lifecycle_events e
        WHERE e.rule_version_id = version_row.rule_version_id AND e.activation_id = activation
          AND e.generation = $3 AND e.event_kind = $5 AND e.revision = $4;
        RETURN event_id;
    END IF;
    SELECT * INTO binding FROM pgreact_internal.consequence_bindings
    WHERE rule_version_id = version_row.rule_version_id AND event_kind = kind;
    IF FOUND OR (kind = 'ACTIVATE' AND version_row.consequence_oid IS NOT NULL) THEN
        SELECT max_pending_per_rule INTO max_pending FROM pgreact_internal.operational_settings;
        IF (SELECT count(*) FROM pgreact_internal.agenda
            WHERE rule_version_id = version_row.rule_version_id
              AND state IN ('PENDING', 'RETRY_WAIT', 'LEASED')) >= max_pending THEN
            PERFORM pgreact_internal.record_runtime_event('ERROR', 'BACKPRESSURE', version_row.rule_version_id,
                NULL, NULL, jsonb_build_object('max_pending_per_rule', max_pending));
            RAISE EXCEPTION 'pg-react backpressure for rule version %: pending-work limit % reached',
                version_row.rule_version_id, max_pending
                USING HINT = 'Drain, cancel, or raise the approved per-rule limit before refreshing again.';
        END IF;
        INSERT INTO pgreact_internal.agenda (
            event_id, rule_id, rule_version_id, activation_id, activation_generation,
            activation_revision, event_kind, state, old_bindings, new_bindings,
            consequence_kind, agenda_group, salience, conflict_key, max_attempts,
            retry_initial_seconds, retry_multiplier, retry_max_seconds, idempotency_key
        ) VALUES (
            event_id, version_row.rule_id, version_row.rule_version_id, activation, generation,
            revision, kind, 'PENDING', old_value, new_value,
            COALESCE(binding.consequence_kind, 'DATABASE_TYPED'), version_row.agenda_group, version_row.salience,
            pgreact_internal.conflict_key(version_row.conflict_key_columns, COALESCE(new_value, old_value)),
            COALESCE(binding.max_attempts, 3), COALESCE(binding.initial_backoff_seconds, 1),
            COALESCE(binding.backoff_multiplier, 2), COALESCE(binding.max_backoff_seconds, 60), event_key
        );
    END IF;
    RETURN event_id;
END $$;

CREATE OR REPLACE FUNCTION pgreact.claim_episode(target_version_id uuid, worker_id text, lease_seconds integer DEFAULT 60)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE episode pgreact_internal.agenda%ROWTYPE; token uuid := gen_random_uuid(); expires_at timestamptz;
    fairness interval; lease_limit integer; group_limit integer;
BEGIN
    SELECT fairness_window, max_lease_seconds INTO fairness, lease_limit FROM pgreact_internal.operational_settings;
    IF lease_seconds NOT BETWEEN 1 AND lease_limit THEN
        RAISE EXCEPTION 'lease_seconds must be between 1 and %', lease_limit;
    END IF;
    expires_at := clock_timestamp() + make_interval(secs => lease_seconds);
    PERFORM pg_catalog.pg_advisory_xact_lock_shared(5788046901200000);
    PERFORM pgreact.sweep_expired_leases(target_version_id);
    IF EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers WHERE rule_version_id = target_version_id) THEN
        RAISE EXCEPTION 'pg-react claims are blocked for rule version %', target_version_id;
    END IF;
    SELECT a.* INTO episode FROM pgreact_internal.agenda a JOIN pgreact_internal.rule_versions v USING (rule_version_id)
    WHERE a.rule_version_id = target_version_id AND a.state IN ('PENDING', 'RETRY_WAIT') AND a.available_at <= clock_timestamp()
      AND v.state IN ('ACTIVE', 'DRAINING')
      AND (a.conflict_key IS NULL OR NOT EXISTS (SELECT 1 FROM pgreact_internal.conflict_leases l
          WHERE l.rule_version_id = a.rule_version_id AND l.conflict_key = a.conflict_key AND l.lease_expires_at > clock_timestamp()))
    ORDER BY CASE WHEN a.available_at <= clock_timestamp() - fairness THEN 0 ELSE 1 END,
             a.available_at, a.salience DESC, a.episode_id
    LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF NOT FOUND THEN RETURN; END IF;
    SELECT max_leases INTO group_limit FROM pgreact_internal.agenda_group_limits WHERE agenda_group = episode.agenda_group;
    IF group_limit IS NOT NULL AND (SELECT count(*) FROM pgreact_internal.agenda
        WHERE agenda_group = episode.agenda_group AND state = 'LEASED' AND lease_expires_at > clock_timestamp()) >= group_limit THEN
        RETURN;
    END IF;
    IF episode.conflict_key IS NOT NULL THEN
        BEGIN
            INSERT INTO pgreact_internal.conflict_leases VALUES (episode.rule_version_id, episode.conflict_key, episode.episode_id, token, expires_at);
        EXCEPTION WHEN unique_violation THEN RETURN;
        END;
    END IF;
    UPDATE pgreact_internal.agenda SET state = 'LEASED', lease_token = token, worker_id = claim_episode.worker_id,
        claimed_at = clock_timestamp(), lease_expires_at = expires_at, attempt_count = attempt_count + 1
    WHERE agenda.episode_id = episode.episode_id;
    RETURN QUERY SELECT episode.episode_id, token, episode.activation_id, COALESCE(episode.new_bindings, episode.old_bindings);
END $$;

CREATE OR REPLACE FUNCTION pgreact.claim(worker_id text, max_items integer DEFAULT 1, lease_for interval DEFAULT interval '60 seconds',
    agenda_groups text[] DEFAULT NULL)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb, event_kind text, rule_version_id uuid)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE candidate record; claimed record; count_claimed integer := 0; seconds integer := extract(epoch FROM lease_for)::integer;
    fairness interval; claim_limit integer;
BEGIN
    SELECT fairness_window, max_claims INTO fairness, claim_limit FROM pgreact_internal.operational_settings;
    IF max_items NOT BETWEEN 1 AND claim_limit THEN RAISE EXCEPTION 'max_items must be between 1 and %', claim_limit; END IF;
    IF seconds < 1 THEN RAISE EXCEPTION 'lease_for must be at least one second'; END IF;
    FOR candidate IN
        SELECT a.rule_version_id
        FROM pgreact_internal.agenda a JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE a.state IN ('PENDING', 'RETRY_WAIT') AND a.available_at <= clock_timestamp()
          AND v.state IN ('ACTIVE', 'DRAINING')
          AND NOT EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers b WHERE b.rule_version_id = a.rule_version_id)
          AND (agenda_groups IS NULL OR a.agenda_group = ANY(agenda_groups))
        ORDER BY CASE WHEN a.available_at <= clock_timestamp() - fairness THEN 0 ELSE 1 END,
                 a.available_at, a.salience DESC, a.episode_id
    LOOP
        SELECT * INTO claimed FROM pgreact.claim_episode(candidate.rule_version_id, worker_id, seconds);
        IF FOUND THEN
            SELECT a.event_kind INTO event_kind FROM pgreact_internal.agenda a WHERE a.episode_id = claimed.episode_id;
            episode_id := claimed.episode_id; lease_token := claimed.lease_token; activation_id := claimed.activation_id;
            bindings := claimed.bindings; rule_version_id := candidate.rule_version_id;
            RETURN NEXT; count_claimed := count_claimed + 1;
            EXIT WHEN count_claimed >= max_items;
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION pgreact.prune_payloads(payload_before timestamptz)
RETURNS TABLE(lifecycle_payloads_cleared bigint, agenda_payloads_cleared bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE lifecycle_count bigint; agenda_count bigint;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'only pgreact_admin may prune payloads'; END IF;
    IF payload_before >= clock_timestamp() THEN RAISE EXCEPTION 'payload_before must be in the past'; END IF;
    WITH cleared AS (
        UPDATE pgreact_internal.lifecycle_events SET old_bindings = NULL, new_bindings = NULL
        WHERE transitioned_at < payload_before AND (old_bindings IS NOT NULL OR new_bindings IS NOT NULL)
        RETURNING 1
    ) SELECT count(*) INTO lifecycle_count FROM cleared;
    WITH cleared AS (
        UPDATE pgreact_internal.agenda SET old_bindings = NULL, new_bindings = NULL
        WHERE completed_at < payload_before AND state IN ('COMPLETED', 'FAILED', 'SKIPPED', 'WITHDRAWN', 'CANCELLED', 'SUPERSEDED')
          AND (old_bindings IS NOT NULL OR new_bindings IS NOT NULL)
        RETURNING 1
    ) SELECT count(*) INTO agenda_count FROM cleared;
    INSERT INTO pgreact_internal.retention_audits (payload_before, lifecycle_payloads_cleared, agenda_payloads_cleared)
    VALUES ($1, lifecycle_count, agenda_count);
    PERFORM pgreact_internal.record_runtime_event('INFO', 'PAYLOAD_PRUNED', NULL, NULL, NULL,
        jsonb_build_object('payload_before', payload_before, 'lifecycle_payloads_cleared', lifecycle_count,
            'agenda_payloads_cleared', agenda_count));
    RETURN QUERY SELECT lifecycle_count, agenda_count;
END $$;

CREATE FUNCTION pgreact.worker_protocol_compatible(worker_protocol integer DEFAULT 1)
RETURNS boolean LANGUAGE SQL STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
    SELECT $1 BETWEEN worker_protocol_min AND worker_protocol_max FROM pgreact_internal.operational_settings
$$;

CREATE FUNCTION pgreact.rebuild_transient_metadata()
RETURNS TABLE(rebuilt_rules bigint, blocked_rules bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; rebuild_id bigint; source_oid oid; match_oid oid;
    binding pgreact_internal.consequence_bindings%ROWTYPE; resolved_function_oid oid; resolved_dispatcher_oid oid;
    rebuilt bigint := 0; blocked bigint := 0; valid boolean;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'only pgreact_admin may rebuild transient metadata'; END IF;
    INSERT INTO pgreact_internal.metadata_rebuild_audits (status) VALUES ('RUNNING') RETURNING metadata_rebuild_id INTO rebuild_id;
    FOR version_row IN SELECT * FROM pgreact_internal.rule_versions WHERE state <> 'REMOVED' FOR UPDATE LOOP
        source_oid := to_regclass(version_row.source_view_name);
        match_oid := to_regclass(version_row.match_name);
        valid := source_oid IS NOT NULL AND match_oid IS NOT NULL
            AND pg_get_viewdef(source_oid, true) = version_row.source_definition
            AND pgreact_internal.source_row_signature(source_oid) = version_row.source_row_signature;
        FOR binding IN SELECT * FROM pgreact_internal.consequence_bindings WHERE rule_version_id = version_row.rule_version_id LOOP
            resolved_function_oid := to_regprocedure(binding.function_identity);
            resolved_dispatcher_oid := CASE WHEN binding.dispatcher_identity IS NULL THEN NULL ELSE to_regprocedure(binding.dispatcher_identity) END;
            valid := valid AND resolved_function_oid IS NOT NULL
                AND sha256(convert_to(pg_get_functiondef(resolved_function_oid), 'UTF8')) = binding.function_digest
                AND (resolved_dispatcher_oid IS NULL OR sha256(convert_to(pg_get_functiondef(resolved_dispatcher_oid), 'UTF8')) = binding.dispatcher_digest);
            IF valid THEN
                UPDATE pgreact_internal.consequence_bindings SET function_oid = resolved_function_oid, dispatcher_oid = resolved_dispatcher_oid
                WHERE rule_version_id = binding.rule_version_id AND event_kind = binding.event_kind;
            END IF;
        END LOOP;
        IF valid THEN
            UPDATE pgreact_internal.rule_versions SET source_view_oid = source_oid, match_relid = match_oid
            WHERE rule_version_id = version_row.rule_version_id;
            rebuilt := rebuilt + 1;
        ELSE
            INSERT INTO pgreact_internal.rule_barriers (rule_version_id, reason)
            VALUES (version_row.rule_version_id, 'RECONCILING')
            ON CONFLICT (rule_version_id) DO UPDATE SET reason = 'RECONCILING', created_at = clock_timestamp();
            PERFORM pgreact_internal.record_runtime_event('ERROR', 'METADATA_REBUILD_BLOCKED', version_row.rule_version_id);
            blocked := blocked + 1;
        END IF;
    END LOOP;
    UPDATE pgreact_internal.metadata_rebuild_audits SET completed_at = clock_timestamp(), rebuilt_rules = rebuilt,
        blocked_rules = blocked, status = 'COMPLETED' WHERE metadata_rebuild_id = rebuild_id;
    RETURN QUERY SELECT rebuilt, blocked;
END $$;

CREATE FUNCTION pgreact.prepare_recovery()
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE barriers bigint;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'only pgreact_admin may prepare recovery'; END IF;
    IF pg_catalog.pg_is_in_recovery() THEN RAISE EXCEPTION 'pg-react workers must not run on a physical standby'; END IF;
    INSERT INTO pgreact_internal.rule_barriers (rule_version_id, reason)
    SELECT rule_version_id, 'RECONCILING' FROM pgreact_internal.rule_versions WHERE state IN ('ACTIVE', 'DRAINING', 'PAUSED')
    ON CONFLICT (rule_version_id) DO UPDATE SET reason = 'RECONCILING', created_at = clock_timestamp();
    GET DIAGNOSTICS barriers = ROW_COUNT;
    PERFORM pgreact_internal.record_runtime_event('INFO', 'RECOVERY_PREPARED', NULL, NULL, NULL,
        jsonb_build_object('barriers', barriers));
    RETURN barriers;
END $$;

CREATE OR REPLACE FUNCTION pgreact.health_check()
RETURNS TABLE(code text, severity text, object_identity text, message text, hint text)
LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT 'BARRIER', 'ERROR', b.rule_version_id::text, 'claims are blocked', 'Repair the reported condition and reconcile or refresh through pg-reactd.' FROM pgreact_internal.rule_barriers b
 UNION ALL SELECT 'SOURCE_DRIFT', CASE WHEN d.status = 'INCOMPATIBLE' THEN 'ERROR' ELSE 'WARNING' END,
   d.rule_version_id::text, 'source view differs from the deployed snapshot',
   CASE WHEN d.status = 'INCOMPATIBLE' THEN 'Claims are blocked; pause, drain, and replace the rule.' ELSE 'Pause, drain, and replace the rule to adopt the changed view.' END
 FROM pgreact.source_drift() d WHERE d.status <> 'CURRENT'
 UNION ALL SELECT 'CONSEQUENCE_DRIFT', 'ERROR', b.rule_version_id::text,
   'consequence or dispatcher is missing, changed, or no longer exact',
   'Pause, drain, and replace the rule with an exact valid consequence binding.'
 FROM pgreact_internal.consequence_bindings b
 LEFT JOIN pg_catalog.pg_proc f ON f.oid = b.function_oid
 LEFT JOIN pg_catalog.pg_proc p ON p.oid = b.dispatcher_oid
 WHERE f.oid IS NULL OR sha256(convert_to(pg_get_functiondef(f.oid), 'UTF8')) <> b.function_digest
    OR (b.dispatcher_oid IS NOT NULL AND (p.oid IS NULL OR sha256(convert_to(pg_get_functiondef(p.oid), 'UTF8')) <> b.dispatcher_digest))
 UNION ALL SELECT 'FAILED_EPISODE', 'ERROR', a.episode_id::text, 'episode reached terminal failure', 'Inspect it with pgreact.explain_episode, then retry or cancel it.'
 FROM pgreact_internal.agenda a WHERE a.state = 'FAILED'
 UNION ALL SELECT 'STALE_LEASE', 'WARNING', a.episode_id::text, 'lease has expired and can be reclaimed', 'Run pgreact.sweep_expired_leases for this rule version.'
 FROM pgreact_internal.agenda a WHERE a.state = 'LEASED' AND a.lease_expires_at <= clock_timestamp()
 UNION ALL SELECT 'AGENDA_BACKLOG', 'WARNING', a.rule_version_id::text, 'pending work exceeds 80 percent of its configured limit',
   'Drain, cancel, or raise the approved per-rule limit before the refresh path reaches backpressure.'
 FROM pgreact_internal.agenda a CROSS JOIN pgreact_internal.operational_settings s
 WHERE a.state IN ('PENDING', 'RETRY_WAIT', 'LEASED')
 GROUP BY a.rule_version_id, s.max_pending_per_rule HAVING count(*) >= s.max_pending_per_rule * 0.8
 UNION ALL SELECT 'STANDBY', 'ERROR', 'database', 'workers cannot claim work on a physical standby',
   'Promote the database, then run prepare_recovery, rebuild_transient_metadata, reconciliation, and health_check.'
 WHERE pg_catalog.pg_is_in_recovery()
$$;

CREATE FUNCTION pgreact.metrics()
RETURNS jsonb LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
 SELECT jsonb_build_object(
   'rules_by_state', COALESCE((SELECT jsonb_object_agg(state, count) FROM (SELECT state, count(*) FROM pgreact_internal.rule_versions WHERE state <> 'REMOVED' GROUP BY state) q), '{}'::jsonb),
   'agenda_by_state', COALESCE((SELECT jsonb_object_agg(state, count) FROM (SELECT state, count(*) FROM pgreact_internal.agenda GROUP BY state) q), '{}'::jsonb),
   'oldest_eligible_age_seconds', COALESCE((SELECT extract(epoch FROM clock_timestamp() - min(available_at)) FROM pgreact_internal.agenda WHERE state IN ('PENDING', 'RETRY_WAIT') AND available_at <= clock_timestamp()), 0),
   'hot_conflict_keys', (SELECT count(*) FROM pgreact_internal.conflict_leases WHERE lease_expires_at > clock_timestamp()),
   'claim_saturation', (SELECT count(*) FROM pgreact_internal.agenda WHERE state = 'LEASED'),
   'failed_episodes', (SELECT count(*) FROM pgreact_internal.agenda WHERE state = 'FAILED'),
   'lease_expiry_count', (SELECT count(*) FROM pgreact_internal.agenda WHERE state = 'LEASED' AND lease_expires_at <= clock_timestamp())
 )
$$;

CREATE VIEW pgreact.operational_status AS
SELECT r.rule_name, v.rule_version_id, v.state, v.agenda_group,
       count(a.episode_id) FILTER (WHERE a.state IN ('PENDING', 'RETRY_WAIT', 'LEASED')) AS outstanding_episodes,
       min(a.available_at) FILTER (WHERE a.state IN ('PENDING', 'RETRY_WAIT') AND a.available_at <= clock_timestamp()) AS oldest_eligible_at,
       count(a.episode_id) FILTER (WHERE a.state = 'FAILED') AS failed_episodes,
       EXISTS (SELECT 1 FROM pgreact_internal.rule_barriers b WHERE b.rule_version_id = v.rule_version_id) AS claims_blocked
FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
LEFT JOIN pgreact_internal.agenda a USING (rule_version_id)
WHERE v.state <> 'REMOVED'
GROUP BY r.rule_name, v.rule_version_id, v.state, v.agenda_group;

REVOKE ALL ON SCHEMA pgreact FROM PUBLIC;
REVOKE ALL ON SCHEMA pgreact_runtime FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA pgreact FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'v1 GA: coordinated DIFFERENTIAL lifecycle, bounded fair agenda, recovery, audited retention, and SQL health metrics';

-- M5 safe rule-set deployment. Worker protocol and lifecycle semantics stay at v1.

CREATE TABLE pgreact_internal.rule_packs (
    pack_id uuid PRIMARY KEY,
    pack_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.rule_pack_versions (
    pack_version_id uuid PRIMARY KEY,
    pack_id uuid NOT NULL REFERENCES pgreact_internal.rule_packs,
    version text NOT NULL,
    definition jsonb NOT NULL,
    mappings jsonb NOT NULL,
    definition_digest bytea NOT NULL,
    plan_digest text NOT NULL,
    state text NOT NULL CHECK (state IN ('STAGED', 'ACTIVE', 'SUPERSEDED')),
    deployed_by name NOT NULL,
    deployed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (pack_id, version)
);

CREATE UNIQUE INDEX rule_pack_one_active_version
    ON pgreact_internal.rule_pack_versions (pack_id) WHERE state = 'ACTIVE';

CREATE TABLE pgreact_internal.rule_pack_members (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    rule_name text NOT NULL,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    dependencies text[] NOT NULL,
    PRIMARY KEY (pack_version_id, rule_name)
);

CREATE TABLE pgreact_internal.rule_pack_actions (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    action_order integer NOT NULL CHECK (action_order > 0),
    action text NOT NULL CHECK (action IN ('ADD', 'REPLACE', 'REMOVE')),
    rule_name text NOT NULL,
    old_rule_version_id uuid REFERENCES pgreact_internal.rule_versions,
    new_rule_version_id uuid REFERENCES pgreact_internal.rule_versions,
    old_work_policy text NOT NULL CHECK (old_work_policy IN ('DRAIN_OLD', 'CANCEL_OLD')),
    details jsonb NOT NULL,
    PRIMARY KEY (pack_version_id, action_order)
);

CREATE FUNCTION pgreact_internal.pack_mapping(mappings jsonb, category text, logical_identity text)
RETURNS text
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
    SELECT COALESCE($1 -> $2 ->> $3, $3)
$$;

CREATE FUNCTION pgreact.validate_pack(definition jsonb, mappings jsonb DEFAULT '{}'::jsonb)
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
#variable_conflict use_variable
DECLARE
    has_error boolean := false;
    pack_name text;
    pack_version text;
    logical_owner text;
    mapped_owner text;
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    owner_oid oid;
    pack_row record;
    active_pack_version uuid;
    unknown_key text;
    duplicate_name text;
    cycle_name text;
    rule_item record;
    rule_definition jsonb;
    rule_name text;
    logical_source text;
    mapped_source text;
    source_oid oid;
    source_type oid;
    key_name name;
    rule_kind text;
    policy text;
    diagnostic record;
    consequence record;
    logical_function text;
    mapped_function text;
    function_oid oid;
    function_row record;
    column_item jsonb;
    dependency_item jsonb;
    dependency_name text;
    dependency_order bigint;
    outbox_item record;
    removal_item record;
BEGIN
    IF pg_catalog.jsonb_typeof(definition) IS DISTINCT FROM 'object' THEN
        RETURN QUERY SELECT 1, 'PACK_NOT_OBJECT', 'ERROR', '<pack>',
            'pack definition must be a JSON object',
            'Pass one format-versioned pack object.', '{}'::jsonb;
        RETURN;
    END IF;
    IF pg_catalog.jsonb_typeof(mappings) IS DISTINCT FROM 'object'
       OR (mappings ? 'objects' AND pg_catalog.jsonb_typeof(mappings -> 'objects') <> 'object')
       OR (mappings ? 'roles' AND pg_catalog.jsonb_typeof(mappings -> 'roles') <> 'object') THEN
        RETURN QUERY SELECT 1, 'MAPPINGS_NOT_OBJECTS', 'ERROR', '<mappings>',
            'mappings must contain only objects and roles JSON objects',
            'Map logical identities to qualified names, never OIDs.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT key INTO unknown_key
    FROM pg_catalog.jsonb_object_keys(definition) AS key
    WHERE key <> ALL (ARRAY['format_version', 'pack', 'version', 'owner', 'rules', 'remove'])
    ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'pack definition contains an unknown field',
            'Remove the field or use a newer supported format_version.', '{}'::jsonb;
    END IF;
    SELECT key INTO unknown_key
    FROM pg_catalog.jsonb_object_keys(mappings) AS key
    WHERE key <> ALL (ARRAY['objects', 'roles'])
    ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'MAPPING_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'mapping definition contains an unknown field',
            'Use only objects and roles maps.', '{}'::jsonb;
    END IF;
    IF definition -> 'format_version' IS DISTINCT FROM '1'::jsonb THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_FORMAT_UNSUPPORTED', 'ERROR', '<pack>',
            'only rule-pack format_version 1 is supported',
            'Set format_version to 1.', jsonb_build_object('received', definition -> 'format_version');
    END IF;
    IF pg_catalog.jsonb_typeof(definition -> 'pack') IS DISTINCT FROM 'string'
       OR definition ->> 'pack' = ''
       OR pg_catalog.jsonb_typeof(definition -> 'version') IS DISTINCT FROM 'string'
       OR definition ->> 'version' = ''
       OR pg_catalog.jsonb_typeof(definition -> 'owner') IS DISTINCT FROM 'string'
       OR definition ->> 'owner' = '' THEN
        RETURN QUERY SELECT 1, 'PACK_IDENTITY_INVALID', 'ERROR', '<pack>',
            'pack, version, and owner must be non-empty strings',
            'Use portable logical names and map them per environment.', '{}'::jsonb;
        RETURN;
    END IF;
    IF pg_catalog.jsonb_typeof(definition -> 'rules') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'remove') IS DISTINCT FROM 'array' THEN
        RETURN QUERY SELECT 1, 'PACK_COLLECTION_INVALID', 'ERROR', '<pack>',
            'rules and remove must be JSON arrays',
            'Use an empty array when no rules are added or removed.', '{}'::jsonb;
        RETURN;
    END IF;

    pack_name := definition ->> 'pack';
    pack_version := definition ->> 'version';
    logical_owner := definition ->> 'owner';
    mapped_owner := pgreact_internal.pack_mapping(mappings, 'roles', logical_owner);
    SELECT oid INTO owner_oid FROM pg_catalog.pg_roles WHERE rolname = mapped_owner;
    IF owner_oid IS NULL OR owner_oid <> caller_oid THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_OWNER_UNSAFE', 'ERROR', logical_owner,
            'mapped pack owner must be the session user',
            'Run deployment as the mapped owner; role mapping never bypasses ownership.',
            jsonb_build_object('mapped_owner', mapped_owner, 'session_user', session_user);
    END IF;

    SELECT p.pack_id, p.owner_oid INTO pack_row
    FROM pgreact_internal.rule_packs p WHERE p.pack_name = pack_name;
    IF FOUND AND pack_row.owner_oid <> caller_oid THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'PACK_NAME_OWNED', 'ERROR', pack_name,
            'another owner already uses this pack name',
            'Choose a different pack name or deploy as its owner.', '{}'::jsonb;
    ELSIF FOUND THEN
        SELECT v.pack_version_id INTO active_pack_version
        FROM pgreact_internal.rule_pack_versions v
        WHERE v.pack_id = pack_row.pack_id AND v.state = 'ACTIVE';
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.rule_pack_versions v
            WHERE v.pack_id = pack_row.pack_id AND v.version = pack_version
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'PACK_VERSION_EXISTS', 'ERROR', pack_version,
                'pack version was already deployed',
                'Use a new immutable version string.', '{}'::jsonb;
        END IF;
    END IF;

    SELECT value ->> 'name' INTO duplicate_name
    FROM pg_catalog.jsonb_array_elements(definition -> 'rules') AS r(value)
    GROUP BY value ->> 'name' HAVING count(*) > 1
    ORDER BY value ->> 'name' LIMIT 1;
    IF duplicate_name IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'RULE_NAME_DUPLICATE', 'ERROR', duplicate_name,
            'rule names must be unique within a pack version',
            'Keep one complete definition for each rule name.', '{}'::jsonb;
    END IF;
    SELECT value ->> 'name' INTO duplicate_name
    FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    GROUP BY value ->> 'name' HAVING count(*) > 1
    ORDER BY value ->> 'name' LIMIT 1;
    IF duplicate_name IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'REMOVAL_DUPLICATE', 'ERROR', duplicate_name,
            'removal names must be unique within a pack version',
            'Keep one explicit removal policy for each rule.', '{}'::jsonb;
    END IF;

    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, ordinal)
    LOOP
        rule_definition := rule_item.value;
        IF pg_catalog.jsonb_typeof(rule_definition) IS DISTINCT FROM 'object' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_NOT_OBJECT', 'ERROR', rule_item.ordinal::text,
                'each rule must be a JSON object', 'Replace the array item with a rule object.', '{}'::jsonb;
            CONTINUE;
        END IF;
        rule_name := rule_definition ->> 'name';
        SELECT key INTO unknown_key
        FROM pg_catalog.jsonb_object_keys(rule_definition) AS key
        WHERE key <> ALL (ARRAY[
            'name', 'definition', 'key', 'kind', 'on_activate', 'on_deactivate',
            'on_change', 'outbox', 'bootstrap_policy', 'change_columns', 'salience',
            'agenda_group', 'conflict_key_columns', 'max_attempts',
            'initial_backoff_seconds', 'backoff_multiplier', 'max_backoff_seconds',
            'old_work_policy', 'depends_on'
        ]) ORDER BY key LIMIT 1;
        IF unknown_key IS NOT NULL THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_FIELD_UNKNOWN', 'ERROR', COALESCE(rule_name, rule_item.ordinal::text),
                'rule definition contains an unknown field',
                'Remove the field or use a newer supported format_version.',
                jsonb_build_object('field', unknown_key);
        END IF;
        IF pg_catalog.jsonb_typeof(rule_definition -> 'name') IS DISTINCT FROM 'string'
           OR rule_name = ''
           OR pg_catalog.jsonb_typeof(rule_definition -> 'definition') IS DISTINCT FROM 'string'
           OR pg_catalog.jsonb_typeof(rule_definition -> 'key') IS DISTINCT FROM 'string'
           OR pg_catalog.jsonb_typeof(rule_definition -> 'kind') IS DISTINCT FROM 'string' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_IDENTITY_INVALID', 'ERROR', COALESCE(rule_name, rule_item.ordinal::text),
                'name, definition, key, and kind must be non-empty strings',
                'Use logical object identities; mappings resolve environment names.', '{}'::jsonb;
            CONTINUE;
        END IF;
        IF EXISTS (
            SELECT 1 FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS x(value)
            WHERE x.value ->> 'name' = rule_name
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_AND_REMOVAL_CONFLICT', 'ERROR', rule_name,
                'a rule cannot be deployed and removed in the same pack version',
                'Keep it in exactly one collection.', '{}'::jsonb;
        END IF;
        rule_kind := rule_definition ->> 'kind';
        IF rule_kind NOT IN ('COMMAND', 'CONSTRAINT') THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_KIND_INVALID', 'ERROR', rule_name,
                'kind must be COMMAND or CONSTRAINT', 'Use an existing v1 rule kind.', '{}'::jsonb;
        END IF;
        policy := COALESCE(rule_definition ->> 'old_work_policy', 'DRAIN_OLD');
        IF policy NOT IN ('DRAIN_OLD', 'CANCEL_OLD') THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'OLD_WORK_POLICY_INVALID', 'ERROR', rule_name,
                'old_work_policy must be DRAIN_OLD or CANCEL_OLD',
                'Choose how pending and retrying work from the prior immutable version is handled.', '{}'::jsonb;
        END IF;
        IF rule_definition ? 'depends_on'
           AND pg_catalog.jsonb_typeof(rule_definition -> 'depends_on') <> 'array' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'DEPENDENCIES_NOT_ARRAY', 'ERROR', rule_name,
                'depends_on must be an array of earlier rule names',
                'Use deployment-order dependencies only.', '{}'::jsonb;
        ELSE
            FOR dependency_item IN
                SELECT value FROM pg_catalog.jsonb_array_elements(COALESCE(rule_definition -> 'depends_on', '[]'::jsonb)) AS d(value)
            LOOP
                IF pg_catalog.jsonb_typeof(dependency_item) <> 'string' THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'DEPENDENCY_INVALID', 'ERROR', rule_name,
                        'dependencies must be rule-name strings',
                        'Reference a rule in the same pack version.', jsonb_build_object('dependency', dependency_item);
                    CONTINUE;
                END IF;
                dependency_name := dependency_item #>> '{}';
                SELECT ordinal INTO dependency_order
                FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
                WITH ORDINALITY AS d(value, ordinal)
                WHERE d.value ->> 'name' = dependency_name;
                IF dependency_order IS NULL THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'DEPENDENCY_MISSING', 'ERROR', rule_name,
                        'dependency is not defined in this pack version',
                        'Add the dependency before this rule.', jsonb_build_object('dependency', dependency_name);
                ELSIF dependency_order >= rule_item.ordinal THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'DEPENDENCY_ORDER_INVALID', 'ERROR', rule_name,
                        'dependency must appear before the dependent rule',
                        'Order rules topologically in the manifest.', jsonb_build_object('dependency', dependency_name);
                END IF;
            END LOOP;
        END IF;

        logical_source := rule_definition ->> 'definition';
        mapped_source := pgreact_internal.pack_mapping(mappings, 'objects', logical_source);
        source_oid := pg_catalog.to_regclass(mapped_source);
        IF source_oid IS NULL THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'SOURCE_NOT_FOUND', 'ERROR', logical_source,
                'mapped source view does not exist',
                'Create it in this environment or correct the object mapping.',
                jsonb_build_object('mapped_identity', mapped_source);
            CONTINUE;
        END IF;
        SELECT reltype INTO source_type FROM pg_catalog.pg_class WHERE oid = source_oid;
        key_name := (rule_definition ->> 'key')::name;
        IF EXISTS (SELECT 1 FROM pgreact.validate_rule(source_oid::regclass, ARRAY[key_name], NULL)
                   WHERE severity = 'ERROR') THEN
            has_error := true;
            FOR diagnostic IN
                SELECT * FROM pgreact.validate_rule(source_oid::regclass, ARRAY[key_name], NULL)
                WHERE severity = 'ERROR'
            LOOP
                RETURN QUERY SELECT 1, diagnostic.code, diagnostic.severity, rule_name,
                    diagnostic.message, diagnostic.hint,
                    diagnostic.details || jsonb_build_object('source', logical_source, 'mapped_source', mapped_source);
            END LOOP;
        END IF;

        IF rule_definition ? 'change_columns'
           AND pg_catalog.jsonb_typeof(rule_definition -> 'change_columns') <> 'array'
           OR rule_definition ? 'conflict_key_columns'
           AND pg_catalog.jsonb_typeof(rule_definition -> 'conflict_key_columns') <> 'array' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'COLUMN_LIST_INVALID', 'ERROR', rule_name,
                'change_columns and conflict_key_columns must be arrays',
                'Use projected column-name strings.', '{}'::jsonb;
        ELSE
            FOR column_item IN
                SELECT value FROM pg_catalog.jsonb_array_elements(
                    COALESCE(rule_definition -> 'change_columns', '[]'::jsonb) ||
                    COALESCE(rule_definition -> 'conflict_key_columns', '[]'::jsonb)
                ) AS c(value)
            LOOP
                IF pg_catalog.jsonb_typeof(column_item) <> 'string'
                   OR NOT EXISTS (
                       SELECT 1 FROM pg_catalog.pg_attribute
                       WHERE attrelid = source_oid AND attname = (column_item #>> '{}')::name
                         AND attnum > 0 AND NOT attisdropped
                   ) THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'COLUMN_NOT_PROJECTED', 'ERROR', rule_name,
                        'policy column must be a projected source-view column',
                        'Correct the column name or source view.', jsonb_build_object('column', column_item);
                END IF;
            END LOOP;
        END IF;

        IF rule_definition ? 'outbox' AND pg_catalog.jsonb_typeof(rule_definition -> 'outbox') <> 'object' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'OUTBOX_INVALID', 'ERROR', rule_name,
                'outbox must be an object keyed by lifecycle event',
                'Use ACTIVATE, CHANGE, or DEACTIVATE sink identities.', '{}'::jsonb;
        END IF;
        IF rule_kind = 'CONSTRAINT' AND (
            rule_definition ->> 'on_activate' IS NOT NULL
            OR rule_definition ->> 'on_deactivate' IS NOT NULL
            OR rule_definition ->> 'on_change' IS NOT NULL
            OR COALESCE(rule_definition -> 'outbox', '{}'::jsonb) <> '{}'::jsonb
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'CONSTRAINT_HAS_CONSEQUENCE', 'ERROR', rule_name,
                'constraint rules cannot have consequences',
                'Remove typed and outbox bindings or use kind COMMAND.', '{}'::jsonb;
        END IF;

        FOR consequence IN
            SELECT * FROM (VALUES
                ('ACTIVATE', rule_definition ->> 'on_activate', 2),
                ('DEACTIVATE', rule_definition ->> 'on_deactivate', 2),
                ('CHANGE', rule_definition ->> 'on_change', 3)
            ) AS c(event_kind, identity, expected_args)
            WHERE identity IS NOT NULL
        LOOP
            logical_function := consequence.identity;
            mapped_function := pgreact_internal.pack_mapping(mappings, 'objects', logical_function);
            function_oid := pg_catalog.to_regprocedure(mapped_function);
            IF function_oid IS NULL THEN
                has_error := true;
                RETURN QUERY SELECT 1, 'CONSEQUENCE_NOT_FOUND', 'ERROR', logical_function,
                    'mapped typed consequence does not exist',
                    'Create it in this environment or correct the object mapping.',
                    jsonb_build_object('mapped_identity', mapped_function, 'rule', rule_name);
                CONTINUE;
            END IF;
            SELECT proowner, prorettype, pronargs, proargtypes INTO function_row
            FROM pg_catalog.pg_proc WHERE oid = function_oid;
            IF function_row.proowner <> caller_oid OR function_row.prorettype <> 'void'::regtype
               OR function_row.pronargs <> consequence.expected_args
               OR function_row.proargtypes[0] <> 'pgreact.activation_context'::regtype
               OR function_row.proargtypes[1] <> source_type
               OR (consequence.event_kind = 'CHANGE' AND function_row.proargtypes[2] <> source_type) THEN
                has_error := true;
                RETURN QUERY SELECT 1, 'CONSEQUENCE_SIGNATURE', 'ERROR', logical_function,
                    'typed consequence is not owned by the pack owner or has the wrong exact signature',
                    'Use the mapped source row type and return void.',
                    jsonb_build_object('mapped_identity', mapped_function, 'rule', rule_name, 'event_kind', consequence.event_kind);
            END IF;
        END LOOP;

        IF pg_catalog.jsonb_typeof(COALESCE(rule_definition -> 'outbox', '{}'::jsonb)) = 'object' THEN
            FOR outbox_item IN
                SELECT key AS event_kind, value #>> '{}' AS identity
                FROM pg_catalog.jsonb_each(COALESCE(rule_definition -> 'outbox', '{}'::jsonb))
            LOOP
                IF outbox_item.event_kind NOT IN ('ACTIVATE', 'CHANGE', 'DEACTIVATE') THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'OUTBOX_EVENT_INVALID', 'ERROR', rule_name,
                        'outbox event must be ACTIVATE, CHANGE, or DEACTIVATE',
                        'Use a supported lifecycle event.', jsonb_build_object('event_kind', outbox_item.event_kind);
                    CONTINUE;
                END IF;
                IF rule_definition ->> ('on_' || lower(outbox_item.event_kind)) IS NOT NULL THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'CONSEQUENCE_DUPLICATE', 'ERROR', rule_name,
                        'one event cannot have both typed and outbox consequences',
                        'Choose exactly one binding kind.', jsonb_build_object('event_kind', outbox_item.event_kind);
                    CONTINUE;
                END IF;
                logical_function := outbox_item.identity;
                mapped_function := pgreact_internal.pack_mapping(mappings, 'objects', logical_function);
                function_oid := pg_catalog.to_regprocedure(mapped_function);
                SELECT proowner, prorettype, pronargs, proargtypes INTO function_row
                FROM pg_catalog.pg_proc WHERE oid = function_oid;
                IF function_oid IS NULL OR function_row.proowner <> caller_oid
                   OR function_row.prorettype <> 'void'::regtype OR function_row.pronargs <> 2
                   OR function_row.proargtypes[0] <> 'pgreact.activation_context'::regtype
                   OR function_row.proargtypes[1] <> 'jsonb'::regtype THEN
                    has_error := true;
                    RETURN QUERY SELECT 1, 'OUTBOX_SIGNATURE', 'ERROR', logical_function,
                        'outbox sink must be owned by the pack owner and accept (pgreact.activation_context, jsonb)',
                        'Create the exact mapped sink before deployment.',
                        jsonb_build_object('mapped_identity', mapped_function, 'rule', rule_name);
                END IF;
            END LOOP;
        END IF;

        IF rule_definition ? 'salience' AND pg_catalog.jsonb_typeof(rule_definition -> 'salience') <> 'number'
           OR rule_definition ? 'max_attempts' AND pg_catalog.jsonb_typeof(rule_definition -> 'max_attempts') <> 'number'
           OR rule_definition ? 'initial_backoff_seconds' AND pg_catalog.jsonb_typeof(rule_definition -> 'initial_backoff_seconds') <> 'number'
           OR rule_definition ? 'backoff_multiplier' AND pg_catalog.jsonb_typeof(rule_definition -> 'backoff_multiplier') <> 'number'
           OR rule_definition ? 'max_backoff_seconds' AND pg_catalog.jsonb_typeof(rule_definition -> 'max_backoff_seconds') <> 'number'
           OR rule_definition ? 'agenda_group' AND pg_catalog.jsonb_typeof(rule_definition -> 'agenda_group') <> 'string'
           OR rule_definition ? 'bootstrap_policy' AND pg_catalog.jsonb_typeof(rule_definition -> 'bootstrap_policy') <> 'string' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_OPTION_TYPE', 'ERROR', rule_name,
                'rule options have invalid JSON types',
                'Use numbers for numeric policies and strings for named policies.', '{}'::jsonb;
        ELSIF COALESCE(rule_definition ->> 'bootstrap_policy', 'SEED_CURRENT') NOT IN ('SEED_CURRENT', 'REQUIRE_EMPTY')
           OR COALESCE(rule_definition ->> 'agenda_group', 'default') = ''
           OR COALESCE((rule_definition ->> 'salience')::numeric, 0) NOT BETWEEN -2147483648 AND 2147483647
           OR COALESCE((rule_definition ->> 'salience')::numeric, 0) <> trunc(COALESCE((rule_definition ->> 'salience')::numeric, 0))
           OR COALESCE((rule_definition ->> 'max_attempts')::numeric, 1) NOT BETWEEN 1 AND 100
           OR COALESCE((rule_definition ->> 'max_attempts')::numeric, 1) <> trunc(COALESCE((rule_definition ->> 'max_attempts')::numeric, 1))
           OR COALESCE((rule_definition ->> 'initial_backoff_seconds')::numeric, 1) NOT BETWEEN 1 AND 3600
           OR COALESCE((rule_definition ->> 'initial_backoff_seconds')::numeric, 1) <> trunc(COALESCE((rule_definition ->> 'initial_backoff_seconds')::numeric, 1))
           OR COALESCE((rule_definition ->> 'max_backoff_seconds')::numeric, 60) NOT BETWEEN 1 AND 86400
           OR COALESCE((rule_definition ->> 'max_backoff_seconds')::numeric, 60) <> trunc(COALESCE((rule_definition ->> 'max_backoff_seconds')::numeric, 60))
           OR COALESCE((rule_definition ->> 'backoff_multiplier')::numeric, 2) < 1 THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_OPTION_INVALID', 'ERROR', rule_name,
                'rule options are outside the supported v1 policy bounds',
                'Use an existing bootstrap policy, a non-empty agenda group, and bounded retry values.', '{}'::jsonb;
        END IF;

        SELECT v.owner_oid, v.state INTO function_row
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_name AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        IF FOUND AND (function_row.owner_oid <> caller_oid OR function_row.state NOT IN ('ACTIVE', 'PAUSED')) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'RULE_NOT_REPLACEABLE', 'ERROR', rule_name,
                'current rule is not owned by this pack owner or is still draining',
                'Finish old work before deploying this rule name.', jsonb_build_object('state', function_row.state);
        END IF;
    END LOOP;

    WITH RECURSIVE edges AS (
        SELECT r.value ->> 'name' AS rule_name, d.value #>> '{}' AS dependency
        FROM pg_catalog.jsonb_array_elements(definition -> 'rules') AS r(value)
        CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(
            CASE WHEN pg_catalog.jsonb_typeof(r.value -> 'depends_on') = 'array'
                 THEN r.value -> 'depends_on' ELSE '[]'::jsonb END
        ) AS d(value)
        WHERE pg_catalog.jsonb_typeof(d.value) = 'string'
    ), walk(origin, node, path, cycle) AS (
        SELECT e.rule_name, e.dependency, ARRAY[e.rule_name, e.dependency], e.rule_name = e.dependency
        FROM edges e
        UNION ALL
        SELECT w.origin, e.dependency, w.path || e.dependency, e.dependency = ANY(w.path)
        FROM walk w JOIN edges e ON e.rule_name = w.node
        WHERE NOT w.cycle
    )
    SELECT origin INTO cycle_name FROM walk WHERE cycle ORDER BY origin LIMIT 1;
    IF cycle_name IS NOT NULL THEN
        has_error := true;
        RETURN QUERY SELECT 1, 'DEPENDENCY_CYCLE', 'ERROR', cycle_name,
            'pack dependency graph contains a cycle',
            'Remove the cycle and order dependencies before dependents.', '{}'::jsonb;
    END IF;

    IF active_pack_version IS NOT NULL THEN
        FOR rule_name IN
            SELECT m.rule_name FROM pgreact_internal.rule_pack_members m
            WHERE m.pack_version_id = active_pack_version
            ORDER BY m.rule_name
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_catalog.jsonb_array_elements(definition -> 'rules') AS x(value)
                WHERE x.value ->> 'name' = rule_name
            ) AND NOT EXISTS (
                SELECT 1 FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS x(value)
                WHERE x.value ->> 'name' = rule_name
            ) THEN
                has_error := true;
                RETURN QUERY SELECT 1, 'REMOVAL_NOT_EXPLICIT', 'ERROR', rule_name,
                    'a current pack member is absent without an explicit removal',
                    'Add it to remove with an old_work_policy.', '{}'::jsonb;
            END IF;
        END LOOP;
    END IF;

    FOR removal_item IN
        SELECT value FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    LOOP
        IF pg_catalog.jsonb_typeof(removal_item.value) IS DISTINCT FROM 'object'
           OR pg_catalog.jsonb_typeof(removal_item.value -> 'name') IS DISTINCT FROM 'string' THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'REMOVAL_INVALID', 'ERROR', '<removal>',
                'each removal must contain a rule-name string',
                'Use {"name": "...", "old_work_policy": "DRAIN_OLD"}.', '{}'::jsonb;
            CONTINUE;
        END IF;
        rule_name := removal_item.value ->> 'name';
        policy := COALESCE(removal_item.value ->> 'old_work_policy', 'DRAIN_OLD');
        IF policy NOT IN ('DRAIN_OLD', 'CANCEL_OLD') THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'OLD_WORK_POLICY_INVALID', 'ERROR', rule_name,
                'old_work_policy must be DRAIN_OLD or CANCEL_OLD',
                'Choose how pending and retrying work is handled.', '{}'::jsonb;
        END IF;
        IF active_pack_version IS NULL OR NOT EXISTS (
            SELECT 1 FROM pgreact_internal.rule_pack_members m
            WHERE m.pack_version_id = active_pack_version AND m.rule_name = rule_name
        ) THEN
            has_error := true;
            RETURN QUERY SELECT 1, 'REMOVAL_UNKNOWN', 'ERROR', rule_name,
                'only a current member of this pack can be removed',
                'Remove the entry or deploy the rule through this pack first.', '{}'::jsonb;
        END IF;
    END LOOP;

    IF NOT has_error THEN
        RETURN QUERY SELECT 1, 'OK', 'INFO', pack_name,
            'rule pack is valid for this environment',
            'Preview the atomic plan before deployment.',
            jsonb_build_object('version', pack_version, 'mapped_owner', mapped_owner,
                               'rule_count', jsonb_array_length(definition -> 'rules'),
                               'removal_count', jsonb_array_length(definition -> 'remove'));
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.pack_plan_digest(definition jsonb, mappings jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    material text := definition::text || E'\n' || mappings::text || E'\nowner:' || session_user;
    rule_item record;
    rule_name text;
    logical_identity text;
    mapped_identity text;
    object_oid oid;
    object_owner oid;
    current_version uuid;
    current_state text;
    current_match text;
    work_state jsonb;
    consequence record;
    active_pack_version uuid;
BEGIN
    SELECT v.pack_version_id INTO active_pack_version
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = definition ->> 'pack'
      AND p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND v.state = 'ACTIVE';
    material := material || E'\nactive_pack:' || COALESCE(active_pack_version::text, '<none>');
    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, ordinal)
    LOOP
        rule_name := rule_item.value ->> 'name';
        logical_identity := rule_item.value ->> 'definition';
        mapped_identity := pgreact_internal.pack_mapping(mappings, 'objects', logical_identity);
        object_oid := pg_catalog.to_regclass(mapped_identity);
        SELECT relowner INTO object_owner FROM pg_catalog.pg_class WHERE oid = object_oid;
        SELECT v.rule_version_id, v.state, v.match_name
          INTO current_version, current_state, current_match
        FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_name AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_version GROUP BY state) AS q;
        material := material || format(E'\nrule:%s:%s:%s:%s:%s:%s:%s:%s',
            rule_item.ordinal, rule_name, object_oid, object_owner,
            encode(sha256(convert_to(pg_get_viewdef(object_oid, true), 'UTF8')), 'hex'),
            encode(pgreact_internal.source_row_signature(object_oid), 'hex'),
            COALESCE(current_version::text || ':' || current_state || ':' || current_match, '<add>'),
            work_state::text);
        FOR consequence IN
            SELECT identity FROM (VALUES
                (rule_item.value ->> 'on_activate'),
                (rule_item.value ->> 'on_deactivate'),
                (rule_item.value ->> 'on_change')
            ) AS typed(identity) WHERE identity IS NOT NULL
            UNION ALL
            SELECT value #>> '{}' FROM pg_catalog.jsonb_each(COALESCE(rule_item.value -> 'outbox', '{}'::jsonb))
        LOOP
            mapped_identity := pgreact_internal.pack_mapping(mappings, 'objects', consequence.identity);
            object_oid := pg_catalog.to_regprocedure(mapped_identity);
            SELECT proowner INTO object_owner FROM pg_catalog.pg_proc WHERE oid = object_oid;
            material := material || format(E'\nfunction:%s:%s:%s:%s', consequence.identity,
                object_oid, object_owner,
                encode(sha256(convert_to(pg_get_functiondef(object_oid), 'UTF8')), 'hex'));
        END LOOP;
    END LOOP;
    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'remove')
        WITH ORDINALITY AS r(value, ordinal)
    LOOP
        rule_name := rule_item.value ->> 'name';
        SELECT m.rule_version_id, v.state, v.match_name
          INTO current_version, current_state, current_match
        FROM pgreact_internal.rule_packs p
        JOIN pgreact_internal.rule_pack_versions pv USING (pack_id)
        JOIN pgreact_internal.rule_pack_members m USING (pack_version_id)
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE p.pack_name = definition ->> 'pack' AND pv.state = 'ACTIVE' AND m.rule_name = rule_name;
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_version GROUP BY state) AS q;
        material := material || format(E'\nremove:%s:%s:%s:%s:%s:%s', rule_item.ordinal,
            rule_name, current_version, current_state, current_match, work_state::text);
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
$$;

CREATE FUNCTION pgreact.preview_pack(definition jsonb, mappings jsonb DEFAULT '{}'::jsonb)
RETURNS TABLE(
    plan_digest text,
    action_order integer,
    action text,
    rule_name text,
    dependencies text[],
    generated_object_changes jsonb,
    lifecycle_risks jsonb,
    details jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    diagnostic record;
    rule_item record;
    current_row record;
    dependency_names text[];
    work_state jsonb;
    digest text;
    ordinal integer := 0;
BEGIN
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    digest := pgreact_internal.pack_plan_digest(definition, mappings);
    FOR rule_item IN
        SELECT value, array_ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, array_ordinal)
    LOOP
        ordinal := ordinal + 1;
        SELECT v.rule_version_id, v.state, v.match_name INTO current_row
        FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT array_agg(value #>> '{}' ORDER BY dependency_ordinal)::text[] INTO dependency_names
        FROM pg_catalog.jsonb_array_elements(COALESCE(rule_item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY AS d(value, dependency_ordinal);
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_row.rule_version_id GROUP BY state) AS q;
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_row.rule_version_id IS NULL THEN 'ADD' ELSE 'REPLACE' END;
        rule_name := rule_item.value ->> 'name';
        dependencies := COALESCE(dependency_names, ARRAY[]::text[]);
        generated_object_changes := jsonb_build_object(
            'create', jsonb_build_array('match_relation', 'lifecycle_triggers') ||
                CASE WHEN rule_item.value ->> 'on_activate' IS NOT NULL
                       OR rule_item.value ->> 'on_deactivate' IS NOT NULL
                       OR rule_item.value ->> 'on_change' IS NOT NULL
                     THEN jsonb_build_array('typed_dispatchers') ELSE '[]'::jsonb END,
            'retire', CASE WHEN current_row.rule_version_id IS NULL THEN '[]'::jsonb
                           ELSE jsonb_build_array(current_row.match_name) END
        );
        lifecycle_risks := CASE WHEN current_row.rule_version_id IS NULL
            THEN jsonb_build_array(COALESCE(rule_item.value ->> 'bootstrap_policy', 'SEED_CURRENT') || ' may seed current matches')
            ELSE jsonb_build_array(COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD') ||
                                   ' applies to prior pending, retrying, and leased work') END;
        details := jsonb_build_object(
            'source', rule_item.value ->> 'definition',
            'mapped_source', pgreact_internal.pack_mapping(mappings, 'objects', rule_item.value ->> 'definition'),
            'prior_rule_version_id', current_row.rule_version_id,
            'prior_state', current_row.state,
            'prior_work', work_state
        );
        RETURN NEXT;
    END LOOP;
    FOR rule_item IN
        SELECT value FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    LOOP
        ordinal := ordinal + 1;
        SELECT m.rule_version_id, v.state, v.match_name INTO current_row
        FROM pgreact_internal.rule_packs p
        JOIN pgreact_internal.rule_pack_versions pv USING (pack_id)
        JOIN pgreact_internal.rule_pack_members m USING (pack_version_id)
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE p.pack_name = definition ->> 'pack' AND pv.state = 'ACTIVE'
          AND m.rule_name = rule_item.value ->> 'name';
        SELECT COALESCE(jsonb_object_agg(state, total ORDER BY state), '{}'::jsonb) INTO work_state
        FROM (SELECT state, count(*) AS total FROM pgreact_internal.agenda
              WHERE rule_version_id = current_row.rule_version_id GROUP BY state) AS q;
        plan_digest := digest;
        action_order := ordinal;
        action := 'REMOVE';
        rule_name := rule_item.value ->> 'name';
        dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object('retire', jsonb_build_array(current_row.match_name));
        lifecycle_risks := jsonb_build_array(COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD') ||
                                             ' applies to pending, retrying, and leased work');
        details := jsonb_build_object('prior_rule_version_id', current_row.rule_version_id,
                                      'prior_state', current_row.state, 'prior_work', work_state);
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.replace_pack_rule(
    target_version_id uuid,
    rule_name text,
    definition regclass,
    key_columns name[],
    kind text,
    on_activate regprocedure,
    on_deactivate regprocedure,
    on_change regprocedure,
    bootstrap_policy text,
    change_columns name[],
    salience integer,
    agenda_group text,
    conflict_key_columns name[],
    max_attempts integer,
    initial_backoff_seconds integer,
    backoff_multiplier numeric,
    max_backoff_seconds integer,
    old_work_policy text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    prior pgreact_internal.rule_versions%ROWTYPE;
    next_version uuid;
    orphan_rule uuid;
    temporary_name text := rule_name || '#pack-' || replace(gen_random_uuid()::text, '-', '');
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    IF prior.state NOT IN ('ACTIVE', 'PAUSED') THEN
        RAISE EXCEPTION 'only active or paused versions can be replaced';
    END IF;
    IF old_work_policy = 'CANCEL_OLD' THEN
        UPDATE pgreact_internal.agenda SET state = 'CANCELLED', completed_at = clock_timestamp()
        WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'RETRY_WAIT');
    END IF;
    -- Older immutable versions may still be draining under the same logical
    -- rule identity. Hide that identity only inside this deployment transaction
    -- so create_rule can compile the next version without weakening old work.
    UPDATE pgreact_internal.rules SET rule_name = temporary_name WHERE rule_id = prior.rule_id;
    UPDATE pgreact_internal.rule_versions SET state = 'REMOVED' WHERE rule_version_id = target_version_id;
    next_version := pgreact.create_rule(rule_name, definition, key_columns, kind,
        on_activate, on_deactivate, on_change, bootstrap_policy, change_columns,
        salience, agenda_group, conflict_key_columns, max_attempts,
        initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
    SELECT rule_id INTO orphan_rule FROM pgreact_internal.rule_versions WHERE rule_version_id = next_version;
    UPDATE pgreact_internal.rule_versions SET rule_id = prior.rule_id WHERE rule_version_id = next_version;
    DELETE FROM pgreact_internal.rules WHERE rule_id = orphan_rule;
    UPDATE pgreact_internal.rules SET rule_name = replace_pack_rule.rule_name WHERE rule_id = prior.rule_id;
    IF prior.match_relid IS NOT NULL THEN
        PERFORM pgtrickle.drop_stream_table(prior.match_name, true);
    END IF;
    UPDATE pgreact_internal.rule_versions
    SET match_relid = NULL,
        state = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.agenda
            WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'LEASED', 'RETRY_WAIT')
        ) THEN 'DRAINING' ELSE 'REMOVED' END
    WHERE rule_version_id = target_version_id;
    RETURN next_version;
END
$$;

CREATE FUNCTION pgreact_internal.retire_pack_rule(target_version_id uuid, old_work_policy text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE prior pgreact_internal.rule_versions%ROWTYPE;
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    IF old_work_policy = 'CANCEL_OLD' THEN
        UPDATE pgreact_internal.agenda SET state = 'CANCELLED', completed_at = clock_timestamp()
        WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'RETRY_WAIT');
    END IF;
    IF prior.match_relid IS NOT NULL THEN
        PERFORM pgtrickle.drop_stream_table(prior.match_name, true);
    END IF;
    UPDATE pgreact_internal.rule_versions
    SET match_relid = NULL,
        state = CASE WHEN EXISTS (
            SELECT 1 FROM pgreact_internal.agenda
            WHERE rule_version_id = target_version_id AND state IN ('PENDING', 'LEASED', 'RETRY_WAIT')
        ) THEN 'DRAINING' ELSE 'REMOVED' END
    WHERE rule_version_id = target_version_id;
END
$$;

CREATE FUNCTION pgreact_internal.maybe_fail_pack(phase text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
BEGIN
    IF pg_catalog.current_setting('pgreact.test_fail_pack_phase', true) = phase THEN
        RAISE EXCEPTION 'injected rule-pack failure after % phase', phase;
    END IF;
END
$$;

CREATE FUNCTION pgreact.deploy_pack(
    definition jsonb,
    expected_plan_digest text,
    mappings jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    diagnostic record;
    actual_plan_digest text;
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    pack_id uuid;
    prior_pack_version uuid;
    next_pack_version uuid := gen_random_uuid();
    rule_item record;
    current_version uuid;
    next_rule_version uuid;
    source_oid oid;
    on_activate_oid oid;
    on_deactivate_oid oid;
    on_change_oid oid;
    change_columns name[];
    conflict_columns name[];
    dependencies text[];
    policy text;
    action_name text;
    action_number integer := 0;
    outbox_item record;
BEGIN
    -- ponytail: global deployment/DDL locks are the smallest correct boundary;
    -- shard by pack only if measured deployment concurrency requires it.
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings)
    WHERE severity = 'ERROR' ORDER BY code, object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message USING HINT = diagnostic.hint;
    END IF;
    actual_plan_digest := pgreact_internal.pack_plan_digest(definition, mappings);
    IF expected_plan_digest IS DISTINCT FROM actual_plan_digest THEN
        RAISE EXCEPTION 'rule-pack preview is stale'
            USING HINT = 'Run pgreact.preview_pack again after concurrent DDL, work, or deployment changes.',
                  DETAIL = format('expected %s, current %s', expected_plan_digest, actual_plan_digest);
    END IF;
    SELECT p.pack_id INTO pack_id FROM pgreact_internal.rule_packs p
    WHERE p.owner_oid = caller_oid AND p.pack_name = definition ->> 'pack';
    IF pack_id IS NULL THEN
        pack_id := gen_random_uuid();
        INSERT INTO pgreact_internal.rule_packs(pack_id, pack_name, owner_oid)
        VALUES (pack_id, definition ->> 'pack', caller_oid);
    ELSE
        SELECT v.pack_version_id INTO prior_pack_version
        FROM pgreact_internal.rule_pack_versions v
        WHERE v.pack_id = pack_id AND v.state = 'ACTIVE';
    END IF;
    INSERT INTO pgreact_internal.rule_pack_versions(
        pack_version_id, pack_id, version, definition, mappings, definition_digest,
        plan_digest, state, deployed_by
    ) VALUES (
        next_pack_version, pack_id, definition ->> 'version', definition, mappings,
        sha256(convert_to(definition::text, 'UTF8')), actual_plan_digest, 'STAGED', session_user
    );
    PERFORM pgreact_internal.maybe_fail_pack('catalog');

    FOR rule_item IN
        SELECT value, ordinal FROM pg_catalog.jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY AS r(value, ordinal) ORDER BY ordinal
    LOOP
        action_number := action_number + 1;
        SELECT v.rule_version_id INTO current_version
        FROM pgreact_internal.rules r JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = rule_item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        source_oid := pg_catalog.to_regclass(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'definition'));
        on_activate_oid := pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'on_activate'));
        on_deactivate_oid := pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'on_deactivate'));
        on_change_oid := pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(
            mappings, 'objects', rule_item.value ->> 'on_change'));
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::name[] INTO change_columns
        FROM pg_catalog.jsonb_array_elements(rule_item.value -> 'change_columns')
        WITH ORDINALITY AS c(value, ordinal);
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::name[] INTO conflict_columns
        FROM pg_catalog.jsonb_array_elements(rule_item.value -> 'conflict_key_columns')
        WITH ORDINALITY AS c(value, ordinal);
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::text[] INTO dependencies
        FROM pg_catalog.jsonb_array_elements(COALESCE(rule_item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY AS d(value, ordinal);
        policy := COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD');
        action_name := CASE WHEN current_version IS NULL THEN 'ADD' ELSE 'REPLACE' END;
        IF current_version IS NULL THEN
            next_rule_version := pgreact.create_rule(
                rule_item.value ->> 'name', source_oid::regclass,
                ARRAY[(rule_item.value ->> 'key')::name], rule_item.value ->> 'kind',
                on_activate_oid::regprocedure, on_deactivate_oid::regprocedure, on_change_oid::regprocedure,
                COALESCE(rule_item.value ->> 'bootstrap_policy', 'SEED_CURRENT'), change_columns,
                COALESCE((rule_item.value ->> 'salience')::integer, 0),
                COALESCE(rule_item.value ->> 'agenda_group', 'default'), conflict_columns,
                COALESCE((rule_item.value ->> 'max_attempts')::integer, 1),
                COALESCE((rule_item.value ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((rule_item.value ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((rule_item.value ->> 'max_backoff_seconds')::integer, 60));
        ELSE
            next_rule_version := pgreact_internal.replace_pack_rule(
                current_version, rule_item.value ->> 'name', source_oid::regclass,
                ARRAY[(rule_item.value ->> 'key')::name], rule_item.value ->> 'kind',
                on_activate_oid::regprocedure, on_deactivate_oid::regprocedure, on_change_oid::regprocedure,
                COALESCE(rule_item.value ->> 'bootstrap_policy', 'SEED_CURRENT'), change_columns,
                COALESCE((rule_item.value ->> 'salience')::integer, 0),
                COALESCE(rule_item.value ->> 'agenda_group', 'default'), conflict_columns,
                COALESCE((rule_item.value ->> 'max_attempts')::integer, 1),
                COALESCE((rule_item.value ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((rule_item.value ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((rule_item.value ->> 'max_backoff_seconds')::integer, 60), policy);
        END IF;
        FOR outbox_item IN
            SELECT key AS event_kind, value #>> '{}' AS identity
            FROM pg_catalog.jsonb_each(COALESCE(rule_item.value -> 'outbox', '{}'::jsonb))
        LOOP
            PERFORM pgreact.bind_outbox_consequence(next_rule_version, outbox_item.event_kind,
                pg_catalog.to_regprocedure(pgreact_internal.pack_mapping(mappings, 'objects', outbox_item.identity)),
                COALESCE((rule_item.value ->> 'max_attempts')::integer, 1),
                COALESCE((rule_item.value ->> 'initial_backoff_seconds')::integer, 1),
                COALESCE((rule_item.value ->> 'backoff_multiplier')::numeric, 2),
                COALESCE((rule_item.value ->> 'max_backoff_seconds')::integer, 60));
        END LOOP;
        INSERT INTO pgreact_internal.rule_pack_members
            (pack_version_id, rule_name, rule_version_id, dependencies)
        VALUES (next_pack_version, rule_item.value ->> 'name', next_rule_version,
                COALESCE(dependencies, ARRAY[]::text[]));
        INSERT INTO pgreact_internal.rule_pack_actions(
            pack_version_id, action_order, action, rule_name, old_rule_version_id,
            new_rule_version_id, old_work_policy, details
        ) VALUES (
            next_pack_version, action_number, action_name, rule_item.value ->> 'name',
            current_version, next_rule_version, policy,
            jsonb_build_object('dependencies', COALESCE(to_jsonb(dependencies), '[]'::jsonb),
                               'source', rule_item.value ->> 'definition')
        );
        current_version := NULL;
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_pack('rules');

    FOR rule_item IN
        SELECT value FROM pg_catalog.jsonb_array_elements(definition -> 'remove') AS r(value)
    LOOP
        action_number := action_number + 1;
        SELECT m.rule_version_id INTO current_version
        FROM pgreact_internal.rule_pack_members m
        WHERE m.pack_version_id = prior_pack_version AND m.rule_name = rule_item.value ->> 'name';
        policy := COALESCE(rule_item.value ->> 'old_work_policy', 'DRAIN_OLD');
        PERFORM pgreact_internal.retire_pack_rule(current_version, policy);
        INSERT INTO pgreact_internal.rule_pack_actions(
            pack_version_id, action_order, action, rule_name, old_rule_version_id,
            old_work_policy, details
        ) VALUES (next_pack_version, action_number, 'REMOVE', rule_item.value ->> 'name',
                  current_version, policy, '{}'::jsonb);
        current_version := NULL;
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_pack('removals');

    UPDATE pgreact_internal.rule_pack_versions SET state = 'SUPERSEDED'
    WHERE pack_version_id = prior_pack_version;
    UPDATE pgreact_internal.rule_pack_versions SET state = 'ACTIVE'
    WHERE pack_version_id = next_pack_version;
    PERFORM pgreact_internal.maybe_fail_pack('activation');
    RETURN next_pack_version;
END
$$;

CREATE FUNCTION pgreact.pack_history(target_pack_name text DEFAULT NULL)
RETURNS TABLE(
    pack_name text,
    version text,
    status text,
    definition_digest text,
    plan_digest text,
    deployed_at timestamptz,
    deployed_by name,
    actions jsonb
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT p.pack_name, v.version, v.state,
           encode(v.definition_digest, 'hex'), v.plan_digest, v.deployed_at, v.deployed_by,
           COALESCE(jsonb_agg(jsonb_build_object(
               'order', a.action_order, 'action', a.action, 'rule', a.rule_name,
               'old_rule_version_id', a.old_rule_version_id,
               'new_rule_version_id', a.new_rule_version_id,
               'old_work_policy', a.old_work_policy, 'details', a.details
           ) ORDER BY a.action_order) FILTER (WHERE a.action_order IS NOT NULL), '[]'::jsonb)
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    LEFT JOIN pgreact_internal.rule_pack_actions a USING (pack_version_id)
    WHERE p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND ($1 IS NULL OR p.pack_name = $1)
    GROUP BY p.pack_name, v.pack_version_id
    ORDER BY p.pack_name, v.deployed_at
$$;

CREATE FUNCTION pgreact.explain_pack(target_pack_name text)
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'pack', jsonb_build_object('name', p.pack_name, 'version', v.version,
                                   'plan_digest', v.plan_digest, 'deployed_at', v.deployed_at),
        'members', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'rule', m.rule_name, 'rule_version_id', m.rule_version_id,
                'dependencies', m.dependencies, 'state', rv.state,
                'source_drift', d.status,
                'outstanding_work', (SELECT count(*) FROM pgreact_internal.agenda a
                                     WHERE a.rule_version_id = m.rule_version_id
                                       AND a.state IN ('PENDING', 'RETRY_WAIT', 'LEASED'))
            ) ORDER BY m.rule_name)
            FROM pgreact_internal.rule_pack_members m
            JOIN pgreact_internal.rule_versions rv USING (rule_version_id)
            LEFT JOIN pgreact.source_drift() d USING (rule_version_id)
            WHERE m.pack_version_id = v.pack_version_id
        ), '[]'::jsonb),
        'draining_old_work', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'rule', a.rule_name, 'rule_version_id', a.old_rule_version_id,
                'state', rv.state,
                'outstanding_work', (SELECT count(*) FROM pgreact_internal.agenda q
                                     WHERE q.rule_version_id = a.old_rule_version_id
                                       AND q.state IN ('PENDING', 'RETRY_WAIT', 'LEASED'))
            ) ORDER BY a.action_order)
            FROM pgreact_internal.rule_pack_actions a
            JOIN pgreact_internal.rule_versions rv ON rv.rule_version_id = a.old_rule_version_id
            WHERE a.pack_version_id = v.pack_version_id AND rv.state = 'DRAINING'
        ), '[]'::jsonb),
        'history', COALESCE((SELECT jsonb_agg(to_jsonb(h) ORDER BY h.deployed_at)
                            FROM pgreact.pack_history(target_pack_name) h), '[]'::jsonb)
    )
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = target_pack_name
      AND p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND v.state = 'ACTIVE'
$$;

DROP EVENT TRIGGER pgreact_binding_ddl_lock;
CREATE EVENT TRIGGER pgreact_binding_ddl_lock
    ON ddl_command_start
    WHEN TAG IN (
        'CREATE FUNCTION', 'ALTER FUNCTION', 'DROP FUNCTION',
        'CREATE TABLE', 'ALTER TABLE', 'DROP TABLE',
        'CREATE VIEW', 'ALTER VIEW', 'DROP VIEW',
        'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW', 'DROP MATERIALIZED VIEW'
    )
    EXECUTE FUNCTION pgreact_internal.binding_ddl_lock();

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M5 safe rule-set deployment over the frozen v1 lifecycle and worker protocol';
