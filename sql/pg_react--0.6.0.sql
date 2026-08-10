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
-- M7 maintained derived knowledge. Derivations reuse the existing activation
-- evaluator but maintain supports and facts instead of creating agenda work.

ALTER TABLE pgreact_internal.rule_versions
    ADD COLUMN rule_kind text NOT NULL DEFAULT 'STANDARD'
        CHECK (rule_kind IN ('STANDARD', 'DERIVATION'));

CREATE TABLE pgreact_internal.derived_relations (
    relation_id uuid PRIMARY KEY,
    relation_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.derived_relation_versions (
    relation_version_id uuid PRIMARY KEY,
    relation_id uuid NOT NULL REFERENCES pgreact_internal.derived_relations,
    version integer NOT NULL CHECK (version > 0),
    owner_oid oid NOT NULL,
    row_type_oid oid NOT NULL,
    row_type_name text NOT NULL,
    row_signature bytea NOT NULL,
    key_column name NOT NULL,
    public_view_oid oid,
    public_view_name text NOT NULL,
    state text NOT NULL CHECK (state IN ('ACTIVE', 'REMOVED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (relation_id, version)
);

CREATE UNIQUE INDEX derived_relation_one_active_version
    ON pgreact_internal.derived_relation_versions (relation_id)
    WHERE state = 'ACTIVE';

CREATE TABLE pgreact_internal.derivation_rule_versions (
    rule_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.rule_versions,
    rule_id uuid NOT NULL REFERENCES pgreact_internal.rules,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    version integer NOT NULL CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (rule_id, version)
);

CREATE TABLE pgreact_internal.derived_frontiers (
    relation_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.derived_relation_versions,
    frontier bigint NOT NULL CHECK (frontier > 0),
    transaction_id xid8 NOT NULL,
    advanced_at timestamptz NOT NULL
);

CREATE TABLE pgreact_internal.derived_supports (
    support_id uuid PRIMARY KEY,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    activation_id uuid NOT NULL,
    activation_generation bigint NOT NULL CHECK (activation_generation > 0),
    activation_revision bigint NOT NULL CHECK (activation_revision >= 0),
    semantic_key bigint NOT NULL,
    fact_id uuid NOT NULL,
    fact jsonb NOT NULL,
    source_binding jsonb NOT NULL,
    active boolean NOT NULL,
    first_frontier bigint NOT NULL,
    last_frontier bigint,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    invalidated_at timestamptz,
    UNIQUE (rule_version_id, activation_id, activation_generation, activation_revision)
);

CREATE UNIQUE INDEX derived_support_one_active_activation
    ON pgreact_internal.derived_supports (rule_version_id, activation_id)
    WHERE active;
CREATE INDEX derived_support_active_fact
    ON pgreact_internal.derived_supports (relation_version_id, semantic_key)
    WHERE active;

CREATE TABLE pgreact_internal.derived_facts (
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    fact_id uuid NOT NULL,
    semantic_key bigint NOT NULL,
    fact jsonb NOT NULL,
    support_count bigint NOT NULL CHECK (support_count > 0),
    first_frontier bigint NOT NULL,
    last_frontier bigint NOT NULL,
    first_derived_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    last_changed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (relation_version_id, fact_id),
    UNIQUE (relation_version_id, semantic_key)
);

CREATE TABLE pgreact_internal.derived_reconciliations (
    reconciliation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    started_at timestamptz NOT NULL,
    completed_at timestamptz,
    repairs bigint,
    status text NOT NULL CHECK (status IN ('RUNNING', 'COMPLETED')),
    requested_by name NOT NULL
);

CREATE TABLE pgreact_internal.derived_repair_diagnostics (
    reconciliation_id bigint NOT NULL REFERENCES pgreact_internal.derived_reconciliations,
    diagnostic_order integer NOT NULL CHECK (diagnostic_order > 0),
    code text NOT NULL CHECK (code IN (
        'MISSING_SUPPORT', 'EXTRA_SUPPORT', 'STALE_SUPPORT',
        'MISSING_FACT', 'EXTRA_FACT', 'STALE_FACT'
    )),
    object_identity text NOT NULL,
    details jsonb NOT NULL,
    PRIMARY KEY (reconciliation_id, diagnostic_order)
);

CREATE FUNCTION pgreact_internal.composite_type_signature(target_type oid)
RETURNS bytea
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sha256(convert_to(string_agg(
        format('%s:%s:%s', a.attname, a.atttypid, a.attnotnull), ',' ORDER BY a.attnum
    ), 'UTF8'))
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
    WHERE t.oid = $1 AND t.typtype = 'c' AND a.attnum > 0 AND NOT a.attisdropped
$$;

CREATE FUNCTION pgreact_internal.source_reads_derived(source_oid oid)
RETURNS boolean
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE dependencies(relid) AS (
        SELECT $1
        UNION
        SELECT d.refobjid
        FROM dependencies parent
        JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
        JOIN pg_catalog.pg_depend d
          ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
         AND d.refclassid = 'pg_class'::regclass
        JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
        WHERE c.relkind IN ('v', 'm')
    )
    SELECT EXISTS (
        SELECT 1
        FROM dependencies d
        JOIN pgreact_internal.derived_relation_versions v
          ON v.public_view_oid = d.relid AND v.state = 'ACTIVE'
    )
$$;

CREATE FUNCTION pgreact_internal.assert_derived_owner(target_relation_version uuid)
RETURNS pgreact_internal.derived_relation_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT relation_row
    FROM pgreact_internal.derived_relation_versions
    WHERE relation_version_id = target_relation_version;
    IF relation_row.owner_oid <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'only the derived-relation owner or pgreact_admin may manage %',
            relation_row.public_view_name;
    END IF;
    RETURN relation_row;
END
$$;

CREATE FUNCTION pgreact.validate_derived_relation(
    name text,
    row_type regtype,
    key_columns name[],
    relation_version integer DEFAULT 1
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
    parts text[] := pg_catalog.parse_ident(name, true);
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    type_row record;
    schema_oid oid;
BEGIN
    IF cardinality(parts) <> 2 THEN
        RETURN QUERY SELECT 2, 'RELATION_NAME_INVALID', 'ERROR', name,
            'derived relation names must be schema-qualified',
            'Use schema.relation.', '{}'::jsonb;
        RETURN;
    END IF;
    schema_oid := pg_catalog.to_regnamespace(parts[1]);
    IF schema_oid IS NULL OR NOT pg_catalog.has_schema_privilege(session_user, schema_oid, 'CREATE') THEN
        RETURN QUERY SELECT 2, 'RELATION_SCHEMA_UNSAFE', 'ERROR', name,
            'the relation owner must have CREATE on the target schema',
            'Choose an owned schema or grant CREATE explicitly.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT t.typowner, t.typtype, t.typrelid,
           format('%I.%I', n.nspname, t.typname) AS identity
    INTO type_row
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE t.oid = row_type;
    IF type_row.typtype IS DISTINCT FROM 'c' OR type_row.typowner IS DISTINCT FROM caller_oid THEN
        RETURN QUERY SELECT 2, 'ROW_TYPE_UNSAFE', 'ERROR', row_type::text,
            'the declared row type must be a caller-owned PostgreSQL composite type',
            'Create and own one composite type for the derived fact shape.', '{}'::jsonb;
        RETURN;
    END IF;
    IF cardinality(key_columns) IS DISTINCT FROM 1 THEN
        RETURN QUERY SELECT 2, 'KEY_CODEC_UNSUPPORTED', 'ERROR', name,
            'M7 supports exactly one semantic key column',
            'Use one non-null bigint key column.', '{}'::jsonb;
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_attribute
        WHERE attrelid = type_row.typrelid AND attname = key_columns[1]
          AND atttypid = 'bigint'::regtype AND attnum > 0 AND NOT attisdropped
    ) THEN
        RETURN QUERY SELECT 2, 'KEY_NOT_BIGINT', 'ERROR', name,
            'M7 semantic keys must use bigint codec v1',
            'Declare one bigint key attribute in the row type.',
            jsonb_build_object('key_column', key_columns[1]);
        RETURN;
    END IF;
    IF relation_version < 1 THEN
        RETURN QUERY SELECT 2, 'RELATION_VERSION_INVALID', 'ERROR', name,
            'relation versions are positive integers',
            'Start at version 1 and increment immutably.', '{}'::jsonb;
        RETURN;
    END IF;
    IF pg_catalog.to_regclass(format('%I.%I', parts[1], parts[2])) IS NOT NULL THEN
        RETURN QUERY SELECT 2, 'RELATION_NAME_EXISTS', 'ERROR', name,
            'the public derived relation name already exists',
            'Choose an unused qualified relation name.', '{}'::jsonb;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = format('%I.%I', parts[1], parts[2])
          AND v.version = relation_version
    ) THEN
        RETURN QUERY SELECT 2, 'RELATION_VERSION_EXISTS', 'ERROR', name,
            'that immutable derived relation version already exists',
            'Use the active version or increment the version.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 2, 'OK', 'INFO', format('%I.%I', parts[1], parts[2]),
        'derived relation can be created',
        'Create derivation rules whose source views project this complete row type.',
        jsonb_build_object('row_type', type_row.identity, 'key_codec', 'bigint-v1',
                           'version', relation_version);
END
$$;

CREATE FUNCTION pgreact.create_derived_relation(
    name text,
    row_type regtype,
    key_columns name[],
    relation_version integer DEFAULT 1
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    parts text[] := pg_catalog.parse_ident(name, true);
    relation_id uuid := gen_random_uuid();
    version_id uuid := gen_random_uuid();
    caller_oid oid := (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user);
    type_name text;
    qualified_name text;
    view_oid oid;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact.validate_derived_relation(name, row_type, key_columns, relation_version)
    WHERE severity = 'ERROR' ORDER BY code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react derived relation validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    qualified_name := format('%I.%I', parts[1], parts[2]);
    SELECT format('%I.%I', n.nspname, t.typname) INTO STRICT type_name
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE t.oid = row_type;
    INSERT INTO pgreact_internal.derived_relations
        (relation_id, relation_name, owner_oid)
    VALUES (relation_id, qualified_name, caller_oid);
    INSERT INTO pgreact_internal.derived_relation_versions (
        relation_version_id, relation_id, version, owner_oid, row_type_oid,
        row_type_name, row_signature, key_column, public_view_name, state
    ) VALUES (
        version_id, relation_id, relation_version, caller_oid, row_type,
        type_name, pgreact_internal.composite_type_signature(row_type),
        key_columns[1], qualified_name, 'ACTIVE'
    );
    EXECUTE format(
        'CREATE VIEW %s WITH (security_barrier=true) AS '
        'SELECT (pg_catalog.jsonb_populate_record(NULL::%s, f.fact)).* '
        'FROM pgreact_internal.derived_facts f WHERE f.relation_version_id = %L::uuid',
        qualified_name, type_name, version_id
    );
    view_oid := pg_catalog.to_regclass(qualified_name);
    UPDATE pgreact_internal.derived_relation_versions
    SET public_view_oid = view_oid WHERE relation_version_id = version_id;
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC', qualified_name);
    EXECUTE format('GRANT SELECT ON %s TO %I', qualified_name, session_user);
    RETURN version_id;
END
$$;

CREATE FUNCTION pgreact.validate_derivation_rule(
    definition regclass,
    target_relation uuid,
    key_columns name[],
    rule_version integer DEFAULT 1
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
    relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    source_row record;
    target_attribute record;
    diagnostic record;
BEGIN
    SELECT * INTO relation_row
    FROM pgreact_internal.derived_relation_versions
    WHERE relation_version_id = target_relation AND state = 'ACTIVE';
    IF NOT FOUND THEN
        RETURN QUERY SELECT 2, 'TARGET_RELATION_INACTIVE', 'ERROR', target_relation::text,
            'the target derived relation version is not active',
            'Use one active caller-owned derived relation version.', '{}'::jsonb;
        RETURN;
    END IF;
    IF relation_row.owner_oid <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user) THEN
        RETURN QUERY SELECT 2, 'TARGET_RELATION_NOT_OWNED', 'ERROR', relation_row.public_view_name,
            'the derivation owner must own its target relation',
            'Create the derivation as the relation owner.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_rule(definition, key_columns, NULL) AS d
    WHERE d.severity = 'ERROR' ORDER BY d.code LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 2, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint, diagnostic.details;
        RETURN;
    END IF;
    IF pgreact_internal.source_reads_derived(definition) THEN
        RETURN QUERY SELECT 2, 'DERIVATION_CHAIN_UNSUPPORTED', 'ERROR', definition::text,
            'derivation source views may not read derived relations',
            'Read only supported authoritative PostgreSQL relations.', '{}'::jsonb;
        RETURN;
    END IF;
    IF key_columns[1] IS DISTINCT FROM relation_row.key_column THEN
        RETURN QUERY SELECT 2, 'DERIVATION_KEY_MISMATCH', 'ERROR', definition::text,
            'the derivation key must match the target relation semantic key',
            'Project the target key under its declared name.',
            jsonb_build_object('expected', relation_row.key_column, 'received', key_columns[1]);
        RETURN;
    END IF;
    SELECT c.reltype INTO STRICT source_row
    FROM pg_catalog.pg_class c WHERE c.oid = definition;
    FOR target_attribute IN
        SELECT a.attname, a.atttypid
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
        WHERE t.oid = relation_row.row_type_oid AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = definition AND a.attname = target_attribute.attname
              AND a.atttypid = target_attribute.atttypid
              AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            RETURN QUERY SELECT 2, 'DERIVATION_FACT_SHAPE', 'ERROR', definition::text,
                'the derivation source does not project the complete target row type',
                'Project every target attribute with its exact PostgreSQL type.',
                jsonb_build_object('missing_or_mismatched_column', target_attribute.attname);
            RETURN;
        END IF;
    END LOOP;
    IF rule_version < 1 THEN
        RETURN QUERY SELECT 2, 'DERIVATION_VERSION_INVALID', 'ERROR', definition::text,
            'derivation rule versions are positive integers',
            'Start at version 1 and increment immutably.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 2, 'OK', 'INFO', definition::text,
        'derivation rule can contribute one support per active match',
        'Create the immutable derivation rule version.',
        jsonb_build_object('target', relation_row.public_view_name,
                           'version', rule_version, 'agenda', false);
END
$$;

CREATE FUNCTION pgreact_internal.advance_derived_frontier(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result bigint;
BEGIN
    INSERT INTO pgreact_internal.derived_frontiers (
        relation_version_id, frontier, transaction_id, advanced_at
    ) VALUES (
        target_relation, 1, pg_catalog.pg_current_xact_id(), clock_timestamp()
    )
    ON CONFLICT (relation_version_id) DO UPDATE SET
        frontier = CASE
            WHEN pgreact_internal.derived_frontiers.transaction_id = EXCLUDED.transaction_id
                THEN pgreact_internal.derived_frontiers.frontier
            ELSE pgreact_internal.derived_frontiers.frontier + 1
        END,
        transaction_id = EXCLUDED.transaction_id,
        advanced_at = CASE
            WHEN pgreact_internal.derived_frontiers.transaction_id = EXCLUDED.transaction_id
                THEN pgreact_internal.derived_frontiers.advanced_at
            ELSE EXCLUDED.advanced_at
        END
    RETURNING frontier INTO result;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_internal.project_derived_fact(target_relation uuid, binding jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE; result jsonb;
BEGIN
    SELECT * INTO STRICT relation_row
    FROM pgreact_internal.derived_relation_versions
    WHERE relation_version_id = target_relation;
    IF pgreact_internal.composite_type_signature(relation_row.row_type_oid)
       IS DISTINCT FROM relation_row.row_signature THEN
        RAISE EXCEPTION 'derived row type drift for %', relation_row.public_view_name;
    END IF;
    EXECUTE format(
        'SELECT to_jsonb(pg_catalog.jsonb_populate_record(NULL::%s, $1))',
        relation_row.row_type_name
    ) INTO result USING binding;
    IF result ->> relation_row.key_column IS NULL THEN
        RAISE EXCEPTION 'derived fact key %.% must be non-null',
            relation_row.public_view_name, relation_row.key_column;
    END IF;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_internal.recompute_derived_fact(
    target_relation uuid,
    target_key bigint,
    frontier_value bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    support_total bigint;
    distinct_facts bigint;
    current_fact jsonb;
    canonical bytea := pgreact_internal.canonical_bigint_v1(target_key);
    target_fact_id uuid := pgreact_internal.activation_uuid(
        pgreact_internal.activation_digest(target_relation, canonical));
BEGIN
    SELECT count(*), count(DISTINCT fact::text), min(fact::text)::jsonb
    INTO support_total, distinct_facts, current_fact
    FROM pgreact_internal.derived_supports
    WHERE relation_version_id = target_relation
      AND semantic_key = target_key AND active;
    IF distinct_facts > 1 THEN
        RAISE EXCEPTION 'conflicting derived payloads for relation % key %',
            target_relation, target_key;
    ELSIF support_total = 0 THEN
        DELETE FROM pgreact_internal.derived_facts
        WHERE relation_version_id = target_relation AND semantic_key = target_key;
    ELSE
        INSERT INTO pgreact_internal.derived_facts (
            relation_version_id, fact_id, semantic_key, fact, support_count,
            first_frontier, last_frontier
        ) VALUES (
            target_relation, target_fact_id, target_key, current_fact, support_total,
            frontier_value, frontier_value
        )
        ON CONFLICT (relation_version_id, fact_id) DO UPDATE SET
            fact = EXCLUDED.fact,
            support_count = EXCLUDED.support_count,
            last_frontier = EXCLUDED.last_frontier,
            last_changed_at = clock_timestamp();
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.maintain_derived_support(
    target_rule_version uuid,
    target_activation uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    derivation pgreact_internal.derivation_rule_versions%ROWTYPE;
    activation pgreact_internal.activation_state%ROWTYPE;
    old_support record;
    projected jsonb;
    canonical bytea;
    target_fact_id uuid;
    target_support_id uuid;
    frontier_value bigint;
    clean_binding jsonb;
BEGIN
    SELECT d.* INTO derivation
    FROM pgreact_internal.derivation_rule_versions d
    JOIN pgreact_internal.rule_versions v USING (rule_version_id)
    WHERE d.rule_version_id = target_rule_version AND v.rule_kind = 'DERIVATION';
    IF NOT FOUND THEN RETURN; END IF;
    SELECT * INTO activation
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = target_rule_version AND activation_id = target_activation;
    IF NOT FOUND THEN RETURN; END IF;
    IF activation.active THEN
        clean_binding := activation.current_bindings - '__pgt_row_id';
        projected := pgreact_internal.project_derived_fact(
            derivation.relation_version_id, clean_binding);
        canonical := pgreact_internal.canonical_bigint_v1(activation.semantic_key);
        target_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(derivation.relation_version_id, canonical));
        target_support_id := pgreact_internal.activation_uuid(sha256(convert_to(
            target_rule_version::text || ':' || target_activation::text || ':' ||
            activation.generation || ':' || activation.revision || ':' || target_fact_id::text,
            'UTF8')));
        IF EXISTS (
            SELECT 1 FROM pgreact_internal.derived_supports s
            WHERE s.relation_version_id = derivation.relation_version_id
              AND s.semantic_key = activation.semantic_key AND s.active
              AND s.support_id <> target_support_id AND s.fact IS DISTINCT FROM projected
        ) THEN
            RAISE EXCEPTION 'conflicting derived payloads for % key %',
                derivation.relation_version_id, activation.semantic_key;
        END IF;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derived_supports s
        WHERE s.rule_version_id = target_rule_version
          AND s.activation_id = target_activation AND s.active
          AND (NOT activation.active OR s.support_id <> target_support_id)
    ) OR (activation.active AND NOT EXISTS (
        SELECT 1 FROM pgreact_internal.derived_supports s
        WHERE s.support_id = target_support_id AND s.active
          AND s.source_binding = clean_binding AND s.fact = projected
    )) THEN
        frontier_value := pgreact_internal.advance_derived_frontier(derivation.relation_version_id);
    ELSE
        RETURN;
    END IF;
    FOR old_support IN
        UPDATE pgreact_internal.derived_supports
        SET active = false, last_frontier = frontier_value,
            invalidated_at = clock_timestamp()
        WHERE rule_version_id = target_rule_version
          AND activation_id = target_activation AND active
          AND (NOT activation.active OR support_id <> target_support_id)
        RETURNING relation_version_id, semantic_key
    LOOP
        PERFORM pgreact_internal.recompute_derived_fact(
            old_support.relation_version_id, old_support.semantic_key, frontier_value);
    END LOOP;
    IF activation.active THEN
        INSERT INTO pgreact_internal.derived_supports (
            support_id, relation_version_id, rule_version_id, activation_id,
            activation_generation, activation_revision, semantic_key, fact_id,
            fact, source_binding, active, first_frontier
        ) VALUES (
            target_support_id, derivation.relation_version_id, target_rule_version,
            target_activation, activation.generation, activation.revision,
            activation.semantic_key, target_fact_id, projected,
            clean_binding, true, frontier_value
        )
        ON CONFLICT (support_id) DO UPDATE SET
            fact = EXCLUDED.fact, source_binding = EXCLUDED.source_binding,
            active = true, last_frontier = NULL, invalidated_at = NULL;
        PERFORM pgreact_internal.recompute_derived_fact(
            derivation.relation_version_id, activation.semantic_key, frontier_value);
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.capture_derived_activation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF TG_OP = 'UPDATE'
       AND (NEW.active, NEW.generation, NEW.revision, NEW.current_bindings)
           IS NOT DISTINCT FROM
           (OLD.active, OLD.generation, OLD.revision, OLD.current_bindings) THEN
        RETURN NEW;
    END IF;
    PERFORM pgreact_internal.maintain_derived_support(
        NEW.rule_version_id, NEW.activation_id);
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_maintain_derived_support
AFTER INSERT OR UPDATE OF active, generation, revision, current_bindings
ON pgreact_internal.activation_state
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.capture_derived_activation();

CREATE FUNCTION pgreact.create_derivation_rule(
    name text,
    definition regclass,
    key_columns name[],
    target_relation uuid,
    rule_version integer DEFAULT 1,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    diagnostic record;
    version_id uuid;
    watched name[];
    active_activation record;
BEGIN
    SELECT * INTO diagnostic
    FROM pgreact.validate_derivation_rule(
        definition, target_relation, key_columns, rule_version)
    WHERE severity = 'ERROR' ORDER BY code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react derivation validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = name AND v.state <> 'REMOVED'
    ) THEN
        RAISE EXCEPTION 'a non-removed rule named % already exists', name;
    END IF;
    version_id := pgreact_internal.register_reference_rule(
        name, definition, key_columns[1], NULL, bootstrap_policy);
    SELECT array_agg(a.attname ORDER BY a.attnum) INTO watched
    FROM pg_catalog.pg_attribute a
    WHERE a.attrelid = definition AND a.attnum > 0 AND NOT a.attisdropped
      AND a.attname <> key_columns[1];
    UPDATE pgreact_internal.rule_versions
    SET rule_kind = 'DERIVATION', change_columns = watched
    WHERE rule_version_id = version_id;
    INSERT INTO pgreact_internal.derivation_rule_versions (
        rule_version_id, rule_id, relation_version_id, version
    ) SELECT version_id, rule_id, target_relation, rule_version
    FROM pgreact_internal.rule_versions WHERE rule_version_id = version_id;
    FOR active_activation IN
        SELECT activation_id FROM pgreact_internal.activation_state
        WHERE rule_version_id = version_id AND active
    LOOP
        PERFORM pgreact_internal.maintain_derived_support(
            version_id, active_activation.activation_id);
    END LOOP;
    RETURN version_id;
END
$$;

CREATE FUNCTION pgreact.refresh_derived_relation(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE producer record; producers bigint := 0;
BEGIN
    PERFORM pgreact_internal.assert_derived_owner(target_relation);
    -- ponytail: reuse the lifecycle-wide lock; split by relation only if measured contention requires it.
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    FOR producer IN
        SELECT v.rule_version_id
        FROM pgreact_internal.derivation_rule_versions d
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        JOIN pgreact_internal.rules r ON r.rule_id = d.rule_id
        WHERE d.relation_version_id = target_relation AND v.state = 'ACTIVE'
        ORDER BY r.rule_name, d.version
    LOOP
        PERFORM pgreact_internal.refresh_rule(producer.rule_version_id);
        producers := producers + 1;
    END LOOP;
    RETURN producers;
END
$$;

CREATE FUNCTION pgreact_internal.retire_derivation_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; activation record;
BEGIN
    SELECT * INTO STRICT version_row
    FROM pgreact_internal.rule_versions WHERE rule_version_id = target_version_id;
    IF version_row.rule_kind <> 'DERIVATION' THEN
        RAISE EXCEPTION 'rule version % is not a derivation', target_version_id;
    END IF;
    FOR activation IN
        SELECT activation_id FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id AND active
    LOOP
        UPDATE pgreact_internal.activation_state
        SET active = false, current_bindings = NULL,
            deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
        WHERE rule_version_id = target_version_id
          AND activation_id = activation.activation_id;
    END LOOP;
    PERFORM pgtrickle.drop_stream_table(version_row.match_name, true);
    UPDATE pgreact_internal.rule_versions
    SET state = 'REMOVED', match_relid = NULL
    WHERE rule_version_id = target_version_id;
END
$$;

CREATE FUNCTION pgreact.remove_derivation_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE derivation pgreact_internal.derivation_rule_versions%ROWTYPE;
BEGIN
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    SELECT * INTO STRICT derivation
    FROM pgreact_internal.derivation_rule_versions
    WHERE rule_version_id = target_version_id;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pgreact_internal.retire_derivation_rule(target_version_id);
END
$$;

CREATE FUNCTION pgreact.replace_derivation_rule(
    target_version_id uuid,
    definition regclass,
    key_columns name[],
    rule_version integer,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    prior pgreact_internal.rule_versions%ROWTYPE;
    derivation pgreact_internal.derivation_rule_versions%ROWTYPE;
    next_version uuid;
    orphan_rule uuid;
    rule_name text;
BEGIN
    prior := pgreact_internal.assert_rule_owner(target_version_id);
    SELECT * INTO STRICT derivation
    FROM pgreact_internal.derivation_rule_versions
    WHERE rule_version_id = target_version_id;
    IF prior.state NOT IN ('ACTIVE', 'PAUSED') THEN
        RAISE EXCEPTION 'only active or paused derivations can be replaced';
    END IF;
    SELECT r.rule_name INTO STRICT rule_name
    FROM pgreact_internal.rules r WHERE r.rule_id = prior.rule_id;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    UPDATE pgreact_internal.rule_versions SET state = 'REMOVED'
    WHERE rule_version_id = target_version_id;
    next_version := pgreact.create_derivation_rule(
        rule_name, definition, key_columns, derivation.relation_version_id,
        rule_version, bootstrap_policy);
    SELECT rule_id INTO STRICT orphan_rule
    FROM pgreact_internal.rule_versions WHERE rule_version_id = next_version;
    UPDATE pgreact_internal.rule_versions SET rule_id = prior.rule_id
    WHERE rule_version_id = next_version;
    UPDATE pgreact_internal.derivation_rule_versions SET rule_id = prior.rule_id
    WHERE rule_version_id = next_version;
    DELETE FROM pgreact_internal.rules WHERE rule_id = orphan_rule;
    PERFORM pgreact_internal.retire_derivation_rule(target_version_id);
    RETURN next_version;
END
$$;

CREATE VIEW pgreact.derived_relations AS
SELECT r.relation_id, r.relation_name, v.relation_version_id,
       v.version AS relation_version, pg_get_userbyid(v.owner_oid) AS owner,
       v.row_type_name AS row_type, v.key_column, v.public_view_name,
       v.state, v.created_at
FROM pgreact_internal.derived_relations r
JOIN pgreact_internal.derived_relation_versions v USING (relation_id);

CREATE VIEW pgreact.derived_facts AS
SELECT f.relation_version_id, r.relation_name, v.version AS relation_version,
       f.fact_id, f.semantic_key, f.fact, f.support_count,
       f.first_frontier, f.last_frontier, f.first_derived_at, f.last_changed_at
FROM pgreact_internal.derived_facts f
JOIN pgreact_internal.derived_relation_versions v USING (relation_version_id)
JOIN pgreact_internal.derived_relations r USING (relation_id);

CREATE VIEW pgreact.support_history AS
SELECT s.support_id, s.relation_version_id, dr.relation_name,
       dv.version AS relation_version, r.rule_name,
       d.version AS rule_version, s.rule_version_id, s.activation_id,
       s.activation_generation, s.activation_revision, s.semantic_key,
       s.fact, s.source_binding, s.active, s.first_frontier,
       s.last_frontier, s.created_at, s.invalidated_at
FROM pgreact_internal.derived_supports s
JOIN pgreact_internal.derived_relation_versions dv USING (relation_version_id)
JOIN pgreact_internal.derived_relations dr USING (relation_id)
JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
JOIN pgreact_internal.rules r ON r.rule_id = d.rule_id;

CREATE VIEW pgreact.derived_repair_diagnostics AS
SELECT d.reconciliation_id, r.relation_version_id, dr.relation_name,
       rv.version AS relation_version, d.diagnostic_order, d.code,
       d.object_identity, d.details, r.started_at, r.completed_at
FROM pgreact_internal.derived_repair_diagnostics d
JOIN pgreact_internal.derived_reconciliations r USING (reconciliation_id)
JOIN pgreact_internal.derived_relation_versions rv USING (relation_version_id)
JOIN pgreact_internal.derived_relations dr USING (relation_id);

CREATE FUNCTION pgreact.current_facts(target_relation uuid, target_key bigint DEFAULT NULL)
RETURNS SETOF pgreact.derived_facts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_derived_owner(target_relation);
    RETURN QUERY SELECT * FROM pgreact.derived_facts f
    WHERE f.relation_version_id = target_relation
      AND (target_key IS NULL OR f.semantic_key = target_key)
    ORDER BY f.semantic_key;
END
$$;

CREATE FUNCTION pgreact.explain_fact(target_relation uuid, target_key bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result jsonb;
BEGIN
    PERFORM pgreact_internal.assert_derived_owner(target_relation);
    SELECT jsonb_build_object(
        'relation', f.relation_name || '@' || f.relation_version,
        'fact', f.fact,
        'active_supports', (
            SELECT jsonb_agg(jsonb_build_object(
                'rule', s.rule_name || '@' || s.rule_version,
                'activation_generation', s.activation_generation,
                'source_binding', s.source_binding
            ) ORDER BY s.rule_name, s.rule_version, s.activation_generation,
                       s.activation_revision)
            FROM pgreact.support_history s
            WHERE s.relation_version_id = target_relation
              AND s.semantic_key = target_key AND s.active
        )
    ) INTO result
    FROM pgreact.derived_facts f
    WHERE f.relation_version_id = target_relation
      AND f.semantic_key = target_key;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact.reconcile_derived_relation(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
    run_id bigint;
    diagnostic_order integer := 0;
    expected record;
    actual record;
    projected jsonb;
    canonical bytea;
    expected_fact_id uuid;
    expected_support_id uuid;
    frontier_value bigint;
    support_total bigint;
    expected_fact jsonb;
BEGIN
    relation_row := pgreact_internal.assert_derived_owner(target_relation);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT frontier INTO frontier_value
    FROM pgreact_internal.derived_frontiers
    WHERE relation_version_id = target_relation;
    frontier_value := COALESCE(frontier_value, 1);
    INSERT INTO pgreact_internal.derived_reconciliations (
        relation_version_id, started_at, status, requested_by
    ) VALUES (target_relation, clock_timestamp(), 'RUNNING', session_user)
    RETURNING reconciliation_id INTO run_id;

    FOR actual IN
        SELECT s.*
        FROM pgreact_internal.derived_supports s
        LEFT JOIN pgreact_internal.activation_state a
          ON a.rule_version_id = s.rule_version_id
         AND a.activation_id = s.activation_id
         AND a.active
         AND a.generation = s.activation_generation
         AND a.revision = s.activation_revision
         AND a.current_bindings - '__pgt_row_id' = s.source_binding
        LEFT JOIN pgreact_internal.rule_versions v
          ON v.rule_version_id = s.rule_version_id AND v.state = 'ACTIVE'
        WHERE s.relation_version_id = target_relation AND s.active
          AND (a.activation_id IS NULL OR v.rule_version_id IS NULL)
        ORDER BY s.support_id
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
            run_id, diagnostic_order,
            CASE WHEN EXISTS (
                SELECT 1 FROM pgreact_internal.activation_state a
                WHERE a.rule_version_id = actual.rule_version_id
                  AND a.activation_id = actual.activation_id
            ) THEN 'STALE_SUPPORT' ELSE 'EXTRA_SUPPORT' END,
            actual.support_id::text,
            jsonb_build_object('rule_version_id', actual.rule_version_id,
                               'activation_id', actual.activation_id)
        );
        UPDATE pgreact_internal.derived_supports
        SET active = false, last_frontier = COALESCE(last_frontier, frontier_value),
            invalidated_at = COALESCE(invalidated_at, clock_timestamp())
        WHERE support_id = actual.support_id;
    END LOOP;

    FOR expected IN
        SELECT d.rule_version_id, a.activation_id, a.generation, a.revision,
               a.semantic_key, a.current_bindings
        FROM pgreact_internal.derivation_rule_versions d
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        JOIN pgreact_internal.activation_state a USING (rule_version_id)
        WHERE d.relation_version_id = target_relation
          AND v.state = 'ACTIVE' AND a.active
        ORDER BY d.rule_version_id, a.activation_id
    LOOP
        projected := pgreact_internal.project_derived_fact(
            target_relation, expected.current_bindings - '__pgt_row_id');
        canonical := pgreact_internal.canonical_bigint_v1(expected.semantic_key);
        expected_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(target_relation, canonical));
        expected_support_id := pgreact_internal.activation_uuid(sha256(convert_to(
            expected.rule_version_id::text || ':' || expected.activation_id::text || ':' ||
            expected.generation || ':' || expected.revision || ':' || expected_fact_id::text,
            'UTF8')));
        SELECT * INTO actual FROM pgreact_internal.derived_supports
        WHERE support_id = expected_support_id;
        IF NOT FOUND THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'MISSING_SUPPORT', expected_support_id::text,
                jsonb_build_object('rule_version_id', expected.rule_version_id,
                                   'activation_id', expected.activation_id)
            );
            INSERT INTO pgreact_internal.derived_supports (
                support_id, relation_version_id, rule_version_id, activation_id,
                activation_generation, activation_revision, semantic_key, fact_id,
                fact, source_binding, active, first_frontier
            ) VALUES (
                expected_support_id, target_relation, expected.rule_version_id,
                expected.activation_id, expected.generation, expected.revision,
                expected.semantic_key, expected_fact_id, projected,
                expected.current_bindings - '__pgt_row_id', true, frontier_value
            );
        ELSIF NOT actual.active OR actual.fact IS DISTINCT FROM projected
              OR actual.source_binding IS DISTINCT FROM expected.current_bindings - '__pgt_row_id'
              OR actual.semantic_key IS DISTINCT FROM expected.semantic_key THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'STALE_SUPPORT', expected_support_id::text,
                jsonb_build_object('rule_version_id', expected.rule_version_id,
                                   'activation_id', expected.activation_id)
            );
            UPDATE pgreact_internal.derived_supports SET
                semantic_key = expected.semantic_key, fact_id = expected_fact_id,
                fact = projected, source_binding = expected.current_bindings - '__pgt_row_id',
                active = true, last_frontier = NULL, invalidated_at = NULL
            WHERE support_id = expected_support_id;
        END IF;
    END LOOP;

    FOR actual IN
        SELECT f.* FROM pgreact_internal.derived_facts f
        WHERE f.relation_version_id = target_relation ORDER BY f.semantic_key
    LOOP
        SELECT count(*), min(s.fact::text)::jsonb
        INTO support_total, expected_fact
        FROM pgreact_internal.derived_supports s
        WHERE s.relation_version_id = target_relation
          AND s.semantic_key = actual.semantic_key AND s.active;
        IF support_total = 0 THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'EXTRA_FACT', actual.fact_id::text,
                jsonb_build_object('semantic_key', actual.semantic_key)
            );
            DELETE FROM pgreact_internal.derived_facts
            WHERE relation_version_id = target_relation AND fact_id = actual.fact_id;
        ELSIF actual.support_count IS DISTINCT FROM support_total
              OR actual.fact IS DISTINCT FROM expected_fact THEN
            diagnostic_order := diagnostic_order + 1;
            INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
                run_id, diagnostic_order, 'STALE_FACT', actual.fact_id::text,
                jsonb_build_object('semantic_key', actual.semantic_key,
                                   'support_count', support_total)
            );
            UPDATE pgreact_internal.derived_facts SET
                fact = expected_fact, support_count = support_total,
                last_changed_at = clock_timestamp()
            WHERE relation_version_id = target_relation AND fact_id = actual.fact_id;
        END IF;
    END LOOP;

    FOR expected IN
        SELECT s.semantic_key, min(s.fact::text)::jsonb AS fact, count(*) AS support_count
        FROM pgreact_internal.derived_supports s
        WHERE s.relation_version_id = target_relation AND s.active
        GROUP BY s.semantic_key
        HAVING NOT EXISTS (
            SELECT 1 FROM pgreact_internal.derived_facts f
            WHERE f.relation_version_id = target_relation
              AND f.semantic_key = s.semantic_key
        )
        ORDER BY s.semantic_key
    LOOP
        canonical := pgreact_internal.canonical_bigint_v1(expected.semantic_key);
        expected_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(target_relation, canonical));
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derived_repair_diagnostics VALUES (
            run_id, diagnostic_order, 'MISSING_FACT', expected_fact_id::text,
            jsonb_build_object('semantic_key', expected.semantic_key,
                               'support_count', expected.support_count)
        );
        INSERT INTO pgreact_internal.derived_facts (
            relation_version_id, fact_id, semantic_key, fact, support_count,
            first_frontier, last_frontier
        ) VALUES (
            target_relation, expected_fact_id, expected.semantic_key, expected.fact,
            expected.support_count, frontier_value, frontier_value
        );
    END LOOP;

    UPDATE pgreact_internal.derived_reconciliations
    SET completed_at = clock_timestamp(), repairs = diagnostic_order,
        status = 'COMPLETED'
    WHERE reconciliation_id = run_id;
    RETURN diagnostic_order;
END
$$;

CREATE FUNCTION pgreact_internal.replace_derived_relation(
    target_relation uuid,
    row_type regtype,
    key_columns name[],
    relation_version integer
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    prior pgreact_internal.derived_relation_versions%ROWTYPE;
    next_version uuid := gen_random_uuid();
    type_row record;
BEGIN
    prior := pgreact_internal.assert_derived_owner(target_relation);
    IF prior.state <> 'ACTIVE' THEN
        RAISE EXCEPTION 'only an active derived relation can be replaced';
    END IF;
    SELECT t.typowner, format('%I.%I', n.nspname, t.typname) AS identity
    INTO STRICT type_row
    FROM pg_catalog.pg_type t
    JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    WHERE t.oid = row_type AND t.typtype = 'c';
    IF type_row.typowner <> prior.owner_oid
       OR cardinality(key_columns) IS DISTINCT FROM 1
       OR key_columns[1] IS DISTINCT FROM prior.key_column
       OR pgreact_internal.composite_type_signature(row_type) IS DISTINCT FROM prior.row_signature THEN
        RAISE EXCEPTION 'M7 derived relation replacement must preserve the exact row type and key';
    END IF;
    IF relation_version <= prior.version THEN
        RAISE EXCEPTION 'derived relation replacement version must increase beyond %', prior.version;
    END IF;
    UPDATE pgreact_internal.derived_relation_versions SET state = 'REMOVED'
    WHERE relation_version_id = target_relation;
    INSERT INTO pgreact_internal.derived_relation_versions (
        relation_version_id, relation_id, version, owner_oid, row_type_oid,
        row_type_name, row_signature, key_column, public_view_oid,
        public_view_name, state
    ) VALUES (
        next_version, prior.relation_id, relation_version, prior.owner_oid,
        row_type, type_row.identity, prior.row_signature, prior.key_column,
        prior.public_view_oid, prior.public_view_name, 'ACTIVE'
    );
    EXECUTE format(
        'CREATE OR REPLACE VIEW %s WITH (security_barrier=true) AS '
        'SELECT (pg_catalog.jsonb_populate_record(NULL::%s, f.fact)).* '
        'FROM pgreact_internal.derived_facts f WHERE f.relation_version_id = %L::uuid',
        prior.public_view_name, type_row.identity, next_version
    );
    RETURN next_version;
END
$$;

CREATE FUNCTION pgreact_internal.remove_derived_relation(target_relation uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE relation_row pgreact_internal.derived_relation_versions%ROWTYPE;
BEGIN
    relation_row := pgreact_internal.assert_derived_owner(target_relation);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derivation_rule_versions d
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        WHERE d.relation_version_id = target_relation AND v.state <> 'REMOVED'
    ) THEN
        RAISE EXCEPTION 'cannot remove derived relation % with active producers',
            relation_row.public_view_name;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rule_versions v
        WHERE v.rule_kind = 'STANDARD' AND v.state <> 'REMOVED'
          AND EXISTS (
              WITH RECURSIVE dependencies(relid) AS (
                  SELECT v.source_view_oid
                  UNION
                  SELECT d.refobjid
                  FROM dependencies parent
                  JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
                  JOIN pg_catalog.pg_depend d
                    ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                   AND d.refclassid = 'pg_class'::regclass
                  JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
                  WHERE c.relkind IN ('v', 'm')
              )
              SELECT 1 FROM dependencies WHERE relid = relation_row.public_view_oid
          )
    ) THEN
        RAISE EXCEPTION 'cannot remove derived relation % with active consumers',
            relation_row.public_view_name;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derived_facts
        WHERE relation_version_id = target_relation
    ) THEN
        RAISE EXCEPTION 'cannot remove derived relation % while current facts remain',
            relation_row.public_view_name;
    END IF;
    EXECUTE format(
        'CREATE OR REPLACE VIEW %s WITH (security_barrier=true) AS '
        'SELECT (pg_catalog.jsonb_populate_record(NULL::%s, f.fact)).* '
        'FROM pgreact_internal.derived_facts f '
        'WHERE f.relation_version_id = %L::uuid AND false',
        relation_row.public_view_name, relation_row.row_type_name, target_relation
    );
    UPDATE pgreact_internal.derived_relation_versions
    SET state = 'REMOVED'
    WHERE relation_version_id = target_relation;
END
$$;

CREATE FUNCTION pgreact.remove_derived_relation(target_relation uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    PERFORM pgreact_internal.remove_derived_relation(target_relation);
END
$$;

CREATE TABLE pgreact_internal.rule_pack_derived_relations (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    relation_name text NOT NULL,
    relation_version_id uuid NOT NULL REFERENCES pgreact_internal.derived_relation_versions,
    PRIMARY KEY (pack_version_id, relation_name)
);

CREATE TABLE pgreact_internal.rule_pack_derivations (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    rule_name text NOT NULL,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_versions,
    target_relation text NOT NULL,
    dependencies text[] NOT NULL,
    PRIMARY KEY (pack_version_id, rule_name)
);

CREATE TABLE pgreact_internal.rule_pack_derived_actions (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    action_order integer NOT NULL CHECK (action_order > 0),
    object_kind text NOT NULL CHECK (object_kind IN ('DERIVED_RELATION', 'DERIVATION')),
    action text NOT NULL CHECK (action IN ('ADD', 'KEEP', 'REPLACE', 'REMOVE')),
    object_name text NOT NULL,
    old_version_id uuid,
    new_version_id uuid,
    details jsonb NOT NULL,
    PRIMARY KEY (pack_version_id, action_order)
);

ALTER FUNCTION pgreact.validate_pack(jsonb, jsonb) RENAME TO validate_pack_v1;
ALTER FUNCTION pgreact.preview_pack(jsonb, jsonb) RENAME TO preview_pack_v1;
ALTER FUNCTION pgreact.deploy_pack(jsonb, text, jsonb) RENAME TO deploy_pack_v1;
ALTER FUNCTION pgreact.explain_pack(text) RENAME TO explain_pack_v1;
ALTER FUNCTION pgreact.validate_pack_v1(jsonb, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.preview_pack_v1(jsonb, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.deploy_pack_v1(jsonb, text, jsonb) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.explain_pack_v1(text) SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact_internal.m7_pack_definition(definition jsonb)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_set(
        $1 - 'derived_relations' - 'derivations'
           - 'remove_derivations' - 'remove_derived_relations',
        '{rules}',
        COALESCE((
            SELECT jsonb_agg(jsonb_set(
                rule_item,
                '{depends_on}',
                COALESCE((
                    SELECT jsonb_agg(dependency ORDER BY dependency #>> '{}')
                    FROM jsonb_array_elements(COALESCE(rule_item -> 'depends_on', '[]'::jsonb)) dependency
                    WHERE EXISTS (
                        SELECT 1 FROM jsonb_array_elements($1 -> 'rules') ordinary
                        WHERE ordinary ->> 'name' = dependency #>> '{}'
                    )
                ), '[]'::jsonb)
            ) ORDER BY ordinal)
            FROM jsonb_array_elements($1 -> 'rules') WITH ORDINALITY r(rule_item, ordinal)
        ), '[]'::jsonb),
        true
    )
$$;

CREATE FUNCTION pgreact_internal.m7_pack_plan_digest(definition jsonb, mappings jsonb)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    material text;
    item record;
    mapped_identity text;
    object_oid oid;
    state_material text;
BEGIN
    material := definition::text || E'\n' || mappings::text || E'\nowner:' || session_user ||
        E'\nv1:' || pgreact_internal.pack_plan_digest(
            pgreact_internal.m7_pack_definition(definition), mappings);
    FOR item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'derived_relations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        mapped_identity := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        SELECT concat_ws(':', v.relation_version_id, v.version, v.state,
                         encode(v.row_signature, 'hex'), v.key_column, v.public_view_oid)
        INTO state_material
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_identity AND v.state = 'ACTIVE';
        object_oid := to_regtype(pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'row_type'))::oid;
        material := material || format(E'\nrelation:%s:%s:%s:%s', item.ordinal,
            mapped_identity, object_oid,
            COALESCE(state_material, '<add>'));
    END LOOP;
    FOR item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'derivations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        mapped_identity := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        object_oid := to_regclass(mapped_identity);
        SELECT concat_ws(':', v.rule_version_id, d.version, v.state, v.match_name,
                         d.relation_version_id,
                         encode(v.source_definition_digest, 'hex'),
                         (SELECT count(*) FROM pgreact_internal.derived_supports s
                          WHERE s.rule_version_id = v.rule_version_id AND s.active))
        INTO state_material
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        material := material || format(E'\nderivation:%s:%s:%s:%s:%s', item.ordinal,
            item.value ->> 'name', object_oid,
            CASE WHEN object_oid IS NULL THEN '<missing>'
                 ELSE encode(sha256(convert_to(pg_get_viewdef(object_oid, true), 'UTF8')), 'hex') END,
            COALESCE(state_material, '<add>'));
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
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
    diagnostic record;
    unknown_key text;
    duplicate_name text;
    item record;
    relation_item jsonb;
    mapped_name text;
    mapped_type text;
    mapped_source text;
    row_type_oid oid;
    source_oid oid;
    active_relation record;
    active_rule record;
    target_item jsonb;
    target_type_oid oid;
    target_key name;
    attribute record;
    dependency text;
    prior_pack uuid;
    has_error boolean := false;
BEGIN
    IF NOT (definition ? 'derived_relations' OR definition ? 'derivations'
            OR definition ? 'remove_derivations' OR definition ? 'remove_derived_relations') THEN
        RETURN QUERY SELECT * FROM pgreact_internal.validate_pack_v1(definition, mappings);
        RETURN;
    END IF;
    SELECT key INTO unknown_key FROM jsonb_object_keys(definition) key
    WHERE key <> ALL (ARRAY[
        'format_version', 'pack', 'version', 'owner', 'rules', 'remove',
        'derived_relations', 'derivations', 'remove_derivations',
        'remove_derived_relations'
    ]) ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        RETURN QUERY SELECT 2, 'PACK_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'pack definition contains an unknown field',
            'Remove the field or use a newer format.', '{}'::jsonb;
        RETURN;
    END IF;
    IF definition -> 'format_version' IS DISTINCT FROM '1'::jsonb
       OR pg_catalog.jsonb_typeof(definition -> 'derived_relations') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'derivations') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'remove_derivations') IS DISTINCT FROM 'array'
       OR pg_catalog.jsonb_typeof(definition -> 'remove_derived_relations') IS DISTINCT FROM 'array' THEN
        RETURN QUERY SELECT 2, 'PACK_COLLECTION_INVALID', 'ERROR', '<pack>',
            'M7 packs use format_version 1 and four derived-object arrays',
            'Provide derived_relations, derivations, remove_derivations, and remove_derived_relations arrays.',
            '{}'::jsonb;
        RETURN;
    END IF;
    FOR diagnostic IN
        SELECT * FROM pgreact_internal.validate_pack_v1(
            pgreact_internal.m7_pack_definition(definition), mappings)
    LOOP
        RETURN QUERY SELECT 2, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint, diagnostic.details;
        has_error := has_error OR diagnostic.severity = 'ERROR';
    END LOOP;
    IF has_error THEN RETURN; END IF;

    SELECT name INTO duplicate_name FROM (
        SELECT value ->> 'name' AS name
        FROM jsonb_array_elements(definition -> 'derived_relations')
        UNION ALL
        SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'derivations')
        UNION ALL
        SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'rules')
    ) names GROUP BY name HAVING count(*) > 1 ORDER BY name LIMIT 1;
    IF duplicate_name IS NOT NULL THEN
        RETURN QUERY SELECT 2, 'OBJECT_NAME_DUPLICATE', 'ERROR', duplicate_name,
            'portable object names must be unique across the pack',
            'Keep one relation, derivation, or ordinary rule with each name.', '{}'::jsonb;
        RETURN;
    END IF;

    FOR item IN
        SELECT value, ordinal FROM jsonb_array_elements(definition -> 'derived_relations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        SELECT key INTO unknown_key FROM jsonb_object_keys(item.value) key
        WHERE key <> ALL (ARRAY['name', 'row_type', 'key', 'version'])
        ORDER BY key LIMIT 1;
        IF unknown_key IS NOT NULL OR item.value ->> 'name' IS NULL
           OR item.value ->> 'row_type' IS NULL OR item.value ->> 'key' IS NULL
           OR (item.value ->> 'version')::integer < 1 THEN
            RETURN QUERY SELECT 2, 'DERIVED_RELATION_INVALID', 'ERROR',
                COALESCE(item.value ->> 'name', item.ordinal::text),
                'derived relation definitions require only name, row_type, key, and positive version',
                'Use exact portable identities and one bigint key.', '{}'::jsonb;
            RETURN;
        END IF;
        mapped_name := pgreact_internal.pack_mapping(mappings, 'objects', item.value ->> 'name');
        mapped_type := pgreact_internal.pack_mapping(mappings, 'objects', item.value ->> 'row_type');
        row_type_oid := to_regtype(mapped_type)::oid;
        IF row_type_oid IS NULL OR NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_type t
            WHERE t.oid = row_type_oid AND t.typtype = 'c'
              AND t.typowner = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
        ) OR NOT EXISTS (
            SELECT 1 FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
            WHERE t.oid = row_type_oid AND a.attname = (item.value ->> 'key')::name
              AND a.atttypid = 'bigint'::regtype AND a.attnum > 0 AND NOT a.attisdropped
        ) THEN
            RETURN QUERY SELECT 2, 'DERIVED_RELATION_TYPE_UNSAFE', 'ERROR', item.value ->> 'name',
                'mapped row type must be caller-owned and contain the declared bigint key',
                'Correct the object mapping or row type.',
                jsonb_build_object('mapped_name', mapped_name, 'mapped_row_type', mapped_type);
            RETURN;
        END IF;
        SELECT v.* INTO active_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        IF FOUND AND ((item.value ->> 'version')::integer < active_relation.version
           OR active_relation.key_column IS DISTINCT FROM (item.value ->> 'key')::name
           OR active_relation.row_signature IS DISTINCT FROM
              pgreact_internal.composite_type_signature(row_type_oid)) THEN
            RETURN QUERY SELECT 2, 'DERIVED_RELATION_REPLACEMENT_UNSAFE', 'ERROR', item.value ->> 'name',
                'M7 relation replacement must increase or keep the version and preserve row type and key',
                'Use a higher compatible version; defer schema evolution to a later milestone.', '{}'::jsonb;
            RETURN;
        END IF;
    END LOOP;

    FOR item IN
        SELECT value, ordinal FROM jsonb_array_elements(definition -> 'derivations')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        SELECT key INTO unknown_key FROM jsonb_object_keys(item.value) key
        WHERE key <> ALL (ARRAY['name', 'definition', 'key', 'target', 'version',
                               'bootstrap_policy', 'depends_on'])
        ORDER BY key LIMIT 1;
        target_item := NULL;
        SELECT value INTO target_item
        FROM jsonb_array_elements(definition -> 'derived_relations') r(value)
        WHERE value ->> 'name' = item.value ->> 'target';
        IF unknown_key IS NOT NULL OR item.value ->> 'name' IS NULL
           OR item.value ->> 'definition' IS NULL OR item.value ->> 'key' IS NULL
           OR target_item IS NULL OR (item.value ->> 'version')::integer < 1
           OR COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT')
              NOT IN ('SEED_CURRENT', 'REQUIRE_EMPTY') THEN
            RETURN QUERY SELECT 2, 'DERIVATION_INVALID', 'ERROR',
                COALESCE(item.value ->> 'name', item.ordinal::text),
                'derivations require name, source definition, key, declared target, and positive version',
                'Declare the target relation in the same pack and use no consequence fields.', '{}'::jsonb;
            RETURN;
        END IF;
        mapped_source := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        source_oid := to_regclass(mapped_source);
        target_type_oid := to_regtype(pgreact_internal.pack_mapping(
            mappings, 'objects', target_item ->> 'row_type'))::oid;
        target_key := (target_item ->> 'key')::name;
        SELECT * INTO diagnostic FROM pgreact.validate_rule(
            source_oid::regclass, ARRAY[(item.value ->> 'key')::name], NULL) AS d
        WHERE d.severity = 'ERROR' ORDER BY d.code LIMIT 1;
        IF source_oid IS NULL OR FOUND OR pgreact_internal.source_reads_derived(source_oid)
           OR (item.value ->> 'key')::name IS DISTINCT FROM target_key THEN
            RETURN QUERY SELECT 2,
                CASE WHEN pgreact_internal.source_reads_derived(source_oid)
                     THEN 'DERIVATION_CHAIN_UNSUPPORTED' ELSE 'DERIVATION_SOURCE_INVALID' END,
                'ERROR', item.value ->> 'name',
                'derivation source or key violates the non-recursive target contract',
                'Use a caller-owned authoritative source view that projects the target key.',
                jsonb_build_object('mapped_source', mapped_source);
            RETURN;
        END IF;
        FOR attribute IN
            SELECT a.attname, a.atttypid
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
            WHERE t.oid = target_type_oid AND a.attnum > 0 AND NOT a.attisdropped
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = source_oid AND a.attname = attribute.attname
                  AND a.atttypid = attribute.atttypid
                  AND a.attnum > 0 AND NOT a.attisdropped
            ) THEN
                RETURN QUERY SELECT 2, 'DERIVATION_FACT_SHAPE', 'ERROR', item.value ->> 'name',
                    'derivation source does not project the complete target row type',
                    'Project every target attribute with its exact PostgreSQL type.',
                    jsonb_build_object('column', attribute.attname);
                RETURN;
            END IF;
        END LOOP;
        SELECT v.rule_kind, v.rule_version_id, d.version,
               d.relation_version_id, v.source_view_name, v.source_definition
        INTO active_rule
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        LEFT JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        IF FOUND AND (active_rule.rule_kind <> 'DERIVATION'
           OR (item.value ->> 'version')::integer < active_rule.version) THEN
            RETURN QUERY SELECT 2, 'DERIVATION_REPLACEMENT_UNSAFE', 'ERROR', item.value ->> 'name',
                'an active rule has an incompatible kind or newer immutable version',
                'Use a new name or increase the derivation version.', '{}'::jsonb;
            RETURN;
        END IF;
        FOR dependency IN
            SELECT value #>> '{}'
            FROM jsonb_array_elements(COALESCE(item.value -> 'depends_on', '[]'::jsonb)) value
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM (
                    SELECT value ->> 'name' AS name FROM jsonb_array_elements(definition -> 'derived_relations')
                    UNION ALL SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'derivations')
                    UNION ALL SELECT value ->> 'name' FROM jsonb_array_elements(definition -> 'rules')
                ) names WHERE name = dependency
            ) THEN
                RETURN QUERY SELECT 2, 'DEPENDENCY_MISSING', 'ERROR', dependency,
                    'derivation dependency is not declared in this pack version',
                    'Declare every dependency or remove the edge.', '{}'::jsonb;
                RETURN;
            END IF;
        END LOOP;
    END LOOP;

    SELECT v.pack_version_id INTO prior_pack
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = definition ->> 'pack' AND v.state = 'ACTIVE';
    IF prior_pack IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.rule_pack_derivations old
        WHERE old.pack_version_id = prior_pack
          AND NOT (definition -> 'derivations' @>
                   jsonb_build_array(jsonb_build_object('name', old.rule_name)))
          AND NOT (definition -> 'remove_derivations' @>
                   jsonb_build_array(jsonb_build_object('name', old.rule_name)))
    ) THEN
        RETURN QUERY SELECT 2, 'DERIVATION_REMOVAL_IMPLICIT', 'ERROR', '<pack>',
            'every omitted derivation requires an explicit removal',
            'List it in remove_derivations.', '{}'::jsonb;
        RETURN;
    END IF;
    IF prior_pack IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.rule_pack_derived_relations old
        WHERE old.pack_version_id = prior_pack
          AND NOT (definition -> 'derived_relations' @>
                   jsonb_build_array(jsonb_build_object('name', old.relation_name)))
          AND NOT (definition -> 'remove_derived_relations' @>
                   jsonb_build_array(jsonb_build_object('name', old.relation_name)))
    ) THEN
        RETURN QUERY SELECT 2, 'DERIVED_RELATION_REMOVAL_IMPLICIT', 'ERROR', '<pack>',
            'every omitted derived relation requires an explicit removal',
            'List it in remove_derived_relations after removing consumers and producers.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 2, 'OK', 'INFO', definition ->> 'pack',
        'M7 pack is valid',
        'Preview and deploy with the returned immutable plan digest.',
        jsonb_build_object('derived_relations', jsonb_array_length(definition -> 'derived_relations'),
                           'derivations', jsonb_array_length(definition -> 'derivations'));
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
    item record;
    current_row record;
    preview_row record;
    digest text;
    ordinal integer := 0;
    mapped_name text;
    mapped_source text;
    dependency_names text[];
