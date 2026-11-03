-- Preserve rule owners and temporal recovery-source identities after restore.
ALTER TABLE pgreact_internal.rules ADD COLUMN owner_name name;
UPDATE pgreact_internal.rules r
SET owner_name = p.rolname
FROM pg_catalog.pg_roles p
WHERE p.oid = r.owner_oid;
ALTER TABLE pgreact_internal.rules ALTER COLUMN owner_name SET NOT NULL;

ALTER TABLE pgreact_internal.temporal_rules
    ADD COLUMN recovery_condition_definition text,
    ADD COLUMN recovery_condition_signature bytea;
UPDATE pgreact_internal.temporal_rules spec
SET recovery_condition_name = pg_catalog.format('%I.%I', namespace.nspname, relation.relname),
    recovery_condition_definition = pg_catalog.pg_get_viewdef(relation.oid, true),
    recovery_condition_signature = pgreact_internal.source_row_signature(relation.oid)
FROM pg_catalog.pg_class relation
JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
WHERE relation.oid = spec.recovery_condition_oid
  AND spec.recovery_condition_oid IS NOT NULL
  AND relation.relkind IN ('v', 'm');
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.temporal_rules
        WHERE recovery_condition_oid IS NOT NULL
          AND (recovery_condition_name IS NULL OR recovery_condition_definition IS NULL
               OR recovery_condition_signature IS NULL)
    ) THEN
        RAISE EXCEPTION 'cannot upgrade: a temporal recovery condition is missing';
    END IF;
END
$$;
ALTER TABLE pgreact_internal.temporal_rules
    ADD CONSTRAINT temporal_recovery_identity_check CHECK (
        (recovery_condition_oid IS NULL AND recovery_condition_name IS NULL
         AND recovery_condition_definition IS NULL AND recovery_condition_signature IS NULL)
        OR (recovery_condition_oid IS NOT NULL AND recovery_condition_name IS NOT NULL
            AND recovery_condition_definition IS NOT NULL AND recovery_condition_signature IS NOT NULL)
    );

CREATE FUNCTION pgreact_internal.capture_temporal_recovery_identity()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE recovery_name text; recovery_definition text; recovery_signature bytea;
BEGIN
    IF NEW.recovery_condition_oid IS NOT NULL
       AND (NEW.recovery_condition_definition IS NULL
            OR NEW.recovery_condition_signature IS NULL) THEN
        SELECT pg_catalog.format('%I.%I', namespace.nspname, relation.relname),
               pg_catalog.pg_get_viewdef(relation.oid, true),
               pgreact_internal.source_row_signature(relation.oid)
        INTO recovery_name, recovery_definition, recovery_signature
        FROM pg_catalog.pg_class relation
        JOIN pg_catalog.pg_namespace namespace ON namespace.oid = relation.relnamespace
        WHERE relation.oid = NEW.recovery_condition_oid
          AND relation.relkind IN ('v', 'm');
        IF NOT FOUND THEN
            RAISE EXCEPTION 'M23_RECOVERY_SOURCE: recovery condition must be a view';
        END IF;
        NEW.recovery_condition_name := recovery_name;
        NEW.recovery_condition_definition := recovery_definition;
        NEW.recovery_condition_signature := recovery_signature;
    END IF;
    RETURN NEW;
END
$m23$;
REVOKE ALL ON FUNCTION pgreact_internal.capture_temporal_recovery_identity() FROM PUBLIC;
CREATE TRIGGER pgreact_capture_temporal_recovery_identity
BEFORE INSERT ON pgreact_internal.temporal_rules
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.capture_temporal_recovery_identity();

CREATE TABLE pgreact_internal.operational_settings_snapshot (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    settings jsonb NOT NULL
);
REVOKE ALL ON TABLE pgreact_internal.operational_settings_snapshot FROM PUBLIC;

CREATE FUNCTION pgreact_internal.snapshot_operational_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $snapshot$
BEGIN
    INSERT INTO pgreact_internal.operational_settings_snapshot AS saved (singleton, settings)
    VALUES (true, to_jsonb(NEW))
    ON CONFLICT (singleton) DO UPDATE
    SET settings = EXCLUDED.settings
    WHERE saved.settings IS DISTINCT FROM EXCLUDED.settings;
    RETURN NEW;
END
$snapshot$;
REVOKE ALL ON FUNCTION pgreact_internal.snapshot_operational_settings() FROM PUBLIC;

CREATE TRIGGER pgreact_snapshot_operational_settings
AFTER INSERT OR UPDATE ON pgreact_internal.operational_settings
FOR EACH ROW EXECUTE FUNCTION pgreact_internal.snapshot_operational_settings();

