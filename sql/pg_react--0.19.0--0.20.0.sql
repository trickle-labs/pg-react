-- M23 practical temporal conditions. Temporal state remains on the inherited
-- match stream and monotone database-time frontier; no second scheduler exists.
ALTER TABLE pgreact_internal.operational_settings
    ADD COLUMN max_temporal_keys_per_pass integer NOT NULL DEFAULT 100000
        CHECK (max_temporal_keys_per_pass BETWEEN 1 AND 10000000);

CREATE TABLE pgreact_internal.temporal_rules (
    rule_version_id uuid PRIMARY KEY REFERENCES pgreact_internal.rule_versions,
    primitive text NOT NULL CHECK (primitive IN ('DURATION', 'ABSENCE', 'COOLDOWN', 'HYSTERESIS')),
    duration_us bigint CHECK (duration_us IS NULL OR duration_us > 0),
    deadline_column name,
    cooldown_us bigint CHECK (cooldown_us IS NULL OR cooldown_us > 0),
    recovery_condition_oid oid,
    recovery_condition_name text,
    recovery_key_column name,
    clock_domain text NOT NULL DEFAULT 'DATABASE_TIME' CHECK (clock_domain = 'DATABASE_TIME'),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((primitive = 'DURATION' AND duration_us IS NOT NULL AND deadline_column IS NULL
             AND cooldown_us IS NULL AND recovery_condition_oid IS NULL)
        OR (primitive = 'ABSENCE' AND deadline_column IS NOT NULL AND duration_us IS NULL
             AND cooldown_us IS NULL AND recovery_condition_oid IS NULL)
        OR (primitive = 'COOLDOWN' AND cooldown_us IS NOT NULL AND duration_us IS NULL
             AND deadline_column IS NULL AND recovery_condition_oid IS NULL)
        OR (primitive = 'HYSTERESIS' AND duration_us IS NULL AND deadline_column IS NULL
             AND cooldown_us IS NULL AND recovery_condition_oid IS NOT NULL))
);

CREATE TABLE pgreact_internal.temporal_state (
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.temporal_rules,
    semantic_key bigint NOT NULL,
    state text NOT NULL CHECK (state IN ('WAITING', 'PENDING', 'ACTIVE', 'COOLDOWN', 'ARMED', 'RECOVERED')),
    active boolean NOT NULL DEFAULT false,
    input_true boolean NOT NULL DEFAULT false,
    recovery_true boolean NOT NULL DEFAULT false,
    continuous_since timestamptz,
    pending_deadline timestamptz,
    cooldown_until timestamptz,
    generation bigint NOT NULL DEFAULT 0 CHECK (generation >= 0),
    last_frontier timestamptz NOT NULL,
    last_bindings jsonb,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (rule_version_id, semantic_key)
);
CREATE INDEX temporal_state_deadline_idx
    ON pgreact_internal.temporal_state (rule_version_id, pending_deadline, semantic_key)
    WHERE pending_deadline IS NOT NULL;
CREATE INDEX temporal_state_cooldown_idx
    ON pgreact_internal.temporal_state (rule_version_id, cooldown_until, semantic_key)
    WHERE cooldown_until IS NOT NULL;