BEGIN
    IF NOT (definition ? 'derived_relations' OR definition ? 'derivations'
            OR definition ? 'remove_derivations' OR definition ? 'remove_derived_relations') THEN
        RETURN QUERY SELECT * FROM pgreact_internal.preview_pack_v1(definition, mappings);
        RETURN;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    digest := pgreact_internal.m7_pack_plan_digest(definition, mappings);
    FOR item IN
        SELECT value, array_ordinal
        FROM jsonb_array_elements(definition -> 'derived_relations')
        WITH ORDINALITY r(value, array_ordinal)
    LOOP
        ordinal := ordinal + 1;
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        SELECT v.relation_version_id, v.version, v.state INTO current_row
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_row.relation_version_id IS NULL THEN 'ADD'
                       WHEN current_row.version = (item.value ->> 'version')::integer THEN 'KEEP'
                       ELSE 'REPLACE' END;
        rule_name := item.value ->> 'name';
        dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVED_RELATION',
            'public_view', mapped_name,
            'row_type', pgreact_internal.pack_mapping(
                mappings, 'objects', item.value ->> 'row_type'));
        lifecycle_risks := CASE WHEN action = 'REPLACE'
            THEN jsonb_build_array('all producers must move to the new immutable relation version atomically')
            ELSE '[]'::jsonb END;
        details := jsonb_build_object(
            'prior_relation_version_id', current_row.relation_version_id,
            'prior_version', current_row.version,
            'next_version', (item.value ->> 'version')::integer);
        RETURN NEXT;
    END LOOP;
    FOR item IN
        SELECT value, array_ordinal
        FROM jsonb_array_elements(definition -> 'derivations')
        WITH ORDINALITY r(value, array_ordinal)
    LOOP
        ordinal := ordinal + 1;
        SELECT v.rule_version_id, d.version, v.state, v.source_view_name
        INTO current_row
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT array_agg(value #>> '{}' ORDER BY dependency_ordinal)::text[]
        INTO dependency_names
        FROM jsonb_array_elements(COALESCE(item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY d(value, dependency_ordinal);
        mapped_source := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_row.rule_version_id IS NULL THEN 'ADD'
                       WHEN current_row.version = (item.value ->> 'version')::integer
                        AND current_row.source_view_name = mapped_source THEN 'KEEP'
                       ELSE 'REPLACE' END;
        rule_name := item.value ->> 'name';
        dependencies := COALESCE(dependency_names, ARRAY[]::text[]);
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION',
            'create', jsonb_build_array('match_relation', 'support_binding'),
            'agenda', false);
        lifecycle_risks := CASE WHEN action = 'REPLACE'
            THEN jsonb_build_array('old supports retract after replacement supports are seeded')
            ELSE jsonb_build_array(COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT') ||
                                   ' may seed current supports') END;
        details := jsonb_build_object(
            'source', item.value ->> 'definition', 'mapped_source', mapped_source,
            'target', item.value ->> 'target',
            'prior_rule_version_id', current_row.rule_version_id,
            'prior_version', current_row.version,
            'next_version', (item.value ->> 'version')::integer);
        RETURN NEXT;
    END LOOP;
    FOR preview_row IN
        SELECT * FROM pgreact_internal.preview_pack_v1(
            pgreact_internal.m7_pack_definition(definition), mappings)
        ORDER BY action_order
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := preview_row.action;
        rule_name := preview_row.rule_name;
        dependencies := preview_row.dependencies;
        generated_object_changes := preview_row.generated_object_changes;
        lifecycle_risks := preview_row.lifecycle_risks;
        details := preview_row.details;
        RETURN NEXT;
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derivations') value
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest; action_order := ordinal; action := 'REMOVE';
        rule_name := item.value ->> 'name'; dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object('object_kind', 'DERIVATION');
        lifecycle_risks := jsonb_build_array('active supports retract before commit');
        details := '{}'::jsonb;
        RETURN NEXT;
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derived_relations') value
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest; action_order := ordinal; action := 'REMOVE';
        rule_name := item.value ->> 'name'; dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object('object_kind', 'DERIVED_RELATION');
        lifecycle_risks := jsonb_build_array('removal requires no active producer, consumer, or fact');
        details := '{}'::jsonb;
        RETURN NEXT;
    END LOOP;
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
    actual_digest text;
    v1_definition jsonb;
    v1_digest text;
    pack_version uuid;
    prior_pack_version uuid;
    item record;
    relation_item record;
    current_relation record;
    target_relation uuid;
    current_rule record;
    next_version uuid;
    prior_version uuid;
    mapped_name text;
    mapped_type text;
    mapped_source text;
    dependency_names text[];
    action_name text;
    action_number integer := 0;
BEGIN
    IF NOT (definition ? 'derived_relations' OR definition ? 'derivations'
            OR definition ? 'remove_derivations' OR definition ? 'remove_derived_relations') THEN
        RETURN pgreact_internal.deploy_pack_v1(definition, expected_plan_digest, mappings);
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    actual_digest := pgreact_internal.m7_pack_plan_digest(definition, mappings);
    IF expected_plan_digest IS DISTINCT FROM actual_digest THEN
        RAISE EXCEPTION 'rule-pack preview is stale'
            USING HINT = 'Run pgreact.preview_pack again after concurrent DDL, support, or deployment changes.',
                  DETAIL = format('expected %s, current %s', expected_plan_digest, actual_digest);
    END IF;
    SELECT v.pack_version_id INTO prior_pack_version
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = definition ->> 'pack' AND v.state = 'ACTIVE';

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derived_relations') value
    LOOP
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        mapped_type := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'row_type');
        SELECT v.relation_version_id, v.version INTO current_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        IF current_relation.relation_version_id IS NULL THEN
            PERFORM pgreact.create_derived_relation(
                mapped_name, to_regtype(mapped_type),
                ARRAY[(item.value ->> 'key')::name],
                (item.value ->> 'version')::integer);
        ELSIF current_relation.version < (item.value ->> 'version')::integer THEN
            PERFORM pgreact_internal.replace_derived_relation(
                current_relation.relation_version_id, to_regtype(mapped_type),
                ARRAY[(item.value ->> 'key')::name],
                (item.value ->> 'version')::integer);
        END IF;
    END LOOP;

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derivations') value
    LOOP
        mapped_source := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'definition');
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'target');
        SELECT v.relation_version_id INTO STRICT target_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        SELECT v.rule_version_id, v.rule_kind, v.source_view_name,
               v.source_definition, d.version, d.relation_version_id
        INTO current_rule
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        LEFT JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        IF current_rule.rule_version_id IS NULL THEN
            PERFORM pgreact.create_derivation_rule(
                item.value ->> 'name', to_regclass(mapped_source),
                ARRAY[(item.value ->> 'key')::name], target_relation,
                (item.value ->> 'version')::integer,
                COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT'));
        ELSIF current_rule.rule_kind <> 'DERIVATION' THEN
            RAISE EXCEPTION 'cannot replace non-derivation rule % with a derivation',
                item.value ->> 'name';
        ELSIF current_rule.version = (item.value ->> 'version')::integer
              AND current_rule.source_view_name = mapped_source
              AND current_rule.source_definition = pg_get_viewdef(to_regclass(mapped_source), true)
              AND current_rule.relation_version_id = target_relation THEN
            NULL;
        ELSIF current_rule.version >= (item.value ->> 'version')::integer THEN
            RAISE EXCEPTION 'immutable derivation version % already exists for %',
                current_rule.version, item.value ->> 'name';
        ELSE
            PERFORM pgreact.replace_derivation_rule(
                current_rule.rule_version_id, to_regclass(mapped_source),
                ARRAY[(item.value ->> 'key')::name],
                (item.value ->> 'version')::integer,
                COALESCE(item.value ->> 'bootstrap_policy', 'SEED_CURRENT'));
        END IF;
    END LOOP;

    v1_definition := pgreact_internal.m7_pack_definition(definition);
    v1_digest := pgreact_internal.pack_plan_digest(v1_definition, mappings);
    PERFORM pgreact_internal.maybe_fail_pack('derived');
    pack_version := pgreact_internal.deploy_pack_v1(v1_definition, v1_digest, mappings);
    UPDATE pgreact_internal.rule_pack_versions SET
        definition = deploy_pack.definition,
        definition_digest = sha256(convert_to(deploy_pack.definition::text, 'UTF8')),
        plan_digest = actual_digest
    WHERE pack_version_id = pack_version;

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derived_relations') value
    LOOP
        action_number := action_number + 1;
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', item.value ->> 'name');
        SELECT v.relation_version_id INTO STRICT next_version
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        SELECT relation_version_id INTO prior_version
        FROM pgreact_internal.rule_pack_derived_relations
        WHERE pack_version_id = prior_pack_version
          AND relation_name = item.value ->> 'name';
        action_name := CASE WHEN prior_version IS NULL THEN 'ADD'
                            WHEN prior_version = next_version THEN 'KEEP'
                            ELSE 'REPLACE' END;
        INSERT INTO pgreact_internal.rule_pack_derived_relations VALUES (
            pack_version, item.value ->> 'name', next_version);
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVED_RELATION', action_name,
            item.value ->> 'name', prior_version, next_version,
            jsonb_build_object('mapped_name', mapped_name,
                               'version', (item.value ->> 'version')::integer));
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'derivations') value
    LOOP
        action_number := action_number + 1;
        SELECT v.rule_version_id INTO STRICT next_version
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        WHERE r.rule_name = item.value ->> 'name' AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        SELECT rule_version_id INTO prior_version
        FROM pgreact_internal.rule_pack_derivations
        WHERE pack_version_id = prior_pack_version
          AND rule_name = item.value ->> 'name';
        SELECT array_agg(value #>> '{}' ORDER BY ordinal)::text[] INTO dependency_names
        FROM jsonb_array_elements(COALESCE(item.value -> 'depends_on', '[]'::jsonb))
        WITH ORDINALITY d(value, ordinal);
        action_name := CASE WHEN prior_version IS NULL THEN 'ADD'
                            WHEN prior_version = next_version THEN 'KEEP'
                            ELSE 'REPLACE' END;
        INSERT INTO pgreact_internal.rule_pack_derivations VALUES (
            pack_version, item.value ->> 'name', next_version,
            item.value ->> 'target', COALESCE(dependency_names, ARRAY[]::text[]));
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVATION', action_name,
            item.value ->> 'name', prior_version, next_version,
            jsonb_build_object('target', item.value ->> 'target',
                               'dependencies', COALESCE(to_jsonb(dependency_names), '[]'::jsonb)));
    END LOOP;

    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derivations') value
    LOOP
        action_number := action_number + 1;
        SELECT rule_version_id INTO STRICT prior_version
        FROM pgreact_internal.rule_pack_derivations
        WHERE pack_version_id = prior_pack_version
          AND rule_name = item.value ->> 'name';
        PERFORM pgreact_internal.retire_derivation_rule(prior_version);
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVATION', 'REMOVE',
            item.value ->> 'name', prior_version, NULL, '{}'::jsonb);
    END LOOP;
    FOR item IN
        SELECT value FROM jsonb_array_elements(definition -> 'remove_derived_relations') value
    LOOP
        action_number := action_number + 1;
        SELECT relation_version_id INTO STRICT prior_version
        FROM pgreact_internal.rule_pack_derived_relations
        WHERE pack_version_id = prior_pack_version
          AND relation_name = item.value ->> 'name';
        PERFORM pgreact_internal.remove_derived_relation(prior_version);
        INSERT INTO pgreact_internal.rule_pack_derived_actions VALUES (
            pack_version, action_number, 'DERIVED_RELATION', 'REMOVE',
            item.value ->> 'name', prior_version, NULL, '{}'::jsonb);
    END LOOP;
    RETURN pack_version;