CREATE OR REPLACE FUNCTION pgreact_internal.register_reference_rule(
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

    INSERT INTO pgreact_internal.rules (rule_id, rule_name, owner_oid, owner_name)
    VALUES (rule_id, rule_name, installer_oid, session_user);
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

INSERT INTO pgreact_internal.operational_settings_snapshot (singleton, settings)
SELECT true, to_jsonb(settings) FROM pgreact_internal.operational_settings settings
WHERE settings.singleton;
-- 0.46.1: disambiguate claim sweep output and honor salience before FIFO within age bucket.
CREATE OR REPLACE FUNCTION pgreact.claim(
    worker_id text,
    max_items integer DEFAULT 1,
    lease_for interval DEFAULT interval '60 seconds',
    agenda_groups text[] DEFAULT NULL)
RETURNS TABLE(
    episode_id bigint, lease_token uuid, activation_id uuid, bindings jsonb,
    event_kind text, rule_version_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $v0433$
DECLARE
    candidate record;
    claimed record;
    version_id uuid;
    count_claimed integer := 0;
    claim_found boolean;
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
    IF seconds < 1 THEN
        RAISE EXCEPTION 'lease_for must be at least one second';
    END IF;
    FOR version_id IN
        SELECT version.rule_version_id
        FROM pgreact_internal.rule_versions AS version
        WHERE version.state IN ('ACTIVE', 'DRAINING')
        ORDER BY version.rule_version_id
    LOOP
        PERFORM pgreact.sweep_expired_leases(version_id);
    END LOOP;
    FOR candidate IN
        SELECT agenda.episode_id, agenda.rule_version_id
        FROM pgreact_internal.agenda agenda
        JOIN pgreact_internal.rule_versions version USING (rule_version_id)
        WHERE agenda.state IN ('PENDING', 'RETRY_WAIT')
          AND agenda.available_at <= clock_timestamp()
          AND version.state IN ('ACTIVE', 'DRAINING')
          AND NOT EXISTS (
              SELECT 1 FROM pgreact_internal.rule_barriers barrier
              WHERE barrier.rule_version_id = agenda.rule_version_id)
          AND (agenda_groups IS NULL OR agenda.agenda_group = ANY(agenda_groups))
        ORDER BY CASE WHEN agenda.available_at <= clock_timestamp() - fairness
                      THEN 0 ELSE 1 END,
                 agenda.salience DESC, agenda.available_at, agenda.episode_id
    LOOP
        claim_found := false;
        -- Roll back a rule-level claim that did not select this globally ordered episode.
        BEGIN
            SELECT * INTO claimed
            FROM pgreact.claim_episode(candidate.rule_version_id, worker_id, seconds);
            claim_found := FOUND;
            IF claim_found AND claimed.episode_id <> candidate.episode_id THEN
                RAISE EXCEPTION USING ERRCODE = 'PGR01',
                    MESSAGE = 'claim_episode returned an episode outside the global claim order';
            END IF;
        EXCEPTION WHEN SQLSTATE 'PGR01' THEN
            claim_found := false;
        END;
        IF claim_found THEN
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
$v0433$;
-- Rebind catalog OIDs and block stale consequence identities after restore.
CREATE OR REPLACE FUNCTION pgreact.rebuild_transient_metadata()
RETURNS TABLE(rebuilt_rules bigint, blocked_rules bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; rebuild_id bigint; source_oid oid; match_oid oid;
    binding pgreact_internal.consequence_bindings%ROWTYPE; resolved_function_oid oid; resolved_dispatcher_oid oid;
    resolved_consequence_oid oid; resolved_version_dispatcher_oid oid;
    rebuilt bigint := 0; blocked bigint := 0; valid boolean;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'only pgreact_admin may rebuild transient metadata'; END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rules r
        WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles p WHERE p.rolname = r.owner_name)
    ) THEN
        RAISE EXCEPTION 'cannot rebuild transient metadata: a stored rule owner is missing';
    END IF;
    UPDATE pgreact_internal.rules r
    SET owner_oid = p.oid
    FROM pg_catalog.pg_roles p
    WHERE p.rolname = r.owner_name;
    UPDATE pgreact_internal.rule_versions v
    SET owner_oid = p.oid
    FROM pgreact_internal.rules r
    JOIN pg_catalog.pg_roles p ON p.rolname = r.owner_name
    WHERE r.rule_id = v.rule_id;
    INSERT INTO pgreact_internal.metadata_rebuild_audits (status) VALUES ('RUNNING') RETURNING metadata_rebuild_id INTO rebuild_id;
    FOR version_row IN SELECT * FROM pgreact_internal.rule_versions WHERE state <> 'REMOVED' FOR UPDATE LOOP
        source_oid := to_regclass(version_row.source_view_name);
        match_oid := to_regclass(version_row.match_name);
        valid := source_oid IS NOT NULL AND match_oid IS NOT NULL
            AND pg_get_viewdef(source_oid, true) = version_row.source_definition
            AND EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                        WHERE c.oid = source_oid AND c.relowner = version_row.owner_oid)
            AND pgreact_internal.source_row_signature(source_oid) = version_row.source_row_signature;
        resolved_consequence_oid := CASE WHEN version_row.consequence_identity IS NULL THEN NULL
            ELSE to_regprocedure(version_row.consequence_identity) END;
        resolved_version_dispatcher_oid := CASE WHEN version_row.dispatcher_identity IS NULL THEN NULL
            ELSE to_regprocedure(version_row.dispatcher_identity) END;
        valid := valid
            AND ((version_row.consequence_identity IS NULL AND version_row.consequence_oid IS NULL)
                 OR (resolved_consequence_oid IS NOT NULL
                     AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                 WHERE p.oid = resolved_consequence_oid AND p.proowner = version_row.owner_oid)
                     AND sha256(convert_to(pg_get_functiondef(resolved_consequence_oid), 'UTF8')) = version_row.consequence_digest))
            AND ((version_row.dispatcher_identity IS NULL AND version_row.dispatcher_oid IS NULL)
                 OR (resolved_version_dispatcher_oid IS NOT NULL
                     AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                 WHERE p.oid = resolved_version_dispatcher_oid AND p.proowner = version_row.owner_oid)
                     AND sha256(convert_to(pg_get_functiondef(resolved_version_dispatcher_oid), 'UTF8')) = version_row.dispatcher_digest));
        FOR binding IN SELECT * FROM pgreact_internal.consequence_bindings WHERE rule_version_id = version_row.rule_version_id LOOP
            resolved_function_oid := to_regprocedure(binding.function_identity);
            resolved_dispatcher_oid := CASE WHEN binding.dispatcher_identity IS NULL THEN NULL ELSE to_regprocedure(binding.dispatcher_identity) END;
            valid := valid AND resolved_function_oid IS NOT NULL
                AND sha256(convert_to(pg_get_functiondef(resolved_function_oid), 'UTF8')) = binding.function_digest
                AND (binding.consequence_kind <> 'DATABASE_TYPED' OR EXISTS (
                    SELECT 1 FROM pg_catalog.pg_proc p
                    WHERE p.oid = resolved_function_oid AND p.proowner = version_row.owner_oid))
                AND ((binding.dispatcher_identity IS NULL AND binding.dispatcher_oid IS NULL)
                     OR (resolved_dispatcher_oid IS NOT NULL
                         AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                     WHERE p.oid = resolved_dispatcher_oid AND p.proowner = version_row.owner_oid)
                         AND sha256(convert_to(pg_get_functiondef(resolved_dispatcher_oid), 'UTF8')) = binding.dispatcher_digest));
            IF valid THEN
                UPDATE pgreact_internal.consequence_bindings SET function_oid = resolved_function_oid, dispatcher_oid = resolved_dispatcher_oid
                WHERE rule_version_id = binding.rule_version_id AND event_kind = binding.event_kind;
            END IF;
        END LOOP;
        IF valid THEN
            UPDATE pgreact_internal.rule_versions
            SET source_view_oid = source_oid, match_relid = match_oid,
                consequence_oid = resolved_consequence_oid,
                dispatcher_oid = resolved_version_dispatcher_oid
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
-- Grant managed-worker access only to React-generated stream tables.
-- Grant managed-worker access only to React-generated stream tables.
CREATE OR REPLACE FUNCTION pgreact_internal.m54_sync_grants(old_roles oid[] DEFAULT ARRAY[]::oid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    author_oid oid;
    operator_oid oid;
    reader_oid oid;
    worker_oid oid;
    role_oid oid;
    stream_row record;
BEGIN
    SELECT application_role.role_oid INTO author_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'author';
    SELECT application_role.role_oid INTO operator_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'operator';
    SELECT application_role.role_oid INTO reader_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'reader';
    SELECT application_role.role_oid INTO worker_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'worker';
    FOREACH role_oid IN ARRAY COALESCE(old_roles, ARRAY[]::oid[]) LOOP
        CONTINUE WHEN role_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE oid = role_oid);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION pgreact_api.managed_cycle() FROM %I', role_oid::regrole::text);
        EXECUTE format('REVOKE ALL ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) FROM %I', role_oid::regrole::text);
        FOR stream_row IN
            SELECT DISTINCT pg_catalog.to_regclass(version.match_name) AS relation
            FROM pgreact_internal.rule_versions AS version
            WHERE pg_catalog.to_regclass(version.match_name) IS NOT NULL
        LOOP
            EXECUTE format('REVOKE MAINTAIN ON TABLE %s FROM %I',
                           stream_row.relation, role_oid::regrole::text);
        END LOOP;
    END LOOP;
    IF worker_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.managed_cycle() TO %I', worker_oid::regrole::text);
        FOR stream_row IN
            SELECT DISTINCT pg_catalog.to_regclass(version.match_name) AS relation
            FROM pgreact_internal.rule_versions AS version
            WHERE pg_catalog.to_regclass(version.match_name) IS NOT NULL
        LOOP
            EXECUTE format('GRANT MAINTAIN ON TABLE %s TO %I',
                           stream_row.relation, worker_oid::regrole::text);
        END LOOP;
    END IF;
    IF author_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.validate(pgreact_api.declaration), pgreact.preview(pgreact_api.declaration,jsonb), pgreact.deploy(pgreact_api.declaration,jsonb), pgreact.export(text,text,text) TO %I', author_oid::regrole::text);
    END IF;
    IF reader_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.validate(pgreact_api.declaration), pgreact.export(text,text,text) TO %I', reader_oid::regrole::text);
    END IF;
    IF operator_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) TO %I', operator_oid::regrole::text);
    END IF;
    FOREACH role_oid IN ARRAY ARRAY[author_oid, operator_oid, reader_oid] LOOP
        CONTINUE WHEN role_oid IS NULL;
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact.compare_results(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact_internal.m54_read_rule_model(name,name,name,text,boolean,integer), pgreact_internal.m54_read_decision_model(name,name,name,name,name,name[],integer,text,integer), pgreact_internal.m54_decision_result(jsonb,name[]) TO %I', role_oid::regrole::text);
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_internal.m34_authoritative_checksum(), pgreact_internal.m34_delta(jsonb,jsonb), pgreact_internal.m34_raw_rows(jsonb,bigint,integer), pgreact_internal.m34_finding(text,text,text,text,text,text,jsonb) TO %I', role_oid::regrole::text);
    END LOOP;
END
$m54$;

-- Repair an already configured predecessor without changing its role mapping.
DO $maintenance$
BEGIN
    PERFORM pgreact_internal.m54_sync_grants();
END
$maintenance$;

-- Keep each generated stream owned by its author while delegating refresh
-- only to the currently configured managed worker.
CREATE OR REPLACE FUNCTION pgreact_internal.create_m0_stream(name text, query text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m0$
DECLARE
    worker_oid oid;
    stream_relation regclass;
BEGIN
    PERFORM pgreact_internal.assert_m0_compatibility();
    PERFORM pgtrickle.create_stream_table(
        name => create_m0_stream.name,
        query => create_m0_stream.query,
        schedule => '1h',
        refresh_mode => 'DIFFERENTIAL',
        initialize => true
    );

    SELECT application_role.role_oid INTO worker_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'worker';
    IF worker_oid IS NOT NULL THEN
        stream_relation := pg_catalog.to_regclass(name);
        EXECUTE format('GRANT MAINTAIN ON TABLE %s TO %I',
                       stream_relation, worker_oid::regrole::text);
    END IF;
END
$m0$;
-- Exact pg_trickle 0.108.0, MDM-pinned 0.108.3, and candidate 0.108.4 compatibility profiles.
--
-- Assumption: integration_capabilities() is a public zero-argument set-returning
-- function whose rows expose capability/name, major(_version), minor(_version),
-- enabled, and optionally status. JSON conversion keeps this boundary independent
-- of the upstream composite type while still rejecting malformed contracts.

CREATE OR REPLACE FUNCTION pgreact_internal.pgtrickle_capability_report(rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
DECLARE row_data jsonb;
    capability_name text;
    major_text text;
    minor_text text;
    major_version integer;
    minor_version integer;
    enabled boolean;
    status text;
    seen text[] := ARRAY[]::text[];
    capabilities jsonb := '{}'::jsonb;
BEGIN
    IF jsonb_typeof(rows) <> 'array' THEN
        RAISE EXCEPTION 'pg-react pg_trickle capability contract must be an array';
    END IF;

    FOR row_data IN SELECT value FROM jsonb_array_elements(rows) LOOP
        IF jsonb_typeof(row_data) <> 'object' THEN
            RAISE EXCEPTION 'pg-react pg_trickle capability row must be an object: %', row_data;
        END IF;
        capability_name := NULLIF(COALESCE(row_data ->> 'capability', row_data ->> 'name'), '');
        major_text := COALESCE(row_data ->> 'major', row_data ->> 'major_version');
        minor_text := COALESCE(row_data ->> 'minor', row_data ->> 'minor_version');
        IF capability_name IS NULL OR major_text IS NULL OR minor_text IS NULL
           OR jsonb_typeof(row_data -> 'enabled') <> 'boolean'
           OR major_text !~ '^[0-9]+$' OR minor_text !~ '^[0-9]+$' THEN
            RAISE EXCEPTION 'pg-react pg_trickle capability row is malformed: %', row_data;
        END IF;
        BEGIN
            major_version := major_text::integer;
            minor_version := minor_text::integer;
        EXCEPTION WHEN numeric_value_out_of_range THEN
            RAISE EXCEPTION 'pg-react pg_trickle capability version is out of range: %', row_data;
        END;
        IF row_data ? 'status' AND jsonb_typeof(row_data -> 'status') <> 'string' THEN
            RAISE EXCEPTION 'pg-react pg_trickle capability status is malformed: %', row_data;
        END IF;
        IF capability_name = ANY(seen) THEN
            RAISE EXCEPTION 'pg-react pg_trickle capability is duplicated: %', capability_name;
        END IF;
        seen := array_append(seen, capability_name);
        enabled := (row_data ->> 'enabled')::boolean;
        status := COALESCE(row_data ->> 'status', row_data -> 'details' ->> 'status',
                           CASE WHEN enabled THEN 'enabled' ELSE 'disabled' END);
        capabilities := capabilities || jsonb_build_object(
            capability_name,
            jsonb_build_object(
                'major', major_version,
                'minor', minor_version,
                'enabled', enabled,
                'status', status,
                'raw', row_data));
    END LOOP;
    RETURN capabilities;
END
$pgtrickle$;

CREATE OR REPLACE FUNCTION pgreact_internal.pgtrickle_integration_status()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
DECLARE installed_version text;
    rows jsonb;
    capabilities jsonb;
    graph jsonb;
    delta jsonb;
    package_qualified boolean;
    capability_qualified boolean;
BEGIN
    SELECT extversion INTO installed_version
    FROM pg_extension WHERE extname = 'pg_trickle';
    IF installed_version IS NULL THEN
        RAISE EXCEPTION 'pg-react requires the pg_trickle extension';
    END IF;

    -- Call only the public API; private pg_trickle catalogs are deliberately out of scope.
    SELECT COALESCE(jsonb_agg(to_jsonb(capability_row)), '[]'::jsonb)
    INTO rows
    FROM pgtrickle.integration_capabilities() AS capability_row;
    capabilities := pgreact_internal.pgtrickle_capability_report(rows);
    graph := capabilities -> 'external_graph_refresh';
    delta := capabilities -> 'output_delta_consumer';
    package_qualified := installed_version IN ('0.108.0', '0.108.3', '0.108.4')
        AND current_setting('transaction_isolation') = 'read committed'
        AND COALESCE(current_setting('pg_trickle.enabled', true), '') = 'off'
        AND COALESCE(current_setting('pg_trickle.cdc_mode', true), '') = 'trigger'
        AND COALESCE(current_setting('pg_trickle.differential_max_change_ratio', true), '0')::numeric = 1.0;
    capability_qualified := graph IS NOT NULL
        AND (graph ->> 'major')::integer = 1
        AND (graph ->> 'minor')::integer = 2
        AND (graph ->> 'enabled')::boolean
        AND graph ->> 'status' = 'stable'
        AND (delta IS NULL OR (
            (delta ->> 'major')::integer = 1
            AND (delta ->> 'minor')::integer = 1
            AND delta ->> 'status' = 'stable'));
    RETURN jsonb_build_object(
        'extension_version', installed_version,
        'package_qualified', package_qualified,
        'capabilities_qualified', capability_qualified,
        'qualified', package_qualified AND capability_qualified,
        'coordination_mode', CASE
            WHEN graph IS NULL OR (graph ->> 'major')::integer <> 1 THEN 'UNSUPPORTED'
            WHEN (graph ->> 'enabled')::boolean
                AND graph ->> 'status' = 'stable' THEN 'LEGACY_EXPLICIT'
            ELSE 'GRAPH_V1_REQUIRED'
        END,
        'graph_v1_used', false,
        'delta_v1_used', false,
        'scheduler_expected', 'off',
        'cdc_expected', 'trigger',
        'capabilities', capabilities);
END
$pgtrickle$;

CREATE OR REPLACE FUNCTION pgreact_internal.require_pgtrickle_runtime()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
DECLARE status jsonb := pgreact_internal.pgtrickle_integration_status();
BEGIN
    IF NOT COALESCE((status ->> 'qualified')::boolean, false) THEN
        RAISE EXCEPTION 'pg-react pg_trickle runtime is unsupported: %', status
            USING HINT = 'Use qualified pg_trickle 0.108.0, 0.108.3, or 0.108.4 with scheduler off, trigger CDC, differential ratio 1.0, READ COMMITTED, and stable enabled Graph V1.2.';
    END IF;
END
$pgtrickle$;

COMMENT ON FUNCTION pgreact_internal.pgtrickle_integration_status() IS
    'Public pg_trickle 0.108.0/0.108.3/0.108.4 capability report; stable enabled Graph V1.2 is admitted without changing React coordination.';

CREATE OR REPLACE FUNCTION pgreact_internal.assert_m0_compatibility()
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
BEGIN
    PERFORM pgreact_internal.require_pgtrickle_runtime();
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'pg-react 0.46.0 requires READ COMMITTED';
    END IF;
END
$pgtrickle$;

CREATE OR REPLACE FUNCTION pgreact_internal.pgtrickle_health_findings()
RETURNS SETOF jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
DECLARE status jsonb;
    graph jsonb;
    delta jsonb;
BEGIN
    BEGIN
        status := pgreact_internal.pgtrickle_integration_status();
    EXCEPTION WHEN OTHERS THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_CAPABILITY_DISCOVERY_FAILED', 'severity', 'ERROR',
            'object_identity', 'pg_trickle',
            'message', 'pg-react could not read pg_trickle.integration_capabilities()',
            'hint', 'Install qualified pg_trickle 0.108.0, 0.108.3, or 0.108.4 and verify its public capability API.',
            'details', jsonb_build_object('sqlstate', SQLSTATE, 'error', SQLERRM));
        RETURN;
    END;

    graph := status -> 'capabilities' -> 'external_graph_refresh';
    delta := status -> 'capabilities' -> 'output_delta_consumer';
    IF (status ->> 'extension_version') NOT IN ('0.108.0', '0.108.3', '0.108.4') THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_RUNTIME_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'pg_trickle',
            'message', format('installed pg_trickle version is %s; pg-react requires qualified 0.108.0, 0.108.3, or 0.108.4',
                              COALESCE(status ->> 'extension_version', '<missing>')),
            'hint', 'Use qualified pg_trickle 0.108.0, 0.108.3, or 0.108.4 before resuming pg-react coordination.',
            'installed_version', status ->> 'extension_version',
            'expected_version', '0.108.0, 0.108.3, or 0.108.4',
            'coordination_mode', status ->> 'coordination_mode');
    END IF;
    IF COALESCE(current_setting('pg_trickle.enabled', true), '') <> 'off' THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_SCHEDULER_ENABLED', 'severity', 'ERROR',
            'object_identity', 'pg_trickle.enabled',
            'message', 'pg_trickle automatic scheduling is enabled',
            'hint', 'Set pg_trickle.enabled=off so pg-react owns the explicit refresh boundary.');
    END IF;
    IF COALESCE(current_setting('pg_trickle.cdc_mode', true), '') <> 'trigger' THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_CDC_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'pg_trickle.cdc_mode',
            'message', 'pg_trickle is not using stable trigger capture',
            'hint', 'Set pg_trickle.cdc_mode=trigger and restart PostgreSQL.');
    END IF;
    IF COALESCE(current_setting('pg_trickle.differential_max_change_ratio', true), '0')::numeric <> 1.0 THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_ADAPTIVE_FULL_REFRESH', 'severity', 'ERROR',
            'object_identity', 'pg_trickle.differential_max_change_ratio',
            'message', 'pg_trickle may fall back to FULL refresh and suppress CDC triggers',
            'hint', 'Set pg_trickle.differential_max_change_ratio=1.0 for coordinated differential refresh.');
    END IF;
    IF graph IS NULL OR (graph ->> 'major')::integer <> 1
       OR (graph ->> 'minor')::integer <> 2
       OR graph ->> 'status' IS DISTINCT FROM 'stable' THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_CAPABILITY_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'external_graph_refresh',
            'message', 'the discovered stable Graph V1.2 capability is missing or unsupported',
            'hint', 'Use qualified pg_trickle 0.108.0, 0.108.3, or 0.108.4 with stable external_graph_refresh 1.2.',
            'capability', 'external_graph_refresh',
            'major', graph ->> 'major', 'minor', graph ->> 'minor',
            'enabled', graph -> 'enabled', 'status', graph ->> 'status');
    ELSIF NOT (graph ->> 'enabled')::boolean THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_GRAPH_DISABLED', 'severity', 'ERROR',
            'object_identity', 'external_graph_refresh',
            'message', 'Graph V1.2 is disabled but the optional stewardship adapter requires it',
            'hint', 'Enable stable external_graph_refresh 1.2 before enabling adapter effects.',
            'capability', 'external_graph_refresh', 'major', graph ->> 'major',
            'minor', graph ->> 'minor', 'enabled', graph -> 'enabled',
            'status', graph ->> 'status');
    ELSE
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_GRAPH_AVAILABLE', 'severity', 'INFO',
            'object_identity', 'external_graph_refresh',
            'message', 'Graph V1.2 is available upstream; pg-react retains explicit coordination',
            'hint', 'No action is required; pg-react does not call Graph V1.2.',
            'capability', 'external_graph_refresh', 'major', graph ->> 'major',
            'minor', graph ->> 'minor', 'enabled', graph -> 'enabled',
            'status', graph ->> 'status');
    END IF;
    IF delta IS NOT NULL AND ((delta ->> 'major')::integer <> 1
       OR (delta ->> 'minor')::integer <> 1
       OR delta ->> 'status' IS DISTINCT FROM 'stable') THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_CAPABILITY_UNSUPPORTED', 'severity', 'ERROR',
            'object_identity', 'output_delta_consumer',
            'message', 'the discovered Delta V1.1 capability is unsupported',
            'hint', 'Use qualified pg_trickle 0.108.0, 0.108.3, or 0.108.4 with stable output_delta_consumer 1.1.',
            'capability', 'output_delta_consumer',
            'major', delta ->> 'major', 'minor', delta ->> 'minor',
            'enabled', delta -> 'enabled', 'status', delta ->> 'status');
    ELSIF delta IS NULL THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_DELTA_UNAVAILABLE', 'severity', 'INFO',
            'object_identity', 'output_delta_consumer',
            'message', 'Delta V1.1 is unavailable; pg-react does not consume output deltas',
            'hint', 'No action is required for the explicit pg-react path.');
    ELSIF (delta ->> 'enabled')::boolean THEN
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_DELTA_AVAILABLE', 'severity', 'INFO',
            'object_identity', 'output_delta_consumer',
            'message', 'Delta V1.1 is available upstream; pg-react does not consume output deltas',
            'hint', 'No action is required; pg-react retains explicit coordination.',
            'capability', 'output_delta_consumer', 'major', delta ->> 'major',
            'minor', delta ->> 'minor', 'enabled', delta -> 'enabled',
            'status', delta ->> 'status');
    ELSE
        RETURN NEXT jsonb_build_object(
            'code', 'PGT_DELTA_DISABLED', 'severity', 'INFO',
            'object_identity', 'output_delta_consumer',
            'message', 'Delta V1.1 is present but disabled; pg-react does not consume output deltas',
            'hint', 'No action is required for the explicit pg-react path.',
            'capability', 'output_delta_consumer', 'major', delta ->> 'major',
            'minor', delta ->> 'minor', 'enabled', delta -> 'enabled',
            'status', delta ->> 'status');
    END IF;
