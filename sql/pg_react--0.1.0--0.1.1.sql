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
