\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT state INTO STRICT actual FROM m8_ref.recovery_state;
    SELECT state INTO STRICT expected FROM m8_ref.recovery_snapshot;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 recursive state changed during recovery: %', actual;
    END IF;
END $$;

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
FROM m8_ref.recovery_control \gset
\if :reconciled
\else
  SELECT 1 / 0;
\endif
SELECT count(*) = 0 AS program_barriers_cleared
FROM pgreact_internal.rule_barriers b
JOIN pgreact_internal.derivation_program_rules r USING (rule_version_id)
JOIN m8_ref.recovery_control c USING (program_version_id) \gset
\if :program_barriers_cleared
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.reconcile_rule(observer_version_id, 'STATE_ONLY') = 0 AS observer_reconciled
FROM m8_ref.recovery_control \gset
\if :observer_reconciled
\else
  SELECT 1 / 0;
\endif
SELECT count(*) = 0 AS all_barriers_cleared
FROM pgreact_internal.rule_barriers \gset
\if :all_barriers_cleared
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.refresh_derivation_program(program_version_id) = 4 AS refresh_noop
FROM m8_ref.recovery_control \gset
\if :refresh_noop
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.refresh_rule(observer_version_id)
FROM m8_ref.recovery_control;

DO $$
DECLARE actual jsonb; expected jsonb; health jsonb;
BEGIN
    SELECT state INTO STRICT actual FROM m8_ref.recovery_state;
    SELECT state INTO STRICT expected FROM m8_ref.recovery_snapshot;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M8 continued state changed after recovery: %', actual;
    END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY code), '[]'::jsonb) INTO health
    FROM pgreact.health_check() h
    WHERE severity = 'ERROR';
    IF health IS DISTINCT FROM '[]'::jsonb THEN
        RAISE EXCEPTION 'M8 recovered health changed: %', health;
    END IF;
END $$;

SELECT 'M8 physical recovery preserved exact recursive facts, supports, graph, and explanation' AS result;