CREATE TABLE pgreact_internal.temporal_history (
    temporal_event_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_version_id uuid NOT NULL REFERENCES pgreact_internal.temporal_rules,
    semantic_key bigint NOT NULL,
    lifecycle_event_id bigint REFERENCES pgreact_internal.lifecycle_events,
    event_kind text NOT NULL CHECK (event_kind IN ('OBSERVE', 'ACTIVATE', 'DEACTIVATE')),
    primitive_state text NOT NULL,
    input_true boolean NOT NULL,
    recovery_true boolean NOT NULL,
    continuous_since timestamptz,
    pending_deadline timestamptz,
    cooldown_until timestamptz,
    clock_frontier timestamptz NOT NULL,
    bindings jsonb,
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX temporal_history_key_idx
    ON pgreact_internal.temporal_history (rule_version_id, semantic_key, temporal_event_id);

CREATE FUNCTION pgreact_internal.temporal_duration_us(value interval)
RETURNS bigint
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE micros numeric;
BEGIN
    IF value IS NULL OR extract(year FROM value) <> 0 OR extract(month FROM value) <> 0 THEN
        RAISE EXCEPTION 'M23_DURATION_VALUE: duration must be a positive integral microsecond interval';
    END IF;
    micros := extract(epoch FROM value)::numeric * 1000000;
    IF micros <> trunc(micros) OR micros < 1 OR micros > 31557600000000000 THEN
        RAISE EXCEPTION 'M23_DURATION_VALUE: duration must be a positive integral microsecond interval within the published bound';
    END IF;
    RETURN micros::bigint;
END
$m23$;

CREATE FUNCTION pgreact_internal.validate_temporal_rule(
    condition regclass,
    semantic_key name,
    primitive text,
    duration interval DEFAULT NULL,
    deadline_column name DEFAULT NULL,
    cooldown interval DEFAULT NULL,
    recovery_condition regclass DEFAULT NULL,
    recovery_key_column name DEFAULT NULL
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE diagnostic record; duration_us bigint; cooldown_us bigint;
BEGIN
    SELECT result.* INTO diagnostic
    FROM pgreact.validate_rule(condition, ARRAY[semantic_key]::name[], NULL::regprocedure) result
    WHERE result.severity = 'ERROR' ORDER BY result.code LIMIT 1;
    IF FOUND THEN
        RETURN QUERY SELECT 11, diagnostic.code, diagnostic.severity,
            diagnostic.object_identity, diagnostic.message, diagnostic.hint, diagnostic.details;
        RETURN;
    END IF;
    IF primitive NOT IN ('DURATION', 'ABSENCE', 'COOLDOWN', 'HYSTERESIS') THEN
        RETURN QUERY SELECT 11, 'M23_PRIMITIVE', 'ERROR', condition::text,
            'primitive must be DURATION, ABSENCE, COOLDOWN, or HYSTERESIS',
            'Choose one supported practical temporal primitive.', '{}'::jsonb;
        RETURN;
    END IF;
    IF primitive = 'DURATION' THEN
        BEGIN duration_us := pgreact_internal.temporal_duration_us(duration);
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT 11, 'M23_DURATION_VALUE', 'ERROR', condition::text,
                SQLERRM, 'Use a positive integral microsecond interval.', '{}'::jsonb;
            RETURN;
        END;
        IF deadline_column IS NOT NULL OR cooldown IS NOT NULL OR recovery_condition IS NOT NULL THEN
            RETURN QUERY SELECT 11, 'M23_DECLARATION_SHAPE', 'ERROR', condition::text,
                'duration conditions accept only one fixed database-time duration',
                'Remove deadline, cooldown, and recovery inputs.', '{}'::jsonb;
            RETURN;
        END IF;
    ELSIF primitive = 'ABSENCE' THEN
        IF deadline_column IS NULL OR duration IS NOT NULL OR cooldown IS NOT NULL
           OR recovery_condition IS NOT NULL THEN
            RETURN QUERY SELECT 11, 'M23_DECLARATION_SHAPE', 'ERROR', condition::text,
                'absence conditions require one direct deadline column and no other temporal input',
                'Project one finite timestamptz deadline unchanged from the condition view.', '{}'::jsonb;
            RETURN;
        END IF;
        SELECT result.* INTO diagnostic
        FROM pgreact_internal.validate_deadline_rule(condition, semantic_key, deadline_column, NULL::regprocedure) result
        WHERE result.severity = 'ERROR' ORDER BY result.code LIMIT 1;
        IF FOUND THEN
            RETURN QUERY SELECT 11, diagnostic.code, diagnostic.severity,
                diagnostic.object_identity, diagnostic.message, diagnostic.hint, diagnostic.details;
            RETURN;
        END IF;
    ELSIF primitive = 'COOLDOWN' THEN
        BEGIN cooldown_us := pgreact_internal.temporal_duration_us(cooldown);
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT 11, 'M23_COOLDOWN_VALUE', 'ERROR', condition::text,
                SQLERRM, 'Use a positive integral microsecond interval.', '{}'::jsonb;
            RETURN;
        END;
        IF duration IS NOT NULL OR deadline_column IS NOT NULL OR recovery_condition IS NOT NULL THEN
            RETURN QUERY SELECT 11, 'M23_DECLARATION_SHAPE', 'ERROR', condition::text,
                'cooldown conditions accept one fixed database-time cooldown',
                'Remove duration, deadline, and recovery inputs.', '{}'::jsonb;
            RETURN;
        END IF;
    ELSE
        IF recovery_condition IS NULL OR recovery_key_column IS NULL
           OR duration IS NOT NULL OR deadline_column IS NOT NULL OR cooldown IS NOT NULL THEN
            RETURN QUERY SELECT 11, 'M23_RECOVERY_DECLARATION', 'ERROR', condition::text,
                'hysteresis conditions require one enter view and one recovery view',
                'Supply recovery_condition and recovery_key_column only.', '{}'::jsonb;
            RETURN;
        END IF;
        SELECT result.* INTO diagnostic
        FROM pgreact.validate_rule(recovery_condition, ARRAY[recovery_key_column]::name[], NULL::regprocedure) result
        WHERE result.severity = 'ERROR' ORDER BY result.code LIMIT 1;
        IF FOUND THEN
            RETURN QUERY SELECT 11, 'M23_RECOVERY_' || diagnostic.code, diagnostic.severity,
                diagnostic.object_identity, diagnostic.message, diagnostic.hint, diagnostic.details;
            RETURN;
        END IF;
    END IF;
    RETURN QUERY SELECT 11, 'OK', 'INFO', condition::text,
        'temporal declaration is valid on the bounded database-time coordinator path',
        'Use author_temporal_rule, then run the coordinator at the required committed frontier.',
        jsonb_build_object('primitive', primitive, 'clock_domain', 'DATABASE_TIME',
                           'duration_us', duration_us, 'cooldown_us', cooldown_us,
                           'deadline_column', deadline_column,
                           'recovery_condition', recovery_condition::text,
                           'recovery_key_column', recovery_key_column);
END
$m23$;

CREATE FUNCTION pgreact_api.validate_temporal_rule(
    condition regclass,
    semantic_key name,
    primitive text,
    duration interval DEFAULT NULL,
    deadline_column name DEFAULT NULL,
    cooldown interval DEFAULT NULL,
    recovery_condition regclass DEFAULT NULL,
    recovery_key_column name DEFAULT NULL
)
RETURNS TABLE(
    contract_version integer, code text, severity text,
    object_identity text, message text, hint text, details jsonb
)
LANGUAGE SQL SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
    SELECT * FROM pgreact_internal.validate_temporal_rule(
        $1, $2, $3, $4, $5, $6, $7, $8)
$m23$;

CREATE FUNCTION pgreact_api.author_temporal_rule(
    rule_name text,
    condition regclass,
    semantic_key name,
    primitive text,
    duration interval DEFAULT NULL,
    deadline_column name DEFAULT NULL,
    cooldown interval DEFAULT NULL,
    recovery_condition regclass DEFAULT NULL,
    recovery_key_column name DEFAULT NULL,
    on_activate regprocedure DEFAULT NULL,
    salience integer DEFAULT 0,
    agenda_group text DEFAULT 'default',
    max_attempts integer DEFAULT 1,
    initial_backoff_seconds integer DEFAULT 1,
    backoff_multiplier numeric DEFAULT 2,
    max_backoff_seconds integer DEFAULT 60
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE diagnostic record; version_id uuid; version_row pgreact_internal.rule_versions%ROWTYPE;
    duration_us bigint; cooldown_us bigint;
BEGIN
    SELECT result.* INTO diagnostic
    FROM pgreact_internal.validate_temporal_rule(
        condition, semantic_key, primitive, duration, deadline_column,
        cooldown, recovery_condition, recovery_key_column) result
    WHERE result.severity = 'ERROR' ORDER BY result.code LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'pg-react temporal validation % for %: %',
            diagnostic.code, diagnostic.object_identity, diagnostic.message
            USING HINT = diagnostic.hint;
    END IF;
    IF primitive = 'DURATION' THEN duration_us := pgreact_internal.temporal_duration_us(duration); END IF;
    IF primitive = 'COOLDOWN' THEN cooldown_us := pgreact_internal.temporal_duration_us(cooldown); END IF;
    version_id := pgreact.create_rule(
        name => rule_name, definition => condition,
        key_columns => ARRAY[semantic_key]::name[], kind => 'CONSTRAINT',
        on_activate => NULL::regprocedure, on_deactivate => NULL::regprocedure,
        on_change => NULL::regprocedure, bootstrap_policy => 'SEED_CURRENT',
        change_columns => NULL::name[], salience => salience,
        agenda_group => agenda_group, conflict_key_columns => NULL::name[],
        max_attempts => max_attempts, initial_backoff_seconds => initial_backoff_seconds,
        backoff_multiplier => backoff_multiplier, max_backoff_seconds => max_backoff_seconds);
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions
    WHERE rule_version_id = version_id;
    IF on_activate IS NOT NULL THEN
        PERFORM pgreact_internal.add_typed_binding(
            version_id, 'ACTIVATE', on_activate, max_attempts,
            initial_backoff_seconds, backoff_multiplier, max_backoff_seconds);
    END IF;
    INSERT INTO pgreact_internal.temporal_rules (
        rule_version_id, primitive, duration_us, deadline_column, cooldown_us,
        recovery_condition_oid, recovery_condition_name, recovery_key_column)
    VALUES (
        version_id, primitive, duration_us, deadline_column, cooldown_us,
        recovery_condition, recovery_condition::text, recovery_key_column);
    EXECUTE format('DROP TRIGGER IF EXISTS pgreact_finalize ON %s', version_row.match_relid::regclass);
    DELETE FROM pgreact_internal.agenda WHERE rule_version_id = version_id;
    DELETE FROM pgreact_internal.lifecycle_events WHERE rule_version_id = version_id;
    DELETE FROM pgreact_internal.activation_state WHERE rule_version_id = version_id;
    EXECUTE format(
        'CREATE CONSTRAINT TRIGGER pgreact_temporal_finalize '
        'AFTER INSERT OR UPDATE OR DELETE ON %s DEFERRABLE INITIALLY DEFERRED '
        'FOR EACH ROW EXECUTE FUNCTION pgreact_internal.finalize_temporal_match_delta(%L)',
        version_row.match_relid::regclass, version_id::text);
    PERFORM pgreact_internal.reconcile_temporal_rule(version_id);
    RETURN version_id;
END
$m23$;

CREATE FUNCTION pgreact_internal.finalize_temporal_match_delta()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE version_id uuid := TG_ARGV[0]::uuid; key_column name; old_key bigint; new_key bigint;
BEGIN
    SELECT rule_versions.key_column INTO STRICT key_column
    FROM pgreact_internal.rule_versions
    WHERE rule_version_id = version_id;
    IF TG_OP <> 'INSERT' THEN
        old_key := (to_jsonb(OLD) ->> key_column)::bigint;
        IF old_key IS NOT NULL THEN PERFORM pgreact_internal.reconcile_temporal_key(version_id, old_key); END IF;
    END IF;
    IF TG_OP <> 'DELETE' THEN
        new_key := (to_jsonb(NEW) ->> key_column)::bigint;
        IF new_key IS NOT NULL AND new_key IS DISTINCT FROM old_key THEN
            PERFORM pgreact_internal.reconcile_temporal_key(version_id, new_key);
        END IF;
    END IF;
    RETURN NULL;
END
$m23$;

CREATE FUNCTION pgreact_internal.reconcile_temporal_key(target_version_id uuid, target_key bigint)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
<<temporal_key>>
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    spec pgreact_internal.temporal_rules%ROWTYPE;
    prior_state pgreact_internal.temporal_state%ROWTYPE;
    prior_activation pgreact_internal.activation_state%ROWTYPE;
    frontier timestamptz; candidate_count bigint; candidate_bindings jsonb;
    declared_deadline timestamptz; recovery_count bigint; recovery_true boolean := false;
    input_true boolean; new_active boolean; new_state text; new_continuous timestamptz;
    new_pending timestamptz; new_cooldown timestamptz; new_bindings jsonb;
    activation uuid; canonical bytea; digest bytea; lifecycle_event bigint;
    event_kind text; next_generation bigint; event_bindings jsonb;
BEGIN
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions WHERE rule_version_id = target_version_id;
    SELECT * INTO STRICT spec FROM pgreact_internal.temporal_rules WHERE rule_version_id = target_version_id;
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock FOR UPDATE;
    EXECUTE format(
        'SELECT count(*)::bigint, min(to_jsonb(v)::text)::jsonb FROM %s v WHERE (%I)::bigint = $1',
        version_row.match_relid::regclass, version_row.key_column)
        INTO candidate_count, candidate_bindings USING target_key;
    IF candidate_count > 1 THEN
        RAISE EXCEPTION 'M23_DUPLICATE_KEY: % contains multiple rows for semantic key %',
            version_row.source_view_name, target_key;
    END IF;
    IF spec.deadline_column IS NOT NULL AND candidate_count = 1 THEN
        EXECUTE format(
            'SELECT (to_jsonb(v) ->> %L)::timestamptz FROM %s v WHERE (%I)::bigint = $1',
            spec.deadline_column::text, version_row.match_relid::regclass, version_row.key_column)
            INTO declared_deadline USING target_key;
        IF declared_deadline IS NULL OR NOT isfinite(declared_deadline) THEN
            RAISE EXCEPTION 'M23_DEADLINE_VALUE: deadline must be finite and non-null for key %', target_key;
        END IF;
    END IF;
    input_true := candidate_count = 1;
    IF spec.recovery_condition_oid IS NOT NULL THEN
        EXECUTE format(
            'SELECT count(*)::bigint FROM %s v WHERE (to_jsonb(v) ->> %L)::bigint = $1',
            spec.recovery_condition_oid::regclass, spec.recovery_key_column::text)
            INTO recovery_count USING target_key;
        IF recovery_count > 1 THEN
            RAISE EXCEPTION 'M23_DUPLICATE_RECOVERY_KEY: recovery condition has multiple rows for key %', target_key;
        END IF;
        recovery_true := recovery_count = 1;
    END IF;
    SELECT * INTO prior_state FROM pgreact_internal.temporal_state
    WHERE rule_version_id = target_version_id AND semantic_key = target_key FOR UPDATE;
    IF NOT FOUND THEN
        INSERT INTO pgreact_internal.temporal_state (
            rule_version_id, semantic_key, state, last_frontier)
        VALUES (target_version_id, target_key, 'WAITING', frontier);
        SELECT * INTO prior_state FROM pgreact_internal.temporal_state
        WHERE rule_version_id = target_version_id AND semantic_key = target_key FOR UPDATE;
    END IF;
    new_active := prior_state.active;
    new_state := prior_state.state;
    new_continuous := prior_state.continuous_since;
    new_pending := prior_state.pending_deadline;
    new_cooldown := prior_state.cooldown_until;
    new_bindings := COALESCE(candidate_bindings, prior_state.last_bindings,
                             jsonb_build_object('semantic_key', target_key));

    IF spec.primitive = 'DURATION' THEN
        IF NOT input_true THEN
            new_active := false; new_state := 'WAITING';
            new_continuous := NULL; new_pending := NULL;
        ELSIF NOT isfinite(frontier) THEN
            new_active := false; new_state := 'WAITING';
        ELSIF new_continuous IS NULL THEN
            new_active := false; new_state := 'PENDING';
            new_continuous := frontier;
            new_pending := frontier + spec.duration_us * interval '1 microsecond';
        ELSIF prior_state.active THEN
            new_active := true; new_state := 'ACTIVE';
        ELSIF new_pending <= frontier THEN
            new_active := true; new_state := 'ACTIVE';
        ELSE
            new_active := false; new_state := 'PENDING';
        END IF;
    ELSIF spec.primitive = 'ABSENCE' THEN
        IF input_true THEN
            new_active := false; new_state := 'WAITING';
            new_pending := declared_deadline;
        ELSIF new_pending IS NULL THEN
            new_active := false; new_state := 'WAITING';
        ELSIF isfinite(frontier) AND frontier >= new_pending THEN
            new_active := true; new_state := 'ACTIVE';
        ELSE
            new_active := false; new_state := 'PENDING';
        END IF;
    ELSIF spec.primitive = 'COOLDOWN' THEN
        IF input_true THEN
            IF prior_state.active THEN
                new_active := true; new_state := 'ACTIVE';
            ELSIF new_cooldown IS NOT NULL AND (NOT isfinite(frontier) OR new_cooldown > frontier) THEN
                new_active := false; new_state := 'COOLDOWN';
            ELSIF isfinite(frontier) THEN
                new_active := true; new_state := 'ACTIVE'; new_cooldown := NULL;
            ELSE
                new_active := false; new_state := 'WAITING';
            END IF;
        ELSIF prior_state.active THEN
            new_active := false; new_state := 'COOLDOWN';
            new_cooldown := CASE WHEN isfinite(frontier)
                THEN frontier + spec.cooldown_us * interval '1 microsecond' ELSE NULL END;
        ELSIF new_cooldown IS NOT NULL AND (NOT isfinite(frontier) OR new_cooldown > frontier) THEN
            new_active := false; new_state := 'COOLDOWN';
        ELSE
            new_active := false; new_state := 'WAITING'; new_cooldown := NULL;
        END IF;
    ELSE
        IF prior_state.active AND recovery_true THEN
            new_active := false; new_state := 'RECOVERED';
        ELSIF prior_state.active THEN
            new_active := true; new_state := 'ACTIVE';
        ELSIF input_true AND isfinite(frontier) THEN
            new_active := true; new_state := 'ACTIVE';
        ELSIF recovery_true THEN
            new_active := false; new_state := 'RECOVERED';
        ELSE
            new_active := false; new_state := 'ARMED';
        END IF;
    END IF;

    IF new_active IS DISTINCT FROM prior_state.active AND isfinite(frontier) THEN
        canonical := pgreact_internal.canonical_bigint_v1(target_key);
        digest := pgreact_internal.activation_digest(target_version_id, canonical);
        activation := pgreact_internal.activation_uuid(digest);
        SELECT * INTO prior_activation FROM pgreact_internal.activation_state
        WHERE rule_version_id = target_version_id AND activation_id = activation FOR UPDATE;
        event_bindings := COALESCE(new_bindings, jsonb_build_object('semantic_key', target_key));
        IF new_active THEN
            next_generation := COALESCE(prior_activation.generation, 0) + 1;
            INSERT INTO pgreact_internal.activation_state (
                rule_version_id, activation_id, semantic_key, canonical_key,
                canonical_key_digest, key_codec_version, active, generation, revision,
                current_bindings, last_active_bindings, first_seen_at, last_seen_at)
            VALUES (target_version_id, activation, target_key, canonical, digest, 1, true,
                    next_generation, 0, event_bindings, event_bindings,
                    clock_timestamp(), clock_timestamp())
            ON CONFLICT (rule_version_id, activation_id) DO UPDATE SET
                active = true, generation = EXCLUDED.generation, revision = 0,
                current_bindings = EXCLUDED.current_bindings,
                last_active_bindings = EXCLUDED.last_active_bindings,
                last_seen_at = EXCLUDED.last_seen_at, deactivated_at = NULL;
            lifecycle_event := pgreact_internal.emit_event(
                version_row, activation, next_generation, 0, 'ACTIVATE', NULL, event_bindings);
            event_kind := 'ACTIVATE';
        ELSE
            next_generation := COALESCE(prior_activation.generation, 1);
            UPDATE pgreact_internal.activation_state
            SET active = false, current_bindings = NULL,
                deactivated_at = clock_timestamp(), last_seen_at = clock_timestamp()
            WHERE rule_version_id = target_version_id AND activation_id = activation;
            lifecycle_event := pgreact_internal.emit_event(
                version_row, activation, next_generation, 0, 'DEACTIVATE',
                COALESCE(prior_activation.last_active_bindings, event_bindings), NULL);
            event_kind := 'DEACTIVATE';
        END IF;
    ELSE
        next_generation := prior_state.generation;
    END IF;
    UPDATE pgreact_internal.temporal_state AS target
    SET state = temporal_key.new_state, active = temporal_key.new_active,
        input_true = temporal_key.input_true, recovery_true = temporal_key.recovery_true,
        continuous_since = temporal_key.new_continuous,
        pending_deadline = temporal_key.new_pending, cooldown_until = temporal_key.new_cooldown,
        generation = CASE WHEN temporal_key.lifecycle_event IS NULL
                          THEN target.generation ELSE temporal_key.next_generation END,
        last_frontier = temporal_key.frontier, last_bindings = temporal_key.new_bindings,
        updated_at = clock_timestamp()
    WHERE target.rule_version_id = target_version_id AND target.semantic_key = target_key;
    INSERT INTO pgreact_internal.temporal_history (
        rule_version_id, semantic_key, lifecycle_event_id, event_kind,
        primitive_state, input_true, recovery_true, continuous_since,
        pending_deadline, cooldown_until, clock_frontier, bindings)
    VALUES (target_version_id, target_key, lifecycle_event,
            COALESCE(event_kind, 'OBSERVE'), new_state, input_true, recovery_true,
            new_continuous, new_pending, new_cooldown, frontier, new_bindings);
    RETURN COALESCE(lifecycle_event, 0);
END
$m23$;

CREATE FUNCTION pgreact_internal.reconcile_temporal_rule(target_version_id uuid)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    spec pgreact_internal.temporal_rules%ROWTYPE; item record; statement text; changed bigint := 0;
BEGIN
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    SELECT * INTO STRICT spec FROM pgreact_internal.temporal_rules
    WHERE rule_version_id = target_version_id;
    statement := format(
        'SELECT (%1$I)::bigint AS semantic_key FROM %2$s WHERE %1$I IS NOT NULL '
        'UNION SELECT semantic_key FROM pgreact_internal.temporal_state WHERE rule_version_id = %3$L::uuid',
        version_row.key_column, version_row.match_relid::regclass, target_version_id::text);
    IF spec.recovery_condition_oid IS NOT NULL THEN
        statement := statement || format(
            ' UNION SELECT (to_jsonb(v) ->> %L)::bigint FROM %s v '
            'WHERE (to_jsonb(v) ->> %L) IS NOT NULL',
            spec.recovery_key_column::text, spec.recovery_condition_oid::regclass,
            spec.recovery_key_column::text);
    END IF;
    FOR item IN EXECUTE statement || ' ORDER BY 1' LOOP
        changed := changed + pgreact_internal.reconcile_temporal_key(
            target_version_id, item.semantic_key);
    END LOOP;
    RETURN changed;
END
$m23$;

CREATE FUNCTION pgreact_internal.reconcile_temporal_frontier()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE spec record; changed bigint := 0;
    max_keys integer;
    total_keys bigint;
BEGIN
    SELECT max_temporal_keys_per_pass INTO max_keys
    FROM pgreact_internal.operational_settings;
    SELECT count(*) INTO total_keys
    FROM pgreact_internal.temporal_state state
    JOIN pgreact_internal.temporal_rules temporal USING (rule_version_id)
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    WHERE version.state = 'ACTIVE';
    IF total_keys > max_keys THEN
        RAISE EXCEPTION 'M23_TEMPORAL_LIMIT: % temporal keys exceed max_temporal_keys_per_pass %',
            total_keys, max_keys;
    END IF;
    FOR spec IN
        SELECT rule_version_id FROM pgreact_internal.temporal_rules spec
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE version.state = 'ACTIVE' ORDER BY rule_version_id
    LOOP
        changed := changed + pgreact_internal.reconcile_temporal_rule(spec.rule_version_id);
    END LOOP;
    RETURN changed;
END
$m23$;

CREATE FUNCTION pgreact_api.temporal_preview(target_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
    SELECT jsonb_build_object(
        'contract_version', 11, 'mode', 'PREVIEW',
        'clock_frontier', (SELECT frontier FROM pgreact_internal.clock_frontier),
        'rules', COALESCE(jsonb_agg(jsonb_build_object(
            'rule', rule.rule_name, 'primitive', spec.primitive,
            'clock_domain', spec.clock_domain, 'states', COALESCE((
                SELECT jsonb_agg(to_jsonb(state) ORDER BY state.semantic_key)
                FROM pgreact_internal.temporal_state state
                WHERE state.rule_version_id = spec.rule_version_id), '[]'::jsonb))
            ORDER BY rule.rule_name), '[]'::jsonb))
    FROM pgreact_internal.temporal_rules spec
    JOIN pgreact_internal.rules rule ON rule.rule_id = (
        SELECT version.rule_id FROM pgreact_internal.rule_versions version
        WHERE version.rule_version_id = spec.rule_version_id)
    WHERE $1 IS NULL OR rule.rule_name = $1
$m23$;

CREATE FUNCTION pgreact_api.temporal_status(target_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
    SELECT pgreact_api.temporal_preview($1) || jsonb_build_object('mode', 'STATUS')
$m23$;

CREATE FUNCTION pgreact_api.temporal_history(target_name text)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'rule', rule.rule_name, 'semantic_key', history.semantic_key,
        'event_kind', history.event_kind, 'primitive_state', history.primitive_state,
        'input_true', history.input_true, 'recovery_true', history.recovery_true,
        'continuous_since', history.continuous_since,
        'pending_deadline', history.pending_deadline,
        'cooldown_until', history.cooldown_until,
        'clock_frontier', history.clock_frontier,
        'lifecycle_event_id', history.lifecycle_event_id,
        'bindings', history.bindings) ORDER BY history.temporal_event_id), '[]'::jsonb)
    FROM pgreact_internal.temporal_history history
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    JOIN pgreact_internal.rules rule USING (rule_id)
    WHERE rule.rule_name = $1
$m23$;

CREATE FUNCTION pgreact_api.temporal_explain(target_name text, target_key bigint)
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
    SELECT jsonb_build_object(
        'contract_version', 11, 'rule', rule.rule_name, 'semantic_key', $2,
        'declaration', jsonb_build_object('primitive', spec.primitive,
            'duration_us', spec.duration_us, 'deadline_column', spec.deadline_column,
            'cooldown_us', spec.cooldown_us, 'clock_domain', spec.clock_domain,
            'recovery_condition', spec.recovery_condition_name,
            'recovery_key_column', spec.recovery_key_column),
        'state', (SELECT to_jsonb(state) FROM pgreact_internal.temporal_state state
                  WHERE state.rule_version_id = spec.rule_version_id AND state.semantic_key = $2),
        'history', COALESCE((SELECT jsonb_agg(to_jsonb(history) ORDER BY history.temporal_event_id)
            FROM pgreact_internal.temporal_history history
            WHERE history.rule_version_id = spec.rule_version_id AND history.semantic_key = $2), '[]'::jsonb),
        'boundary', 'committed database-time frontier; consequence delivery remains asynchronous')
    FROM pgreact_internal.temporal_rules spec
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    JOIN pgreact_internal.rules rule USING (rule_id)
    WHERE rule.rule_name = $1
$m23$;

CREATE FUNCTION pgreact_api.temporal_doctor()
RETURNS jsonb
LANGUAGE SQL STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
    WITH diagnostics AS (
        SELECT jsonb_build_object('code', 'M23_EXTENSION_VERSION', 'severity', 'ERROR',
            'object_identity', 'pg_react', 'message', 'pg_react extension version is not 0.20.0',
            'hint', 'Install matching extension files and run ALTER EXTENSION pg_react UPDATE.') diagnostic
        WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension
                          WHERE extname = 'pg_react' AND extversion = '0.20.0')
        UNION ALL
        SELECT jsonb_build_object('code', 'M23_TEMPORAL_ORPHAN_STATE', 'severity', 'ERROR',
            'object_identity', state.rule_version_id::text,
            'message', 'temporal state has no active temporal declaration',
            'hint', 'Run temporal reconciliation or remove the incomplete declaration.')
        FROM pgreact_internal.temporal_state state
        LEFT JOIN pgreact_internal.temporal_rules spec USING (rule_version_id)
        WHERE spec.rule_version_id IS NULL
        UNION ALL
        SELECT jsonb_build_object('code', 'M23_TEMPORAL_BACKWARD_FRONTIER', 'severity', 'ERROR',
            'object_identity', 'clock_frontier',
            'message', 'temporal frontier is behind a recorded temporal observation',
            'hint', 'Restore the last complete clock frontier before advancing again.')
        WHERE EXISTS (SELECT 1 FROM pgreact_internal.temporal_state state
                      WHERE state.last_frontier > (SELECT frontier FROM pgreact_internal.clock_frontier))
    ), ordered AS (
        SELECT diagnostic FROM diagnostics
        ORDER BY CASE diagnostic ->> 'severity' WHEN 'ERROR' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END,
                 diagnostic ->> 'code', diagnostic ->> 'object_identity'
    )
    SELECT jsonb_build_object('contract_version', 11,
        'status', CASE WHEN EXISTS (SELECT 1 FROM ordered WHERE diagnostic ->> 'severity' = 'ERROR')
                       THEN 'attention' ELSE 'ready' END,
        'diagnostics', COALESCE((SELECT jsonb_agg(diagnostic) FROM ordered), '[]'::jsonb),
        'clock_domain', 'DATABASE_TIME', 'limits', jsonb_build_object(
            'max_temporal_keys_per_pass', (SELECT max_temporal_keys_per_pass
                                           FROM pgreact_internal.operational_settings)))
$m23$;

CREATE FUNCTION pgreact_api.reconcile_temporal_rule(target_name text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE version_id uuid; repaired bigint;
BEGIN
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.temporal_rules spec USING (rule_version_id)
    WHERE rule.rule_name = target_name AND version.state = 'ACTIVE';
    PERFORM pgreact.refresh_rule(version_id);
    SET CONSTRAINTS ALL IMMEDIATE;
    repaired := pgreact_internal.reconcile_temporal_rule(version_id);
    RETURN repaired;
END
$m23$;

CREATE FUNCTION pgreact_api.pause_temporal_rule(target_name text)
RETURNS void LANGUAGE SQL SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m23$
    SELECT pgreact.pause_rule((SELECT version.rule_version_id
        FROM pgreact_internal.rules rule JOIN pgreact_internal.rule_versions version USING (rule_id)
        JOIN pgreact_internal.temporal_rules spec USING (rule_version_id)
        WHERE rule.rule_name = $1 ORDER BY version.created_at DESC LIMIT 1))
$m23$;

CREATE FUNCTION pgreact_api.resume_temporal_rule(target_name text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.temporal_rules spec USING (rule_version_id)
    WHERE rule.rule_name = target_name AND version.state = 'PAUSED';
    PERFORM pgreact.resume_rule(version_id);
    PERFORM pgreact_internal.reconcile_temporal_rule(version_id);
END
$m23$;

CREATE FUNCTION pgreact_api.remove_temporal_rule(target_name text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.temporal_rules spec USING (rule_version_id)
    WHERE rule.rule_name = target_name AND version.state <> 'REMOVED'
    ORDER BY version.created_at DESC LIMIT 1;
    PERFORM pgreact.pause_rule(version_id);
    DELETE FROM pgreact_internal.temporal_history WHERE rule_version_id = version_id;
    DELETE FROM pgreact_internal.temporal_state WHERE rule_version_id = version_id;
    DELETE FROM pgreact_internal.temporal_rules WHERE rule_version_id = version_id;
    PERFORM pgreact.remove_rule(version_id);
END
$m23$;

ALTER FUNCTION pgreact_api.run(timestamptz) SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.run(timestamptz) RENAME TO run_m22;
CREATE FUNCTION pgreact_api.run(sampled_time timestamptz DEFAULT clock_timestamp())
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m23$
DECLARE result jsonb; temporal_changed bigint;
BEGIN
    result := pgreact_internal.run_m22(sampled_time);
    temporal_changed := pgreact_internal.reconcile_temporal_frontier();
    RETURN jsonb_set(result || jsonb_build_object('temporal_changed', temporal_changed),
        '{contract_version}', '11'::jsonb, true);
END
$m23$;

ALTER FUNCTION pgreact_api.doctor() SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.doctor() RENAME TO doctor_m22;
CREATE FUNCTION pgreact_api.doctor()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m23$
DECLARE result jsonb; diagnostics jsonb; temporal jsonb;
BEGIN
    result := pgreact_internal.doctor_m22();
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.ordinality), '[]'::jsonb)
    INTO diagnostics
    FROM jsonb_array_elements(COALESCE(result -> 'diagnostics', '[]'::jsonb))
         WITH ORDINALITY item
    WHERE item.value ->> 'code' NOT LIKE '%_EXTENSION_VERSION';
    temporal := pgreact_api.temporal_doctor();
    diagnostics := diagnostics || COALESCE(temporal -> 'diagnostics', '[]'::jsonb);
    RETURN jsonb_build_object('contract_version', 11,
        'status', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(diagnostics) item
                                    WHERE item ->> 'severity' = 'ERROR')
                       THEN 'attention' ELSE 'ready' END,
        'diagnostics', diagnostics);
END
$m23$;

ALTER FUNCTION pgreact_api.configure_roles(regrole, regrole, regrole, regrole, regrole)
    SET SCHEMA pgreact_internal;
ALTER FUNCTION pgreact_internal.configure_roles(regrole, regrole, regrole, regrole, regrole)
    RENAME TO configure_roles_m22;
CREATE FUNCTION pgreact_api.configure_roles(
    author_role regrole, operator_role regrole, worker_role regrole,
    reader_role regrole, advanced_reader_role regrole)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $m23$
BEGIN
    PERFORM pgreact_internal.configure_roles_m22(
        author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.validate_temporal_rule(regclass,name,text,interval,name,interval,regclass,name), '
        'pgreact_api.author_temporal_rule(text,regclass,name,text,interval,name,interval,regclass,name,regprocedure,integer,text,integer,integer,numeric,integer) TO %I', author_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.temporal_preview(text), pgreact_api.temporal_status(text), '
        'pgreact_api.temporal_history(text), pgreact_api.temporal_explain(text,bigint), pgreact_api.temporal_doctor() TO %I', reader_role::text);
    EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.temporal_preview(text), pgreact_api.temporal_status(text), '
        'pgreact_api.temporal_history(text), pgreact_api.temporal_explain(text,bigint), pgreact_api.temporal_doctor(), '
        'pgreact_api.reconcile_temporal_rule(text), pgreact_api.pause_temporal_rule(text), '
        'pgreact_api.resume_temporal_rule(text), pgreact_api.remove_temporal_rule(text) TO %I', operator_role::text);
