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