END
$pgtrickle$;

DO $pgtrickle_compat$
BEGIN
    IF to_regprocedure('pgreact.health_check()') IS NOT NULL
       AND to_regprocedure('pgreact.health_check_m44()') IS NULL THEN
        EXECUTE 'ALTER FUNCTION pgreact.health_check() RENAME TO health_check_m44';
    END IF;
END
$pgtrickle_compat$;

CREATE OR REPLACE FUNCTION pgreact.health_check()
RETURNS TABLE(code text, severity text, object_identity text, message text, hint text)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
    SELECT code, severity, object_identity, message, hint
    FROM pgreact.health_check_m44()
    UNION ALL
    SELECT finding ->> 'code', finding ->> 'severity', finding ->> 'object_identity',
           finding ->> 'message', finding ->> 'hint'
    FROM pgreact_internal.pgtrickle_health_findings() finding
$pgtrickle$;

DO $pgtrickle_compat$
BEGIN
    IF to_regprocedure('pgreact_api.doctor()') IS NOT NULL
       AND to_regprocedure('pgreact_api.doctor_m44()') IS NULL THEN
        EXECUTE 'ALTER FUNCTION pgreact_api.doctor() RENAME TO doctor_m44';
    END IF;
END
$pgtrickle_compat$;

CREATE OR REPLACE FUNCTION pgreact_api.doctor()
RETURNS jsonb
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
    WITH base AS (SELECT pgreact_api.doctor_m44() AS value),
    diagnostics AS (
        SELECT diagnostic
        FROM base, jsonb_array_elements(base.value -> 'diagnostics') diagnostic
        WHERE diagnostic ->> 'code' NOT LIKE '%TRICKLE%'
          AND diagnostic ->> 'code' NOT LIKE 'PGT_%'
    ), combined AS (
        SELECT diagnostic FROM diagnostics
        UNION ALL
        SELECT finding FROM pgreact_internal.pgtrickle_health_findings() finding
    )
    SELECT base.value || jsonb_build_object(
        'diagnostics', COALESCE((SELECT jsonb_agg(diagnostic ORDER BY diagnostic ->> 'code',
                                                                    diagnostic ->> 'object_identity')
                                FROM combined), '[]'::jsonb),
        'status', CASE WHEN EXISTS (
            SELECT 1 FROM combined WHERE diagnostic ->> 'severity' = 'ERROR')
            THEN 'attention' ELSE 'ready' END)
    FROM base