END
$$;

CREATE OR REPLACE FUNCTION pgreact.pack_history(target_pack_name text DEFAULT NULL)
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
           encode(v.definition_digest, 'hex'), v.plan_digest,
           v.deployed_at, v.deployed_by,
           COALESCE((
               SELECT jsonb_agg(action ORDER BY phase, action_order, object_name)
               FROM (
                   SELECT 2 AS phase, a.action_order, a.rule_name AS object_name,
                          jsonb_build_object(
                              'order', a.action_order, 'action', a.action,
                              'rule', a.rule_name,
                              'old_rule_version_id', a.old_rule_version_id,
                              'new_rule_version_id', a.new_rule_version_id,
                              'old_work_policy', a.old_work_policy,
                              'details', a.details) AS action
                   FROM pgreact_internal.rule_pack_actions a
                   WHERE a.pack_version_id = v.pack_version_id
                   UNION ALL
                   SELECT CASE WHEN a.action = 'REMOVE' THEN 3
                               WHEN a.object_kind = 'DERIVED_RELATION' THEN 0 ELSE 1 END,
                          a.action_order, a.object_name,
                          jsonb_build_object(
                              'order', a.action_order, 'action', a.action,
                              'rule', a.object_name,
                              'old_rule_version_id', a.old_version_id,
                              'new_rule_version_id', a.new_version_id,
                              'old_work_policy', NULL,
                              'details', a.details || jsonb_build_object(
                                  'object_kind', a.object_kind))
                   FROM pgreact_internal.rule_pack_derived_actions a
                   WHERE a.pack_version_id = v.pack_version_id
               ) combined
           ), '[]'::jsonb)
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND ($1 IS NULL OR p.pack_name = $1)
    ORDER BY p.pack_name, v.deployed_at
$$;

CREATE FUNCTION pgreact.explain_pack(target_pack_name text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    base jsonb;
    active_version uuid;
BEGIN
    base := pgreact_internal.explain_pack_v1(target_pack_name);
    SELECT v.pack_version_id INTO active_version
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = target_pack_name
      AND p.owner_oid = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
      AND v.state = 'ACTIVE';
    IF active_version IS NULL THEN RETURN base; END IF;
    RETURN base || jsonb_build_object(
        'derived_relations', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'name', m.relation_name, 'relation_version_id', m.relation_version_id,
                'version', v.version, 'state', v.state,
                'public_view', v.public_view_name
            ) ORDER BY m.relation_name)
            FROM pgreact_internal.rule_pack_derived_relations m
            JOIN pgreact_internal.derived_relation_versions v USING (relation_version_id)
            WHERE m.pack_version_id = active_version
        ), '[]'::jsonb),
        'derivations', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'name', m.rule_name, 'rule_version_id', m.rule_version_id,
                'version', d.version, 'state', v.state,
                'target', m.target_relation, 'dependencies', m.dependencies,
                'active_supports', (SELECT count(*)
                    FROM pgreact_internal.derived_supports s
                    WHERE s.rule_version_id = m.rule_version_id AND s.active)
            ) ORDER BY m.rule_name)
            FROM pgreact_internal.rule_pack_derivations m
            JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
            JOIN pgreact_internal.rule_versions v USING (rule_version_id)
            WHERE m.pack_version_id = active_version
        ), '[]'::jsonb)
    );
END
$$;

CREATE OR REPLACE FUNCTION pgreact.health_check()
RETURNS TABLE(code text, severity text, object_identity text, message text, hint text)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
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
 UNION ALL SELECT 'DERIVED_FACT_INVALID', 'ERROR',
   f.relation_version_id::text || ':' || f.semantic_key,
   'derived fact support count or payload differs from active supports',
   'Run pgreact.reconcile_derived_relation for the affected relation version.'
 FROM pgreact_internal.derived_facts f
 LEFT JOIN LATERAL (
   SELECT count(*) AS support_count, count(DISTINCT s.fact::text) AS fact_count,
          min(s.fact::text)::jsonb AS fact
   FROM pgreact_internal.derived_supports s
   WHERE s.relation_version_id = f.relation_version_id
     AND s.semantic_key = f.semantic_key AND s.active
 ) expected ON true
 WHERE expected.support_count = 0 OR expected.fact_count <> 1
    OR expected.support_count <> f.support_count OR expected.fact IS DISTINCT FROM f.fact
 UNION ALL SELECT 'DERIVED_FACT_MISSING', 'ERROR',
   s.relation_version_id::text || ':' || s.semantic_key,
   'active supports have no current derived fact',
   'Run pgreact.reconcile_derived_relation for the affected relation version.'
 FROM pgreact_internal.derived_supports s
 WHERE s.active AND NOT EXISTS (
   SELECT 1 FROM pgreact_internal.derived_facts f
   WHERE f.relation_version_id = s.relation_version_id
     AND f.semantic_key = s.semantic_key
 )
 GROUP BY s.relation_version_id, s.semantic_key
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M7 non-recursive maintained derived knowledge with durable supports and provenance';
-- M8 monotone recursive derivation.  M7 derivations remain unchanged unless
-- they are deployed as members of an explicit derivation program.

