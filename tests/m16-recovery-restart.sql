\set ON_ERROR_STOP on
DO $$
DECLARE expected m16_recovery.control%ROWTYPE;
BEGIN
    SELECT * INTO STRICT expected FROM m16_recovery.control;
    IF (SELECT jsonb_agg(to_jsonb(evidence) ORDER BY rule_name, public_group_key)
        FROM pgreact.aggregate_dependency_evidence evidence
        WHERE program_name = 'm16.recovery') IS DISTINCT FROM expected.evidence
       OR pgreact_api.explain('m16_recovery.alert', '1'::jsonb)
          IS DISTINCT FROM expected.true_explanation
       OR pgreact_api.explain('m16_recovery.alert', '2'::jsonb)
          IS DISTINCT FROM expected.false_explanation THEN
        RAISE EXCEPTION 'M16 crash restart changed typed aggregate state';
    END IF;
END
$$;
SELECT 'M16 crash restart preserved typed aggregate state';
