CREATE SCHEMA logical_restore_temporal_probe;
CREATE TABLE logical_restore_temporal_probe.conditions (
    semantic_key bigint PRIMARY KEY,
    enter_condition boolean NOT NULL,
    recovery_condition boolean NOT NULL
);
INSERT INTO logical_restore_temporal_probe.conditions VALUES
    (9001, false, true), (9002, true, false);
CREATE VIEW logical_restore_temporal_probe.source AS
SELECT semantic_key FROM logical_restore_temporal_probe.conditions WHERE enter_condition;
CREATE VIEW logical_restore_temporal_probe.recovery AS
SELECT semantic_key FROM logical_restore_temporal_probe.conditions WHERE recovery_condition;

DO $probe$
DECLARE
    rule_id uuid := gen_random_uuid();
    version_id uuid := gen_random_uuid();
    source_oid oid := 'logical_restore_temporal_probe.source'::regclass;
    recovery_oid oid := 'logical_restore_temporal_probe.recovery'::regclass;
    source_definition text := pg_get_viewdef(source_oid, true);
    frontier timestamptz;
BEGIN
    SELECT clock.frontier INTO STRICT frontier
    FROM pgreact_internal.clock_frontier clock WHERE singleton;

    INSERT INTO pgreact_internal.rules (rule_id, rule_name, owner_oid, owner_name)
    VALUES (rule_id, 's1-logical-restore-temporal-probe', 'postgres'::regrole, 'postgres');
    INSERT INTO pgreact_internal.rule_versions (
        rule_version_id, rule_id, owner_oid, source_view_oid, source_view_name,
        source_definition, source_definition_digest, source_row_signature, key_column,
        match_name, bootstrap_policy, refresh_mode, isolation_level, state
    ) VALUES (
        version_id, rule_id, 'postgres'::regrole, source_oid,
        'logical_restore_temporal_probe.source', source_definition,
        sha256(convert_to(source_definition, 'UTF8')),
        pgreact_internal.source_row_signature(source_oid), 'semantic_key',
        'pgreact_runtime.logical_restore_temporal_probe', 'SEED_CURRENT',
        'DIFFERENTIAL', 'read committed', 'REMOVED'
    );
    INSERT INTO pgreact_internal.temporal_rules (
        rule_version_id, primitive, recovery_condition_oid, recovery_key_column
    ) VALUES (version_id, 'HYSTERESIS', recovery_oid, 'semantic_key');
    UPDATE pgreact_internal.temporal_rules
    SET recovery_condition_oid = '0'::oid
    WHERE rule_version_id = version_id;
    INSERT INTO pgreact_internal.temporal_state (
        rule_version_id, semantic_key, state, active, input_true, recovery_true,
        generation, last_frontier, last_bindings
    ) VALUES (
        version_id, 9001, 'RECOVERED', false, false, true,
        1, frontier, jsonb_build_object('semantic_key', 9001)
    );
    INSERT INTO pgreact_internal.temporal_history (
        rule_version_id, semantic_key, event_kind, primitive_state,
        input_true, recovery_true, clock_frontier, bindings
    ) VALUES (
        version_id, 9001, 'DEACTIVATE', 'RECOVERED',
        false, true, frontier, jsonb_build_object('semantic_key', 9001)
    );
END
$probe$;
DO $active_temporal$
BEGIN
    PERFORM pgreact_api.author_temporal_rule(
        's1-logical-restore-active-temporal',
        'logical_restore_temporal_probe.source'::regclass,
        'semantic_key', 'HYSTERESIS',
        recovery_condition => 'logical_restore_temporal_probe.recovery'::regclass,
        recovery_key_column => 'semantic_key');
END
$active_temporal$;
CREATE TABLE logical_restore_temporal_probe.duration_conditions (
    semantic_key bigint PRIMARY KEY
);
INSERT INTO logical_restore_temporal_probe.duration_conditions VALUES (9101);
CREATE VIEW logical_restore_temporal_probe.duration_source AS
SELECT semantic_key FROM logical_restore_temporal_probe.duration_conditions;
DO $active_duration$
BEGIN
    PERFORM pgreact_api.author_temporal_rule(
        's1-logical-restore-active-duration',
        'logical_restore_temporal_probe.duration_source'::regclass,
        'semantic_key', 'DURATION', interval '1 hour');
END
$active_duration$;
SELECT 'logical_restore_temporal_probe_seeded';