$pgtrickle$;

DO $pgtrickle_compat$
BEGIN
    IF to_regprocedure('pgreact_internal.managed_cycle(integer)') IS NOT NULL
       AND to_regprocedure('pgreact_internal.managed_cycle_m44(integer)') IS NULL THEN
        EXECUTE 'ALTER FUNCTION pgreact_internal.managed_cycle(integer) RENAME TO managed_cycle_m44';
    END IF;
END
$pgtrickle_compat$;

CREATE OR REPLACE FUNCTION pgreact_internal.managed_cycle(process_pid integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $pgtrickle$
DECLARE worker text := format('pg-react-managed/%s/%s', current_database(), process_pid);
    pending bigint;
    status jsonb;
    adapter_ready boolean;
BEGIN
    SELECT count(*) INTO pending
    FROM pgreact_internal.agenda job
    WHERE job.state IN ('PENDING', 'LEASED', 'RETRY_WAIT');
    BEGIN
        status := pgreact_internal.pgtrickle_integration_status();
    EXCEPTION WHEN OTHERS THEN
        status := jsonb_build_object(
            'qualified', false, 'extension_version',
            (SELECT extversion FROM pg_extension WHERE extname = 'pg_trickle'),
            'error_code', 'PGT_CAPABILITY_DISCOVERY_FAILED',
            'error', SQLSTATE || ': ' || SQLERRM);
    END;
    IF NOT COALESCE((status ->> 'qualified')::boolean, false) THEN
        INSERT INTO pgreact_internal.managed_processes (
            database_oid, database_name, backend_pid, state, protocol, pending_jobs, detail)
        VALUES ((SELECT oid FROM pg_database WHERE datname = current_database()),
                current_database(), process_pid, 'error', 2, pending,
                'pg_trickle compatibility blocked: ' || status::text)
        ON CONFLICT (database_oid) DO UPDATE
        SET backend_pid = EXCLUDED.backend_pid, state = 'error', protocol = EXCLUDED.protocol,
            pending_jobs = EXCLUDED.pending_jobs, heartbeat_at = clock_timestamp(),
            detail = EXCLUDED.detail;
        RETURN jsonb_build_object(
            'state', 'blocked', 'pending_jobs', pending, 'processed_jobs', 0,
            'compatibility', status);
    END IF;
    IF to_regclass('pgreact_mdm.policy_intent_bindings') IS NOT NULL THEN
        IF to_regprocedure('pgreact_mdm.policy_runtime_ready()') IS NULL THEN
            EXECUTE 'SELECT NOT EXISTS (SELECT 1 FROM pgreact_mdm.policy_intent_bindings WHERE enabled)'
                INTO adapter_ready;
        ELSE
            EXECUTE 'SELECT pgreact_mdm.policy_runtime_ready()' INTO adapter_ready;
        END IF;
        IF NOT COALESCE(adapter_ready, false) THEN
            INSERT INTO pgreact_internal.managed_processes (
                database_oid, database_name, backend_pid, state, protocol, pending_jobs, detail)
            VALUES ((SELECT oid FROM pg_database WHERE datname = current_database()),
                    current_database(), process_pid, 'error', 2, pending,
                    'MDM activation required')
            ON CONFLICT (database_oid) DO UPDATE
            SET backend_pid = EXCLUDED.backend_pid, state = 'error', protocol = EXCLUDED.protocol,
                pending_jobs = EXCLUDED.pending_jobs, heartbeat_at = clock_timestamp(),
                detail = EXCLUDED.detail;
            RETURN jsonb_build_object('state', 'blocked', 'pending_jobs', pending,
                                      'processed_jobs', 0, 'reason', 'MDM activation required');
        END IF;
    END IF;
    IF NOT pg_is_in_recovery()
       AND to_regprocedure('pgreact_mdm.sync_intent_case_identities()') IS NOT NULL THEN
        -- Enroll MDM-owned occurrences before the existing refresh/time frontier.
        PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
        EXECUTE 'SELECT pgreact_mdm.sync_intent_case_identities()';
    END IF;
    RETURN pgreact_internal.managed_cycle_m44(process_pid);
END
$pgtrickle$;
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
    IF EXISTS (SELECT 1 FROM pgreact_internal.operational_settings_snapshot WHERE singleton) THEN
        DELETE FROM pgreact_internal.operational_settings WHERE singleton;
        INSERT INTO pgreact_internal.operational_settings
        SELECT (pg_catalog.jsonb_populate_record(
            NULL::pgreact_internal.operational_settings, snapshot.settings)).*
        FROM pgreact_internal.operational_settings_snapshot snapshot
        WHERE snapshot.singleton;
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pgreact_internal.temporal_rules spec
        LEFT JOIN pg_catalog.pg_class relation
          ON relation.oid = pg_catalog.to_regclass(spec.recovery_condition_name)
        WHERE spec.recovery_condition_oid IS NOT NULL
          AND (relation.oid IS NULL OR relation.relkind NOT IN ('v', 'm')
               OR CASE WHEN relation.relkind IN ('v', 'm')
                       THEN pg_catalog.pg_get_viewdef(relation.oid, true) END
                    IS DISTINCT FROM spec.recovery_condition_definition
               OR pgreact_internal.source_row_signature(relation.oid)
                    IS DISTINCT FROM spec.recovery_condition_signature)
    ) THEN
        RAISE EXCEPTION 'cannot prepare recovery: a temporal recovery condition is missing or changed';
    END IF;
    UPDATE pgreact_internal.temporal_rules spec
    SET recovery_condition_oid = pg_catalog.to_regclass(spec.recovery_condition_name)
    WHERE spec.recovery_condition_oid IS NOT NULL;
    -- Rebuild the seeded frontier from the clock log after logical restore.
    UPDATE pgreact_internal.clock_frontier AS frontier
    SET frontier = GREATEST(frontier.frontier, history.frontier),
        last_sampled_time = CASE WHEN history.frontier >= frontier.frontier
                                 THEN history.sampled_time ELSE frontier.last_sampled_time END,
        last_advanced_at = CASE WHEN history.frontier >= frontier.frontier
                                THEN history.advanced_at ELSE frontier.last_advanced_at END
    FROM (
        SELECT sampled_time, frontier, advanced_at
        FROM pgreact_internal.clock_history
        ORDER BY clock_event_id DESC
        LIMIT 1
    ) AS history
    WHERE frontier.singleton;
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

