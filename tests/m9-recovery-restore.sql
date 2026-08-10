\set ON_ERROR_STOP on

SELECT set_config('m9.slice4_program', program_version_id::text, false),
       set_config('m9.slice4_observer', observer_version_id::text, false),
       set_config('m9.slice4_reverse_schedule', 'false', false)
FROM m9_slice4.recovery_control;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT state INTO STRICT actual FROM m9_slice4.recovery_state;
    SELECT state INTO STRICT expected FROM m9_slice4.recovery_snapshot;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M9 stratified state changed during recovery: %', actual;
    END IF;
END
$$;

SELECT pgreact.prepare_recovery() = 8 AS recovery_barriered \gset
\if :recovery_barriered
\else
  SELECT 1 / 0;
\endif
SELECT rebuilt_rules = 8 AND blocked_rules = 0 AS metadata_rebuilt
FROM pgreact.rebuild_transient_metadata() \gset
\if :metadata_rebuilt
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.reconcile_derivation_program(program_version_id) = 0 AS reconciled
FROM m9_slice4.recovery_control \gset
\if :reconciled
\else
  SELECT 1 / 0;
\endif

DO $$
DECLARE rule record; repairs integer;
BEGIN
    FOR rule IN
        SELECT rule_version_id
        FROM m9_slice4.recovery_control,
             LATERAL (VALUES (observer_version_id), (base_version_id))
                 versions(rule_version_id)
    LOOP
        repairs := pgreact.reconcile_rule(rule.rule_version_id, 'STATE_ONLY');
        IF repairs <> 0 THEN
            RAISE EXCEPTION 'M9 recovered rule required % repairs', repairs;
        END IF;
    END LOOP;
END
$$;

SELECT count(*) = 0 AS all_barriers_cleared
FROM pgreact_internal.rule_barriers \gset
\if :all_barriers_cleared
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.refresh_derivation_program(program_version_id) = 7 AS refresh_noop
FROM m9_slice4.recovery_control \gset
\if :refresh_noop
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.refresh_rule(observer_version_id)
FROM m9_slice4.recovery_control;
SELECT pgreact.refresh_rule(base_version_id)
FROM m9_slice4.recovery_control;

DO $$
DECLARE actual jsonb; expected jsonb; health jsonb;
BEGIN
    SELECT state INTO STRICT actual FROM m9_slice4.recovery_state;
    SELECT state INTO STRICT expected FROM m9_slice4.recovery_snapshot;
    SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY code), '[]'::jsonb)
    INTO health FROM pgreact.health_check() row WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM expected OR health <> '[]'::jsonb THEN
        RAISE EXCEPTION 'M9 recovered state changed: %, health=%', actual, health;
    END IF;
END
$$;

SELECT 'M9 physical recovery preserved exact stratified state and explanation' AS result;
