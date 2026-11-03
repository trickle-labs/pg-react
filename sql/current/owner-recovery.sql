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