CREATE FUNCTION pgreact_internal.view_key_is_direct(
    view_oid oid,
    key_attno smallint
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'view_key_is_direct_wrapper'
LANGUAGE C STABLE STRICT;

CREATE FUNCTION pgreact_internal.view_key_is_direct_from(
    view_oid oid,
    key_attno smallint,
    required_view_oid oid,
    required_attno smallint
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'view_key_is_direct_from_wrapper'
LANGUAGE C STABLE STRICT;

CREATE FUNCTION pgreact_internal.view_key_uses_operator(
    view_oid oid,
    key_attno smallint
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'view_key_uses_operator_wrapper'
LANGUAGE C STABLE STRICT;

CREATE TABLE pgreact_internal.derivation_programs (
    program_id uuid PRIMARY KEY,
    program_name text NOT NULL UNIQUE,
    owner_oid oid NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE pgreact_internal.derivation_program_versions (
    program_version_id uuid PRIMARY KEY,
    program_id uuid NOT NULL REFERENCES pgreact_internal.derivation_programs,
    pack_version_id uuid REFERENCES pgreact_internal.rule_pack_versions,
    version integer NOT NULL CHECK (version > 0),
    owner_oid oid NOT NULL,
    definition jsonb NOT NULL,
    definition_digest bytea NOT NULL,
    max_iterations integer NOT NULL CHECK (max_iterations > 0),
    max_facts bigint NOT NULL CHECK (max_facts > 0),
    frontier bigint NOT NULL DEFAULT 0 CHECK (frontier >= 0),
    state text NOT NULL CHECK (state IN ('ACTIVE', 'REMOVED')),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (program_id, version)
);

CREATE UNIQUE INDEX derivation_program_one_active_version
    ON pgreact_internal.derivation_program_versions (program_id)
    WHERE state = 'ACTIVE';

CREATE TABLE pgreact_internal.derivation_program_components (
    program_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_program_versions,
    component_id uuid NOT NULL,
    component_order integer NOT NULL CHECK (component_order > 0),
    cyclic boolean NOT NULL,
    rule_names text[] NOT NULL,
    target_relations uuid[] NOT NULL,
    PRIMARY KEY (program_version_id, component_id),
    UNIQUE (program_version_id, component_order)
);

CREATE TABLE pgreact_internal.derivation_program_rules (
    program_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_program_versions,
    rule_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_rule_versions,
    rule_name text NOT NULL,
    rule_order integer NOT NULL CHECK (rule_order > 0),
    component_id uuid NOT NULL,
    source_view_oid oid NOT NULL,
    source_view_name text NOT NULL,
    source_definition text NOT NULL,
    source_definition_digest bytea NOT NULL,
    target_relation_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derived_relation_versions,
    PRIMARY KEY (program_version_id, rule_version_id),
    UNIQUE (program_version_id, rule_name),
    FOREIGN KEY (program_version_id, component_id)
        REFERENCES pgreact_internal.derivation_program_components
);

CREATE TABLE pgreact_internal.derivation_program_inputs (
    program_version_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    input_order integer NOT NULL CHECK (input_order > 0),
    relation_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derived_relation_versions,
    key_column name NOT NULL,
    PRIMARY KEY (program_version_id, rule_version_id, input_order),
    UNIQUE (program_version_id, rule_version_id, relation_version_id),
    FOREIGN KEY (program_version_id, rule_version_id)
        REFERENCES pgreact_internal.derivation_program_rules
);

CREATE TABLE pgreact_internal.derivation_program_component_frontiers (
    program_version_id uuid NOT NULL,
    component_id uuid NOT NULL,
    frontier bigint NOT NULL CHECK (frontier > 0),
    iterations integer NOT NULL CHECK (iterations > 0),
    fact_count bigint NOT NULL CHECK (fact_count >= 0),
    support_count bigint NOT NULL CHECK (support_count >= 0),
    fingerprint bytea NOT NULL,
    committed_at timestamptz NOT NULL,
    PRIMARY KEY (program_version_id, component_id),
    FOREIGN KEY (program_version_id, component_id)
        REFERENCES pgreact_internal.derivation_program_components
);

CREATE TABLE pgreact_internal.derivation_program_runs (
    run_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    program_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_program_versions,
    started_at timestamptz NOT NULL,
    completed_at timestamptz,
    prior_frontier bigint NOT NULL,
    committed_frontier bigint,
    iterations integer,
    fact_count bigint,
    support_count bigint,
    status text NOT NULL CHECK (status IN ('RUNNING', 'COMPLETED', 'NOOP', 'FAILED')),
    error_sqlstate text,
    error_message text,
    error_detail text,
    error_hint text,
    requested_by name NOT NULL
);

CREATE TABLE pgreact_internal.derivation_program_iterations (
    run_id bigint NOT NULL REFERENCES pgreact_internal.derivation_program_runs,
    program_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_program_versions,
    component_id uuid NOT NULL,
    iteration integer NOT NULL CHECK (iteration > 0),
    fact_count bigint NOT NULL CHECK (fact_count >= 0),
    support_count bigint NOT NULL CHECK (support_count >= 0),
    fingerprint bytea NOT NULL,
    completed_at timestamptz NOT NULL,
    PRIMARY KEY (run_id, component_id, iteration),
    FOREIGN KEY (program_version_id, component_id)
        REFERENCES pgreact_internal.derivation_program_components
);

ALTER TABLE pgreact_internal.derived_supports
    ADD COLUMN program_version_id uuid
        REFERENCES pgreact_internal.derivation_program_versions,
    ADD COLUMN grounded boolean NOT NULL DEFAULT true,
    ADD COLUMN support_frontier bigint,
    ADD COLUMN logical_support_id uuid;

UPDATE pgreact_internal.derived_supports SET logical_support_id = support_id;
ALTER TABLE pgreact_internal.derived_supports
    ALTER COLUMN logical_support_id SET NOT NULL;
CREATE INDEX derived_support_logical_identity
    ON pgreact_internal.derived_supports (logical_support_id);

CREATE FUNCTION pgreact_internal.default_logical_support_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    NEW.logical_support_id := COALESCE(NEW.logical_support_id, NEW.support_id);
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_default_logical_support_id
BEFORE INSERT ON pgreact_internal.derived_supports
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.default_logical_support_id();

CREATE TABLE pgreact_internal.derived_support_inputs (
    support_id uuid NOT NULL REFERENCES pgreact_internal.derived_supports,
    input_order integer NOT NULL CHECK (input_order > 0),
    relation_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derived_relation_versions,
    semantic_key bigint NOT NULL,
    fact_id uuid NOT NULL,
    PRIMARY KEY (support_id, input_order)
);

CREATE TABLE pgreact_internal.derivation_program_reconciliations (
    reconciliation_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    program_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_program_versions,
    started_at timestamptz NOT NULL,
    completed_at timestamptz,
    repairs bigint,
    status text NOT NULL CHECK (status IN ('RUNNING', 'COMPLETED')),
    requested_by name NOT NULL
);

CREATE TABLE pgreact_internal.derivation_program_repair_diagnostics (
    reconciliation_id bigint NOT NULL
        REFERENCES pgreact_internal.derivation_program_reconciliations,
    diagnostic_order integer NOT NULL CHECK (diagnostic_order > 0),
    code text NOT NULL CHECK (code IN (
        'MISSING_SUPPORT', 'EXTRA_SUPPORT', 'STALE_SUPPORT',
        'MISSING_FACT', 'EXTRA_FACT', 'STALE_FACT',
        'CIRCULAR_ONLY', 'WRONG_FRONTIER'
    )),
    object_identity text NOT NULL,
    details jsonb NOT NULL,
    PRIMARY KEY (reconciliation_id, diagnostic_order)
);

CREATE TABLE pgreact_internal.rule_pack_programs (
    pack_version_id uuid NOT NULL REFERENCES pgreact_internal.rule_pack_versions,
    program_name text NOT NULL,
    program_version_id uuid NOT NULL
        REFERENCES pgreact_internal.derivation_program_versions,
    PRIMARY KEY (pack_version_id, program_name)
);

CREATE FUNCTION pgreact_internal.source_derived_dependencies(source_oid oid)
RETURNS TABLE(relation_version_id uuid, relation_name text, public_view_oid oid)
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE dependencies(relid) AS (
        SELECT $1
        UNION
        SELECT d.refobjid
        FROM dependencies parent
        JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
        JOIN pg_catalog.pg_depend d
          ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
         AND d.refclassid = 'pg_class'::regclass
        JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
        WHERE c.relkind IN ('v', 'm')
    )
    SELECT v.relation_version_id, r.relation_name, v.public_view_oid
    FROM dependencies d
    JOIN pgreact_internal.derived_relation_versions v
      ON v.public_view_oid = d.relid AND v.state = 'ACTIVE'
    JOIN pgreact_internal.derived_relations r USING (relation_id)
    ORDER BY r.relation_name
$$;

CREATE FUNCTION pgreact_internal.source_closure_digest(source_oid oid)
RETURNS bytea
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE views(relid) AS (
        SELECT $1
        UNION
        SELECT d.refobjid
        FROM views parent
        JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
        JOIN pg_catalog.pg_depend d
          ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
         AND d.refclassid = 'pg_class'::regclass
        JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
        WHERE c.relkind IN ('v', 'm')
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.derived_relation_versions dv
              WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
          )
    ), closure AS (
        SELECT format('%I.%I', n.nspname, c.relname) AS identity,
               pg_catalog.pg_get_viewdef(c.oid, true) AS definition
        FROM views v
        JOIN pg_catalog.pg_class c ON c.oid = v.relid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    )
    SELECT sha256(convert_to(COALESCE(jsonb_agg(
        jsonb_build_object('identity', identity, 'definition', definition)
        ORDER BY identity), '[]'::jsonb)::text, 'UTF8'))
    FROM closure
$$;

CREATE FUNCTION pgreact_internal.assert_program_owner(target_program uuid)
RETURNS pgreact_internal.derivation_program_versions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE result pgreact_internal.derivation_program_versions%ROWTYPE;
BEGIN
    SELECT * INTO STRICT result
    FROM pgreact_internal.derivation_program_versions
    WHERE program_version_id = target_program;
    IF result.owner_oid <> (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
       AND NOT pgreact_internal.is_operator_admin() THEN
        RAISE EXCEPTION 'only the derivation-program owner or pgreact_admin may manage %',
            target_program;
    END IF;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact_internal.maybe_fail_program(phase text)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF pg_catalog.current_setting('pgreact.test_fail_program_phase', true) = phase THEN
        RAISE EXCEPTION 'injected derivation-program failure after % phase', phase;
    END IF;
END
$$;

CREATE FUNCTION pgreact_internal.assert_not_active_program_member(
    target_version_id uuid,
    operation text,
    operation_hint text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_rules r
        JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
        WHERE r.rule_version_id = target_version_id AND v.state = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'program member % cannot be % independently',
            target_version_id, operation
            USING HINT = operation_hint;
    END IF;
END
$$;

ALTER FUNCTION pgreact.validate_pack(jsonb, jsonb)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.preview_pack(jsonb, jsonb)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.deploy_pack(jsonb, text, jsonb)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.create_derivation_rule(text, regclass, name[], uuid, integer, text)
    RENAME TO create_derivation_rule_m7;
ALTER FUNCTION pgreact.remove_derivation_rule(uuid)
    RENAME TO remove_derivation_rule_m7;
ALTER FUNCTION pgreact.replace_derivation_rule(uuid, regclass, name[], integer, text)
    RENAME TO replace_derivation_rule_m7;
ALTER FUNCTION pgreact.create_derivation_rule_m7(text, regclass, name[], uuid, integer, text)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.remove_derivation_rule_m7(uuid)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.replace_derivation_rule_m7(uuid, regclass, name[], integer, text)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.maintain_derived_support(uuid, uuid)
    RENAME TO maintain_derived_support_m7;
ALTER FUNCTION pgreact.refresh_rule(uuid) RENAME TO refresh_rule_m7;
ALTER FUNCTION pgreact.refresh_derived_relation(uuid)
    RENAME TO refresh_derived_relation_m7;
ALTER FUNCTION pgreact.reconcile_derived_relation(uuid)
    RENAME TO reconcile_derived_relation_m7;
ALTER FUNCTION pgreact.refresh_rule_m7(uuid)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.refresh_derived_relation_m7(uuid)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.reconcile_derived_relation_m7(uuid)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.pause_rule(uuid) RENAME TO pause_rule_m7;
ALTER FUNCTION pgreact.pause_rule_m7(uuid) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.resume_rule(uuid) RENAME TO resume_rule_m7;
ALTER FUNCTION pgreact.resume_rule_m7(uuid) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.replace_rule(uuid, regclass, name[], regprocedure, text, regprocedure, regprocedure, text)
    RENAME TO replace_rule_m7;
ALTER FUNCTION pgreact.replace_rule_m7(uuid, regclass, name[], regprocedure, text, regprocedure, regprocedure, text)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.remove_rule(uuid) RENAME TO remove_rule_m7;
ALTER FUNCTION pgreact.remove_rule_m7(uuid) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.reconcile_rule(uuid, text) RENAME TO reconcile_rule_m7;
ALTER FUNCTION pgreact.reconcile_rule_m7(uuid, text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.begin_refresh(uuid, bigint) RENAME TO begin_refresh_m7;
ALTER FUNCTION pgreact.begin_refresh_m7(uuid, bigint) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.clear_refresh_barrier(uuid) RENAME TO clear_refresh_barrier_m7;
ALTER FUNCTION pgreact.clear_refresh_barrier_m7(uuid) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.begin_reconciliation(uuid) RENAME TO begin_reconciliation_m7;
ALTER FUNCTION pgreact.begin_reconciliation_m7(uuid) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.bind_outbox_consequence(uuid, text, regprocedure, integer, integer, numeric, integer)
    RENAME TO bind_outbox_consequence_m7;
ALTER FUNCTION pgreact.bind_outbox_consequence_m7(uuid, text, regprocedure, integer, integer, numeric, integer)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.declare_batch_safe(uuid, text) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.claim_episode(uuid, text, integer) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.claim_batch(uuid, text, text, integer, interval) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.sweep_expired_leases(uuid) RENAME TO sweep_expired_leases_m7;
ALTER FUNCTION pgreact.sweep_expired_leases_m7(uuid) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.heartbeat_episode(bigint, text, uuid, interval) RENAME TO heartbeat_episode_m7;
ALTER FUNCTION pgreact.heartbeat_episode_m7(bigint, text, uuid, interval) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.requeue_episode(bigint) RENAME TO requeue_episode_m7;
ALTER FUNCTION pgreact.requeue_episode_m7(bigint) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.cancel_episode(bigint) RENAME TO cancel_episode_m7;
ALTER FUNCTION pgreact.cancel_episode_m7(bigint) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.execute_claimed_episode(bigint, text, uuid)
    RENAME TO execute_claimed_episode_m7;
ALTER FUNCTION pgreact.execute_claimed_episode_m7(bigint, text, uuid)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact.execute_claimed_batch(uuid, text) RENAME TO execute_claimed_batch_m7;
ALTER FUNCTION pgreact.execute_claimed_batch_m7(uuid, text) SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact.pause_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'paused',
        'Manage program rules through the complete derivation-program pack.');
    PERFORM pgreact_internal.pause_rule_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.resume_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'resumed',
        'Manage program rules through the complete derivation-program pack.');
    PERFORM pgreact_internal.resume_rule_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.replace_rule(
    target_version_id uuid,
    definition regclass,
    key_columns name[],
    on_activate regprocedure DEFAULT NULL,
    bootstrap_policy text DEFAULT 'SEED_CURRENT',
    on_deactivate regprocedure DEFAULT NULL,
    on_change regprocedure DEFAULT NULL,
    old_work_policy text DEFAULT 'DRAIN_OLD'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'replaced',
        'Replace the complete derivation program through its rule pack.');
    RETURN pgreact_internal.replace_rule_m7(
        target_version_id, definition, key_columns, on_activate,
        bootstrap_policy, on_deactivate, on_change, old_work_policy);
END
$$;

CREATE FUNCTION pgreact.remove_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'removed',
        'Replace or remove the complete derivation program through its rule pack.');
    PERFORM pgreact_internal.remove_rule_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.reconcile_rule(
    target_version_id uuid,
    emission_mode text DEFAULT 'STATE_ONLY'
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'reconciled',
        'Use pgreact.reconcile_derivation_program.');
    RETURN pgreact_internal.reconcile_rule_m7(target_version_id, emission_mode);
END
$$;

CREATE FUNCTION pgreact.begin_refresh(target_version_id uuid, refresh_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'refresh-barrier managed',
        'Use pgreact.refresh_derivation_program.');
    PERFORM pgreact_internal.begin_refresh_m7(target_version_id, refresh_id);
END
$$;

CREATE FUNCTION pgreact.clear_refresh_barrier(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'refresh-barrier managed',
        'Use pgreact.refresh_derivation_program.');
    PERFORM pgreact_internal.clear_refresh_barrier_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.begin_reconciliation(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'reconciliation-barrier managed',
        'Use pgreact.reconcile_derivation_program.');
    PERFORM pgreact_internal.begin_reconciliation_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.bind_outbox_consequence(
    target_version_id uuid,
    kind text,
    sink regprocedure,
    max_attempts integer DEFAULT 3,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'bound to an agenda consequence',
        'Manage program rules through the complete derivation-program pack.');
    PERFORM pgreact_internal.bind_outbox_consequence_m7(
        target_version_id, kind, sink, max_attempts,
        initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
END
$$;

CREATE FUNCTION pgreact.declare_batch_safe(target_version_id uuid, event_kind text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'declared batch-safe',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    PERFORM pgreact_internal.declare_batch_safe(target_version_id, event_kind);
END
$$;

CREATE FUNCTION pgreact.claim_episode(
    target_version_id uuid,
    worker_id text,
    lease_seconds integer DEFAULT 60
)
RETURNS TABLE(episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'agenda-claimed',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    RETURN QUERY SELECT *
    FROM pgreact_internal.claim_episode(
        target_version_id, worker_id, lease_seconds);
END
$$;

CREATE FUNCTION pgreact.claim_batch(
    target_version_id uuid,
    event_kind text,
    worker_id text,
    max_items integer DEFAULT 32,
    lease_for interval DEFAULT interval '60 seconds'
)
RETURNS TABLE(batch_id uuid, item_order integer, episode_id bigint, lease_token uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'batch-claimed',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    RETURN QUERY SELECT *
    FROM pgreact_internal.claim_batch(
        target_version_id, event_kind, worker_id, max_items, lease_for);
END
$$;

CREATE FUNCTION pgreact.sweep_expired_leases(target_version_id uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'lease-swept',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    RETURN pgreact_internal.sweep_expired_leases_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.heartbeat_episode(
    target_episode_id bigint,
    expected_worker_id text,
    expected_lease_token uuid,
    extend_for interval DEFAULT interval '60 seconds'
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        (SELECT rule_version_id FROM pgreact_internal.agenda
         WHERE episode_id = target_episode_id),
        'agenda-lease managed',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    RETURN pgreact_internal.heartbeat_episode_m7(
        target_episode_id, expected_worker_id, expected_lease_token, extend_for);
END
$$;

CREATE FUNCTION pgreact.requeue_episode(target_episode_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        (SELECT rule_version_id FROM pgreact_internal.agenda
         WHERE episode_id = target_episode_id),
        'agenda-requeued',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    PERFORM pgreact_internal.requeue_episode_m7(target_episode_id);
END
$$;

CREATE FUNCTION pgreact.cancel_episode(target_episode_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        (SELECT rule_version_id FROM pgreact_internal.agenda
         WHERE episode_id = target_episode_id),
        'agenda-cancelled',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    PERFORM pgreact_internal.cancel_episode_m7(target_episode_id);
END
$$;

CREATE FUNCTION pgreact.execute_claimed_episode(
    target_episode_id bigint,
    expected_worker_id text,
    expected_lease_token uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        (SELECT rule_version_id FROM pgreact_internal.agenda
         WHERE episode_id = target_episode_id),
        'agenda-executed',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    RETURN pgreact_internal.execute_claimed_episode_m7(
        target_episode_id, expected_worker_id, expected_lease_token);
END
$$;

CREATE FUNCTION pgreact.execute_claimed_batch(
    target_batch_id uuid,
    expected_worker_id text
)
RETURNS TABLE(episode_id bigint, status text, error_code text, error_message text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        (SELECT rule_version_id FROM pgreact_internal.execution_batches
         WHERE batch_id = target_batch_id),
        'batch-executed',
        'Program derivations do not use the agenda; use pgreact.refresh_derivation_program.');
    RETURN QUERY SELECT *
    FROM pgreact_internal.execute_claimed_batch_m7(
        target_batch_id, expected_worker_id);
END
$$;

CREATE FUNCTION pgreact.create_derivation_rule(
    name text,
    definition regclass,
    key_columns name[],
    target_relation uuid,
    rule_version integer DEFAULT 1,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_components c
        JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
        WHERE v.state = 'ACTIVE' AND target_relation = ANY (c.target_relations)
    ) THEN
        RAISE EXCEPTION 'program relation % cannot accept an independent producer',
            target_relation
            USING HINT = 'Replace the complete derivation program through its rule pack.';
    END IF;
    RETURN pgreact_internal.create_derivation_rule_m7(
        name, definition, key_columns, target_relation,
        rule_version, bootstrap_policy);
END
$$;

CREATE FUNCTION pgreact.remove_derivation_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_rules r
        JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
        WHERE v.state = 'ACTIVE' AND r.rule_version_id = target_version_id
    ) THEN
        RAISE EXCEPTION 'program member % cannot be removed independently',
            target_version_id
            USING HINT = 'Replace or remove the complete derivation program through its rule pack.';
    END IF;
    PERFORM pgreact_internal.remove_derivation_rule_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.replace_derivation_rule(
    target_version_id uuid,
    definition regclass,
    key_columns name[],
    rule_version integer,
    bootstrap_policy text DEFAULT 'SEED_CURRENT'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_rules r
        JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
        WHERE v.state = 'ACTIVE' AND r.rule_version_id = target_version_id
    ) THEN
        RAISE EXCEPTION 'program member % cannot be replaced independently',
            target_version_id
            USING HINT = 'Replace the complete derivation program through its rule pack.';
    END IF;
    RETURN pgreact_internal.replace_derivation_rule_m7(
        target_version_id, definition, key_columns,
        rule_version, bootstrap_policy);
END
$$;

CREATE FUNCTION pgreact.validate_derivation_program(definition jsonb)
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
    unknown_key text;
    item record;
    input_item record;
    duplicate_name text;
    source_oid oid;
    source_tree text;
    target_row record;
    input_row record;
    diagnostic record;
    target_attribute record;
    declared_dependencies text[];
    discovered_dependencies text[];
    current_program record;
    overlap record;
BEGIN
    IF pg_catalog.jsonb_typeof(definition) IS DISTINCT FROM 'object'
       OR NOT definition ?& ARRAY['name', 'version', 'max_iterations', 'max_facts', 'rules']
       OR pg_catalog.jsonb_typeof(definition -> 'rules') IS DISTINCT FROM 'array'
       OR jsonb_array_length(definition -> 'rules') = 0 THEN
        RETURN QUERY SELECT 3, 'PROGRAM_INVALID', 'ERROR', '<program>',
            'a derivation program requires name, version, max_iterations, max_facts, and non-empty rules',
            'Provide the exact M8 derivation-program object.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT key INTO unknown_key FROM jsonb_object_keys(definition) key
    WHERE key <> ALL (ARRAY['name', 'version', 'max_iterations', 'max_facts', 'rules'])
    ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        RETURN QUERY SELECT 3, 'PROGRAM_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'derivation program contains an unknown field',
            'Remove the field; M8 program definitions are closed.', '{}'::jsonb;
        RETURN;
    END IF;
    IF definition ->> 'name' IS NULL OR btrim(definition ->> 'name') = ''
       OR definition ->> 'version' !~ '^[1-9][0-9]*$'
       OR NOT COALESCE(pg_catalog.pg_input_is_valid(
           definition ->> 'version', 'integer'), false) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_VERSION_INVALID', 'ERROR',
            COALESCE(definition ->> 'name', '<program>'),
            'program name must be non-empty and version must be a positive integer',
            'Use one stable name and increment immutable positive versions.', '{}'::jsonb;
        RETURN;
    END IF;
    IF definition ->> 'max_iterations' !~ '^[1-9][0-9]*$'
       OR definition ->> 'max_facts' !~ '^[1-9][0-9]*$'
       OR NOT COALESCE(pg_catalog.pg_input_is_valid(
           definition ->> 'max_iterations', 'integer'), false)
       OR NOT COALESCE(pg_catalog.pg_input_is_valid(
           definition ->> 'max_facts', 'bigint'), false) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_LIMIT_INVALID', 'ERROR', definition ->> 'name',
            'max_iterations must be 1..10000 and max_facts must be 1..10000000',
            'Choose finite resource limits inside the supported boundary.', '{}'::jsonb;
        RETURN;
    END IF;
    IF (definition ->> 'max_iterations')::integer > 10000
       OR (definition ->> 'max_facts')::bigint > 10000000 THEN
        RETURN QUERY SELECT 3, 'PROGRAM_LIMIT_INVALID', 'ERROR', definition ->> 'name',
            'max_iterations must be 1..10000 and max_facts must be 1..10000000',
            'Choose finite resource limits inside the supported boundary.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT v.version, v.definition INTO current_program
    FROM pgreact_internal.derivation_programs p
    JOIN pgreact_internal.derivation_program_versions v USING (program_id)
    WHERE p.program_name = definition ->> 'name' AND v.state = 'ACTIVE';
    IF FOUND AND ((definition ->> 'version')::integer < current_program.version
       OR ((definition ->> 'version')::integer = current_program.version
           AND definition IS DISTINCT FROM current_program.definition)) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_VERSION_EXISTS', 'ERROR', definition ->> 'name',
            'an immutable active program version already exists',
            'Keep the exact definition or increment the program version.',
            jsonb_build_object('active_version', current_program.version);
        RETURN;
    END IF;
    SELECT rule_name INTO duplicate_name
    FROM (
        SELECT value ->> 'name' AS rule_name
        FROM jsonb_array_elements(definition -> 'rules')
    ) names
    GROUP BY rule_name HAVING count(*) > 1 OR rule_name IS NULL
    ORDER BY rule_name NULLS FIRST LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 3, 'PROGRAM_DUPLICATE_RULE', 'ERROR',
            COALESCE(duplicate_name, '<unnamed>'),
            'program rule names must be present and unique',
            'Give every program rule one unique immutable name.', '{}'::jsonb;
        RETURN;
    END IF;

    FOR item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY r(value, ordinal)
    LOOP
        IF pg_catalog.jsonb_typeof(item.value) IS DISTINCT FROM 'object'
           OR NOT item.value ?& ARRAY['name', 'definition', 'key', 'target', 'version', 'inputs']
           OR pg_catalog.jsonb_typeof(item.value -> 'inputs') IS DISTINCT FROM 'array'
           OR item.value ->> 'version' !~ '^[1-9][0-9]*$'
           OR NOT COALESCE(pg_catalog.pg_input_is_valid(
               item.value ->> 'version', 'integer'), false) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_RULE_INVALID', 'ERROR',
                COALESCE(item.value ->> 'name', item.ordinal::text),
                'program rules require name, definition, key, target, positive version, and inputs',
                'Provide the exact M8 program-rule object.', '{}'::jsonb;
            RETURN;
        END IF;
        SELECT key INTO unknown_key FROM jsonb_object_keys(item.value) key
        WHERE key <> ALL (ARRAY['name', 'definition', 'key', 'target', 'version', 'inputs'])
        ORDER BY key LIMIT 1;
        IF unknown_key IS NOT NULL THEN
            RETURN QUERY SELECT 3, 'PROGRAM_RULE_FIELD_UNKNOWN', 'ERROR',
                item.value ->> 'name',
                'program rule contains an unknown field',
                'Remove the field; M8 program rules are closed.',
                jsonb_build_object('field', unknown_key);
            RETURN;
        END IF;
        source_oid := pg_catalog.to_regclass(item.value ->> 'definition');
        IF source_oid IS NULL THEN
            RETURN QUERY SELECT 3, 'PROGRAM_OBJECT_UNRESOLVED', 'ERROR',
                item.value ->> 'definition',
                'program source view does not resolve',
                'Create the owned source view before validation.', '{}'::jsonb;
            RETURN;
        END IF;
        SELECT v.*, r.relation_name INTO target_row
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = item.value ->> 'target' AND v.state = 'ACTIVE';
        IF NOT FOUND THEN
            RETURN QUERY SELECT 3, 'PROGRAM_TARGET_INACTIVE', 'ERROR',
                item.value ->> 'target',
                'program target is not an active derived relation',
                'Create the target derived relation before deploying the program.', '{}'::jsonb;
            RETURN;
        END IF;
        IF target_row.owner_oid <> (
                SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user
           ) AND NOT pgreact_internal.is_operator_admin() THEN
            RETURN QUERY SELECT 3, 'PROGRAM_TARGET_INACTIVE', 'ERROR',
                item.value ->> 'target',
                'program target must be owned by the caller or managed by pgreact_admin',
                'Deploy as the derived-relation owner or pgreact_admin.', '{}'::jsonb;
            RETURN;
        END IF;
        SELECT * INTO diagnostic
        FROM pgreact.validate_rule(source_oid::regclass,
            ARRAY[(item.value ->> 'key')::name], NULL) d
        WHERE d.severity = 'ERROR' ORDER BY d.code LIMIT 1;
        IF FOUND THEN
            RETURN QUERY SELECT 3, 'PROGRAM_SOURCE_INVALID', 'ERROR',
                item.value ->> 'name',
                'program source violates the inherited rule-source contract',
                diagnostic.message,
                jsonb_build_object('source_code', diagnostic.code,
                                   'source', item.value ->> 'definition');
            RETURN;
        END IF;
        IF EXISTS (
            WITH RECURSIVE views(relid) AS (
                SELECT source_oid
                UNION
                SELECT d.refobjid
                FROM views parent
                JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
                JOIN pg_catalog.pg_depend d
                  ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                 AND d.refclassid = 'pg_class'::regclass
                JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
                WHERE c.relkind IN ('v', 'm')
                  AND NOT EXISTS (
                      SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                      WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
                  )
            )
            SELECT 1
            FROM views parent
            JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
            JOIN pg_catalog.pg_depend d
              ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
             AND d.refclassid = 'pg_class'::regclass
            JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
            WHERE (c.relrowsecurity OR c.relforcerowsecurity)
              AND NOT EXISTS (
                  SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                  WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
              )
        ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_SOURCE_INVALID', 'ERROR',
                item.value ->> 'name',
                'program source violates the inherited rule-source contract',
                'RLS-protected sources are unsupported in M1',
                jsonb_build_object('source_code', 'RLS_UNSUPPORTED',
                                   'source', item.value ->> 'definition');
            RETURN;
        END IF;
        IF (item.value ->> 'key')::name IS DISTINCT FROM target_row.key_column THEN
            RETURN QUERY SELECT 3, 'PROGRAM_KEY_MISMATCH', 'ERROR', item.value ->> 'name',
                'program output key must match its target relation key',
                'Project the target key unchanged.',
                jsonb_build_object('expected', target_row.key_column,
                                   'received', item.value ->> 'key');
            RETURN;
        END IF;
        FOR target_attribute IN
            SELECT a.attname, a.atttypid
            FROM pg_catalog.pg_type t
            JOIN pg_catalog.pg_attribute a ON a.attrelid = t.typrelid
            WHERE t.oid = target_row.row_type_oid
              AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
        LOOP
            IF NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = source_oid
                  AND a.attname = target_attribute.attname
                  AND a.atttypid = target_attribute.atttypid
                  AND a.attnum > 0 AND NOT a.attisdropped
            ) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_SOURCE_INVALID', 'ERROR',
                    item.value ->> 'name',
                    'program source does not project the complete target row type',
                    'Project every target attribute with its exact PostgreSQL type.',
                    jsonb_build_object('column', target_attribute.attname);
                RETURN;
            END IF;
        END LOOP;

        WITH RECURSIVE views(relid) AS (
            SELECT source_oid
            UNION
            SELECT d.refobjid FROM views parent
            JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
            JOIN pg_catalog.pg_depend d
              ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
             AND d.refclassid = 'pg_class'::regclass
            JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
            WHERE c.relkind IN ('v', 'm') AND NOT EXISTS (
                SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
            )
        )
        SELECT string_agg(source_rewrite.ev_action::text, E'\n' ORDER BY v.relid)
        INTO source_tree
        FROM views v
        JOIN pg_catalog.pg_rewrite source_rewrite
          ON source_rewrite.ev_class = v.relid
         AND source_rewrite.rulename = '_RETURN'
        WHERE NOT EXISTS (
            SELECT 1 FROM pgreact_internal.derived_relation_versions dv
            WHERE dv.public_view_oid = v.relid AND dv.state = 'ACTIVE'
        );
        IF source_tree ~ E'\\{BOOLEXPR[[:space:]]+:boolop[[:space:]]+not[[:space:]]'
           OR source_tree ~ E':jointype[[:space:]]+[1-9][[:space:]]'
           OR source_tree ~ E':has(WindowFuncs|DistinctOn|Recursive|ModifyingCTE|ForUpdate|GroupRTE)[[:space:]]+true'
           OR source_tree ~ E':(groupClause|groupingSets|havingQual|distinctClause|windowClause|rowMarks|setOperations|limitOffset|limitCount)[[:space:]]+[({]'
           OR source_tree ~ E':subLinkType[[:space:]]+(1|3|4|5|6|7)[[:space:]]'
           OR source_tree ~ E':tablesample[[:space:]]+\\{TABLESAMPLECLAUSE' THEN
            RETURN QUERY SELECT 3, 'PROGRAM_NOT_POSITIVE', 'ERROR',
                item.value ->> 'name',
                'program sources permit only positive inner-join, filter, and projection SQL',
                'Remove negation, set operations, outer or anti joins, recursion, distinct, windows, and limits.',
                jsonb_build_object('source', item.value ->> 'definition');
            RETURN;
        END IF;
        IF EXISTS (
            WITH RECURSIVE views(relid) AS (
                SELECT source_oid
                UNION
                SELECT d.refobjid FROM views parent
                JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
                JOIN pg_catalog.pg_depend d
                  ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                 AND d.refclassid = 'pg_class'::regclass
                JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
                WHERE c.relkind IN ('v', 'm') AND NOT EXISTS (
                    SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                    WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
                )
            )
            SELECT 1 FROM views v
            JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = v.relid
            JOIN pg_catalog.pg_depend d
              ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
             AND d.refclassid = 'pg_proc'::regclass
            JOIN pg_catalog.pg_aggregate a ON a.aggfnoid = d.refobjid
            WHERE NOT EXISTS (
                SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                WHERE dv.public_view_oid = v.relid AND dv.state = 'ACTIVE'
            )
        ) OR source_tree ~ E':hasAggs[[:space:]]+true'
          OR source_tree ~ E':aggfnoid[[:space:]]+[1-9]' THEN
            RETURN QUERY SELECT 3, 'PROGRAM_AGGREGATE_UNSUPPORTED', 'ERROR',
                item.value ->> 'name',
                'aggregate derivation is outside the monotone M8 subset',
                'Use non-aggregate positive rows.', '{}'::jsonb;
            RETURN;
        END IF;
        IF source_tree ~ E':hasTargetSRFs[[:space:]]+true'
           OR source_tree ~ E':funcretset[[:space:]]+true'
           OR source_tree ~ E':rtekind[[:space:]]+(3|4|5|7)[[:space:]]'
           OR pgreact_internal.view_key_uses_operator(
                source_oid,
                (SELECT a.attnum
                 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = source_oid
                   AND a.attname = (item.value ->> 'key')::name
                   AND a.attnum > 0 AND NOT a.attisdropped)
              )
           OR EXISTS (
            WITH RECURSIVE views(relid) AS (
                SELECT source_oid
                UNION
                SELECT d.refobjid FROM views parent
                JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
                JOIN pg_catalog.pg_depend d
                  ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                 AND d.refclassid = 'pg_class'::regclass
                JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
                WHERE c.relkind IN ('v', 'm') AND NOT EXISTS (
                    SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                    WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
                )
            )
            SELECT 1 FROM views v
            JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = v.relid
            JOIN pg_catalog.pg_depend d
              ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
             AND d.refclassid = 'pg_proc'::regclass
            JOIN pg_catalog.pg_proc p ON p.oid = d.refobjid
            WHERE p.proretset AND NOT EXISTS (
                SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                WHERE dv.public_view_oid = v.relid AND dv.state = 'ACTIVE'
            )
        ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_UNBOUNDED_UNSUPPORTED', 'ERROR',
                item.value ->> 'name',
                'set-returning or additive value invention is outside the range-restricted M8 subset',
                'Project keys from finite input rows without + or set-returning functions.', '{}'::jsonb;
            RETURN;
        END IF;
        IF source_tree ~ E'\\{SQLVALUEFUNCTION[[:space:]]'
           OR EXISTS (
            WITH RECURSIVE views(relid) AS (
                SELECT source_oid
                UNION
                SELECT d.refobjid FROM views parent
                JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
                JOIN pg_catalog.pg_depend d
                  ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                 AND d.refclassid = 'pg_class'::regclass
                JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
                WHERE c.relkind IN ('v', 'm') AND NOT EXISTS (
                    SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                    WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
                )
            )
            SELECT 1 FROM views v
            JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = v.relid
            JOIN pg_catalog.pg_depend d
              ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
             AND d.refclassid = 'pg_proc'::regclass
            JOIN pg_catalog.pg_proc p ON p.oid = d.refobjid
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE NOT EXISTS (
                      SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                      WHERE dv.public_view_oid = v.relid AND dv.state = 'ACTIVE'
                  )
              AND (p.provolatile <> 'i' OR n.nspname <> 'pg_catalog')
        ) OR EXISTS (
            WITH RECURSIVE views(relid) AS (
                SELECT source_oid
                UNION
                SELECT d.refobjid FROM views parent
                JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = parent.relid
                JOIN pg_catalog.pg_depend d
                  ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
                 AND d.refclassid = 'pg_class'::regclass
                JOIN pg_catalog.pg_class c ON c.oid = d.refobjid
                WHERE c.relkind IN ('v', 'm') AND NOT EXISTS (
                    SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                    WHERE dv.public_view_oid = parent.relid AND dv.state = 'ACTIVE'
                )
            )
            SELECT 1 FROM views v
            JOIN pg_catalog.pg_rewrite rw ON rw.ev_class = v.relid
            JOIN pg_catalog.pg_depend d
              ON d.classid = 'pg_rewrite'::regclass AND d.objid = rw.oid
             AND d.refclassid = 'pg_operator'::regclass
            JOIN pg_catalog.pg_operator o ON o.oid = d.refobjid
            JOIN pg_catalog.pg_namespace operator_namespace
              ON operator_namespace.oid = o.oprnamespace
            JOIN pg_catalog.pg_proc p ON p.oid = o.oprcode
            JOIN pg_catalog.pg_namespace function_namespace
              ON function_namespace.oid = p.pronamespace
            WHERE NOT EXISTS (
                      SELECT 1 FROM pgreact_internal.derived_relation_versions dv
                      WHERE dv.public_view_oid = v.relid AND dv.state = 'ACTIVE'
                  )
              AND (operator_namespace.nspname <> 'pg_catalog'
                   OR function_namespace.nspname <> 'pg_catalog'
                   OR p.provolatile <> 'i')
        ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_FUNCTION_UNSUPPORTED', 'ERROR',
                item.value ->> 'name',
                'program sources may use only immutable pg_catalog functions',
                'Remove stable, volatile, or user-defined executable dependencies.', '{}'::jsonb;
            RETURN;
        END IF;

        declared_dependencies := ARRAY[]::text[];
        FOR input_item IN
            SELECT value, ordinal
            FROM jsonb_array_elements(item.value -> 'inputs')
            WITH ORDINALITY i(value, ordinal)
        LOOP
            IF pg_catalog.jsonb_typeof(input_item.value) IS DISTINCT FROM 'object'
               OR NOT input_item.value ?& ARRAY['relation', 'key']
               OR (SELECT count(*) FROM jsonb_object_keys(input_item.value)) <> 2 THEN
                RETURN QUERY SELECT 3, 'PROGRAM_INPUT_INVALID', 'ERROR',
                    item.value ->> 'name',
                    'program inputs require exactly relation and key',
                    'Declare each derived input and its projected bigint key.',
                    jsonb_build_object('input_order', input_item.ordinal);
                RETURN;
            END IF;
            SELECT v.*, r.relation_name INTO input_row
            FROM pgreact_internal.derived_relations r
            JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
            WHERE r.relation_name = input_item.value ->> 'relation'
              AND v.state = 'ACTIVE';
            IF NOT FOUND THEN
                RETURN QUERY SELECT 3, 'PROGRAM_OBJECT_UNRESOLVED', 'ERROR',
                    input_item.value ->> 'relation',
                    'declared program input is not an active derived relation',
                    'Use an active public derived relation name.', '{}'::jsonb;
                RETURN;
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_attribute a
                WHERE a.attrelid = source_oid
                  AND a.attname = (input_item.value ->> 'key')::name
                  AND a.atttypid = 'bigint'::regtype
                  AND a.attnum > 0 AND NOT a.attisdropped
            ) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_INPUT_KEY_INVALID', 'ERROR',
                    item.value ->> 'name',
                    'declared input key must be a projected bigint source column',
                    'Project one bigint input key used for runtime key preservation.',
                    jsonb_build_object('relation', input_item.value ->> 'relation',
                                       'key', input_item.value ->> 'key');
                RETURN;
            END IF;
            IF input_item.value ->> 'key' IS DISTINCT FROM item.value ->> 'key' THEN
                RETURN QUERY SELECT 3, 'PROGRAM_KEY_MISMATCH', 'ERROR',
                    item.value ->> 'name',
                    'M8 input and output key columns must have the same name',
                    'Alias the derived input key to the target key name.',
                    jsonb_build_object('input_key', input_item.value ->> 'key',
                                       'output_key', item.value ->> 'key');
                RETURN;
            END IF;
            declared_dependencies := array_append(
                declared_dependencies, input_item.value ->> 'relation');
        END LOOP;
        SELECT COALESCE(array_agg(dependency ORDER BY dependency), ARRAY[]::text[])
        INTO declared_dependencies
        FROM unnest(declared_dependencies) dependency;
        IF cardinality(declared_dependencies) <> (
            SELECT count(DISTINCT dependency) FROM unnest(declared_dependencies) dependency
        ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_INPUT_INVALID', 'ERROR',
                item.value ->> 'name',
                'program input relations must be unique per rule',
                'Declare each derived input once.', '{}'::jsonb;
            RETURN;
        END IF;
        SELECT COALESCE(array_agg(d.relation_name ORDER BY d.relation_name), ARRAY[]::text[])
        INTO discovered_dependencies
        FROM pgreact_internal.source_derived_dependencies(source_oid) d;
        IF declared_dependencies IS DISTINCT FROM discovered_dependencies THEN
            RETURN QUERY SELECT 3, 'PROGRAM_DEPENDENCY_MISMATCH', 'ERROR',
                item.value ->> 'name',
                'declared derived inputs do not exactly match nested view dependencies',
                'Declare every discovered derived relation once and no others.',
                jsonb_build_object('declared', declared_dependencies,
                                   'discovered', discovered_dependencies);
            RETURN;
        END IF;
        IF cardinality(declared_dependencies) = 0 THEN
            IF pgreact_internal.view_key_is_direct(
                source_oid,
                (SELECT a.attnum
                 FROM pg_catalog.pg_attribute a
                 WHERE a.attrelid = source_oid
                   AND a.attname = (item.value ->> 'key')::name
                   AND a.attnum > 0 AND NOT a.attisdropped)
               ) IS DISTINCT FROM true THEN
                RETURN QUERY SELECT 3, 'PROGRAM_KEY_MISMATCH', 'ERROR',
                    item.value ->> 'name',
                    'program output key must match its target relation key',
                    'Project the target key unchanged.',
                    jsonb_build_object(
                        'expected', 'direct source column',
                        'received', 'computed key projection');
                RETURN;
            END IF;
        ELSIF EXISTS (
            SELECT 1
            FROM pgreact_internal.source_derived_dependencies(source_oid) dependency
            JOIN pgreact_internal.derived_relation_versions input_version
              USING (relation_version_id)
            WHERE NOT EXISTS (
                SELECT 1
                FROM pg_catalog.pg_attribute source_key
                JOIN pg_catalog.pg_attribute input_key
                  ON input_key.attrelid = dependency.public_view_oid
                 AND input_key.attname = input_version.key_column::name
                 AND input_key.attnum > 0
                 AND NOT input_key.attisdropped
                WHERE source_key.attrelid = source_oid
                  AND source_key.attname = (item.value ->> 'key')::name
                  AND source_key.attnum > 0
                  AND NOT source_key.attisdropped
                  AND pgreact_internal.view_key_is_direct_from(
                        source_oid,
                        source_key.attnum,
                        dependency.public_view_oid,
                        input_key.attnum)
            )
        ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_KEY_MISMATCH', 'ERROR',
                item.value ->> 'name',
                'program output key must match its target relation key',
                'Project the target key unchanged.',
                jsonb_build_object(
                    'expected', 'direct source column',
                    'received', 'computed key projection');
            RETURN;
        END IF;
    END LOOP;

    SELECT incoming.value ->> 'name' AS object_identity,
           owner_program.program_name AS owner_program
    INTO overlap
    FROM jsonb_array_elements(definition -> 'rules') incoming(value)
    JOIN pgreact_internal.derivation_program_rules member
      ON member.rule_name = incoming.value ->> 'name'
    JOIN pgreact_internal.derivation_program_versions owner_version
      USING (program_version_id)
    JOIN pgreact_internal.derivation_programs owner_program USING (program_id)
    WHERE owner_version.state = 'ACTIVE'
      AND owner_program.program_name <> definition ->> 'name'
    ORDER BY incoming.value ->> 'name', owner_program.program_name
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 3, 'PROGRAM_RULE_OVERLAP', 'ERROR',
            overlap.object_identity,
            'rule name is owned by another active derivation program',
            'Replace that owning program or choose a different rule name.',
            jsonb_build_object('program', definition ->> 'name',
                               'owner_program', overlap.owner_program);
        RETURN;
    END IF;
    SELECT incoming.value ->> 'target' AS object_identity,
           owner_program.program_name AS owner_program
    INTO overlap
    FROM jsonb_array_elements(definition -> 'rules') incoming(value)
    JOIN pgreact_internal.derived_relations target_relation
      ON target_relation.relation_name = incoming.value ->> 'target'
    JOIN pgreact_internal.derived_relation_versions target_version
      USING (relation_id)
    JOIN pgreact_internal.derivation_program_rules member
      ON member.target_relation_version_id = target_version.relation_version_id
    JOIN pgreact_internal.derivation_program_versions owner_version
      USING (program_version_id)
    JOIN pgreact_internal.derivation_programs owner_program USING (program_id)
    WHERE owner_version.state = 'ACTIVE'
      AND owner_program.program_name <> definition ->> 'name'
    ORDER BY incoming.value ->> 'target', owner_program.program_name
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 3, 'PROGRAM_TARGET_OVERLAP', 'ERROR',
            overlap.object_identity,
            'target relation is owned by another active derivation program',
            'Replace that owning program or choose a different target relation.',
            jsonb_build_object('program', definition ->> 'name',
                               'owner_program', overlap.owner_program);
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(definition -> 'rules') rule_item(value)
        CROSS JOIN LATERAL jsonb_array_elements(rule_item.value -> 'inputs') input_item(value)
        WHERE NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(definition -> 'rules') producer(value)
            WHERE producer.value ->> 'target' = input_item.value ->> 'relation'
        )
    ) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_GRAPH_OPEN', 'ERROR', definition ->> 'name',
            'every derived input relation must be produced inside the same program',
            'Add its producer rule so the recursive graph is closed.', '{}'::jsonb;
        RETURN;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_rule_versions d
        JOIN pgreact_internal.rule_versions v USING (rule_version_id)
        JOIN pgreact_internal.rules r ON r.rule_id = v.rule_id
        JOIN pgreact_internal.derived_relations target_relation
          ON target_relation.relation_id = (
              SELECT relation_id
              FROM pgreact_internal.derived_relation_versions
              WHERE relation_version_id = d.relation_version_id
          )
        WHERE v.state = 'ACTIVE'
          AND target_relation.relation_name IN (
              SELECT value ->> 'target'
              FROM jsonb_array_elements(definition -> 'rules') value
          )
          AND NOT EXISTS (
              SELECT 1
              FROM pgreact_internal.derivation_program_rules prior_rule
              JOIN pgreact_internal.derivation_program_versions prior_version
                USING (program_version_id)
              JOIN pgreact_internal.derivation_programs prior_program
                USING (program_id)
              WHERE prior_rule.rule_version_id = d.rule_version_id
                AND prior_version.state = 'ACTIVE'
                AND prior_program.program_name = definition ->> 'name'
          )
    ) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_GRAPH_OPEN', 'ERROR', definition ->> 'name',
            'program target relations have an active producer outside the program',
            'Move every active producer for program relations into the same program.', '{}'::jsonb;
        RETURN;
    END IF;

    RETURN QUERY SELECT 3, 'OK', 'INFO', definition ->> 'name',
        'derivation program is a closed positive key-preserving graph',
        'Preview and deploy the containing pack.',
        jsonb_build_object('version', (definition ->> 'version')::integer,
                           'rules', jsonb_array_length(definition -> 'rules'),
                           'max_iterations', (definition ->> 'max_iterations')::integer,
                           'max_facts', (definition ->> 'max_facts')::bigint);
END
$$;

CREATE FUNCTION pgreact_internal.maintain_derived_support(
    target_rule_version uuid,
    target_activation uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program_rule record;
    activation pgreact_internal.activation_state%ROWTYPE;
    old_support record;
    input_row record;
    input_fact_id uuid;
    input_ready boolean := true;
    projected jsonb;
    clean_binding jsonb;
    canonical bytea;
    target_fact_id uuid;
    target_logical_support_id uuid;
    target_support_id uuid;
    frontier_value bigint;
BEGIN
    SELECT pr.*, pv.frontier AS program_frontier
    INTO program_rule
    FROM pgreact_internal.derivation_program_rules pr
    JOIN pgreact_internal.derivation_program_versions pv USING (program_version_id)
    WHERE pr.rule_version_id = target_rule_version AND pv.state = 'ACTIVE'
    ORDER BY pv.created_at DESC LIMIT 1;
    IF NOT FOUND THEN
        PERFORM pgreact_internal.maintain_derived_support_m7(
            target_rule_version, target_activation);
        RETURN;
    END IF;
    SELECT * INTO activation
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = target_rule_version
      AND activation_id = target_activation;
    IF NOT FOUND THEN RETURN; END IF;

    IF activation.active THEN
        clean_binding := activation.current_bindings - '__pgt_row_id';
        projected := pgreact_internal.project_derived_fact(
            program_rule.target_relation_version_id, clean_binding);
        canonical := pgreact_internal.canonical_bigint_v1(activation.semantic_key);
        target_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(
                program_rule.target_relation_version_id, canonical));
        target_logical_support_id := pgreact_internal.activation_uuid(sha256(convert_to(
            target_rule_version::text || ':' || target_activation::text || ':' ||
            target_fact_id::text, 'UTF8')));
        target_support_id := pgreact_internal.activation_uuid(sha256(convert_to(
            target_rule_version::text || ':' || target_activation::text || ':' ||
            activation.generation || ':' || activation.revision || ':' ||
            target_fact_id::text, 'UTF8')));
        FOR input_row IN
            SELECT * FROM pgreact_internal.derivation_program_inputs
            WHERE program_version_id = program_rule.program_version_id
              AND rule_version_id = target_rule_version
            ORDER BY input_order
        LOOP
            IF clean_binding ->> input_row.key_column IS NULL
               OR (clean_binding ->> input_row.key_column)::bigint
                    IS DISTINCT FROM activation.semantic_key THEN
                RAISE EXCEPTION 'program rule % input key % must equal output key %',
                    program_rule.rule_name, input_row.key_column,
                    activation.semantic_key;
            END IF;
            SELECT f.fact_id INTO input_fact_id
            FROM pgreact_internal.derived_facts f
            WHERE f.relation_version_id = input_row.relation_version_id
              AND f.semantic_key = activation.semantic_key;
            input_ready := input_ready AND FOUND;
        END LOOP;
    END IF;

    SELECT * INTO old_support
    FROM pgreact_internal.derived_supports s
    WHERE s.rule_version_id = target_rule_version
      AND s.activation_id = target_activation AND s.active;
    IF activation.active AND input_ready AND FOUND
       AND old_support.logical_support_id = target_logical_support_id
       AND old_support.support_id = target_support_id
       AND old_support.fact = projected
       AND old_support.source_binding = clean_binding
       AND old_support.activation_generation = activation.generation
       AND old_support.activation_revision = activation.revision
       AND NOT EXISTS (
            SELECT 1
            FROM pgreact_internal.derivation_program_inputs i
            LEFT JOIN pgreact_internal.derived_support_inputs si
              ON si.support_id = target_support_id
             AND si.input_order = i.input_order
             AND si.relation_version_id = i.relation_version_id
             AND si.semantic_key = activation.semantic_key
             AND si.fact_id = pgreact_internal.activation_uuid(
                 pgreact_internal.activation_digest(
                     i.relation_version_id,
                     pgreact_internal.canonical_bigint_v1(activation.semantic_key)))
            WHERE i.program_version_id = program_rule.program_version_id
              AND i.rule_version_id = target_rule_version
              AND si.support_id IS NULL
       ) THEN
        RETURN;
    END IF;
    IF old_support.support_id IS NULL AND (NOT activation.active OR NOT input_ready) THEN
        RETURN;
    END IF;

    frontier_value := pgreact_internal.advance_derived_frontier(
        program_rule.target_relation_version_id);
    IF old_support.support_id IS NOT NULL THEN
        UPDATE pgreact_internal.derived_supports
        SET active = false, grounded = false,
            last_frontier = frontier_value,
            invalidated_at = clock_timestamp()
        WHERE support_id = old_support.support_id;
        PERFORM pgreact_internal.recompute_derived_fact(
            old_support.relation_version_id,
            old_support.semantic_key, frontier_value);
    END IF;
    IF NOT activation.active OR NOT input_ready THEN RETURN; END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.derived_supports s
        WHERE s.relation_version_id = program_rule.target_relation_version_id
          AND s.semantic_key = activation.semantic_key AND s.active
          AND s.support_id <> target_support_id
          AND s.fact IS DISTINCT FROM projected
    ) THEN
        RAISE EXCEPTION 'conflicting derived payloads for % key %',
            program_rule.target_relation_version_id, activation.semantic_key;
    END IF;
    INSERT INTO pgreact_internal.derived_supports (
        support_id, logical_support_id, relation_version_id, rule_version_id, activation_id,
        activation_generation, activation_revision, semantic_key, fact_id,
        fact, source_binding, active, first_frontier, program_version_id,
        grounded, support_frontier
    ) VALUES (
        target_support_id, target_logical_support_id,
        program_rule.target_relation_version_id,
        target_rule_version, target_activation, activation.generation,
        activation.revision, activation.semantic_key, target_fact_id,
        projected, clean_binding, true, frontier_value,
        program_rule.program_version_id, true,
        COALESCE(NULLIF(pg_catalog.current_setting(
            'pgreact.program_support_frontier', true), '')::bigint,
            program_rule.program_frontier + 1)
    )
    ON CONFLICT (support_id) DO UPDATE SET
        fact = EXCLUDED.fact,
        source_binding = EXCLUDED.source_binding,
        active = true,
        last_frontier = NULL,
        invalidated_at = NULL,
        program_version_id = EXCLUDED.program_version_id,
        grounded = true,
        support_frontier = EXCLUDED.support_frontier;
    DELETE FROM pgreact_internal.derived_support_inputs
    WHERE support_id = target_support_id;
    FOR input_row IN
        SELECT * FROM pgreact_internal.derivation_program_inputs
        WHERE program_version_id = program_rule.program_version_id
          AND rule_version_id = target_rule_version
        ORDER BY input_order
    LOOP
        input_fact_id := pgreact_internal.activation_uuid(
            pgreact_internal.activation_digest(
                input_row.relation_version_id,
                pgreact_internal.canonical_bigint_v1(activation.semantic_key)));
        INSERT INTO pgreact_internal.derived_support_inputs (
            support_id, input_order, relation_version_id,
            semantic_key, fact_id
        ) VALUES (
            target_support_id, input_row.input_order,
            input_row.relation_version_id, activation.semantic_key,
            input_fact_id
        );
    END LOOP;
    PERFORM pgreact_internal.recompute_derived_fact(
        program_rule.target_relation_version_id,
        activation.semantic_key, frontier_value);
END
$$;

CREATE FUNCTION pgreact_internal.derivation_program_components(definition jsonb)
RETURNS TABLE(
    component_order integer,
    component_id uuid,
    cyclic boolean,
    rule_names text[],
    target_names text[]
)
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE
    rules(rule_name, target_name) AS (
        SELECT value ->> 'name', value ->> 'target'
        FROM jsonb_array_elements($1 -> 'rules') value
    ),
    relations(relation_name) AS (
        SELECT DISTINCT target_name FROM rules
    ),
    edges(source_relation, target_relation) AS (
        SELECT input.value ->> 'relation', consumer.value ->> 'target'
        FROM jsonb_array_elements($1 -> 'rules') consumer(value)
        CROSS JOIN LATERAL jsonb_array_elements(consumer.value -> 'inputs') input(value)
    ),
    reach(source_relation, target_relation) AS (
        SELECT relation_name, relation_name FROM relations
        UNION
        SELECT source_relation, target_relation FROM edges
        UNION
        SELECT reach.source_relation, edges.target_relation
        FROM reach JOIN edges
          ON edges.source_relation = reach.target_relation
    ),
    membership AS (
        SELECT r.relation_name,
               ARRAY(
                   SELECT peer.relation_name FROM relations peer
                   WHERE EXISTS (
                       SELECT 1 FROM reach
                       WHERE source_relation = r.relation_name
                         AND target_relation = peer.relation_name
                   ) AND EXISTS (
                       SELECT 1 FROM reach
                       WHERE source_relation = peer.relation_name
                         AND target_relation = r.relation_name
                   )
                   ORDER BY peer.relation_name
               ) AS members
        FROM relations r
    ),
    components AS (
        SELECT DISTINCT members,
               ARRAY(
                   SELECT r.rule_name
                   FROM rules r WHERE r.target_name = ANY (members)
                   ORDER BY r.rule_name
               ) AS member_rules
        FROM membership
    ),
    component_edges(source_members, target_members) AS (
        SELECT DISTINCT source_component.members, target_component.members
        FROM edges e
        JOIN membership source_component
          ON source_component.relation_name = e.source_relation
        JOIN membership target_component
          ON target_component.relation_name = e.target_relation
        WHERE source_component.members <> target_component.members
    ),
    component_reach(source_members, target_members) AS (
        SELECT source_members, target_members FROM component_edges
        UNION
        SELECT reach.source_members, edge.target_members
        FROM component_reach reach
        JOIN component_edges edge
          ON edge.source_members = reach.target_members
    ),
    ranked AS (
        SELECT c.members, c.member_rules,
               count(DISTINCT reach.source_members) AS ancestor_count
        FROM components c
        LEFT JOIN component_reach reach ON reach.target_members = c.members
        GROUP BY c.members, c.member_rules
    )
    SELECT row_number() OVER (
               ORDER BY ancestor_count, array_to_string(members, ',')
           )::integer,
           pgreact_internal.activation_uuid(sha256(convert_to(
               $1 ->> 'name' || ':' || array_to_string(members, ','), 'UTF8'))),
           cardinality(members) > 1 OR EXISTS (
               SELECT 1 FROM edges
               WHERE source_relation = members[1]
                 AND target_relation = members[1]
           ),
           member_rules,
           members
    FROM ranked
    ORDER BY 1
$$;

CREATE FUNCTION pgreact_internal.derivation_component_fingerprint(
    target_program uuid,
    target_component uuid
)
RETURNS bytea
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT sha256(convert_to(
        COALESCE((
            SELECT string_agg(format('%s@%s:%s@%s:%s:%s:%s:%s',
                                     rule.rule_name, rule_version.version,
                                     relation.relation_name, relation_version.version,
                                     s.semantic_key, s.fact::text,
                                     s.source_binding::text,
                                     COALESCE((
                                         SELECT string_agg(format('%s@%s:%s',
                                                                  input_relation.relation_name,
                                                                  input_version.version,
                                                                  input.semantic_key),
                                                           ',' ORDER BY input.input_order)
                                         FROM pgreact_internal.derived_support_inputs input
                                         JOIN pgreact_internal.derived_relation_versions input_version
                                           ON input_version.relation_version_id = input.relation_version_id
                                         JOIN pgreact_internal.derived_relations input_relation
                                           USING (relation_id)
                                         WHERE input.support_id = s.support_id
                                     ), '')),
                              E'\n' ORDER BY rule.rule_name, rule_version.version,
                                             relation.relation_name,
                                             relation_version.version,
                                             s.semantic_key, s.fact::text,
                                             s.source_binding::text)
            FROM pgreact_internal.derived_supports s
            JOIN pgreact_internal.derivation_program_rules member
              ON member.program_version_id = $1
             AND member.component_id = $2
             AND member.rule_version_id = s.rule_version_id
            JOIN pgreact_internal.derivation_rule_versions rule_version
              ON rule_version.rule_version_id = s.rule_version_id
            JOIN pgreact_internal.rules rule
              ON rule.rule_id = rule_version.rule_id
            JOIN pgreact_internal.derived_relation_versions relation_version
              ON relation_version.relation_version_id = s.relation_version_id
            JOIN pgreact_internal.derived_relations relation USING (relation_id)
            WHERE s.active
        ), '') || E'\n--facts--\n' || COALESCE((
            SELECT string_agg(format('%s@%s:%s:%s', relation.relation_name,
                                     relation_version.version,
                                     f.semantic_key, f.fact::text),
                              E'\n' ORDER BY relation.relation_name,
                                             relation_version.version,
                                             f.semantic_key)
            FROM pgreact_internal.derived_facts f
            JOIN pgreact_internal.derivation_program_components c
              ON c.program_version_id = $1 AND c.component_id = $2
             AND f.relation_version_id = ANY (c.target_relations)
            JOIN pgreact_internal.derived_relation_versions relation_version
              ON relation_version.relation_version_id = f.relation_version_id
            JOIN pgreact_internal.derived_relations relation USING (relation_id)
        ), ''), 'UTF8'))
$$;

CREATE FUNCTION pgreact_internal.derivation_rule_source_current(
    target_rule_version uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    source_relation regclass;
    match_relation regclass;
    source_rows jsonb;
    match_rows jsonb;
BEGIN
    SELECT p.source_view_oid::regclass, v.match_relid::regclass
    INTO STRICT source_relation, match_relation
    FROM pgreact_internal.derivation_program_rules p
    JOIN pgreact_internal.rule_versions v USING (rule_version_id)
    JOIN pgreact_internal.derivation_program_versions pv
      USING (program_version_id)
    WHERE p.rule_version_id = target_rule_version
      AND pv.state = 'ACTIVE'
    ORDER BY pv.created_at DESC
    LIMIT 1;
    EXECUTE format(
        'SELECT '
        'COALESCE((SELECT jsonb_agg(to_jsonb(s) ORDER BY to_jsonb(s)::text) FROM %s s), ''[]''::jsonb), '
        'COALESCE((SELECT jsonb_agg(to_jsonb(m) - ''__pgt_row_id'' '
        'ORDER BY (to_jsonb(m) - ''__pgt_row_id'')::text) FROM %s m), ''[]''::jsonb)',
        source_relation, match_relation)
    INTO source_rows, match_rows;
    RETURN source_rows IS NOT DISTINCT FROM match_rows;
END
$$;

CREATE FUNCTION pgreact_internal.rebuild_derivation_program(
    target_program uuid,
    force_rebuild boolean DEFAULT false,
    preserve_frontier boolean DEFAULT false,
    existing_run_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    component_row record;
    rule_row record;
    activation_row record;
    relation_id uuid;
    run_id bigint := existing_run_id;
    component_iterations integer;
    total_iterations integer := 0;
    previous_fingerprint bytea;
    current_fingerprint bytea;
    before_fingerprint bytea;
    after_fingerprint bytea;
    facts bigint;
    supports bigint;
    relation_frontier bigint;
    component_converged boolean;
    source_drift record;
BEGIN
    SELECT * INTO STRICT program_row
    FROM pgreact_internal.derivation_program_versions
    WHERE program_version_id = target_program AND state = 'ACTIVE';
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT r.rule_name,
           encode(r.source_definition_digest, 'hex') AS expected_digest,
           encode(pgreact_internal.source_closure_digest(r.source_view_oid), 'hex')
             AS current_digest
    INTO source_drift
    FROM pgreact_internal.derivation_program_rules r
    WHERE r.program_version_id = target_program
      AND r.source_definition_digest IS DISTINCT FROM
          pgreact_internal.source_closure_digest(r.source_view_oid)
    ORDER BY r.rule_order, r.rule_name
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'derivation program source drift for %',
            source_drift.rule_name
            USING HINT = 'Replace the complete derivation program through its rule pack.',
                  DETAIL = format('expected %s, current %s',
                                  source_drift.expected_digest,
                                  source_drift.current_digest);
    END IF;
    PERFORM pg_catalog.set_config(
        'pgreact.program_support_frontier',
        CASE WHEN preserve_frontier THEN program_row.frontier
             ELSE program_row.frontier + 1 END::text,
        true);
    IF run_id IS NULL THEN
        INSERT INTO pgreact_internal.derivation_program_runs (
            program_version_id, started_at, prior_frontier, status, requested_by
        ) VALUES (
            target_program, clock_timestamp(), program_row.frontier,
            'RUNNING', session_user
        ) RETURNING pgreact_internal.derivation_program_runs.run_id INTO run_id;
    END IF;

    SELECT sha256(convert_to(COALESCE(string_agg(
        encode(pgreact_internal.derivation_component_fingerprint(
            target_program, c.component_id), 'hex'), '' ORDER BY c.component_order), ''), 'UTF8'))
    INTO before_fingerprint
    FROM pgreact_internal.derivation_program_components c
    WHERE c.program_version_id = target_program;

    IF NOT preserve_frontier THEN
      FOR rule_row IN
        SELECT r.rule_version_id
        FROM pgreact_internal.derivation_program_components c
        JOIN pgreact_internal.derivation_program_rules r
          USING (program_version_id, component_id)
        WHERE c.program_version_id = target_program
        ORDER BY c.component_order, r.rule_order, r.rule_name
    LOOP
        IF NOT pgreact_internal.derivation_rule_source_current(
            rule_row.rule_version_id) THEN
            PERFORM pgreact_internal.refresh_rule(rule_row.rule_version_id);
            SET CONSTRAINTS ALL IMMEDIATE;
            SET CONSTRAINTS ALL DEFERRED;
        END IF;
        FOR activation_row IN
            SELECT activation_id
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = rule_row.rule_version_id AND active
            ORDER BY activation_id
        LOOP
            PERFORM pgreact_internal.maintain_derived_support(
                rule_row.rule_version_id, activation_row.activation_id);
        END LOOP;
      END LOOP;
      SELECT sha256(convert_to(COALESCE(string_agg(
        encode(pgreact_internal.derivation_component_fingerprint(
            target_program, c.component_id), 'hex'), '' ORDER BY c.component_order), ''), 'UTF8'))
      INTO after_fingerprint
      FROM pgreact_internal.derivation_program_components c
      WHERE c.program_version_id = target_program;
      IF NOT force_rebuild AND before_fingerprint = after_fingerprint THEN
        UPDATE pgreact_internal.derivation_program_runs SET
            completed_at = clock_timestamp(),
            committed_frontier = program_row.frontier,
            iterations = 0,
            fact_count = (
                SELECT count(*)
                FROM pgreact_internal.derived_facts f
                JOIN pgreact_internal.derivation_program_components c
                  ON c.program_version_id = target_program
                 AND f.relation_version_id = ANY (c.target_relations)
            ),
            support_count = (
                SELECT count(*)
                FROM pgreact_internal.derived_supports s
                JOIN pgreact_internal.derivation_program_rules r
                  ON r.program_version_id = target_program
                 AND r.rule_version_id = s.rule_version_id
                WHERE s.active
            ),
            status = 'NOOP'
        WHERE pgreact_internal.derivation_program_runs.run_id = run_id;
          RETURN program_row.frontier;
      END IF;
    END IF;

    IF preserve_frontier THEN
        UPDATE pgreact_internal.derived_frontiers f
        SET transaction_id = pg_catalog.pg_current_xact_id()
        FROM pgreact_internal.derivation_program_components c
        WHERE c.program_version_id = target_program
          AND f.relation_version_id = ANY (c.target_relations);
    END IF;

    FOR relation_id IN
        SELECT DISTINCT unnest(c.target_relations)
        FROM pgreact_internal.derivation_program_components c
        WHERE c.program_version_id = target_program
        ORDER BY 1
    LOOP
        relation_frontier := pgreact_internal.advance_derived_frontier(relation_id);
        UPDATE pgreact_internal.derived_supports s SET
            active = false,
            grounded = false,
            last_frontier = relation_frontier,
            invalidated_at = clock_timestamp()
        FROM pgreact_internal.derivation_program_rules r
        WHERE r.program_version_id = target_program
          AND r.rule_version_id = s.rule_version_id
          AND s.relation_version_id = relation_id
          AND s.active;
        DELETE FROM pgreact_internal.derived_facts f
        WHERE f.relation_version_id = relation_id;
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_program('after_empty');

    FOR component_row IN
        SELECT * FROM pgreact_internal.derivation_program_components
        WHERE program_version_id = target_program
        ORDER BY component_order
    LOOP
        component_converged := false;
        component_iterations := 0;
        previous_fingerprint := pgreact_internal.derivation_component_fingerprint(
            target_program, component_row.component_id);
        FOR iteration_number IN 1..program_row.max_iterations LOOP
            component_iterations := iteration_number;
            total_iterations := total_iterations + 1;
            FOR rule_row IN
                SELECT * FROM pgreact_internal.derivation_program_rules
                WHERE program_version_id = target_program
                  AND component_id = component_row.component_id
                ORDER BY rule_order, rule_name
            LOOP
                FOR activation_row IN
                    SELECT activation_id
                    FROM pgreact_internal.activation_state
                    WHERE rule_version_id = rule_row.rule_version_id AND active
                    ORDER BY activation_id
                LOOP
                    PERFORM pgreact_internal.maintain_derived_support(
                        rule_row.rule_version_id, activation_row.activation_id);
                END LOOP;
            END LOOP;
            current_fingerprint := pgreact_internal.derivation_component_fingerprint(
                target_program, component_row.component_id);
            SELECT count(*) INTO facts
            FROM pgreact_internal.derived_facts
            WHERE relation_version_id = ANY (component_row.target_relations);
            SELECT count(*) INTO supports
            FROM pgreact_internal.derived_supports s
            JOIN pgreact_internal.derivation_program_rules r
              ON r.program_version_id = target_program
             AND r.component_id = component_row.component_id
             AND r.rule_version_id = s.rule_version_id
            WHERE s.active;
            INSERT INTO pgreact_internal.derivation_program_iterations (
                run_id, program_version_id, component_id, iteration,
                fact_count, support_count, fingerprint, completed_at
            ) VALUES (
                run_id, target_program, component_row.component_id,
                iteration_number, facts, supports,
                current_fingerprint, clock_timestamp()
            );
            IF (
                SELECT count(*) FROM pgreact_internal.derived_facts f
                JOIN pgreact_internal.derivation_program_components c
                  ON c.program_version_id = target_program
                 AND f.relation_version_id = ANY (c.target_relations)
            ) > program_row.max_facts THEN
                RAISE EXCEPTION 'derivation program % exceeded max_facts %',
                    target_program, program_row.max_facts;
            END IF;
            PERFORM pgreact_internal.maybe_fail_program('after_iteration');
            IF current_fingerprint = previous_fingerprint THEN
                component_converged := true;
                EXIT;
            END IF;
            previous_fingerprint := current_fingerprint;
        END LOOP;
        IF NOT component_converged THEN
            RAISE EXCEPTION 'derivation program % component % did not converge within % iterations',
                target_program, component_row.component_id,
                program_row.max_iterations;
        END IF;
        INSERT INTO pgreact_internal.derivation_program_component_frontiers (
            program_version_id, component_id, frontier, iterations,
            fact_count, support_count, fingerprint, committed_at
        ) VALUES (
            target_program, component_row.component_id,
            CASE WHEN preserve_frontier THEN program_row.frontier
                 ELSE program_row.frontier + 1 END,
            component_iterations,
            facts, supports, current_fingerprint, clock_timestamp()
        )
        ON CONFLICT (program_version_id, component_id) DO UPDATE SET
            frontier = EXCLUDED.frontier,
            iterations = EXCLUDED.iterations,
            fact_count = EXCLUDED.fact_count,
            support_count = EXCLUDED.support_count,
            fingerprint = EXCLUDED.fingerprint,
            committed_at = EXCLUDED.committed_at;
    END LOOP;

    IF NOT preserve_frontier THEN
        UPDATE pgreact_internal.derivation_program_versions
        SET frontier = frontier + 1
        WHERE program_version_id = target_program
        RETURNING frontier INTO program_row.frontier;
    END IF;
    SELECT count(*) INTO facts
    FROM pgreact_internal.derived_facts f
    JOIN pgreact_internal.derivation_program_components c
      ON c.program_version_id = target_program
     AND f.relation_version_id = ANY (c.target_relations);
    SELECT count(*) INTO supports
    FROM pgreact_internal.derived_supports s
    JOIN pgreact_internal.derivation_program_rules r
      ON r.program_version_id = target_program
     AND r.rule_version_id = s.rule_version_id
    WHERE s.active;
    UPDATE pgreact_internal.derivation_program_runs SET
        completed_at = clock_timestamp(),
        committed_frontier = program_row.frontier,
        iterations = total_iterations,
        fact_count = facts,
        support_count = supports,
        status = 'COMPLETED'
    WHERE pgreact_internal.derivation_program_runs.run_id = run_id;
    PERFORM pgreact_internal.maybe_fail_program('before_commit');
    RETURN program_row.frontier;
END
$$;

CREATE FUNCTION pgreact_internal.deploy_derivation_program(
    definition jsonb,
    target_pack_version uuid
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    logical_program uuid;
    next_program uuid := gen_random_uuid();
    prior_program uuid;
    component_row record;
    rule_item record;
    input_item record;
    current_rule record;
    target_relation uuid;
    source_oid oid;
    source_digest bytea;
    component_id uuid;
    next_rule uuid;
    orphan_rule uuid;
    watched name[];
    active_activation record;
    removed_rule record;
    diagnostic record;
    caller_oid oid := (
        SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user
    );
BEGIN
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    SELECT * INTO diagnostic
    FROM pgreact.validate_derivation_program(definition) d
    WHERE d.severity = 'ERROR'
    ORDER BY d.code, d.object_identity
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react derivation-program validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    SELECT p.program_id, v.program_version_id
    INTO logical_program, prior_program
    FROM pgreact_internal.derivation_programs p
    LEFT JOIN pgreact_internal.derivation_program_versions v
      ON v.program_id = p.program_id AND v.state = 'ACTIVE'
    WHERE p.program_name = definition ->> 'name';
    IF logical_program IS NULL THEN
        logical_program := gen_random_uuid();
        INSERT INTO pgreact_internal.derivation_programs (
            program_id, program_name, owner_oid
        ) VALUES (logical_program, definition ->> 'name', caller_oid);
    ELSIF NOT EXISTS (
        SELECT 1 FROM pgreact_internal.derivation_programs
        WHERE program_id = logical_program
          AND (owner_oid = caller_oid OR pgreact_internal.is_operator_admin())
    ) THEN
        RAISE EXCEPTION 'only the derivation-program owner or pgreact_admin may replace %',
            definition ->> 'name';
    END IF;
    IF prior_program IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.derivation_program_versions
        WHERE program_version_id = prior_program
          AND version = (definition ->> 'version')::integer
          AND definition = deploy_derivation_program.definition
    ) THEN
        RETURN prior_program;
    END IF;
    UPDATE pgreact_internal.derivation_program_versions
    SET state = 'REMOVED'
    WHERE program_version_id = prior_program;
    FOR removed_rule IN
        SELECT r.rule_version_id
        FROM pgreact_internal.derivation_program_rules r
        WHERE r.program_version_id = prior_program
          AND NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements(definition -> 'rules') incoming
              WHERE incoming ->> 'name' = r.rule_name
          )
        ORDER BY r.rule_order DESC, r.rule_name DESC
    LOOP
        PERFORM pgreact_internal.retire_derivation_rule(
            removed_rule.rule_version_id);
    END LOOP;
    INSERT INTO pgreact_internal.derivation_program_versions (
        program_version_id, program_id, pack_version_id, version,
        owner_oid, definition, definition_digest, max_iterations,
        max_facts, state
    ) VALUES (
        next_program, logical_program, target_pack_version,
        (definition ->> 'version')::integer, caller_oid, definition,
        sha256(convert_to(definition::text, 'UTF8')),
        (definition ->> 'max_iterations')::integer,
        (definition ->> 'max_facts')::bigint, 'ACTIVE'
    );
    FOR component_row IN
        SELECT * FROM pgreact_internal.derivation_program_components(definition)
    LOOP
        INSERT INTO pgreact_internal.derivation_program_components (
            program_version_id, component_id, component_order, cyclic,
            rule_names, target_relations
        ) SELECT
            next_program, component_row.component_id,
            component_row.component_order, component_row.cyclic,
            component_row.rule_names,
            ARRAY(
                SELECT v.relation_version_id
                FROM unnest(component_row.target_names) WITH ORDINALITY names(name, ordinal)
                JOIN pgreact_internal.derived_relations r ON r.relation_name = names.name
                JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
                WHERE v.state = 'ACTIVE' ORDER BY names.ordinal
            );
    END LOOP;

    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY r(value, ordinal)
        ORDER BY ordinal
    LOOP
        source_oid := pg_catalog.to_regclass(rule_item.value ->> 'definition');
        source_digest := pgreact_internal.source_closure_digest(source_oid);
        SELECT v.relation_version_id INTO STRICT target_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = rule_item.value ->> 'target'
          AND v.state = 'ACTIVE';
        SELECT c.component_id INTO STRICT component_id
        FROM pgreact_internal.derivation_program_components c
        WHERE c.program_version_id = next_program
          AND rule_item.value ->> 'name' = ANY (c.rule_names);
        SELECT v.rule_version_id, v.rule_id, v.rule_kind,
               v.source_view_name, v.source_definition,
               d.version, d.relation_version_id,
               prior_member.source_definition_digest
        INTO current_rule
        FROM pgreact_internal.rules r
        JOIN pgreact_internal.rule_versions v USING (rule_id)
        LEFT JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
        LEFT JOIN pgreact_internal.derivation_program_rules prior_member
          ON prior_member.program_version_id = prior_program
         AND prior_member.rule_version_id = v.rule_version_id
        WHERE r.rule_name = rule_item.value ->> 'name'
          AND v.state <> 'REMOVED'
        ORDER BY v.created_at DESC LIMIT 1;
        IF FOUND AND current_rule.rule_kind = 'DERIVATION'
           AND current_rule.version = (rule_item.value ->> 'version')::integer
           AND current_rule.source_view_name = rule_item.value ->> 'definition'
           AND current_rule.source_definition = pg_catalog.pg_get_viewdef(source_oid, true)
           AND current_rule.source_definition_digest = source_digest
           AND current_rule.relation_version_id = target_relation THEN
            next_rule := current_rule.rule_version_id;
        ELSE
            IF FOUND AND (current_rule.rule_kind <> 'DERIVATION'
               OR current_rule.version >= (rule_item.value ->> 'version')::integer) THEN
                RAISE EXCEPTION 'immutable rule version conflict for program rule %',
                    rule_item.value ->> 'name';
            END IF;
            IF FOUND THEN
                UPDATE pgreact_internal.rule_versions SET state = 'REMOVED'
                WHERE rule_version_id = current_rule.rule_version_id;
            END IF;
            next_rule := pgreact_internal.register_reference_rule(
                rule_item.value ->> 'name', source_oid::regclass,
                (rule_item.value ->> 'key')::name, NULL, 'SEED_CURRENT');
            SELECT array_agg(a.attname ORDER BY a.attnum) INTO watched
            FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = source_oid AND a.attnum > 0 AND NOT a.attisdropped
              AND a.attname <> (rule_item.value ->> 'key')::name;
            UPDATE pgreact_internal.rule_versions
            SET rule_kind = 'DERIVATION', change_columns = watched
            WHERE rule_version_id = next_rule;
            INSERT INTO pgreact_internal.derivation_rule_versions (
                rule_version_id, rule_id, relation_version_id, version
            ) SELECT next_rule, rule_id, target_relation,
                     (rule_item.value ->> 'version')::integer
              FROM pgreact_internal.rule_versions
              WHERE rule_version_id = next_rule;
            IF current_rule.rule_version_id IS NOT NULL THEN
                SELECT rule_id INTO STRICT orphan_rule
                FROM pgreact_internal.rule_versions
                WHERE rule_version_id = next_rule;
                UPDATE pgreact_internal.rule_versions SET rule_id = current_rule.rule_id
                WHERE rule_version_id = next_rule;
                UPDATE pgreact_internal.derivation_rule_versions SET rule_id = current_rule.rule_id
                WHERE rule_version_id = next_rule;
                DELETE FROM pgreact_internal.rules WHERE rule_id = orphan_rule;
                PERFORM pgreact_internal.retire_derivation_rule(
                    current_rule.rule_version_id);
            END IF;
        END IF;
        INSERT INTO pgreact_internal.derivation_program_rules (
            program_version_id, rule_version_id, rule_name, rule_order,
            component_id, source_view_oid, source_view_name,
            source_definition, source_definition_digest,
            target_relation_version_id
        ) VALUES (
            next_program, next_rule, rule_item.value ->> 'name',
            rule_item.ordinal, component_id, source_oid,
            rule_item.value ->> 'definition',
            pg_catalog.pg_get_viewdef(source_oid, true),
            source_digest,
            target_relation
        );
        FOR input_item IN
            SELECT value, ordinal
            FROM jsonb_array_elements(rule_item.value -> 'inputs')
            WITH ORDINALITY i(value, ordinal)
        LOOP
            INSERT INTO pgreact_internal.derivation_program_inputs (
                program_version_id, rule_version_id, input_order,
                relation_version_id, key_column
            ) SELECT
                next_program, next_rule, input_item.ordinal,
                v.relation_version_id, (input_item.value ->> 'key')::name
            FROM pgreact_internal.derived_relations r
            JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
            WHERE r.relation_name = input_item.value ->> 'relation'
              AND v.state = 'ACTIVE';
        END LOOP;
        FOR active_activation IN
            SELECT activation_id
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = next_rule AND active
            ORDER BY activation_id
        LOOP
            PERFORM pgreact_internal.maintain_derived_support(
                next_rule, active_activation.activation_id);
        END LOOP;
    END LOOP;
    PERFORM pgreact_internal.rebuild_derivation_program(next_program, true);
    RETURN next_program;
END
$$;

CREATE FUNCTION pgreact_internal.m8_pack_definition(definition jsonb)
RETURNS jsonb
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT $1 - 'programs' - 'remove_programs'
$$;

CREATE FUNCTION pgreact_internal.m8_program_definition(
    program jsonb,
    mappings jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_set($1, '{rules}', COALESCE((
        SELECT jsonb_agg(
            (rule_item - 'definition' - 'target' - 'inputs') ||
            jsonb_build_object(
                'definition', pgreact_internal.pack_mapping(
                    $2, 'objects', rule_item ->> 'definition'),
                'target', pgreact_internal.pack_mapping(
                    $2, 'objects', rule_item ->> 'target'),
                'inputs', COALESCE((
                    SELECT jsonb_agg(
                        (input_item - 'relation') || jsonb_build_object(
                            'relation', pgreact_internal.pack_mapping(
                                $2, 'objects', input_item ->> 'relation'))
                        ORDER BY input_ordinal
                    )
                    FROM jsonb_array_elements(rule_item -> 'inputs')
                    WITH ORDINALITY inputs(input_item, input_ordinal)
                ), '[]'::jsonb)
            ) ORDER BY rule_ordinal
        )
        FROM jsonb_array_elements($1 -> 'rules')
        WITH ORDINALITY rules(rule_item, rule_ordinal)
    ), '[]'::jsonb), true)
$$;

CREATE FUNCTION pgreact_internal.m8_pack_plan_digest(
    definition jsonb,
    mappings jsonb
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    base_digest text;
    material text;
    item record;
    program_state text;
    source_state text;
    mapped_program jsonb;
BEGIN
    SELECT plan_digest INTO base_digest
    FROM pgreact_internal.preview_pack(
        pgreact_internal.m8_pack_definition(definition), mappings)
    ORDER BY action_order LIMIT 1;
    material := definition::text || E'\n' || mappings::text ||
        E'\nbase:' || COALESCE(base_digest, '<empty>') ||
        E'\nowner:' || session_user;
    FOR item IN
        SELECT program, program_ordinal, rule, rule_ordinal
        FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb))
             WITH ORDINALITY programs(program, program_ordinal)
        LEFT JOIN LATERAL jsonb_array_elements(program -> 'rules')
             WITH ORDINALITY rules(rule, rule_ordinal) ON true
        ORDER BY program_ordinal, rule_ordinal
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            item.program, mappings);
        SELECT concat_ws(':', v.program_version_id, v.version, v.state,
                         v.frontier, encode(v.definition_digest, 'hex'))
        INTO program_state
        FROM pgreact_internal.derivation_programs p
        JOIN pgreact_internal.derivation_program_versions v USING (program_id)
        WHERE p.program_name = item.program ->> 'name' AND v.state = 'ACTIVE';
        IF item.rule IS NOT NULL THEN
            SELECT concat_ws(':', c.oid,
                encode(pgreact_internal.source_closure_digest(c.oid), 'hex'),
                pgreact_internal.source_row_signature(c.oid))
            INTO source_state
            FROM pg_catalog.pg_class c
            WHERE c.oid = pg_catalog.to_regclass(
                mapped_program -> 'rules' -> (item.rule_ordinal - 1)::integer ->> 'definition');
        ELSE
            source_state := '<no-rule>';
        END IF;
        material := material || format(E'\nprogram:%s:%s:%s:rule:%s:%s:%s',
            item.program_ordinal, item.program ->> 'name',
            COALESCE(program_state, '<add>'), item.rule_ordinal,
            COALESCE(item.rule ->> 'name', '<none>'),
            COALESCE(source_state, '<missing>'));
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
$$;

CREATE FUNCTION pgreact.validate_pack(
    definition jsonb,
    mappings jsonb DEFAULT '{}'::jsonb
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
#variable_conflict use_variable
DECLARE
    diagnostic record;
    program_item record;
    removal_item record;
    unknown_key text;
    duplicate_name text;
    prior_pack uuid;
    has_error boolean := false;
    mapped_program jsonb;
    base_item record;
    mapped_name text;
    active_relation record;
    overlap record;
    pack_owner record;
BEGIN
    FOR base_item IN
        SELECT value FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'derived_relations') = 'array'
            THEN definition -> 'derived_relations' ELSE '[]'::jsonb END) value
    LOOP
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', base_item.value ->> 'name');
        SELECT v.relation_version_id, v.version INTO active_relation
        FROM pgreact_internal.derived_relations r
        JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
        WHERE r.relation_name = mapped_name AND v.state = 'ACTIVE';
        IF FOUND AND active_relation.version IS DISTINCT FROM
                     (base_item.value ->> 'version')::integer
           AND EXISTS (
               SELECT 1
               FROM pgreact_internal.derivation_program_components c
               JOIN pgreact_internal.derivation_program_versions p USING (program_version_id)
               WHERE p.state = 'ACTIVE'
                 AND active_relation.relation_version_id = ANY (c.target_relations)
           ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_OBJECT_MANAGED', 'ERROR', mapped_name,
                'active program target relations cannot be replaced through legacy pack fields',
                'Replace the complete derivation program.', '{}'::jsonb;
            RETURN;
        END IF;
    END LOOP;
    FOR base_item IN
        SELECT value FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'remove_derived_relations') = 'array'
            THEN definition -> 'remove_derived_relations' ELSE '[]'::jsonb END) value
    LOOP
        mapped_name := pgreact_internal.pack_mapping(
            mappings, 'objects', base_item.value ->> 'name');
        IF EXISTS (
            SELECT 1
            FROM pgreact_internal.derived_relations r
            JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
            JOIN pgreact_internal.derivation_program_components c
              ON v.relation_version_id = ANY (c.target_relations)
            JOIN pgreact_internal.derivation_program_versions p USING (program_version_id)
            WHERE r.relation_name = mapped_name
              AND v.state = 'ACTIVE' AND p.state = 'ACTIVE'
        ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_OBJECT_MANAGED', 'ERROR', mapped_name,
                'active program target relations cannot be removed through legacy pack fields',
                'Remove the complete derivation program first.', '{}'::jsonb;
            RETURN;
        END IF;
    END LOOP;
    FOR base_item IN
        SELECT value, object_kind
        FROM (
            SELECT value, 'derivation'::text AS object_kind
            FROM jsonb_array_elements(CASE
                WHEN pg_catalog.jsonb_typeof(definition -> 'derivations') = 'array'
                THEN definition -> 'derivations' ELSE '[]'::jsonb END) value
            UNION ALL
            SELECT value, 'rule'
            FROM jsonb_array_elements(CASE
                WHEN pg_catalog.jsonb_typeof(definition -> 'rules') = 'array'
                THEN definition -> 'rules' ELSE '[]'::jsonb END) value
            UNION ALL
            SELECT value, 'remove_derivation'
            FROM jsonb_array_elements(CASE
                WHEN pg_catalog.jsonb_typeof(definition -> 'remove_derivations') = 'array'
                THEN definition -> 'remove_derivations' ELSE '[]'::jsonb END) value
            UNION ALL
            SELECT value, 'remove_rule'
            FROM jsonb_array_elements(CASE
                WHEN pg_catalog.jsonb_typeof(definition -> 'remove') = 'array'
                THEN definition -> 'remove' ELSE '[]'::jsonb END) value
        ) objects
    LOOP
        IF EXISTS (
            SELECT 1
            FROM pgreact_internal.rules r
            JOIN pgreact_internal.rule_versions v USING (rule_id)
            JOIN pgreact_internal.derivation_program_rules member
              ON member.rule_version_id = v.rule_version_id
            JOIN pgreact_internal.derivation_program_versions program
              USING (program_version_id)
            WHERE r.rule_name = base_item.value ->> 'name'
              AND v.state = 'ACTIVE' AND program.state = 'ACTIVE'
        ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_OBJECT_MANAGED', 'ERROR',
                base_item.value ->> 'name',
                'active program members cannot be associated, replaced, or removed through legacy pack fields',
                'Replace or remove the complete derivation program.',
                jsonb_build_object('field_kind', base_item.object_kind);
            RETURN;
        END IF;
        IF base_item.object_kind = 'derivation' THEN
            mapped_name := pgreact_internal.pack_mapping(
                mappings, 'objects', base_item.value ->> 'target');
            IF EXISTS (
                SELECT 1
                FROM pgreact_internal.derived_relations r
                JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
                JOIN pgreact_internal.derivation_program_components c
                  ON v.relation_version_id = ANY (c.target_relations)
                JOIN pgreact_internal.derivation_program_versions p USING (program_version_id)
                WHERE r.relation_name = mapped_name
                  AND v.state = 'ACTIVE' AND p.state = 'ACTIVE'
            ) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_OBJECT_MANAGED', 'ERROR', mapped_name,
                    'active program target relations cannot accept legacy pack producers',
                    'Replace the complete derivation program.', '{}'::jsonb;
                RETURN;
            END IF;
        END IF;
    END LOOP;
    IF NOT (definition ? 'programs' OR definition ? 'remove_programs') THEN
        RETURN QUERY SELECT * FROM pgreact_internal.validate_pack(definition, mappings);
        RETURN;
    END IF;
    IF (definition ? 'programs'
        AND pg_catalog.jsonb_typeof(definition -> 'programs') IS DISTINCT FROM 'array')
       OR (definition ? 'remove_programs'
           AND pg_catalog.jsonb_typeof(definition -> 'remove_programs') IS DISTINCT FROM 'array') THEN
        RETURN QUERY SELECT 3, 'PROGRAM_INVALID', 'ERROR', '<pack>',
            'programs and remove_programs must be arrays when present',
            'Use an array or omit the field.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT key INTO unknown_key FROM jsonb_object_keys(definition) key
    WHERE key <> ALL (ARRAY[
        'format_version', 'pack', 'version', 'owner', 'rules', 'remove',
        'derived_relations', 'derivations', 'remove_derivations',
        'remove_derived_relations', 'programs', 'remove_programs'
    ]) ORDER BY key LIMIT 1;
    IF unknown_key IS NOT NULL THEN
        RETURN QUERY SELECT 3, 'PROGRAM_FIELD_UNKNOWN', 'ERROR', unknown_key,
            'M8 pack contains an unknown top-level field',
            'Remove the field.', '{}'::jsonb;
        RETURN;
    END IF;
    FOR diagnostic IN
        SELECT * FROM pgreact_internal.validate_pack(
            pgreact_internal.m8_pack_definition(definition), mappings)
        WHERE code <> 'OK'
    LOOP
        RETURN QUERY SELECT 3, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message,
            diagnostic.hint, diagnostic.details;
        has_error := has_error OR diagnostic.severity = 'ERROR';
    END LOOP;
    IF has_error THEN RETURN; END IF;
    SELECT name INTO duplicate_name
    FROM (
        SELECT value ->> 'name' AS name
        FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb)) value
        UNION ALL
        SELECT value ->> 'name'
        FROM jsonb_array_elements(COALESCE(definition -> 'remove_programs', '[]'::jsonb)) value
    ) names
    GROUP BY name HAVING count(*) > 1 OR name IS NULL
    ORDER BY name NULLS FIRST LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 3, 'PROGRAM_DUPLICATE_RULE', 'ERROR',
            COALESCE(duplicate_name, '<unnamed>'),
            'program names must be unique across additions and removals',
            'Keep one action per program name.', '{}'::jsonb;
        RETURN;
    END IF;
    SELECT item.value ->> 'name' AS program_name,
           owner_pack.pack_name AS owner_pack
    INTO pack_owner
    FROM jsonb_array_elements(
        COALESCE(definition -> 'programs', '[]'::jsonb)) item(value)
    JOIN pgreact_internal.rule_pack_programs owned
      ON owned.program_name = item.value ->> 'name'
    JOIN pgreact_internal.rule_pack_versions owner_version
      USING (pack_version_id)
    JOIN pgreact_internal.rule_packs owner_pack USING (pack_id)
    JOIN pgreact_internal.derivation_program_versions owned_program
      ON owned_program.program_version_id = owned.program_version_id
    WHERE owner_version.state = 'ACTIVE'
      AND owned_program.state = 'ACTIVE'
      AND owner_pack.pack_name <> definition ->> 'pack'
    ORDER BY item.value ->> 'name', owner_pack.pack_name
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 3, 'PROGRAM_PACK_OWNERSHIP', 'ERROR',
            pack_owner.program_name,
            'active derivation program cannot be replaced by another logical pack',
            'Deploy the next version through its owning logical pack.',
            jsonb_build_object(
                'action', 'REPLACE',
                'incoming_pack', definition ->> 'pack',
                'owner_pack', pack_owner.owner_pack);
        RETURN;
    END IF;
    SELECT item.value ->> 'name' AS program_name,
           owner_pack.pack_name AS owner_pack
    INTO pack_owner
    FROM jsonb_array_elements(
        COALESCE(definition -> 'remove_programs', '[]'::jsonb)) item(value)
    JOIN pgreact_internal.rule_pack_programs owned
      ON owned.program_name = item.value ->> 'name'
    JOIN pgreact_internal.rule_pack_versions owner_version
      USING (pack_version_id)
    JOIN pgreact_internal.rule_packs owner_pack USING (pack_id)
    JOIN pgreact_internal.derivation_program_versions owned_program
      ON owned_program.program_version_id = owned.program_version_id
    WHERE owner_version.state = 'ACTIVE'
      AND owned_program.state = 'ACTIVE'
      AND owner_pack.pack_name <> definition ->> 'pack'
    ORDER BY item.value ->> 'name', owner_pack.pack_name
    LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 3, 'PROGRAM_PACK_OWNERSHIP', 'ERROR',
            pack_owner.program_name,
            'active derivation program cannot be removed by another logical pack',
            'Remove the program through its owning logical pack.',
            jsonb_build_object(
                'action', 'REMOVE',
                'incoming_pack', definition ->> 'pack',
                'owner_pack', pack_owner.owner_pack);
        RETURN;
    END IF;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb)) value
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            program_item.value, mappings);
        FOR diagnostic IN
            SELECT * FROM pgreact.validate_derivation_program(mapped_program)
            WHERE code <> 'OK'
        LOOP
            RETURN QUERY SELECT 3, diagnostic.code, diagnostic.severity,
                diagnostic.object_identity, diagnostic.message,
                diagnostic.hint, diagnostic.details;
            has_error := has_error OR diagnostic.severity = 'ERROR';
        END LOOP;
    END LOOP;
    IF has_error THEN RETURN; END IF;
    WITH mapped_programs AS (
        SELECT programs.program_ordinal,
               pgreact_internal.m8_program_definition(
                   programs.program_item, mappings) AS mapped_program
        FROM jsonb_array_elements(
            COALESCE(definition -> 'programs', '[]'::jsonb))
        WITH ORDINALITY programs(program_item, program_ordinal)
    ), members AS (
        SELECT p.program_ordinal,
               p.mapped_program ->> 'name' AS program_name,
               rule_item ->> 'name' AS rule_name,
               rule_item ->> 'target' AS target_name
        FROM mapped_programs p
        CROSS JOIN LATERAL jsonb_array_elements(
            p.mapped_program -> 'rules') rules(rule_item)
    ), program_overlaps AS (
        SELECT 'RULE'::text AS overlap_kind,
               left_member.rule_name AS object_identity,
               least(left_member.program_name, right_member.program_name) AS program_a,
               greatest(left_member.program_name, right_member.program_name) AS program_b
        FROM members left_member
        JOIN members right_member
          ON left_member.program_ordinal < right_member.program_ordinal
         AND left_member.rule_name = right_member.rule_name
        UNION ALL
        SELECT 'TARGET', left_member.target_name,
               least(left_member.program_name, right_member.program_name),
               greatest(left_member.program_name, right_member.program_name)
        FROM members left_member
        JOIN members right_member
          ON left_member.program_ordinal < right_member.program_ordinal
         AND left_member.target_name = right_member.target_name
    )
    SELECT program_overlaps.overlap_kind,
           program_overlaps.object_identity,
           program_overlaps.program_a,
           program_overlaps.program_b
    INTO overlap
    FROM program_overlaps
    ORDER BY CASE program_overlaps.overlap_kind WHEN 'RULE' THEN 1 ELSE 2 END,
             program_overlaps.object_identity,
             program_overlaps.program_a,
             program_overlaps.program_b
    LIMIT 1;
    IF FOUND AND overlap.overlap_kind = 'RULE' THEN
        RETURN QUERY SELECT 3, 'PROGRAM_RULE_OVERLAP', 'ERROR',
            overlap.object_identity,
            'rule name is shared by multiple derivation programs in the same pack',
            'Give every derivation-program rule one owning program.',
            jsonb_build_object(
                'programs', jsonb_build_array(overlap.program_a, overlap.program_b));
        RETURN;
    ELSIF FOUND THEN
        RETURN QUERY SELECT 3, 'PROGRAM_TARGET_OVERLAP', 'ERROR',
            overlap.object_identity,
            'target relation is shared by multiple derivation programs in the same pack',
            'Give every target relation one owning derivation program.',
            jsonb_build_object(
                'programs', jsonb_build_array(overlap.program_a, overlap.program_b));
        RETURN;
    END IF;
    FOR removal_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(definition -> 'remove_programs', '[]'::jsonb)) value
    LOOP
        IF pg_catalog.jsonb_typeof(removal_item.value) IS DISTINCT FROM 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(removal_item.value)) <> 1
           OR removal_item.value ->> 'name' IS NULL
           OR NOT EXISTS (
               SELECT 1 FROM pgreact_internal.derivation_programs p
               JOIN pgreact_internal.derivation_program_versions v USING (program_id)
               WHERE p.program_name = removal_item.value ->> 'name'
                 AND v.state = 'ACTIVE'
                 AND (v.owner_oid = (SELECT oid FROM pg_catalog.pg_roles
                                     WHERE rolname = session_user)
                      OR pgreact_internal.is_operator_admin())
           ) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_OBJECT_UNRESOLVED', 'ERROR',
                COALESCE(removal_item.value ->> 'name', '<program>'),
                'remove_programs entries must name an active caller-managed program',
                'Use exactly {"name":"program"}.', '{}'::jsonb;
            RETURN;
        END IF;
    END LOOP;
    SELECT v.pack_version_id INTO prior_pack
    FROM pgreact_internal.rule_packs p
    JOIN pgreact_internal.rule_pack_versions v USING (pack_id)
    WHERE p.pack_name = definition ->> 'pack' AND v.state = 'ACTIVE';
    IF prior_pack IS NOT NULL AND EXISTS (
        SELECT 1 FROM pgreact_internal.rule_pack_programs old
        WHERE old.pack_version_id = prior_pack
          AND NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb)) item
              WHERE item ->> 'name' = old.program_name
          )
          AND NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements(COALESCE(definition -> 'remove_programs', '[]'::jsonb)) item
              WHERE item ->> 'name' = old.program_name
          )
    ) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_GRAPH_OPEN', 'ERROR', '<pack>',
            'every omitted program requires an explicit removal',
            'Keep it in programs or list it in remove_programs.', '{}'::jsonb;
        RETURN;
    END IF;
    RETURN QUERY SELECT 3, 'OK', 'INFO', definition ->> 'pack',
        'M8 pack and derivation programs are valid',
        'Preview and deploy with the exact plan digest.',
        jsonb_build_object('programs', jsonb_array_length(COALESCE(definition -> 'programs', '[]'::jsonb)),
                           'remove_programs', jsonb_array_length(COALESCE(definition -> 'remove_programs', '[]'::jsonb)));
