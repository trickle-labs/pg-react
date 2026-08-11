\set ON_ERROR_STOP on

SELECT set_config('m10.slice1_program', program_version_id::text, false),
       set_config('m10.slice1_observer', observer_version_id::text, false)
FROM m10_slice1.recovery_control;

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT state INTO STRICT actual FROM m10_slice1.recovery_state;
    SELECT state INTO STRICT expected FROM m10_slice1.recovery_snapshot;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M10 aggregate state changed during recovery: %', actual;
    END IF;
END
$$;

SELECT pgreact.prepare_recovery() = 3 AS recovery_barriered \gset
\if :recovery_barriered
\else
  SELECT 1 / 0;
\endif
SELECT rebuilt_rules = 3 AND blocked_rules = 0 AS metadata_rebuilt
FROM pgreact.rebuild_transient_metadata() \gset
\if :metadata_rebuilt
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.reconcile_derivation_program(program_version_id) = 0 AS reconciled
FROM m10_slice1.recovery_control \gset
\if :reconciled
\else
  SELECT 1 / 0;
\endif
DO $$
DECLARE rule record; repairs integer;
BEGIN
    FOR rule IN
        SELECT rule_version_id
        FROM m10_slice1.recovery_control,
             LATERAL (VALUES (observer_version_id), (base_version_id))
                 versions(rule_version_id)
    LOOP
        repairs := pgreact.reconcile_rule(rule.rule_version_id, 'STATE_ONLY');
        IF repairs <> 0 THEN
            RAISE EXCEPTION 'M10 recovered rule required % repairs', repairs;
        END IF;
    END LOOP;
END
$$;
SELECT pgreact.refresh_derivation_program(program_version_id) = 6 AS refresh_noop
FROM m10_slice1.recovery_control \gset
\if :refresh_noop
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.refresh_rule(observer_version_id)
FROM m10_slice1.recovery_control;
SELECT pgreact.refresh_rule(base_version_id)
FROM m10_slice1.recovery_control;

DO $$
DECLARE actual jsonb; expected jsonb; health jsonb;
BEGIN
    SELECT state INTO STRICT actual FROM m10_slice1.recovery_state;
    SELECT state INTO STRICT expected FROM m10_slice1.recovery_snapshot;
    SELECT COALESCE(jsonb_agg(to_jsonb(row) ORDER BY code), '[]'::jsonb)
    INTO health FROM pgreact.health_check() row WHERE severity = 'ERROR';
    IF actual IS DISTINCT FROM expected OR health <> '[]'::jsonb THEN
        RAISE EXCEPTION 'M10 recovered aggregate state changed: %, health=%', actual, health;
    END IF;
END
$$;

SELECT 'M10 physical recovery preserved exact aggregate state and explanation' AS result;
