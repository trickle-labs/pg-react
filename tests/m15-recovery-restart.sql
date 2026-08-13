\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

DO $$
DECLARE expected m15_recovery.control%ROWTYPE;
BEGIN
    SELECT * INTO STRICT expected FROM m15_recovery.control;
    IF pgreact_api.matches('m15.recovery') IS DISTINCT FROM expected.matches
       OR pgreact_api.jobs('m15.recovery') IS DISTINCT FROM expected.jobs
       OR pgreact_api.attempts('m15.recovery') IS DISTINCT FROM expected.attempts
       OR pgreact_api.deadline_history('m15.recovery') IS DISTINCT FROM expected.history
       OR pgreact_api.explain(
            'm15.recovery', '["north","123e4567-e89b-12d3-a456-426614174010"]'::jsonb)
          IS DISTINCT FROM expected.explanation
       OR (SELECT jsonb_agg(jsonb_build_object(
                'semantic_key', semantic_key,
                'canonical_key', encode(canonical_key, 'hex'),
                'public_key', public_key) ORDER BY semantic_key)
           FROM pgreact_internal.semantic_key_identities
           WHERE rule_version_id = expected.rule_version_id)
          IS DISTINCT FROM expected.identities
       OR EXISTS (SELECT 1 FROM m15_recovery.effects) THEN
        RAISE EXCEPTION 'M15 crash or standby changed the exact typed pending state';
    END IF;
END
$$;

SELECT 'M15 crash or standby preserved exact typed pending state';
