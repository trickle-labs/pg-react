\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT state INTO STRICT actual FROM clinical.recovery_state;
    SELECT state INTO STRICT expected FROM clinical.recovery_snapshot;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M7 derived state changed during physical recovery: %', actual;
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
SELECT pgreact.reconcile_derived_relation(relation_version_id) = 0 AS reconciled
FROM clinical.recovery_control \gset
\if :reconciled
\else
  SELECT 1 / 0;
\endif
SELECT pgreact.refresh_derived_relation(relation_version_id) = 2 AS refresh_noop
FROM clinical.recovery_control \gset
\if :refresh_noop
\else
  SELECT 1 / 0;
\endif

DO $$
DECLARE actual jsonb; expected jsonb;
BEGIN
    SELECT jsonb_build_object(
        'rows', (SELECT jsonb_agg(to_jsonb(f) ORDER BY patient_id)
                 FROM clinical.patient_fever f),
        'explanation', pgreact.explain_fact(
            (SELECT relation_version_id FROM clinical.recovery_control), 42),
        'derived_health', (SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY code), '[]'::jsonb)
                           FROM pgreact.health_check() h WHERE code LIKE 'DERIVED_%')
    ) INTO actual;
    expected := jsonb_build_object(
        'rows', jsonb_build_array(jsonb_build_object('patient_id', 42)),
        'explanation', jsonb_build_object(
            'relation', 'clinical.patient_fever@1',
            'fact', jsonb_build_object('patient_id', 42),
            'active_supports', jsonb_build_array(jsonb_build_object(
                'rule', 'clinical.fever_from_temperature@1',
                'activation_generation', 2,
                'source_binding', jsonb_build_object(
                    'patient_id', 42, 'temperature_c', 39.2)))),
        'derived_health', jsonb_build_array());
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'M7 recovered workflow changed: %', actual;
    END IF;
END
$$;

SELECT 'M7 physical recovery preserved exact derived facts and supports' AS result;