END
$$;

CREATE FUNCTION pgreact.preview_pack(
    definition jsonb,
    mappings jsonb DEFAULT '{}'::jsonb
)
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
    preview_row record;
    program_item record;
    current_program record;
    digest text;
    ordinal integer := 0;
    dependency_names text[];
    mapped_program jsonb;
BEGIN
    IF NOT (definition ? 'programs' OR definition ? 'remove_programs') THEN
        SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
        WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'pg-react pack validation % for %: %',
                diagnostic.code, diagnostic.object_identity, diagnostic.message
                USING HINT = diagnostic.hint;
        END IF;
        RETURN QUERY SELECT * FROM pgreact_internal.preview_pack(definition, mappings);
        RETURN;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    digest := pgreact_internal.m8_pack_plan_digest(definition, mappings);
    FOR preview_row IN
        SELECT * FROM pgreact_internal.preview_pack(
            pgreact_internal.m8_pack_definition(definition), mappings)
        ORDER BY action_order
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := preview_row.action;
        rule_name := preview_row.rule_name;
        dependencies := preview_row.dependencies;
        generated_object_changes := preview_row.generated_object_changes;
        lifecycle_risks := preview_row.lifecycle_risks;
        details := preview_row.details;
        RETURN NEXT;
    END LOOP;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb)) value
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            program_item.value, mappings);
        SELECT v.program_version_id, v.version INTO current_program
        FROM pgreact_internal.derivation_programs p
        JOIN pgreact_internal.derivation_program_versions v USING (program_id)
        WHERE p.program_name = program_item.value ->> 'name'
          AND v.state = 'ACTIVE';
        SELECT array_agg(value ->> 'name' ORDER BY ordinal)::text[]
        INTO dependency_names
        FROM jsonb_array_elements(program_item.value -> 'rules')
        WITH ORDINALITY r(value, ordinal);
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_program.program_version_id IS NULL THEN 'ADD'
                       WHEN current_program.version =
                            (program_item.value ->> 'version')::integer THEN 'KEEP'
                       ELSE 'REPLACE' END;
        rule_name := program_item.value ->> 'name';
        dependencies := COALESCE(dependency_names, ARRAY[]::text[]);
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION_PROGRAM',
            'components', (SELECT count(*)
                           FROM pgreact_internal.derivation_program_components(mapped_program)));
        lifecycle_risks := jsonb_build_array(
            'the complete program is rebuilt and commits at one frontier');
        details := jsonb_build_object(
            'prior_program_version_id', current_program.program_version_id,
            'prior_version', current_program.version,
            'next_version', (program_item.value ->> 'version')::integer,
            'max_iterations', (program_item.value ->> 'max_iterations')::integer,
            'max_facts', (program_item.value ->> 'max_facts')::bigint);
        RETURN NEXT;
    END LOOP;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(definition -> 'remove_programs', '[]'::jsonb)) value
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := 'REMOVE';
        rule_name := program_item.value ->> 'name';
        dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION_PROGRAM');
        lifecycle_risks := jsonb_build_array(
            'all member supports and facts retract atomically');
        details := '{}'::jsonb;
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.remove_derivation_program(target_program uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    rule_row record;
    relation_id uuid;
BEGIN
    SELECT * INTO STRICT program_row
    FROM pgreact_internal.derivation_program_versions
    WHERE program_version_id = target_program AND state = 'ACTIVE';
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    FOR rule_row IN
        SELECT rule_version_id
        FROM pgreact_internal.derivation_program_rules
        WHERE program_version_id = target_program
        ORDER BY rule_order DESC, rule_name DESC
    LOOP
        PERFORM pgreact_internal.retire_derivation_rule(rule_row.rule_version_id);
    END LOOP;
    UPDATE pgreact_internal.derived_supports s SET
        active = false,
        grounded = false,
        last_frontier = COALESCE(last_frontier, program_row.frontier + 1),
        invalidated_at = COALESCE(invalidated_at, clock_timestamp())
    FROM pgreact_internal.derivation_program_rules r
    WHERE r.program_version_id = target_program
      AND r.rule_version_id = s.rule_version_id AND s.active;
    FOR relation_id IN
        SELECT DISTINCT unnest(target_relations)
        FROM pgreact_internal.derivation_program_components
        WHERE program_version_id = target_program
    LOOP
        DELETE FROM pgreact_internal.derived_facts
        WHERE relation_version_id = relation_id;
    END LOOP;
    UPDATE pgreact_internal.derivation_program_versions
    SET state = 'REMOVED' WHERE program_version_id = target_program;
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
    actual_digest text;
    base_definition jsonb;
    base_digest text;
    pack_version uuid;
    program_item record;
    program_version uuid;
    mapped_program jsonb;
BEGIN
    IF NOT (definition ? 'programs' OR definition ? 'remove_programs') THEN
        SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
        WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'pg-react pack validation % for %: %',
                diagnostic.code, diagnostic.object_identity, diagnostic.message
                USING HINT = diagnostic.hint;
        END IF;
        RETURN pgreact_internal.deploy_pack(
            definition, expected_plan_digest, mappings);
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    actual_digest := pgreact_internal.m8_pack_plan_digest(definition, mappings);
    IF expected_plan_digest IS DISTINCT FROM actual_digest THEN
        RAISE EXCEPTION 'rule-pack preview is stale'
            USING HINT = 'Run pgreact.preview_pack again after concurrent DDL, support, or deployment changes.',
                  DETAIL = format('expected %s, current %s',
                                  expected_plan_digest, actual_digest);
    END IF;
    base_definition := pgreact_internal.m8_pack_definition(definition);
    SELECT plan_digest INTO base_digest
    FROM pgreact_internal.preview_pack(base_definition, mappings)
    ORDER BY action_order LIMIT 1;
    pack_version := pgreact_internal.deploy_pack(
        base_definition, base_digest, mappings);
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb)) value
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            program_item.value, mappings);
        program_version := pgreact_internal.deploy_derivation_program(
            mapped_program, pack_version);
        INSERT INTO pgreact_internal.rule_pack_programs (
            pack_version_id, program_name, program_version_id
        ) VALUES (
            pack_version, program_item.value ->> 'name', program_version
        );
    END LOOP;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(definition -> 'remove_programs', '[]'::jsonb)) value
    LOOP
        SELECT v.program_version_id INTO STRICT program_version
        FROM pgreact_internal.derivation_programs p
        JOIN pgreact_internal.derivation_program_versions v USING (program_id)
        WHERE p.program_name = program_item.value ->> 'name'
          AND v.state = 'ACTIVE';
        PERFORM pgreact_internal.remove_derivation_program(program_version);
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_pack('programs');
    UPDATE pgreact_internal.rule_pack_versions SET
        definition = deploy_pack.definition,
        definition_digest = sha256(convert_to(deploy_pack.definition::text, 'UTF8')),
        plan_digest = actual_digest
    WHERE pack_version_id = pack_version;
    RETURN pack_version;
