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