-- Preserve the rule ledger and pending work in logical database dumps.
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.rules', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.rule_versions', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.activation_state', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.agenda_group_limits', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.operational_settings_snapshot', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.lifecycle_events', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.agenda', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.executions', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.rule_barriers', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.consequence_bindings', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.metadata_rebuild_audits', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.deadline_rules', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.deadline_lifecycle', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.temporal_rules', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.temporal_state', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.temporal_history', '');
SELECT pg_catalog.pg_extension_config_dump('pgreact_internal.clock_history', '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('pgreact_internal.lifecycle_events', 'event_id')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('pgreact_internal.agenda', 'episode_id')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('pgreact_internal.executions', 'execution_id')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('pgreact_internal.metadata_rebuild_audits', 'metadata_rebuild_id')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('pgreact_internal.clock_history', 'clock_event_id')::regclass, '');
SELECT pg_catalog.pg_extension_config_dump(
    pg_catalog.pg_get_serial_sequence('pgreact_internal.temporal_history', 'temporal_event_id')::regclass, '');

-- Preserve supplied timestamps when logical restore loads extension config rows.
CREATE OR REPLACE FUNCTION pgreact_internal.agenda_state_timestamp()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $v0433$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.state_changed_at := COALESCE(NEW.state_changed_at, clock_timestamp());
    ELSIF ROW(NEW.state, NEW.available_at, NEW.lease_token, NEW.worker_id,
              NEW.claimed_at, NEW.lease_expires_at, NEW.completed_at,
              NEW.attempt_count, NEW.last_error)
          IS DISTINCT FROM
          ROW(OLD.state, OLD.available_at, OLD.lease_token, OLD.worker_id,
              OLD.claimed_at, OLD.lease_expires_at, OLD.completed_at,
              OLD.attempt_count, OLD.last_error) THEN
        NEW.state_changed_at := clock_timestamp();
    END IF;
    RETURN NEW;
END
$v0433$;

-- Serialize the global temporal-key bound and guard generic refresh/resume.
CREATE OR REPLACE FUNCTION pgreact_internal.assert_temporal_key_limit(
    candidate_condition regclass,
    key_column name,
    target_version_id uuid DEFAULT NULL,
    recovery_condition regclass DEFAULT NULL,
    recovery_key_column name DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE max_keys integer; existing_keys bigint; candidate_keys bigint; statement text;
BEGIN
    IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'M23_ISOLATION_UNSUPPORTED: temporal-key operations require READ COMMITTED';
    END IF;
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    SELECT max_temporal_keys_per_pass INTO STRICT max_keys
    FROM pgreact_internal.operational_settings;
    IF candidate_condition IS NULL OR key_column IS NULL THEN
        RAISE EXCEPTION 'M23_TEMPORAL_SOURCE: temporal condition is unavailable';
    END IF;
    SELECT count(*) INTO existing_keys
    FROM pgreact_internal.temporal_state state
    JOIN pgreact_internal.rule_versions version USING (rule_version_id)
    JOIN pgreact_internal.temporal_rules temporal USING (rule_version_id)
    WHERE version.state = 'ACTIVE'
      AND (target_version_id IS NULL OR state.rule_version_id <> target_version_id);
    statement := format(
        'SELECT (%1$I)::bigint AS semantic_key FROM %2$s WHERE %1$I IS NOT NULL',
        key_column, candidate_condition);
    IF target_version_id IS NOT NULL THEN
        statement := statement || format(
            ' UNION SELECT semantic_key FROM pgreact_internal.temporal_state '
            'WHERE rule_version_id = %L::uuid', target_version_id);
    END IF;
    IF recovery_condition IS NOT NULL THEN
        statement := statement || format(
            ' UNION SELECT (to_jsonb(recovery_row) ->> %L)::bigint FROM %s recovery_row '
            'WHERE (to_jsonb(recovery_row) ->> %L) IS NOT NULL',
            recovery_key_column::text, recovery_condition, recovery_key_column::text);
    END IF;
    EXECUTE 'SELECT count(*) FROM (' || statement || ') AS temporal_keys'
        INTO candidate_keys;
    IF existing_keys + candidate_keys > max_keys THEN
        RAISE EXCEPTION 'M23_TEMPORAL_LIMIT: % temporal keys exceed max_temporal_keys_per_pass %',
            existing_keys + candidate_keys, max_keys;
    END IF;
END
$m23$;
REVOKE ALL ON FUNCTION pgreact_internal.assert_temporal_key_limit(regclass,name,uuid,regclass,name) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pgreact_internal.assert_temporal_rule_key_limit(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE;
    spec pgreact_internal.temporal_rules%ROWTYPE; recovery_relation regclass;
BEGIN
    SELECT * INTO STRICT version_row FROM pgreact_internal.rule_versions
    WHERE rule_version_id = target_version_id;
    SELECT * INTO STRICT spec FROM pgreact_internal.temporal_rules
    WHERE rule_version_id = target_version_id;
    IF spec.recovery_condition_name IS NOT NULL THEN
        recovery_relation := pg_catalog.to_regclass(spec.recovery_condition_name);
    END IF;
    PERFORM pgreact_internal.assert_temporal_key_limit(
        pg_catalog.to_regclass(version_row.source_view_name), version_row.key_column,
        target_version_id, recovery_relation, spec.recovery_key_column);
END
$m23$;
REVOKE ALL ON FUNCTION pgreact_internal.assert_temporal_rule_key_limit(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION pgreact_api.author_temporal_rule(
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
    PERFORM pgreact_internal.assert_temporal_key_limit(
        condition, semantic_key, NULL, recovery_condition, recovery_key_column);
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

CREATE OR REPLACE FUNCTION pgreact_internal.reconcile_temporal_rule(target_version_id uuid)
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
    PERFORM pgreact_internal.assert_temporal_key_limit(
        version_row.match_relid::regclass, version_row.key_column, target_version_id,
        CASE WHEN spec.recovery_condition_name IS NULL THEN NULL::regclass
             ELSE pg_catalog.to_regclass(spec.recovery_condition_name) END,
        spec.recovery_key_column);
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

CREATE OR REPLACE FUNCTION pgreact.resume_rule(target_version_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'resumed',
        'Manage program rules through the complete derivation-program pack.');
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.temporal_rules
        WHERE rule_version_id = target_version_id
    ) THEN
        PERFORM pgreact_internal.assert_temporal_rule_key_limit(target_version_id);
    END IF;
    PERFORM pgreact_internal.resume_rule_m7(target_version_id);
END
$$;

CREATE OR REPLACE FUNCTION pgreact.refresh_rule(target_version_id uuid)
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
    PERFORM pgreact_internal.assert_rule_owner(target_version_id);
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.temporal_rules
        WHERE rule_version_id = target_version_id
    ) THEN
        PERFORM pgreact_internal.assert_temporal_rule_key_limit(target_version_id);
    END IF;
    PERFORM pgreact_internal.refresh_rule_m7(target_version_id);
END
$$;

CREATE OR REPLACE FUNCTION pgreact_api.reconcile_temporal_rule(target_name text)
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
    DELETE FROM pgreact_internal.rule_barriers
    WHERE rule_version_id = version_id AND reason = 'RECONCILING';
    RETURN repaired;
END
$m23$;

CREATE OR REPLACE FUNCTION pgreact_api.resume_temporal_rule(target_name text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE version_id uuid;
BEGIN
    SELECT version.rule_version_id INTO STRICT version_id
    FROM pgreact_internal.rules rule
    JOIN pgreact_internal.rule_versions version USING (rule_id)
    JOIN pgreact_internal.temporal_rules spec USING (rule_version_id)
    WHERE rule.rule_name = target_name AND version.state = 'PAUSED';
    PERFORM pgreact.resume_rule(version_id);
    PERFORM pgreact_internal.reconcile_temporal_rule(version_id);
END
$m23$;

CREATE OR REPLACE FUNCTION pgreact.reconcile_rule(
    target_version_id uuid,
    emission_mode text DEFAULT 'STATE_ONLY'
)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m23$
DECLARE repaired bigint;
BEGIN
    PERFORM pgreact_internal.assert_not_active_program_member(
        target_version_id, 'reconciled',
        'Use pgreact.reconcile_derivation_program.');
    IF emission_mode NOT IN ('STATE_ONLY', 'EMIT_MISSING_EVENTS') THEN
        RAISE EXCEPTION 'emission_mode must be STATE_ONLY or EMIT_MISSING_EVENTS';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.temporal_rules
        WHERE rule_version_id = target_version_id
    ) THEN
        IF emission_mode <> 'STATE_ONLY' THEN
            RAISE EXCEPTION 'temporal rules support STATE_ONLY reconciliation only';
        END IF;
        PERFORM pgreact_internal.assert_rule_owner(target_version_id);
        PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
        IF NOT EXISTS (
            SELECT 1 FROM pgreact_internal.rule_barriers
            WHERE rule_version_id = target_version_id AND reason = 'RECONCILING'
        ) THEN
            RAISE EXCEPTION 'reconciliation requires a committed claim barrier for rule version %',
                target_version_id
                USING HINT = 'Commit pgreact.begin_reconciliation(version), then retry reconciliation in a new transaction.';
        END IF;
        PERFORM pgreact_internal.assert_temporal_rule_key_limit(target_version_id);
        repaired := pgreact_internal.reconcile_temporal_rule(target_version_id);
        DELETE FROM pgreact_internal.rule_barriers
        WHERE rule_version_id = target_version_id AND reason = 'RECONCILING';
        RETURN repaired;
    END IF;
    RETURN pgreact_internal.reconcile_rule_m7(target_version_id, emission_mode);
END
$m23$;
-- Temp relations are session-local and cannot change persistent React bindings.
CREATE OR REPLACE FUNCTION pgreact_internal.binding_ddl_lock()
RETURNS event_trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    call_context text;
BEGIN
    GET DIAGNOSTICS call_context = PG_CONTEXT;
    IF TG_TAG IN (
        'CREATE TABLE', 'ALTER TABLE', 'DROP TABLE',
        'CREATE VIEW', 'ALTER VIEW', 'DROP VIEW',
        'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW', 'DROP MATERIALIZED VIEW'
    ) AND (
        call_context ~* 'SQL statement "[[:space:]]*CREATE[[:space:]]+(GLOBAL[[:space:]]+|LOCAL[[:space:]]+)?(TEMP|TEMPORARY)[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW)([[:space:]]|$)'
        OR call_context ~* 'SQL statement "[[:space:]]*(CREATE[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW)|ALTER[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW)|DROP[[:space:]]+(TABLE|VIEW|MATERIALIZED[[:space:]]+VIEW))[[:space:]]+(IF[[:space:]]+(NOT[[:space:]]+)?EXISTS[[:space:]]+)?("?pg_temp(_[0-9]+)?"?[.])'
    ) THEN
        RETURN;
    END IF;

    -- Preserve the coordinator-before-binding order used by deployment.
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200000);
    PERFORM pg_catalog.pg_advisory_xact_lock(5788046901200001);
END
$$;