END
$$;

CREATE FUNCTION pgreact.refresh_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_rules r
        JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
        WHERE r.rule_version_id = target_version_id AND v.state = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'program member % cannot be refreshed independently',
            target_version_id
            USING HINT = 'Use pgreact.refresh_derivation_program.';
    END IF;
    PERFORM pgreact_internal.refresh_rule_m7(target_version_id);
END
$$;

CREATE FUNCTION pgreact.refresh_derived_relation(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_components c
        JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
        WHERE target_relation = ANY (c.target_relations) AND v.state = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'program relation % cannot be refreshed independently',
            target_relation
            USING HINT = 'Use pgreact.refresh_derivation_program.';
    END IF;
    RETURN pgreact_internal.refresh_derived_relation_m7(target_relation);
END
$$;

CREATE FUNCTION pgreact.reconcile_derived_relation(target_relation uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_components c
        JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
        WHERE target_relation = ANY (c.target_relations) AND v.state = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'program relation % cannot be reconciled independently',
            target_relation
            USING HINT = 'Use pgreact.reconcile_derivation_program.';
    END IF;
    RETURN pgreact_internal.reconcile_derived_relation_m7(target_relation);
END
$$;

CREATE FUNCTION pgreact.refresh_derivation_program(target_program uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    refresh_run_id bigint;
    result bigint;
    failure_sqlstate text;
    failure_message text;
    failure_detail text;
    failure_hint text;
BEGIN
    program_row := pgreact_internal.assert_program_owner(target_program);
    INSERT INTO pgreact_internal.derivation_program_runs (
        program_version_id, started_at, prior_frontier, status, requested_by
    ) VALUES (
        target_program, clock_timestamp(), program_row.frontier,
        'RUNNING', session_user
    ) RETURNING pgreact_internal.derivation_program_runs.run_id INTO refresh_run_id;
    BEGIN
        result := pgreact_internal.rebuild_derivation_program(
            target_program, false, false, refresh_run_id);
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            failure_sqlstate = RETURNED_SQLSTATE,
            failure_message = MESSAGE_TEXT,
            failure_detail = PG_EXCEPTION_DETAIL,
            failure_hint = PG_EXCEPTION_HINT;
        UPDATE pgreact_internal.derivation_program_runs SET
            completed_at = clock_timestamp(),
            committed_frontier = program_row.frontier,
            iterations = 0,
            status = 'FAILED',
            error_sqlstate = failure_sqlstate,
            error_message = failure_message,
            error_detail = NULLIF(failure_detail, ''),
            error_hint = NULLIF(failure_hint, '')
        WHERE pgreact_internal.derivation_program_runs.run_id = refresh_run_id;
        RETURN NULL;
    END;
    RETURN result;
END
$$;

CREATE FUNCTION pgreact.remove_derivation_program(target_program uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_program_owner(target_program);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.rule_pack_programs p
        JOIN pgreact_internal.rule_pack_versions v USING (pack_version_id)
        WHERE p.program_version_id = target_program AND v.state = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'active pack-owned program % cannot be removed directly',
            target_program
            USING HINT = 'Deploy the next pack version with the program in remove_programs.';
    END IF;
    PERFORM pgreact_internal.remove_derivation_program(target_program);
END
$$;

CREATE FUNCTION pgreact_internal.grounded_program_facts(target_program uuid)
RETURNS uuid[]
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    grounded uuid[];
    additions uuid[];
BEGIN
    SELECT COALESCE(array_agg(DISTINCT s.fact_id ORDER BY s.fact_id), ARRAY[]::uuid[])
    INTO grounded
    FROM pgreact_internal.derived_supports s
    JOIN pgreact_internal.derivation_program_rules r
      ON r.program_version_id = target_program
     AND r.rule_version_id = s.rule_version_id
    WHERE s.active AND NOT EXISTS (
        SELECT 1
        FROM pgreact_internal.derivation_program_inputs i
        WHERE i.program_version_id = target_program
          AND i.rule_version_id = r.rule_version_id
    );
    LOOP
        SELECT COALESCE(array_agg(fact_id ORDER BY fact_id), ARRAY[]::uuid[])
        INTO additions
        FROM (
            SELECT DISTINCT s.fact_id
            FROM pgreact_internal.derived_supports s
            JOIN pgreact_internal.derivation_program_rules r
              ON r.program_version_id = target_program
             AND r.rule_version_id = s.rule_version_id
            WHERE s.active AND NOT (s.fact_id = ANY (grounded))
              AND EXISTS (
                  SELECT 1
                  FROM pgreact_internal.derivation_program_inputs i
                  WHERE i.program_version_id = target_program
                    AND i.rule_version_id = r.rule_version_id
              )
              AND NOT EXISTS (
                  SELECT 1
                  FROM pgreact_internal.derivation_program_inputs expected
                  LEFT JOIN pgreact_internal.derived_support_inputs actual
                    ON actual.support_id = s.support_id
                   AND actual.input_order = expected.input_order
                   AND actual.relation_version_id = expected.relation_version_id
                   AND actual.semantic_key = s.semantic_key
                   AND actual.fact_id = pgreact_internal.activation_uuid(
                       pgreact_internal.activation_digest(
                           expected.relation_version_id,
                           pgreact_internal.canonical_bigint_v1(s.semantic_key)))
                  WHERE expected.program_version_id = target_program
                    AND expected.rule_version_id = r.rule_version_id
                    AND (actual.support_id IS NULL
                         OR NOT (actual.fact_id = ANY (grounded)))
              )
        ) ready;
        IF cardinality(additions) = 0 THEN
            RETURN grounded;
        END IF;
        grounded := grounded || additions;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact.reconcile_derivation_program(target_program uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    reconciliation_id bigint;
    diagnostic_order integer := 0;
    defect record;
    grounded_facts uuid[];
BEGIN
    program_row := pgreact_internal.assert_program_owner(target_program);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    INSERT INTO pgreact_internal.derivation_program_reconciliations (
        program_version_id, started_at, status, requested_by
    ) VALUES (
        target_program, clock_timestamp(), 'RUNNING', session_user
    ) RETURNING pgreact_internal.derivation_program_reconciliations.reconciliation_id
      INTO reconciliation_id;

    FOR defect IN
        SELECT r.rule_version_id, a.activation_id,
               pgreact_internal.activation_uuid(sha256(convert_to(
                   r.rule_version_id::text || ':' || a.activation_id::text || ':' ||
                   a.generation || ':' || a.revision || ':' ||
                   pgreact_internal.activation_uuid(
                       pgreact_internal.activation_digest(
                           r.target_relation_version_id,
                           pgreact_internal.canonical_bigint_v1(a.semantic_key)
                       ))::text, 'UTF8'))) AS support_id
        FROM pgreact_internal.derivation_program_rules r
        JOIN pgreact_internal.activation_state a USING (rule_version_id)
        WHERE r.program_version_id = target_program AND a.active
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.derived_supports s
              WHERE s.rule_version_id = r.rule_version_id
                AND s.activation_id = a.activation_id AND s.active
          )
        ORDER BY r.rule_order, a.activation_id
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_id, diagnostic_order, 'MISSING_SUPPORT',
            defect.support_id::text,
            jsonb_build_object('rule_version_id', defect.rule_version_id,
                               'activation_id', defect.activation_id)
        );
    END LOOP;
    FOR defect IN
        SELECT s.*, a.activation_id AS expected_activation,
               a.generation AS expected_generation,
               a.revision AS expected_revision,
               a.current_bindings - '__pgt_row_id' AS expected_binding
        FROM pgreact_internal.derived_supports s
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = target_program
         AND r.rule_version_id = s.rule_version_id
        LEFT JOIN pgreact_internal.activation_state a
          ON a.rule_version_id = s.rule_version_id
         AND a.activation_id = s.activation_id AND a.active
        WHERE s.active AND (
            a.activation_id IS NULL
            OR s.activation_generation IS DISTINCT FROM a.generation
            OR s.activation_revision IS DISTINCT FROM a.revision
            OR s.semantic_key IS DISTINCT FROM a.semantic_key
            OR s.source_binding IS DISTINCT FROM a.current_bindings - '__pgt_row_id'
            OR s.program_version_id IS DISTINCT FROM target_program
            OR s.fact_id IS DISTINCT FROM pgreact_internal.activation_uuid(
                pgreact_internal.activation_digest(
                    r.target_relation_version_id,
                    pgreact_internal.canonical_bigint_v1(a.semantic_key)))
            OR s.fact IS DISTINCT FROM pgreact_internal.project_derived_fact(
                r.target_relation_version_id,
                a.current_bindings - '__pgt_row_id')
            OR EXISTS (
                SELECT 1
                FROM pgreact_internal.derivation_program_inputs expected_input
                LEFT JOIN pgreact_internal.derived_support_inputs actual_input
                  ON actual_input.support_id = s.support_id
                 AND actual_input.input_order = expected_input.input_order
                 AND actual_input.relation_version_id = expected_input.relation_version_id
                 AND actual_input.semantic_key = a.semantic_key
                 AND actual_input.fact_id = pgreact_internal.activation_uuid(
                     pgreact_internal.activation_digest(
                         expected_input.relation_version_id,
                         pgreact_internal.canonical_bigint_v1(a.semantic_key)))
                WHERE expected_input.program_version_id = target_program
                  AND expected_input.rule_version_id = r.rule_version_id
                  AND actual_input.support_id IS NULL
            )
            OR (SELECT count(*) FROM pgreact_internal.derived_support_inputs actual_input
                WHERE actual_input.support_id = s.support_id)
               <> (SELECT count(*)
                   FROM pgreact_internal.derivation_program_inputs expected_input
                   WHERE expected_input.program_version_id = target_program
                     AND expected_input.rule_version_id = r.rule_version_id)
        )
        ORDER BY s.support_id
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_id, diagnostic_order,
            CASE WHEN defect.expected_activation IS NULL
                 THEN 'EXTRA_SUPPORT' ELSE 'STALE_SUPPORT' END,
            defect.support_id::text,
            jsonb_build_object('rule_version_id', defect.rule_version_id,
                               'activation_id', defect.activation_id)
        );
    END LOOP;
    FOR defect IN
        SELECT f.*, expected.support_count AS expected_support_count,
               expected.expected_fact
        FROM pgreact_internal.derived_facts f
        JOIN pgreact_internal.derivation_program_components c
          ON c.program_version_id = target_program
         AND f.relation_version_id = ANY (c.target_relations)
        LEFT JOIN LATERAL (
            SELECT count(*) AS support_count,
                   min(s.fact::text)::jsonb AS expected_fact
            FROM pgreact_internal.derived_supports s
            JOIN pgreact_internal.derivation_program_rules r
              ON r.program_version_id = target_program
             AND r.rule_version_id = s.rule_version_id
            WHERE s.relation_version_id = f.relation_version_id
              AND s.semantic_key = f.semantic_key AND s.active
        ) expected ON true
        WHERE expected.support_count = 0
           OR f.support_count IS DISTINCT FROM expected.support_count
           OR f.fact IS DISTINCT FROM expected.expected_fact
        ORDER BY f.relation_version_id, f.semantic_key
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_id, diagnostic_order,
            CASE WHEN defect.expected_support_count = 0
                 THEN 'EXTRA_FACT' ELSE 'STALE_FACT' END,
            defect.fact_id::text,
            jsonb_build_object('semantic_key', defect.semantic_key,
                               'support_count', defect.expected_support_count)
        );
    END LOOP;
    FOR defect IN
        SELECT s.relation_version_id, s.semantic_key, min(s.fact_id::text)::uuid AS fact_id
        FROM pgreact_internal.derived_supports s
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = target_program
         AND r.rule_version_id = s.rule_version_id
        WHERE s.active AND NOT EXISTS (
            SELECT 1 FROM pgreact_internal.derived_facts f
            WHERE f.relation_version_id = s.relation_version_id
              AND f.semantic_key = s.semantic_key
        )
        GROUP BY s.relation_version_id, s.semantic_key
        ORDER BY s.relation_version_id, s.semantic_key
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_id, diagnostic_order, 'MISSING_FACT',
            defect.fact_id::text,
            jsonb_build_object('relation_version_id', defect.relation_version_id,
                               'semantic_key', defect.semantic_key)
        );
    END LOOP;
    grounded_facts := pgreact_internal.grounded_program_facts(target_program);
    FOR defect IN
        SELECT f.relation_version_id, f.semantic_key, f.fact_id
        FROM pgreact_internal.derived_facts f
        JOIN pgreact_internal.derivation_program_components c
          ON c.program_version_id = target_program
         AND f.relation_version_id = ANY (c.target_relations)
        WHERE NOT (f.fact_id = ANY (grounded_facts))
        ORDER BY f.relation_version_id, f.semantic_key
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_id, diagnostic_order, 'CIRCULAR_ONLY',
            defect.fact_id::text,
            jsonb_build_object('relation_version_id', defect.relation_version_id,
                               'semantic_key', defect.semantic_key)
        );
    END LOOP;
    FOR defect IN
        SELECT s.support_id, s.support_frontier
        FROM pgreact_internal.derived_supports s
        JOIN pgreact_internal.derivation_program_rules r
          ON r.program_version_id = target_program
         AND r.rule_version_id = s.rule_version_id
        WHERE s.active AND s.support_frontier IS DISTINCT FROM program_row.frontier
        ORDER BY s.support_id
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_id, diagnostic_order, 'WRONG_FRONTIER',
            defect.support_id::text,
            jsonb_build_object('expected', program_row.frontier,
                               'actual', defect.support_frontier)
        );
    END LOOP;
    FOR defect IN
        SELECT c.component_id, f.frontier
        FROM pgreact_internal.derivation_program_components c
        LEFT JOIN pgreact_internal.derivation_program_component_frontiers f
          USING (program_version_id, component_id)
        WHERE c.program_version_id = target_program
          AND f.frontier IS DISTINCT FROM program_row.frontier
        ORDER BY c.component_order
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            reconciliation_id, diagnostic_order, 'WRONG_FRONTIER',
            defect.component_id::text,
            jsonb_build_object('expected', program_row.frontier,
                               'actual', defect.frontier)
        );
    END LOOP;
    PERFORM pgreact_internal.rebuild_derivation_program(
        target_program, diagnostic_order > 0, diagnostic_order > 0);
    DELETE FROM pgreact_internal.rule_barriers barrier
    USING pgreact_internal.derivation_program_rules member,
          pgreact_internal.rule_versions rule_version
    WHERE member.program_version_id = target_program
      AND rule_version.rule_version_id = member.rule_version_id
      AND rule_version.state = 'ACTIVE'
      AND barrier.reason = 'RECONCILING'
      AND barrier.rule_version_id = member.rule_version_id;
    UPDATE pgreact_internal.derivation_program_reconciliations SET
        completed_at = clock_timestamp(), repairs = diagnostic_order,
        status = 'COMPLETED'
    WHERE pgreact_internal.derivation_program_reconciliations.reconciliation_id = reconciliation_id;
    RETURN diagnostic_order;
END
$$;

