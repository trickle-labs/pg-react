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