END
$m23$;

REVOKE ALL ON ALL TABLES IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_internal FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgreact_api FROM PUBLIC;

DO $m23$
DECLARE author_role regrole; operator_role regrole; worker_role regrole;
    reader_role regrole; advanced_reader_role regrole;
BEGIN
    SELECT role_oid::regrole INTO author_role FROM pgreact_internal.application_roles WHERE role_kind = 'author';
    SELECT role_oid::regrole INTO operator_role FROM pgreact_internal.application_roles WHERE role_kind = 'operator';
    SELECT role_oid::regrole INTO worker_role FROM pgreact_internal.application_roles WHERE role_kind = 'worker';
    SELECT role_oid::regrole INTO reader_role FROM pgreact_internal.application_roles WHERE role_kind = 'reader';
    SELECT role_oid::regrole INTO advanced_reader_role FROM pgreact_internal.advanced_readers;
    IF author_role IS NOT NULL AND operator_role IS NOT NULL AND worker_role IS NOT NULL
       AND reader_role IS NOT NULL AND advanced_reader_role IS NOT NULL THEN
        PERFORM pgreact_api.configure_roles(
            author_role, operator_role, worker_role, reader_role, advanced_reader_role);
    END IF;
END
$m23$;

COMMENT ON EXTENSION pg_react IS
    'M23 practical database-time temporal conditions over the M22 provenance platform';