CREATE FUNCTION pgreact_internal.recursive_fact_proof(
    target_program uuid,
    target_relation uuid,
    target_key bigint,
    path uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    fact_row record;
    support_row record;
    input_row record;
    supports jsonb := '[]'::jsonb;
    inputs jsonb;
    input_node jsonb;
    relation_identity text;
BEGIN
    SELECT f.fact_id, f.fact, r.relation_name, v.version
    INTO fact_row
    FROM pgreact_internal.derived_facts f
    JOIN pgreact_internal.derived_relation_versions v USING (relation_version_id)
    JOIN pgreact_internal.derived_relations r USING (relation_id)
    WHERE f.relation_version_id = target_relation
      AND f.semantic_key = target_key;
    IF NOT FOUND THEN RETURN NULL; END IF;
    relation_identity := fact_row.relation_name || '@' || fact_row.version;
    IF fact_row.fact_id = ANY (path) THEN
        RETURN jsonb_build_object(
            'cycle', true,
            'relation', relation_identity,
            'semantic_key', target_key
        );
    END IF;
    FOR support_row IN
        SELECT s.support_id, s.logical_support_id, s.source_binding,
               r.rule_name, d.version
        FROM pgreact_internal.derived_supports s
        JOIN pgreact_internal.derivation_program_rules pr
          ON pr.program_version_id = target_program
         AND pr.rule_version_id = s.rule_version_id
        JOIN pgreact_internal.derivation_rule_versions d
          ON d.rule_version_id = s.rule_version_id
        JOIN pgreact_internal.rules r ON r.rule_id = d.rule_id
        WHERE s.relation_version_id = target_relation
          AND s.semantic_key = target_key AND s.active
        ORDER BY r.rule_name, d.version, s.logical_support_id
    LOOP
        inputs := '[]'::jsonb;
        FOR input_row IN
            SELECT i.*, r.relation_name, v.version
            FROM pgreact_internal.derived_support_inputs i
            JOIN pgreact_internal.derived_relation_versions v
              ON v.relation_version_id = i.relation_version_id
            JOIN pgreact_internal.derived_relations r USING (relation_id)
            WHERE i.support_id = support_row.support_id
            ORDER BY i.input_order
        LOOP
            IF input_row.fact_id = ANY (path || fact_row.fact_id) THEN
                input_node := jsonb_build_object(
                    'cycle', true,
                    'relation', input_row.relation_name || '@' || input_row.version,
                    'semantic_key', input_row.semantic_key
                );
            ELSE
                input_node := pgreact_internal.recursive_fact_proof(
                    target_program, input_row.relation_version_id,
                    input_row.semantic_key, path || fact_row.fact_id);
            END IF;
            inputs := inputs || jsonb_build_array(input_node);
        END LOOP;
        supports := supports || jsonb_build_array(jsonb_build_object(
            'rule', support_row.rule_name || '@' || support_row.version,
            'source_binding', support_row.source_binding,
            'inputs', inputs
        ));
    END LOOP;
    RETURN jsonb_build_object(
        'relation', relation_identity,
        'fact', fact_row.fact,
        'supports', supports
    );
END
$$;

CREATE FUNCTION pgreact.explain_recursive_fact(
    target_program uuid,
    target_relation uuid,
    target_key bigint
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program_row record;
    relation_identity text;
    proof jsonb;
BEGIN
    PERFORM pgreact_internal.assert_program_owner(target_program);
    SELECT p.program_name, v.version, v.frontier
    INTO STRICT program_row
    FROM pgreact_internal.derivation_programs p
    JOIN pgreact_internal.derivation_program_versions v USING (program_id)
    WHERE v.program_version_id = target_program AND v.state = 'ACTIVE';
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_internal.derivation_program_components
        WHERE program_version_id = target_program
          AND target_relation = ANY (target_relations)
    ) THEN
        RAISE EXCEPTION 'relation % is not a member of program %',
            target_relation, target_program;
    END IF;
    SELECT r.relation_name || '@' || v.version INTO STRICT relation_identity
    FROM pgreact_internal.derived_relations r
    JOIN pgreact_internal.derived_relation_versions v USING (relation_id)
    WHERE v.relation_version_id = target_relation;
    proof := pgreact_internal.recursive_fact_proof(
        target_program, target_relation, target_key, ARRAY[]::uuid[]);
    IF proof IS NULL THEN RETURN NULL; END IF;
    RETURN jsonb_build_object(
        'program', program_row.program_name || '@' || program_row.version,
        'frontier', program_row.frontier,
        'relation', relation_identity,
        'fact', proof -> 'fact',
        'proof', proof
    );
END
$$;

CREATE VIEW pgreact.derivation_programs AS
SELECT p.program_id, p.program_name, v.program_version_id,
       v.version AS program_version,
       pg_catalog.pg_get_userbyid(v.owner_oid) AS owner,
       v.state, v.max_iterations, v.max_facts, v.frontier, v.created_at
FROM pgreact_internal.derivation_programs p
JOIN pgreact_internal.derivation_program_versions v USING (program_id);

CREATE VIEW pgreact.derivation_program_runs AS
SELECT r.run_id, r.program_version_id, p.program_name,
       v.version AS program_version,
       r.started_at, r.completed_at, r.prior_frontier, r.committed_frontier,
       r.iterations, r.fact_count, r.support_count, r.status,
       r.error_sqlstate, r.error_message, r.error_detail, r.error_hint,
       r.requested_by
FROM pgreact_internal.derivation_program_runs r
JOIN pgreact_internal.derivation_program_versions v USING (program_version_id)
JOIN pgreact_internal.derivation_programs p USING (program_id);

CREATE VIEW pgreact.derivation_components AS
SELECT c.program_version_id, c.component_id, c.component_order, c.cyclic,
       c.rule_names,
       ARRAY(
           SELECT r.relation_name
           FROM unnest(c.target_relations) WITH ORDINALITY target(relation_version_id, ordinal)
           JOIN pgreact_internal.derived_relation_versions v USING (relation_version_id)
           JOIN pgreact_internal.derived_relations r USING (relation_id)
           ORDER BY target.ordinal
       ) AS target_relations,
       f.frontier, f.iterations, f.fact_count, f.support_count,
       CASE WHEN f.fingerprint IS NULL THEN NULL
            ELSE encode(f.fingerprint, 'hex') END AS fingerprint,
       f.committed_at
FROM pgreact_internal.derivation_program_components c
LEFT JOIN pgreact_internal.derivation_program_component_frontiers f
  USING (program_version_id, component_id);

CREATE VIEW pgreact.derivation_iterations AS
SELECT i.run_id, i.program_version_id, i.component_id, i.iteration,
       i.fact_count, i.support_count, encode(i.fingerprint, 'hex') AS fingerprint,
       i.completed_at
FROM pgreact_internal.derivation_program_iterations i;

CREATE VIEW pgreact.recursive_support_inputs AS
SELECT s.logical_support_id AS support_id, i.input_order,
       i.relation_version_id, r.relation_name,
       i.semantic_key, i.fact_id
FROM pgreact_internal.derived_support_inputs i
JOIN pgreact_internal.derived_supports s USING (support_id)
JOIN pgreact_internal.derived_relation_versions v
  ON v.relation_version_id = i.relation_version_id
JOIN pgreact_internal.derived_relations r USING (relation_id);

CREATE VIEW pgreact.derivation_program_repair_diagnostics AS
SELECT d.reconciliation_id, r.program_version_id, p.program_name,
       v.version AS program_version, d.diagnostic_order, d.code,
       d.object_identity, d.details, r.started_at, r.completed_at
FROM pgreact_internal.derivation_program_repair_diagnostics d
JOIN pgreact_internal.derivation_program_reconciliations r
  USING (reconciliation_id)
JOIN pgreact_internal.derivation_program_versions v
  USING (program_version_id)
JOIN pgreact_internal.derivation_programs p USING (program_id);

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;
REVOKE ALL ON pgreact.derivation_programs,
    pgreact.derivation_program_runs,
    pgreact.derivation_components,
    pgreact.derivation_iterations,
    pgreact.recursive_support_inputs,
    pgreact.derivation_program_repair_diagnostics FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M8 monotone recursive derivation with grounded least-fixed-point programs';
-- M9 slice 6: grounded negative explanations and exact program repair.

ALTER TABLE pgreact_internal.derivation_program_components
    ADD COLUMN stratum integer NOT NULL DEFAULT 0 CHECK (stratum >= 0);

CREATE TABLE pgreact_internal.derivation_program_negative_inputs (
    program_version_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    input_order integer NOT NULL CHECK (input_order > 0),
    relation_oid oid NOT NULL,
    relation_name text NOT NULL,
    key_column name NOT NULL,
    relation_definition_digest bytea NOT NULL,
    relation_row_signature bytea NOT NULL,
    PRIMARY KEY (program_version_id, rule_version_id, input_order),
    UNIQUE (program_version_id, rule_version_id, relation_oid),
    FOREIGN KEY (program_version_id, rule_version_id)
        REFERENCES pgreact_internal.derivation_program_rules
);

CREATE TABLE pgreact_internal.negative_dependency_evidence (
    evidence_id uuid PRIMARY KEY,
    program_version_id uuid NOT NULL,
    rule_version_id uuid NOT NULL,
    input_order integer NOT NULL CHECK (input_order > 0),
    support_id uuid NOT NULL
        REFERENCES pgreact_internal.derived_supports ON DELETE CASCADE,
    semantic_key bigint NOT NULL,
    relation_oid oid NOT NULL,
    relation_name text NOT NULL,
    source_stratum integer NOT NULL CHECK (source_stratum >= 0),
    target_stratum integer NOT NULL CHECK (target_stratum > source_stratum),
    lower_frontier bigint NOT NULL CHECK (lower_frontier > 0),
    active boolean NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    invalidated_at timestamptz,
    FOREIGN KEY (program_version_id, rule_version_id, input_order)
        REFERENCES pgreact_internal.derivation_program_negative_inputs
        ON DELETE CASCADE
);

CREATE FUNCTION pgreact_internal.invalidate_negative_dependency_evidence()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    UPDATE pgreact_internal.negative_dependency_evidence
    SET active = false, invalidated_at = clock_timestamp()
    WHERE support_id = NEW.support_id AND active;
    RETURN NULL;
END
$$;

CREATE TRIGGER pgreact_invalidate_negative_dependency_evidence
AFTER UPDATE OF active ON pgreact_internal.derived_supports
FOR EACH ROW WHEN (OLD.active AND NOT NEW.active)
EXECUTE FUNCTION pgreact_internal.invalidate_negative_dependency_evidence();

ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    DROP CONSTRAINT derivation_program_repair_diagnostics_code_check;
ALTER TABLE pgreact_internal.derivation_program_repair_diagnostics
    ADD CHECK (code IN (
        'MISSING_SUPPORT', 'EXTRA_SUPPORT', 'STALE_SUPPORT',
        'MISSING_FACT', 'EXTRA_FACT', 'STALE_FACT',
        'CIRCULAR_ONLY', 'WRONG_FRONTIER', 'MISSING_EVIDENCE',
        'EXTRA_EVIDENCE', 'STALE_EVIDENCE', 'WRONG_STRATUM'
    ));

CREATE FUNCTION pgreact_internal.relation_query_tree(target_relation oid)
RETURNS text
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE views(relid) AS (
        SELECT $1
        UNION
        SELECT dependency.refobjid
        FROM views parent
        JOIN pg_catalog.pg_rewrite rewrite ON rewrite.ev_class = parent.relid
        JOIN pg_catalog.pg_depend dependency
          ON dependency.classid = 'pg_rewrite'::regclass
         AND dependency.objid = rewrite.oid
         AND dependency.refclassid = 'pg_class'::regclass
        JOIN pg_catalog.pg_class relation ON relation.oid = dependency.refobjid
        WHERE relation.relkind IN ('v', 'm')
    )
    SELECT string_agg(rewrite.ev_action::text, E'\n' ORDER BY views.relid)
    FROM views
    JOIN pg_catalog.pg_rewrite rewrite
      ON rewrite.ev_class = views.relid AND rewrite.rulename = '_RETURN'
$$;

ALTER FUNCTION pgreact.validate_derivation_program(jsonb)
    RENAME TO validate_derivation_program_m8;
ALTER FUNCTION pgreact.validate_derivation_program_m8(jsonb)
    SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact.validate_derivation_program(definition jsonb)
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
    rule_item record;
    negative_item record;
    diagnostic record;
    source_oid oid;
    negative_oid oid;
    source_tree text;
    seen_negative_oids oid[];
    base_definition jsonb;
    current_program record;
    has_negative_field boolean;
BEGIN
    has_negative_field := EXISTS (
        SELECT 1
        FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END) rule(value)
        WHERE rule.value ? 'negative_inputs'
    );

    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END)
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        source_oid := pg_catalog.to_regclass(rule_item.value ->> 'definition');
        IF source_oid IS NOT NULL THEN
            source_tree := pgreact_internal.relation_query_tree(source_oid);
            IF source_tree ~ E'\\{BOOLEXPR[[:space:]]+:boolop[[:space:]]+not[[:space:]]'
               OR source_tree ~ E':jointype[[:space:]]+[1-5][[:space:]]'
               OR source_tree ~ E':setOperations[[:space:]]+\\{SETOPERATIONSTMT[[:space:]]+:op[[:space:]]+3[[:space:]]' THEN
                RETURN QUERY SELECT 3, 'PROGRAM_ABSENCE_UNSUPPORTED', 'ERROR',
                    COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                    'absence must be declared with negative_inputs',
                    'Remove NOT EXISTS, outer joins, and EXCEPT from the source SQL.',
                    jsonb_build_object('source', rule_item.value ->> 'definition');
                RETURN;
            END IF;
        END IF;
    END LOOP;

    IF NOT has_negative_field THEN
        RETURN QUERY
        SELECT * FROM pgreact_internal.validate_derivation_program_m8(definition);
        RETURN;
    END IF;

    FOR rule_item IN
        SELECT value, ordinal
        FROM jsonb_array_elements(CASE
            WHEN pg_catalog.jsonb_typeof(definition -> 'rules') = 'array'
            THEN definition -> 'rules' ELSE '[]'::jsonb END)
        WITH ORDINALITY rules(value, ordinal)
    LOOP
        IF rule_item.value ? 'negative_inputs'
           AND pg_catalog.jsonb_typeof(rule_item.value -> 'negative_inputs')
               IS DISTINCT FROM 'array' THEN
            RETURN QUERY SELECT 3, 'PROGRAM_RULE_INVALID', 'ERROR',
                COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                'negative_inputs must be an array',
                'Use an array of objects containing exactly relation and key.',
                '{}'::jsonb;
            RETURN;
        END IF;
        seen_negative_oids := ARRAY[]::oid[];
        FOR negative_item IN
            SELECT value, ordinal
            FROM jsonb_array_elements(COALESCE(
                rule_item.value -> 'negative_inputs', '[]'::jsonb))
            WITH ORDINALITY inputs(value, ordinal)
        LOOP
            IF pg_catalog.jsonb_typeof(negative_item.value) IS DISTINCT FROM 'object'
               OR NOT negative_item.value ?& ARRAY['relation', 'key']
               OR (SELECT count(*) FROM jsonb_object_keys(negative_item.value)) <> 2 THEN
                RETURN QUERY SELECT 3, 'PROGRAM_RULE_INVALID', 'ERROR',
                    COALESCE(rule_item.value ->> 'name', rule_item.ordinal::text),
                    'negative inputs require exactly relation and key',
                    'Remove unsupported negative predicates and expressions.',
                    jsonb_build_object('input', negative_item.ordinal);
                RETURN;
            END IF;
            negative_oid := pg_catalog.to_regclass(
                negative_item.value ->> 'relation');
            IF negative_oid IS NULL OR NOT EXISTS (
                SELECT 1 FROM pg_catalog.pg_class
                WHERE oid = negative_oid AND relkind IN ('r', 'p', 'v', 'm')
            ) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_UNRESOLVED', 'ERROR',
                    negative_item.value ->> 'relation',
                    'negative input does not resolve to a table or view',
                    'Map relation to one existing authoritative or derived relation.',
                    jsonb_build_object('rule', rule_item.value ->> 'name');
                RETURN;
            END IF;
            IF negative_oid = ANY (seen_negative_oids) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_DUPLICATE', 'ERROR',
                    rule_item.value ->> 'name',
                    'the same relation cannot be checked twice by one rule',
                    'Declare each negative relation once.',
                    jsonb_build_object('relation', negative_item.value ->> 'relation');
                RETURN;
            END IF;
            seen_negative_oids := array_append(seen_negative_oids, negative_oid);
            IF NOT EXISTS (
                SELECT 1
                FROM pg_catalog.pg_attribute attribute
                WHERE attribute.attrelid = negative_oid
                  AND attribute.attname = (negative_item.value ->> 'key')::name
                  AND attribute.atttypid = 'bigint'::regtype
                  AND attribute.attnum > 0 AND NOT attribute.attisdropped
            ) THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_KEY_INVALID', 'ERROR',
                    rule_item.value ->> 'name',
                    'negative input key must be one bigint column',
                    'Project one bigint key with the rule output-key name.',
                    jsonb_build_object('relation', negative_item.value ->> 'relation',
                                       'key', negative_item.value ->> 'key');
                RETURN;
            END IF;
            IF negative_item.value ->> 'key'
               IS DISTINCT FROM rule_item.value ->> 'key' THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_UNBOUND', 'ERROR',
                    rule_item.value ->> 'name',
                    'negative input key must equal the non-null output key',
                    'Bind absence to the rule output key.',
                    jsonb_build_object('negative_key', negative_item.value ->> 'key',
                                       'output_key', rule_item.value ->> 'key');
                RETURN;
            END IF;
            source_tree := pgreact_internal.relation_query_tree(negative_oid);
            IF source_tree ~ E':hasAggs[[:space:]]+true'
               OR source_tree ~ E':aggfnoid[[:space:]]+[1-9]' THEN
                RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_AGGREGATE', 'ERROR',
                    rule_item.value ->> 'name',
                    'aggregate negative inputs are outside M9',
                    'Check one non-aggregate keyed relation.',
                    jsonb_build_object('relation', negative_item.value ->> 'relation');
                RETURN;
            END IF;
        END LOOP;
    END LOOP;

    IF EXISTS (
        WITH RECURSIVE edges(source_relation, target_relation, polarity, rule_name) AS (
            SELECT input.value ->> 'relation', rule.value ->> 'target',
                   'POSITIVE'::text, rule.value ->> 'name'
            FROM jsonb_array_elements(definition -> 'rules') rule(value)
            CROSS JOIN LATERAL jsonb_array_elements(rule.value -> 'inputs') input(value)
            UNION ALL
            SELECT input.value ->> 'relation', rule.value ->> 'target',
                   'NEGATIVE', rule.value ->> 'name'
            FROM jsonb_array_elements(definition -> 'rules') rule(value)
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
                rule.value -> 'negative_inputs', '[]'::jsonb)) input(value)
        ), reach(source_relation, target_relation) AS (
            SELECT source_relation, target_relation FROM edges
            UNION
            SELECT reach.source_relation, edges.target_relation
            FROM reach JOIN edges
              ON edges.source_relation = reach.target_relation
        )
        SELECT 1
        FROM edges negative_edge
        WHERE negative_edge.polarity = 'NEGATIVE'
          AND EXISTS (
              SELECT 1 FROM reach
              WHERE reach.source_relation = negative_edge.target_relation
                AND reach.target_relation = negative_edge.source_relation
          )
    ) THEN
        RETURN QUERY SELECT 3, 'PROGRAM_NEGATIVE_CYCLE', 'ERROR',
            definition ->> 'name',
            'derivation program contains a cycle through negation',
            'Make every negative dependency point to a lower stratum.',
            '{}'::jsonb;
        RETURN;
    END IF;

    base_definition := jsonb_set(definition, '{rules}', COALESCE((
        SELECT jsonb_agg(value - 'negative_inputs' ORDER BY ordinal)
        FROM jsonb_array_elements(definition -> 'rules')
        WITH ORDINALITY rules(value, ordinal)
    ), '[]'::jsonb), true);
    IF definition ->> 'version' ~ '^[1-9][0-9]*$'
       AND COALESCE(pg_catalog.pg_input_is_valid(
           definition ->> 'version', 'integer'), false) THEN
        SELECT version, definition INTO current_program
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = definition ->> 'name'
          AND version.state = 'ACTIVE';
        IF FOUND AND ((definition ->> 'version')::integer < current_program.version
           OR ((definition ->> 'version')::integer = current_program.version
               AND definition IS DISTINCT FROM current_program.definition)) THEN
            RETURN QUERY SELECT 3, 'PROGRAM_VERSION_EXISTS', 'ERROR',
                definition ->> 'name',
                'an immutable active program version already exists',
                'Keep the exact definition or increment the program version.',
                jsonb_build_object('active_version', current_program.version);
            RETURN;
        ELSIF FOUND AND (definition ->> 'version')::integer = current_program.version THEN
            base_definition := jsonb_set(base_definition, '{version}',
                to_jsonb((current_program.version + 1)::text));
        END IF;
    END IF;

    FOR diagnostic IN
        SELECT *
        FROM pgreact_internal.validate_derivation_program_m8(base_definition)
        WHERE code <> 'OK'
    LOOP
        RETURN QUERY SELECT diagnostic.contract_version, diagnostic.code,
            diagnostic.severity, diagnostic.object_identity,
            diagnostic.message, diagnostic.hint, diagnostic.details;
        RETURN;
    END LOOP;
    RETURN QUERY SELECT 3, 'OK', 'INFO', definition ->> 'name',
        'stratified derivation program is valid',
        'Preview and deploy the containing pack.',
        jsonb_build_object('version', (definition ->> 'version')::integer,
                           'rules', jsonb_array_length(definition -> 'rules'));
END
$$;

CREATE FUNCTION pgreact_internal.derivation_program_strata(definition jsonb)
RETURNS TABLE(component_id uuid, stratum integer)
LANGUAGE SQL
IMMUTABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    WITH RECURSIVE
    components AS (
        SELECT * FROM pgreact_internal.derivation_program_components($1)
    ),
    membership AS (
        SELECT component_id, relation_name
        FROM components
        CROSS JOIN LATERAL unnest(target_names) relation_name
    ),
    raw_edges(source_relation, target_relation, weight) AS (
        SELECT input.value ->> 'relation', rule.value ->> 'target', 0
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(rule.value -> 'inputs') input(value)
        UNION ALL
        SELECT input.value ->> 'relation', rule.value ->> 'target', 1
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
            rule.value -> 'negative_inputs', '[]'::jsonb)) input(value)
    ),
    component_edges(source_component, target_component, weight) AS (
        SELECT source_member.component_id, target_member.component_id, raw_edges.weight
        FROM raw_edges
        LEFT JOIN membership source_member
          ON source_member.relation_name = raw_edges.source_relation
        JOIN membership target_member
          ON target_member.relation_name = raw_edges.target_relation
        WHERE source_member.component_id IS DISTINCT FROM target_member.component_id
    ),
    seeds(component_id, stratum) AS (
        SELECT components.component_id, 0 FROM components
        UNION
        SELECT target_component, weight
        FROM component_edges WHERE source_component IS NULL
    ),
    paths(component_id, stratum) AS (
        SELECT component_id, stratum FROM seeds
        UNION
        SELECT edge.target_component, paths.stratum + edge.weight
        FROM paths
        JOIN component_edges edge ON edge.source_component = paths.component_id
    )
    SELECT components.component_id, max(paths.stratum)::integer
    FROM components JOIN paths USING (component_id)
    GROUP BY components.component_id
$$;

CREATE FUNCTION pgreact_internal.derivation_program_graph(definition jsonb)
RETURNS TABLE(
    dependency_id uuid,
    rule_name text,
    input_order integer,
    polarity text,
    source_relation text,
    target_relation text,
    source_component_id uuid,
    target_component_id uuid,
    source_stratum integer,
    target_stratum integer
)
LANGUAGE SQL
IMMUTABLE
STRICT
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    WITH components AS (
        SELECT * FROM pgreact_internal.derivation_program_components($1)
    ),
    membership AS (
        SELECT component_id, relation_name
        FROM components
        CROSS JOIN LATERAL unnest(target_names) relation_name
    ),
    strata AS (
        SELECT * FROM pgreact_internal.derivation_program_strata($1)
    ),
    edges AS (
        SELECT rule.value ->> 'name' AS rule_name,
               input.ordinal::integer AS input_order,
               'POSITIVE'::text AS polarity,
               input.value ->> 'relation' AS source_relation,
               rule.value ->> 'target' AS target_relation
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(rule.value -> 'inputs')
            WITH ORDINALITY input(value, ordinal)
        UNION ALL
        SELECT rule.value ->> 'name', input.ordinal::integer, 'NEGATIVE',
               input.value ->> 'relation', rule.value ->> 'target'
        FROM jsonb_array_elements($1 -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
            rule.value -> 'negative_inputs', '[]'::jsonb))
            WITH ORDINALITY input(value, ordinal)
    )
    SELECT pgreact_internal.activation_uuid(sha256(convert_to(
               ($1 ->> 'name') || '@' || ($1 ->> 'version') || ':' ||
               edges.rule_name || ':' || edges.polarity || ':' ||
               edges.input_order || ':' || edges.source_relation || ':' ||
               edges.target_relation, 'UTF8'))),
           edges.rule_name, edges.input_order, edges.polarity,
           edges.source_relation, edges.target_relation,
           source_member.component_id, target_member.component_id,
           COALESCE(source_stratum.stratum, 0), target_stratum.stratum
    FROM edges
    LEFT JOIN membership source_member
      ON source_member.relation_name = edges.source_relation
    JOIN membership target_member
      ON target_member.relation_name = edges.target_relation
    LEFT JOIN strata source_stratum
      ON source_stratum.component_id = source_member.component_id
    JOIN strata target_stratum
      ON target_stratum.component_id = target_member.component_id
    ORDER BY target_stratum.stratum, edges.rule_name, edges.polarity,
             edges.input_order, edges.source_relation
$$;

CREATE FUNCTION pgreact_internal.set_derivation_component_stratum()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    SELECT assigned.stratum, assigned.component_order
    INTO STRICT NEW.stratum, NEW.component_order
    FROM pgreact_internal.derivation_program_versions version
    CROSS JOIN LATERAL (
        SELECT strata.component_id, strata.stratum,
               row_number() OVER (
                   ORDER BY strata.stratum, component.component_order
               )::integer AS component_order
        FROM pgreact_internal.derivation_program_components(
            version.definition) component
        JOIN pgreact_internal.derivation_program_strata(
            version.definition) strata USING (component_id)
    ) assigned
    WHERE version.program_version_id = NEW.program_version_id
      AND assigned.component_id = NEW.component_id;
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_set_derivation_component_stratum
BEFORE INSERT ON pgreact_internal.derivation_program_components
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.set_derivation_component_stratum();

CREATE FUNCTION pgreact_internal.attach_derivation_negative_inputs()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    negative_item record;
BEGIN
    FOR negative_item IN
        SELECT input.value, input.ordinal
        FROM pgreact_internal.derivation_program_versions version
        CROSS JOIN LATERAL jsonb_array_elements(version.definition -> 'rules') rule(value)
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(
            rule.value -> 'negative_inputs', '[]'::jsonb))
            WITH ORDINALITY input(value, ordinal)
        WHERE version.program_version_id = NEW.program_version_id
          AND rule.value ->> 'name' = NEW.rule_name
    LOOP
        INSERT INTO pgreact_internal.derivation_program_negative_inputs (
            program_version_id, rule_version_id, input_order,
            relation_oid, relation_name, key_column,
            relation_definition_digest, relation_row_signature
        ) VALUES (
            NEW.program_version_id, NEW.rule_version_id, negative_item.ordinal,
            pg_catalog.to_regclass(negative_item.value ->> 'relation'),
            negative_item.value ->> 'relation',
            (negative_item.value ->> 'key')::name,
            pgreact_internal.source_closure_digest(
                pg_catalog.to_regclass(negative_item.value ->> 'relation')),
            pgreact_internal.source_row_signature(
                pg_catalog.to_regclass(negative_item.value ->> 'relation'))
        );
    END LOOP;
    RETURN NEW;
END
$$;

CREATE TRIGGER pgreact_attach_derivation_negative_inputs
AFTER INSERT ON pgreact_internal.derivation_program_rules
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.attach_derivation_negative_inputs();

CREATE OR REPLACE FUNCTION pgreact_internal.m8_program_definition(
    program jsonb,
    mappings jsonb
)
RETURNS jsonb
LANGUAGE SQL
STABLE
STRICT
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_set($1, '{rules}', COALESCE((
        SELECT jsonb_agg(
            (rule_item - 'definition' - 'target' - 'inputs' - 'negative_inputs') ||
            jsonb_build_object(
                'definition', pgreact_internal.pack_mapping(
                    $2, 'objects', rule_item ->> 'definition'),
                'target', pgreact_internal.pack_mapping(
                    $2, 'objects', rule_item ->> 'target'),
                'inputs', COALESCE((
                    SELECT jsonb_agg(
                        (input_item - 'relation') || jsonb_build_object(
                            'relation', pgreact_internal.pack_mapping(
                                $2, 'objects', input_item ->> 'relation'))
                        ORDER BY input_ordinal
                    )
                    FROM jsonb_array_elements(rule_item -> 'inputs')
                    WITH ORDINALITY inputs(input_item, input_ordinal)
                ), '[]'::jsonb)
            ) || CASE WHEN rule_item ? 'negative_inputs' THEN
                jsonb_build_object('negative_inputs', COALESCE((
                    SELECT jsonb_agg(
                        (input_item - 'relation') || jsonb_build_object(
                            'relation', pgreact_internal.pack_mapping(
                                $2, 'objects', input_item ->> 'relation'))
                        ORDER BY input_ordinal
                    )
                    FROM jsonb_array_elements(rule_item -> 'negative_inputs')
                    WITH ORDINALITY inputs(input_item, input_ordinal)
                ), '[]'::jsonb))
            ELSE '{}'::jsonb END
            ORDER BY rule_ordinal
        )
        FROM jsonb_array_elements($1 -> 'rules')
        WITH ORDINALITY rules(rule_item, rule_ordinal)
    ), '[]'::jsonb), true)
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.m8_pack_plan_digest(
    definition jsonb,
    mappings jsonb
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    base_digest text;
    material text;
    item record;
    negative_item record;
    program_state text;
    source_state text;
    negative_state text;
    mapped_program jsonb;
BEGIN
    SELECT plan_digest INTO base_digest
    FROM pgreact_internal.preview_pack(
        pgreact_internal.m8_pack_definition(definition), mappings)
    ORDER BY action_order LIMIT 1;
    material := definition::text || E'\n' || mappings::text ||
        E'\nbase:' || COALESCE(base_digest, '<empty>') ||
        E'\nowner:' || session_user;
    FOR item IN
        SELECT program, program_ordinal, rule, rule_ordinal
        FROM jsonb_array_elements(COALESCE(definition -> 'programs', '[]'::jsonb))
             WITH ORDINALITY programs(program, program_ordinal)
        LEFT JOIN LATERAL jsonb_array_elements(program -> 'rules')
             WITH ORDINALITY rules(rule, rule_ordinal) ON true
        ORDER BY program_ordinal, rule_ordinal
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            item.program, mappings);
        SELECT concat_ws(':', version.program_version_id, version.version,
                         version.state, version.frontier,
                         encode(version.definition_digest, 'hex'))
        INTO program_state
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = item.program ->> 'name'
          AND version.state = 'ACTIVE';
        IF item.rule IS NOT NULL THEN
            SELECT concat_ws(':', relation.oid,
                encode(pgreact_internal.source_closure_digest(relation.oid), 'hex'),
                pgreact_internal.source_row_signature(relation.oid))
            INTO source_state
            FROM pg_catalog.pg_class relation
            WHERE relation.oid = pg_catalog.to_regclass(
                mapped_program -> 'rules' ->
                    (item.rule_ordinal - 1)::integer ->> 'definition');
        ELSE
            source_state := '<no-rule>';
        END IF;
        material := material || format(E'\nprogram:%s:%s:%s:rule:%s:%s:%s',
            item.program_ordinal, item.program ->> 'name',
            COALESCE(program_state, '<add>'), item.rule_ordinal,
            COALESCE(item.rule ->> 'name', '<none>'),
            COALESCE(source_state, '<missing>'));
        FOR negative_item IN
            SELECT input.value, input.ordinal
            FROM jsonb_array_elements(COALESCE(
                mapped_program -> 'rules' ->
                    (item.rule_ordinal - 1)::integer -> 'negative_inputs',
                '[]'::jsonb)) WITH ORDINALITY input(value, ordinal)
        LOOP
            SELECT concat_ws(':', relation.oid,
                encode(pgreact_internal.source_closure_digest(relation.oid), 'hex'),
                pgreact_internal.source_row_signature(relation.oid))
            INTO negative_state
            FROM pg_catalog.pg_class relation
            WHERE relation.oid = pg_catalog.to_regclass(
                negative_item.value ->> 'relation');
            material := material || format(E'\nnegative:%s:%s:%s',
                negative_item.ordinal,
                negative_item.value ->> 'relation',
                COALESCE(negative_state, '<missing>'));
        END LOOP;
    END LOOP;
    RETURN encode(sha256(convert_to(material, 'UTF8')), 'hex');
END
$$;

CREATE OR REPLACE FUNCTION pgreact.preview_pack(
    definition jsonb,
    mappings jsonb DEFAULT '{}'::jsonb
)
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
    preview_row record;
    program_item record;
    current_program record;
    digest text;
    ordinal integer := 0;
    dependency_names text[];
    mapped_program jsonb;
    has_negative boolean;
BEGIN
    IF NOT (definition ? 'programs' OR definition ? 'remove_programs') THEN
        SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
        WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'pg-react pack validation % for %: %',
                diagnostic.code, diagnostic.object_identity, diagnostic.message
                USING HINT = diagnostic.hint;
        END IF;
        RETURN QUERY SELECT * FROM pgreact_internal.preview_pack(definition, mappings);
        RETURN;
    END IF;
    SELECT * INTO diagnostic FROM pgreact.validate_pack(definition, mappings) d
    WHERE d.severity = 'ERROR' ORDER BY d.code, d.object_identity LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react pack validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    digest := pgreact_internal.m8_pack_plan_digest(definition, mappings);
    FOR preview_row IN
        SELECT * FROM pgreact_internal.preview_pack(
            pgreact_internal.m8_pack_definition(definition), mappings)
        ORDER BY action_order
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := preview_row.action;
        rule_name := preview_row.rule_name;
        dependencies := preview_row.dependencies;
        generated_object_changes := preview_row.generated_object_changes;
        lifecycle_risks := preview_row.lifecycle_risks;
        details := preview_row.details;
        RETURN NEXT;
    END LOOP;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(
            definition -> 'programs', '[]'::jsonb)) value
    LOOP
        mapped_program := pgreact_internal.m8_program_definition(
            program_item.value, mappings);
        SELECT version.program_version_id, version.version INTO current_program
        FROM pgreact_internal.derivation_programs program
        JOIN pgreact_internal.derivation_program_versions version USING (program_id)
        WHERE program.program_name = program_item.value ->> 'name'
          AND version.state = 'ACTIVE';
        SELECT array_agg(value ->> 'name' ORDER BY rule_ordinal)::text[]
        INTO dependency_names
        FROM jsonb_array_elements(program_item.value -> 'rules')
        WITH ORDINALITY rules(value, rule_ordinal);
        SELECT EXISTS (
            SELECT 1
            FROM jsonb_array_elements(mapped_program -> 'rules') rule(value)
            WHERE jsonb_array_length(COALESCE(
                rule.value -> 'negative_inputs', '[]'::jsonb)) > 0
        ) INTO has_negative;
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := CASE WHEN current_program.program_version_id IS NULL THEN 'ADD'
                       WHEN current_program.version =
                            (program_item.value ->> 'version')::integer THEN 'KEEP'
                       ELSE 'REPLACE' END;
        rule_name := program_item.value ->> 'name';
        dependencies := COALESCE(dependency_names, ARRAY[]::text[]);
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION_PROGRAM',
            'components', (SELECT count(*)
                           FROM pgreact_internal.derivation_program_components(
                               mapped_program))) || CASE WHEN has_negative THEN
            jsonb_build_object(
                'dependency_graph', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'id', dependency_id,
                        'rule', graph.rule_name,
                        'input_order', graph.input_order,
                        'polarity', polarity,
                        'source', source_relation,
                        'target', target_relation,
                        'source_stratum', source_stratum,
                        'target_stratum', target_stratum)
                        ORDER BY target_stratum, graph.rule_name, polarity,
                                 graph.input_order, source_relation)
                    FROM pgreact_internal.derivation_program_graph(
                        mapped_program) graph
                ), '[]'::jsonb),
                'strata', COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'component_id', component.component_id,
                        'stratum', assigned.stratum,
                        'rules', component.rule_names,
                        'targets', component.target_names)
                        ORDER BY assigned.stratum, component.component_order)
                    FROM pgreact_internal.derivation_program_components(
                        mapped_program) component
                    JOIN pgreact_internal.derivation_program_strata(
                        mapped_program) assigned USING (component_id)
                ), '[]'::jsonb)
            ) ELSE '{}'::jsonb END;
        lifecycle_risks := jsonb_build_array(
            'the complete program is rebuilt and commits at one frontier');
        details := jsonb_build_object(
            'prior_program_version_id', current_program.program_version_id,
            'prior_version', current_program.version,
            'next_version', (program_item.value ->> 'version')::integer,
            'max_iterations', (program_item.value ->> 'max_iterations')::integer,
            'max_facts', (program_item.value ->> 'max_facts')::bigint);
        RETURN NEXT;
    END LOOP;
    FOR program_item IN
        SELECT value FROM jsonb_array_elements(COALESCE(
            definition -> 'remove_programs', '[]'::jsonb)) value
    LOOP
        ordinal := ordinal + 1;
        plan_digest := digest;
        action_order := ordinal;
        action := 'REMOVE';
        rule_name := program_item.value ->> 'name';
        dependencies := ARRAY[]::text[];
        generated_object_changes := jsonb_build_object(
            'object_kind', 'DERIVATION_PROGRAM');
        lifecycle_risks := jsonb_build_array(
            'all member supports and facts retract atomically');
        details := '{}'::jsonb;
        RETURN NEXT;
    END LOOP;
END
$$;

CREATE FUNCTION pgreact_internal.derivation_negative_blocked(
    target_program uuid,
    target_rule_version uuid,
    target_key bigint
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    negative_input record;
    blocked boolean;
BEGIN
    FOR negative_input IN
        SELECT *
        FROM pgreact_internal.derivation_program_negative_inputs
        WHERE program_version_id = target_program
          AND rule_version_id = target_rule_version
        ORDER BY input_order
    LOOP
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %s WHERE %I = $1)',
            negative_input.relation_oid::regclass,
            negative_input.key_column)
        INTO blocked USING target_key;
        IF blocked THEN RETURN true; END IF;
    END LOOP;
    RETURN false;
END
$$;

ALTER FUNCTION pgreact_internal.maintain_derived_support(uuid, uuid)
    RENAME TO maintain_derived_support_m8;

