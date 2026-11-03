\set ON_ERROR_STOP on

CREATE SCHEMA dispatcher_recovery;
CREATE TABLE dispatcher_recovery.source (id bigint PRIMARY KEY);
INSERT INTO dispatcher_recovery.source VALUES (1);
CREATE VIEW dispatcher_recovery.condition AS SELECT id FROM dispatcher_recovery.source;
CREATE FUNCTION dispatcher_recovery.noop(
    context pgreact.activation_context, match dispatcher_recovery.condition
) RETURNS void LANGUAGE plpgsql AS $$ BEGIN NULL; END $$;

SELECT pgreact.create_rule(
    name => 'dispatcher-recovery-probe',
    definition => 'dispatcher_recovery.condition'::regclass,
    key_columns => ARRAY['id'],
    kind => 'COMMAND',
    on_activate => 'dispatcher_recovery.noop(pgreact.activation_context,dispatcher_recovery.condition)'::regprocedure
);

DO $missing_dispatcher$
DECLARE
    target_version uuid;
    target_event text;
    missing_identity text;
    expected_rebuilt bigint;
    actual jsonb;
    barrier_reason text;
    repaired_rows bigint;
BEGIN
    SELECT version.rule_version_id INTO STRICT target_version
    FROM pgreact_internal.rule_versions version
    JOIN pgreact_internal.rules rule USING (rule_id)
    WHERE rule.rule_name = 'dispatcher-recovery-probe' AND version.state <> 'REMOVED';
    SELECT binding.event_kind INTO STRICT target_event
    FROM pgreact_internal.consequence_bindings binding
    WHERE binding.rule_version_id = target_version
      AND binding.consequence_kind = 'DATABASE_TYPED'
      AND binding.dispatcher_identity IS NOT NULL;
    SELECT count(*) INTO expected_rebuilt
    FROM pgreact_internal.rule_versions WHERE state <> 'REMOVED';
    UPDATE pgreact_internal.consequence_bindings
    SET dispatcher_identity = replace(dispatcher_identity, '(', '_missing(')
    WHERE rule_version_id = target_version AND event_kind = target_event
    RETURNING dispatcher_identity INTO missing_identity;
    IF NOT FOUND OR to_regprocedure(missing_identity) IS NOT NULL THEN
        RAISE EXCEPTION 'test failed to create an unresolved dispatcher identity';
    END IF;
    SELECT row_to_json(result)::jsonb INTO actual
    FROM pgreact.rebuild_transient_metadata() result;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'rebuilt_rules', expected_rebuilt - 1, 'blocked_rules', 1) THEN
        RAISE EXCEPTION 'missing dispatcher recovery result differs: %', actual;
    END IF;
    SELECT reason INTO STRICT barrier_reason
    FROM pgreact_internal.rule_barriers WHERE rule_version_id = target_version;
    IF barrier_reason IS DISTINCT FROM 'RECONCILING' THEN
        RAISE EXCEPTION 'missing dispatcher recovery barrier differs: %', barrier_reason;
    END IF;
    UPDATE pgreact_internal.consequence_bindings
    SET dispatcher_identity = replace(dispatcher_identity, '_missing(', '(')
    WHERE rule_version_id = target_version AND event_kind = target_event;
    SELECT row_to_json(result)::jsonb INTO actual
    FROM pgreact.rebuild_transient_metadata() result;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'rebuilt_rules', expected_rebuilt, 'blocked_rules', 0) THEN
        RAISE EXCEPTION 'restored dispatcher recovery result differs: %', actual;
    END IF;
    SELECT pgreact.reconcile_rule(target_version, 'STATE_ONLY') INTO repaired_rows;
    IF repaired_rows <> 0 OR EXISTS (
        SELECT 1 FROM pgreact_internal.rule_barriers WHERE rule_version_id = target_version
    ) THEN
        RAISE EXCEPTION 'restored dispatcher did not clear its recovery barrier';
    END IF;
END
$missing_dispatcher$;