CREATE FUNCTION pgreact_internal.maintain_derived_support(
    target_rule_version uuid,
    target_activation uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    program_rule record;
    activation_key bigint;
    negative_input record;
    old_support record;
    current_support record;
    frontier_value bigint;
BEGIN
    SELECT rule.*, version.definition
    INTO program_rule
    FROM pgreact_internal.derivation_program_rules rule
    JOIN pgreact_internal.derivation_program_versions version
      USING (program_version_id)
    WHERE rule.rule_version_id = target_rule_version
      AND version.state = 'ACTIVE'
    ORDER BY version.created_at DESC
    LIMIT 1;
    IF NOT FOUND THEN
        PERFORM pgreact_internal.maintain_derived_support_m8(
            target_rule_version, target_activation);
        RETURN;
    END IF;
    SELECT semantic_key INTO activation_key
    FROM pgreact_internal.activation_state
    WHERE rule_version_id = target_rule_version
      AND activation_id = target_activation AND active;
    IF FOUND AND pgreact_internal.derivation_negative_blocked(
        program_rule.program_version_id, target_rule_version, activation_key) THEN
        SELECT support_id, relation_version_id, semantic_key
        INTO old_support
        FROM pgreact_internal.derived_supports
        WHERE rule_version_id = target_rule_version
          AND activation_id = target_activation AND active;
        IF FOUND THEN
            frontier_value := pgreact_internal.advance_derived_frontier(
                old_support.relation_version_id);
            UPDATE pgreact_internal.derived_supports
            SET active = false, grounded = false,
                last_frontier = frontier_value,
                invalidated_at = clock_timestamp()
            WHERE support_id = old_support.support_id;
            PERFORM pgreact_internal.recompute_derived_fact(
                old_support.relation_version_id,
                old_support.semantic_key, frontier_value);
        END IF;
        RETURN;
    END IF;
    PERFORM pgreact_internal.maintain_derived_support_m8(
        target_rule_version, target_activation);
    SELECT support_id, semantic_key, support_frontier
    INTO current_support
    FROM pgreact_internal.derived_supports
    WHERE rule_version_id = target_rule_version
      AND activation_id = target_activation AND active;
    IF NOT FOUND THEN RETURN; END IF;
    FOR negative_input IN
        SELECT input.*, graph.source_stratum, graph.target_stratum
        FROM pgreact_internal.derivation_program_negative_inputs input
        CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
            program_rule.definition) graph
        WHERE input.program_version_id = program_rule.program_version_id
          AND input.rule_version_id = target_rule_version
          AND graph.rule_name = program_rule.rule_name
          AND graph.polarity = 'NEGATIVE'
          AND graph.input_order = input.input_order
        ORDER BY input.input_order
    LOOP
        INSERT INTO pgreact_internal.negative_dependency_evidence (
            evidence_id, program_version_id, rule_version_id, input_order,
            support_id, semantic_key, relation_oid, relation_name,
            source_stratum, target_stratum, lower_frontier, active
        ) VALUES (
            pgreact_internal.activation_uuid(sha256(convert_to(
                program_rule.program_version_id::text || ':' ||
                target_rule_version::text || ':' ||
                negative_input.input_order || ':' ||
                current_support.semantic_key, 'UTF8'))),
            program_rule.program_version_id, target_rule_version,
            negative_input.input_order, current_support.support_id,
            current_support.semantic_key, negative_input.relation_oid,
            negative_input.relation_name, negative_input.source_stratum,
            negative_input.target_stratum, current_support.support_frontier, true
        )
        ON CONFLICT (evidence_id) DO UPDATE SET
            support_id = EXCLUDED.support_id,
            semantic_key = EXCLUDED.semantic_key,
            relation_oid = EXCLUDED.relation_oid,
            relation_name = EXCLUDED.relation_name,
            source_stratum = EXCLUDED.source_stratum,
            target_stratum = EXCLUDED.target_stratum,
            lower_frontier = EXCLUDED.lower_frontier,
            active = true,
            invalidated_at = NULL;
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.rebuild_derivation_program(
    target_program uuid,
    force_rebuild boolean DEFAULT false,
    preserve_frontier boolean DEFAULT false,
    existing_run_id bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    component_row record;
    rule_row record;
    activation_row record;
    relation_id uuid;
    run_id bigint := existing_run_id;
    component_iterations integer;
    total_iterations integer := 0;
    previous_fingerprint bytea;
    current_fingerprint bytea;
    before_fingerprint bytea;
    after_fingerprint bytea;
    facts bigint;
    supports bigint;
    relation_frontier bigint;
    component_converged boolean;
    source_drift record;
    locked_relation oid;
BEGIN
    SELECT * INTO STRICT program_row
    FROM pgreact_internal.derivation_program_versions
    WHERE program_version_id = target_program AND state = 'ACTIVE';
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    FOR locked_relation IN
        SELECT relation_oid
        FROM (
            SELECT rule.source_view_oid AS relation_oid
            FROM pgreact_internal.derivation_program_rules rule
            WHERE rule.program_version_id = target_program
            UNION
            SELECT input.relation_oid
            FROM pgreact_internal.derivation_program_negative_inputs input
            WHERE input.program_version_id = target_program
            UNION
            SELECT version.public_view_oid
            FROM pgreact_internal.derivation_program_components component
            CROSS JOIN LATERAL unnest(component.target_relations) target(relation_version_id)
            JOIN pgreact_internal.derived_relation_versions version
              USING (relation_version_id)
            WHERE component.program_version_id = target_program
        ) relations
        ORDER BY relation_oid
    LOOP
        EXECUTE format(
            'LOCK TABLE %s IN ACCESS SHARE MODE', locked_relation::regclass);
    END LOOP;
    SELECT r.rule_name,
           encode(r.source_definition_digest, 'hex') AS expected_digest,
           encode(pgreact_internal.source_closure_digest(r.source_view_oid), 'hex')
             AS current_digest
    INTO source_drift
    FROM pgreact_internal.derivation_program_rules r
    WHERE r.program_version_id = target_program
      AND r.source_definition_digest IS DISTINCT FROM
          pgreact_internal.source_closure_digest(r.source_view_oid)
    ORDER BY r.rule_order, r.rule_name
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'derivation program source drift for %',
            source_drift.rule_name
            USING HINT = 'Replace the complete derivation program through its rule pack.',
                  DETAIL = format('expected %s, current %s',
                                  source_drift.expected_digest,
                                  source_drift.current_digest);
    END IF;
    SELECT rule.rule_name, input.relation_name,
           encode(input.relation_definition_digest, 'hex') AS expected_digest,
           encode(pgreact_internal.source_closure_digest(input.relation_oid), 'hex')
             AS current_digest,
           encode(input.relation_row_signature, 'hex') AS expected_signature,
           encode(pgreact_internal.source_row_signature(input.relation_oid), 'hex')
             AS current_signature
    INTO source_drift
    FROM pgreact_internal.derivation_program_negative_inputs input
    JOIN pgreact_internal.derivation_program_rules rule
      USING (program_version_id, rule_version_id)
    WHERE input.program_version_id = target_program
      AND (input.relation_definition_digest IS DISTINCT FROM
               pgreact_internal.source_closure_digest(input.relation_oid)
           OR input.relation_row_signature IS DISTINCT FROM
               pgreact_internal.source_row_signature(input.relation_oid))
    ORDER BY rule.rule_order, rule.rule_name, input.input_order
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'derivation program negative-input drift for %',
            source_drift.rule_name
            USING HINT = 'Replace the complete derivation program through its rule pack.',
                  DETAIL = format(
                      'relation %s; expected definition %s, current %s; expected row signature %s, current %s',
                      source_drift.relation_name,
                      source_drift.expected_digest,
                      source_drift.current_digest,
                      source_drift.expected_signature,
                      source_drift.current_signature);
    END IF;
    PERFORM pg_catalog.set_config(
        'pgreact.program_support_frontier',
        CASE WHEN preserve_frontier THEN program_row.frontier
             ELSE program_row.frontier + 1 END::text,
        true);
    IF run_id IS NULL THEN
        INSERT INTO pgreact_internal.derivation_program_runs (
            program_version_id, started_at, prior_frontier, status, requested_by
        ) VALUES (
            target_program, clock_timestamp(), program_row.frontier,
            'RUNNING', session_user
        ) RETURNING pgreact_internal.derivation_program_runs.run_id INTO run_id;
    END IF;

    SELECT sha256(convert_to(COALESCE(string_agg(
        encode(pgreact_internal.derivation_component_fingerprint(
            target_program, c.component_id), 'hex'), '' ORDER BY c.component_order), ''), 'UTF8'))
    INTO before_fingerprint
    FROM pgreact_internal.derivation_program_components c
    WHERE c.program_version_id = target_program;

    IF NOT preserve_frontier THEN
      FOR rule_row IN
        SELECT r.rule_version_id
        FROM pgreact_internal.derivation_program_components c
        JOIN pgreact_internal.derivation_program_rules r
          USING (program_version_id, component_id)
        WHERE c.program_version_id = target_program
        ORDER BY c.component_order, r.rule_order, r.rule_name
    LOOP
        IF NOT pgreact_internal.derivation_rule_source_current(
            rule_row.rule_version_id) THEN
            PERFORM pgreact_internal.refresh_rule(rule_row.rule_version_id);
            SET CONSTRAINTS ALL IMMEDIATE;
            SET CONSTRAINTS ALL DEFERRED;
        END IF;
        FOR activation_row IN
            SELECT activation_id
            FROM pgreact_internal.activation_state
            WHERE rule_version_id = rule_row.rule_version_id AND active
            ORDER BY activation_id
        LOOP
            PERFORM pgreact_internal.maintain_derived_support(
                rule_row.rule_version_id, activation_row.activation_id);
        END LOOP;
      END LOOP;
      SELECT sha256(convert_to(COALESCE(string_agg(
        encode(pgreact_internal.derivation_component_fingerprint(
            target_program, c.component_id), 'hex'), '' ORDER BY c.component_order), ''), 'UTF8'))
      INTO after_fingerprint
      FROM pgreact_internal.derivation_program_components c
      WHERE c.program_version_id = target_program;
      IF NOT force_rebuild AND before_fingerprint = after_fingerprint THEN
        UPDATE pgreact_internal.derivation_program_runs SET
            completed_at = clock_timestamp(),
            committed_frontier = program_row.frontier,
            iterations = 0,
            fact_count = (
                SELECT count(*)
                FROM pgreact_internal.derived_facts f
                JOIN pgreact_internal.derivation_program_components c
                  ON c.program_version_id = target_program
                 AND f.relation_version_id = ANY (c.target_relations)
            ),
            support_count = (
                SELECT count(*)
                FROM pgreact_internal.derived_supports s
                JOIN pgreact_internal.derivation_program_rules r
                  ON r.program_version_id = target_program
                 AND r.rule_version_id = s.rule_version_id
                WHERE s.active
            ),
            status = 'NOOP'
        WHERE pgreact_internal.derivation_program_runs.run_id = run_id;
          RETURN program_row.frontier;
      END IF;
    END IF;

    IF preserve_frontier THEN
        UPDATE pgreact_internal.derived_frontiers f
        SET transaction_id = pg_catalog.pg_current_xact_id()
        FROM pgreact_internal.derivation_program_components c
        WHERE c.program_version_id = target_program
          AND f.relation_version_id = ANY (c.target_relations);
    END IF;

    FOR relation_id IN
        SELECT DISTINCT unnest(c.target_relations)
        FROM pgreact_internal.derivation_program_components c
        WHERE c.program_version_id = target_program
        ORDER BY 1
    LOOP
        relation_frontier := pgreact_internal.advance_derived_frontier(relation_id);
        UPDATE pgreact_internal.derived_supports s SET
            active = false,
            grounded = false,
            last_frontier = relation_frontier,
            invalidated_at = clock_timestamp()
        FROM pgreact_internal.derivation_program_rules r
        WHERE r.program_version_id = target_program
          AND r.rule_version_id = s.rule_version_id
          AND s.relation_version_id = relation_id
          AND s.active;
        DELETE FROM pgreact_internal.derived_facts f
        WHERE f.relation_version_id = relation_id;
    END LOOP;
    PERFORM pgreact_internal.maybe_fail_program('after_empty');

    FOR component_row IN
        SELECT * FROM pgreact_internal.derivation_program_components
        WHERE program_version_id = target_program
        ORDER BY component_order
    LOOP
        component_converged := false;
        component_iterations := 0;
        previous_fingerprint := pgreact_internal.derivation_component_fingerprint(
            target_program, component_row.component_id);
        FOR iteration_number IN 1..program_row.max_iterations LOOP
            component_iterations := iteration_number;
            total_iterations := total_iterations + 1;
            FOR rule_row IN
                SELECT * FROM pgreact_internal.derivation_program_rules
                WHERE program_version_id = target_program
                  AND component_id = component_row.component_id
                ORDER BY rule_order, rule_name
            LOOP
                IF NOT pgreact_internal.derivation_rule_source_current(
                    rule_row.rule_version_id) THEN
                    PERFORM pgreact_internal.refresh_rule(
                        rule_row.rule_version_id);
                    SET CONSTRAINTS ALL IMMEDIATE;
                    SET CONSTRAINTS ALL DEFERRED;
                END IF;
                FOR activation_row IN
                    SELECT activation_id
                    FROM pgreact_internal.activation_state
                    WHERE rule_version_id = rule_row.rule_version_id AND active
                    ORDER BY activation_id
                LOOP
                    PERFORM pgreact_internal.maintain_derived_support(
                        rule_row.rule_version_id, activation_row.activation_id);
                END LOOP;
            END LOOP;
            current_fingerprint := pgreact_internal.derivation_component_fingerprint(
                target_program, component_row.component_id);
            SELECT count(*) INTO facts
            FROM pgreact_internal.derived_facts
            WHERE relation_version_id = ANY (component_row.target_relations);
            SELECT count(*) INTO supports
            FROM pgreact_internal.derived_supports s
            JOIN pgreact_internal.derivation_program_rules r
              ON r.program_version_id = target_program
             AND r.component_id = component_row.component_id
             AND r.rule_version_id = s.rule_version_id
            WHERE s.active;
            INSERT INTO pgreact_internal.derivation_program_iterations (
                run_id, program_version_id, component_id, iteration,
                fact_count, support_count, fingerprint, completed_at
            ) VALUES (
                run_id, target_program, component_row.component_id,
                iteration_number, facts, supports,
                current_fingerprint, clock_timestamp()
            );
            IF (
                SELECT count(*) FROM pgreact_internal.derived_facts f
                JOIN pgreact_internal.derivation_program_components c
                  ON c.program_version_id = target_program
                 AND f.relation_version_id = ANY (c.target_relations)
            ) > program_row.max_facts THEN
                RAISE EXCEPTION 'derivation program % exceeded max_facts %',
                    target_program, program_row.max_facts;
            END IF;
            PERFORM pgreact_internal.maybe_fail_program('after_iteration');
            IF current_fingerprint = previous_fingerprint THEN
                component_converged := true;
                EXIT;
            END IF;
            previous_fingerprint := current_fingerprint;
        END LOOP;
        IF NOT component_converged THEN
            RAISE EXCEPTION 'derivation program % component % did not converge within % iterations',
                target_program, component_row.component_id,
                program_row.max_iterations;
        END IF;
        INSERT INTO pgreact_internal.derivation_program_component_frontiers (
            program_version_id, component_id, frontier, iterations,
            fact_count, support_count, fingerprint, committed_at
        ) VALUES (
            target_program, component_row.component_id,
            CASE WHEN preserve_frontier THEN program_row.frontier
                 ELSE program_row.frontier + 1 END,
            component_iterations,
            facts, supports, current_fingerprint, clock_timestamp()
        )
        ON CONFLICT (program_version_id, component_id) DO UPDATE SET
            frontier = EXCLUDED.frontier,
            iterations = EXCLUDED.iterations,
            fact_count = EXCLUDED.fact_count,
            support_count = EXCLUDED.support_count,
            fingerprint = EXCLUDED.fingerprint,
            committed_at = EXCLUDED.committed_at;
    END LOOP;

    IF NOT preserve_frontier THEN
        UPDATE pgreact_internal.derivation_program_versions
        SET frontier = frontier + 1
        WHERE program_version_id = target_program
        RETURNING frontier INTO program_row.frontier;
    END IF;
    SELECT count(*) INTO facts
    FROM pgreact_internal.derived_facts f
    JOIN pgreact_internal.derivation_program_components c
      ON c.program_version_id = target_program
     AND f.relation_version_id = ANY (c.target_relations);
    SELECT count(*) INTO supports
    FROM pgreact_internal.derived_supports s
    JOIN pgreact_internal.derivation_program_rules r
      ON r.program_version_id = target_program
     AND r.rule_version_id = s.rule_version_id
    WHERE s.active;
    UPDATE pgreact_internal.derivation_program_runs SET
        completed_at = clock_timestamp(),
        committed_frontier = program_row.frontier,
        iterations = total_iterations,
        fact_count = facts,
        support_count = supports,
        status = 'COMPLETED'
    WHERE pgreact_internal.derivation_program_runs.run_id = run_id;
    PERFORM pgreact_internal.maybe_fail_program('before_commit');
    RETURN program_row.frontier;
END
$$;

ALTER FUNCTION pgreact.reconcile_derivation_program(uuid)
    RENAME TO reconcile_derivation_program_m8;
ALTER FUNCTION pgreact.reconcile_derivation_program_m8(uuid)
    SET SCHEMA pgreact_internal;

CREATE FUNCTION pgreact.reconcile_derivation_program(target_program uuid)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
#variable_conflict use_variable
DECLARE
    program_row pgreact_internal.derivation_program_versions%ROWTYPE;
    target_reconciliation_id bigint;
    diagnostic_order integer;
    repair_count bigint;
    defect record;
    defects jsonb := '[]'::jsonb;
BEGIN
    program_row := pgreact_internal.assert_program_owner(target_program);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);

    FOR defect IN
        SELECT component.component_id, component.stratum AS actual,
               expected.stratum AS expected
        FROM pgreact_internal.derivation_program_components component
        JOIN LATERAL pgreact_internal.derivation_program_strata(
            program_row.definition) expected
          ON expected.component_id = component.component_id
        WHERE component.program_version_id = target_program
          AND component.stratum IS DISTINCT FROM expected.stratum
        ORDER BY component.component_order
    LOOP
        defects := defects || jsonb_build_array(jsonb_build_object(
            'code', 'WRONG_STRATUM',
            'object_identity', defect.component_id,
            'details', jsonb_build_object(
                'object_kind', 'COMPONENT',
                'expected', defect.expected,
                'actual', defect.actual)));
    END LOOP;
    UPDATE pgreact_internal.derivation_program_components component
    SET stratum = expected.stratum
    FROM pgreact_internal.derivation_program_strata(
        program_row.definition) expected
    WHERE component.program_version_id = target_program
      AND component.component_id = expected.component_id
      AND component.stratum IS DISTINCT FROM expected.stratum;

    FOR defect IN
        SELECT support.support_id, support.rule_version_id,
               support.semantic_key
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = target_program
         AND rule.rule_version_id = support.rule_version_id
        WHERE support.active
          AND EXISTS (
              SELECT 1
              FROM pgreact_internal.derivation_program_negative_inputs input
              WHERE input.program_version_id = target_program
                AND input.rule_version_id = support.rule_version_id)
        ORDER BY support.support_id
    LOOP
        IF pgreact_internal.derivation_negative_blocked(
            target_program, defect.rule_version_id, defect.semantic_key) THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'EXTRA_SUPPORT',
                'object_identity', defect.support_id,
                'details', jsonb_build_object(
                    'rule_version_id', defect.rule_version_id,
                    'semantic_key', defect.semantic_key,
                    'reason', 'negative input is present')));
        END IF;
    END LOOP;

    FOR defect IN
        WITH expected AS (
            SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                       target_program::text || ':' || support.rule_version_id::text || ':' ||
                       input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id,
                   support.support_id, support.rule_version_id,
                   input.input_order, support.semantic_key,
                   input.relation_oid, input.relation_name,
                   graph.source_stratum, graph.target_stratum,
                   support.support_frontier AS lower_frontier
            FROM pgreact_internal.derived_supports support
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = target_program
             AND rule.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.derivation_program_negative_inputs input
              ON input.program_version_id = target_program
             AND input.rule_version_id = support.rule_version_id
            CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
                program_row.definition) graph
            WHERE support.active
              AND graph.rule_name = rule.rule_name
              AND graph.polarity = 'NEGATIVE'
              AND graph.input_order = input.input_order
        )
        SELECT expected.*
        FROM expected
        LEFT JOIN pgreact_internal.negative_dependency_evidence evidence
          ON evidence.evidence_id = expected.evidence_id AND evidence.active
        WHERE evidence.evidence_id IS NULL
        ORDER BY expected.evidence_id
    LOOP
        defects := defects || jsonb_build_array(jsonb_build_object(
            'code', 'MISSING_EVIDENCE',
            'object_identity', defect.evidence_id,
            'details', jsonb_build_object(
                'rule_version_id', defect.rule_version_id,
                'input_order', defect.input_order,
                'semantic_key', defect.semantic_key)));
    END LOOP;

    FOR defect IN
        WITH expected AS (
            SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                       target_program::text || ':' || support.rule_version_id::text || ':' ||
                       input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id
            FROM pgreact_internal.derived_supports support
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = target_program
             AND rule.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.derivation_program_negative_inputs input
              ON input.program_version_id = target_program
             AND input.rule_version_id = support.rule_version_id
            WHERE support.active
        )
        SELECT evidence.evidence_id
        FROM pgreact_internal.negative_dependency_evidence evidence
        WHERE evidence.program_version_id = target_program AND evidence.active
          AND NOT EXISTS (
              SELECT 1 FROM expected
              WHERE expected.evidence_id = evidence.evidence_id)
        ORDER BY evidence.evidence_id
    LOOP
        defects := defects || jsonb_build_array(jsonb_build_object(
            'code', 'EXTRA_EVIDENCE',
            'object_identity', defect.evidence_id,
            'details', '{}'::jsonb));
    END LOOP;

    FOR defect IN
        WITH expected AS (
            SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                       target_program::text || ':' || support.rule_version_id::text || ':' ||
                       input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id,
                   support.support_id, support.rule_version_id,
                   input.input_order, support.semantic_key,
                   input.relation_oid, input.relation_name,
                   graph.source_stratum, graph.target_stratum,
                   support.support_frontier AS lower_frontier
            FROM pgreact_internal.derived_supports support
            JOIN pgreact_internal.derivation_program_rules rule
              ON rule.program_version_id = target_program
             AND rule.rule_version_id = support.rule_version_id
            JOIN pgreact_internal.derivation_program_negative_inputs input
              ON input.program_version_id = target_program
             AND input.rule_version_id = support.rule_version_id
            CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
                program_row.definition) graph
            WHERE support.active
              AND graph.rule_name = rule.rule_name
              AND graph.polarity = 'NEGATIVE'
              AND graph.input_order = input.input_order
        )
        SELECT evidence.*, expected.evidence_id AS expected_evidence_id,
               expected.support_id AS expected_support_id,
               expected.relation_oid AS expected_relation_oid,
               expected.relation_name AS expected_relation_name,
               expected.source_stratum AS expected_source_stratum,
               expected.target_stratum AS expected_target_stratum,
               expected.lower_frontier AS expected_lower_frontier
        FROM pgreact_internal.negative_dependency_evidence evidence
        JOIN expected
          ON expected.rule_version_id = evidence.rule_version_id
         AND expected.input_order = evidence.input_order
         AND expected.semantic_key = evidence.semantic_key
        WHERE evidence.program_version_id = target_program AND evidence.active
        ORDER BY evidence.evidence_id
    LOOP
        IF defect.evidence_id IS DISTINCT FROM defect.expected_evidence_id
           OR defect.support_id IS DISTINCT FROM defect.expected_support_id
           OR defect.relation_oid IS DISTINCT FROM defect.expected_relation_oid
           OR defect.relation_name IS DISTINCT FROM defect.expected_relation_name THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'STALE_EVIDENCE',
                'object_identity', defect.evidence_id,
                'details', jsonb_build_object(
                    'expected_evidence_id', defect.expected_evidence_id,
                    'expected_support_id', defect.expected_support_id,
                    'expected_relation', defect.expected_relation_name)));
        END IF;
        IF defect.source_stratum IS DISTINCT FROM defect.expected_source_stratum
           OR defect.target_stratum IS DISTINCT FROM defect.expected_target_stratum THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'WRONG_STRATUM',
                'object_identity', defect.evidence_id,
                'details', jsonb_build_object(
                    'object_kind', 'EVIDENCE',
                    'expected_source', defect.expected_source_stratum,
                    'actual_source', defect.source_stratum,
                    'expected_target', defect.expected_target_stratum,
                    'actual_target', defect.target_stratum)));
        END IF;
        IF defect.lower_frontier IS DISTINCT FROM defect.expected_lower_frontier THEN
            defects := defects || jsonb_build_array(jsonb_build_object(
                'code', 'WRONG_FRONTIER',
                'object_identity', defect.evidence_id,
                'details', jsonb_build_object(
                    'object_kind', 'EVIDENCE',
                    'expected', defect.expected_lower_frontier,
                    'actual', defect.lower_frontier)));
        END IF;
    END LOOP;

    PERFORM pgreact_internal.reconcile_derivation_program_m8(target_program);
    SELECT max(reconciliation.reconciliation_id)
    INTO STRICT target_reconciliation_id
    FROM pgreact_internal.derivation_program_reconciliations reconciliation
    WHERE reconciliation.program_version_id = target_program;

    FOR defect IN
        SELECT diagnostic.diagnostic_order, activation.semantic_key,
               (diagnostic.details ->> 'rule_version_id')::uuid AS rule_version_id
        FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
        JOIN pgreact_internal.activation_state activation
          ON activation.rule_version_id =
                 (diagnostic.details ->> 'rule_version_id')::uuid
         AND activation.activation_id =
                 (diagnostic.details ->> 'activation_id')::uuid
        WHERE diagnostic.reconciliation_id = target_reconciliation_id
          AND diagnostic.code = 'MISSING_SUPPORT'
        ORDER BY diagnostic.diagnostic_order
    LOOP
        IF pgreact_internal.derivation_negative_blocked(
            target_program, defect.rule_version_id, defect.semantic_key) THEN
            DELETE FROM pgreact_internal.derivation_program_repair_diagnostics
            WHERE pgreact_internal.derivation_program_repair_diagnostics.reconciliation_id =
                      target_reconciliation_id
              AND pgreact_internal.derivation_program_repair_diagnostics.diagnostic_order =
                      defect.diagnostic_order;
        END IF;
    END LOOP;

    WITH expected AS (
        SELECT pgreact_internal.activation_uuid(sha256(convert_to(
                   target_program::text || ':' || support.rule_version_id::text || ':' ||
                   input.input_order || ':' || support.semantic_key, 'UTF8'))) AS evidence_id
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules rule
          ON rule.program_version_id = target_program
         AND rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derivation_program_negative_inputs input
          ON input.program_version_id = target_program
         AND input.rule_version_id = support.rule_version_id
        WHERE support.active
    )
    DELETE FROM pgreact_internal.negative_dependency_evidence evidence
    WHERE evidence.program_version_id = target_program AND evidence.active
      AND NOT EXISTS (
          SELECT 1 FROM expected
          WHERE expected.evidence_id = evidence.evidence_id);

    SELECT COALESCE(max(diagnostic.diagnostic_order), 0)
    INTO diagnostic_order
    FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
    WHERE diagnostic.reconciliation_id = target_reconciliation_id;
    FOR defect IN
        SELECT item.value
        FROM jsonb_array_elements(defects) WITH ORDINALITY item(value, ordinal)
        ORDER BY item.ordinal
    LOOP
        diagnostic_order := diagnostic_order + 1;
        INSERT INTO pgreact_internal.derivation_program_repair_diagnostics VALUES (
            target_reconciliation_id, diagnostic_order,
            defect.value ->> 'code', defect.value ->> 'object_identity',
            defect.value -> 'details');
    END LOOP;
    SELECT count(*) INTO repair_count
    FROM pgreact_internal.derivation_program_repair_diagnostics diagnostic
    WHERE diagnostic.reconciliation_id = target_reconciliation_id;
    UPDATE pgreact_internal.derivation_program_reconciliations
    SET repairs = repair_count
    WHERE pgreact_internal.derivation_program_reconciliations.reconciliation_id =
          target_reconciliation_id;
    RETURN repair_count;
END
$$;

CREATE OR REPLACE FUNCTION pgreact_internal.recursive_fact_proof(
    target_program uuid,
    target_relation uuid,
    target_key bigint,
    path uuid[]
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    fact_row record;
    support_row record;
    input_row record;
    evidence_row record;
    supports jsonb := '[]'::jsonb;
    inputs jsonb;
    negative_checks jsonb;
    input_node jsonb;
    relation_identity text;
BEGIN
    SELECT f.fact_id, f.fact, relation.relation_name, version.version
    INTO fact_row
    FROM pgreact_internal.derived_facts f
    JOIN pgreact_internal.derived_relation_versions version
      USING (relation_version_id)
    JOIN pgreact_internal.derived_relations relation USING (relation_id)
    WHERE f.relation_version_id = target_relation
      AND f.semantic_key = target_key;
    IF NOT FOUND THEN RETURN NULL; END IF;
    relation_identity := fact_row.relation_name || '@' || fact_row.version;
    IF fact_row.fact_id = ANY (path) THEN
        RETURN jsonb_build_object(
            'cycle', true,
            'relation', relation_identity,
            'semantic_key', target_key
        );
    END IF;
    FOR support_row IN
        SELECT support.support_id, support.logical_support_id,
               support.source_binding, rule.rule_name, derivation.version
        FROM pgreact_internal.derived_supports support
        JOIN pgreact_internal.derivation_program_rules program_rule
          ON program_rule.program_version_id = target_program
         AND program_rule.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.derivation_rule_versions derivation
          ON derivation.rule_version_id = support.rule_version_id
        JOIN pgreact_internal.rules rule ON rule.rule_id = derivation.rule_id
        WHERE support.relation_version_id = target_relation
          AND support.semantic_key = target_key AND support.active
        ORDER BY rule.rule_name, derivation.version,
                 support.logical_support_id
    LOOP
        inputs := '[]'::jsonb;
        FOR input_row IN
            SELECT input.*, relation.relation_name, version.version
            FROM pgreact_internal.derived_support_inputs input
            JOIN pgreact_internal.derived_relation_versions version
              ON version.relation_version_id = input.relation_version_id
            JOIN pgreact_internal.derived_relations relation USING (relation_id)
            WHERE input.support_id = support_row.support_id
            ORDER BY input.input_order
        LOOP
            IF input_row.fact_id = ANY (path || fact_row.fact_id) THEN
                input_node := jsonb_build_object(
                    'cycle', true,
                    'relation', input_row.relation_name || '@' || input_row.version,
                    'semantic_key', input_row.semantic_key
                );
            ELSE
                input_node := pgreact_internal.recursive_fact_proof(
                    target_program, input_row.relation_version_id,
                    input_row.semantic_key, path || fact_row.fact_id);
            END IF;
            inputs := inputs || jsonb_build_array(input_node);
        END LOOP;
        negative_checks := '[]'::jsonb;
        FOR evidence_row IN
            SELECT *
            FROM pgreact_internal.negative_dependency_evidence
            WHERE support_id = support_row.support_id AND active
            ORDER BY input_order
        LOOP
            negative_checks := negative_checks || jsonb_build_array(
                jsonb_build_object(
                    'evidence_id', evidence_row.evidence_id,
                    'relation', evidence_row.relation_name,
                    'semantic_key', evidence_row.semantic_key,
                    'source_stratum', evidence_row.source_stratum,
                    'lower_frontier', evidence_row.lower_frontier
                ));
        END LOOP;
        supports := supports || jsonb_build_array(jsonb_build_object(
            'rule', support_row.rule_name || '@' || support_row.version,
            'source_binding', support_row.source_binding,
            'inputs', inputs,
            'negative_checks', negative_checks
        ));
    END LOOP;
    RETURN jsonb_build_object(
        'relation', relation_identity,
        'fact', fact_row.fact,
        'supports', supports
    );
END
$$;

CREATE VIEW pgreact.derivation_dependency_graph AS
SELECT version.program_version_id, program.program_name,
       version.version AS program_version,
       graph.dependency_id, graph.rule_name, graph.input_order,
       graph.polarity, graph.source_relation, graph.target_relation,
       graph.source_component_id, graph.target_component_id,
       graph.source_stratum, graph.target_stratum
FROM pgreact_internal.derivation_program_versions version
JOIN pgreact_internal.derivation_programs program USING (program_id)
CROSS JOIN LATERAL pgreact_internal.derivation_program_graph(
    version.definition) graph;

CREATE VIEW pgreact.derivation_strata AS
SELECT component.program_version_id, program.program_name,
       version.version AS program_version, component.component_id,
       component.stratum, component.component_order, component.cyclic,
       component.rule_names,
       ARRAY(
           SELECT relation.relation_name
           FROM unnest(component.target_relations)
                WITH ORDINALITY target(relation_version_id, ordinal)
           JOIN pgreact_internal.derived_relation_versions relation_version
             USING (relation_version_id)
           JOIN pgreact_internal.derived_relations relation USING (relation_id)
           ORDER BY target.ordinal
       ) AS target_relations,
       frontier.frontier, frontier.iterations, frontier.fact_count,
       frontier.support_count, frontier.committed_at
FROM pgreact_internal.derivation_program_components component
JOIN pgreact_internal.derivation_program_versions version USING (program_version_id)
JOIN pgreact_internal.derivation_programs program USING (program_id)
LEFT JOIN pgreact_internal.derivation_program_component_frontiers frontier
  USING (program_version_id, component_id);

CREATE VIEW pgreact.negative_dependency_evidence AS
SELECT evidence.evidence_id, evidence.program_version_id,
       program.program_name, version.version AS program_version,
       evidence.rule_version_id, rule.rule_name, evidence.input_order,
       evidence.support_id, evidence.semantic_key,
       evidence.relation_name AS checked_relation,
       evidence.source_stratum, evidence.target_stratum,
       evidence.lower_frontier
FROM pgreact_internal.negative_dependency_evidence evidence
JOIN pgreact_internal.derivation_program_versions version
  USING (program_version_id)
JOIN pgreact_internal.derivation_programs program USING (program_id)
JOIN pgreact_internal.derivation_program_rules rule
  USING (program_version_id, rule_version_id)
JOIN pgreact_internal.derived_supports support USING (support_id)
WHERE version.state = 'ACTIVE' AND evidence.active AND support.active;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
    pgreact_internal.derivation_program_graph(jsonb) TO PUBLIC;
REVOKE ALL ON pgreact.derivation_dependency_graph,
    pgreact.derivation_strata,
    pgreact.negative_dependency_evidence FROM PUBLIC;

COMMENT ON EXTENSION pg_react IS
    'M9 stratified negation composed with positive fixed points';
