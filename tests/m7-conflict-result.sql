\set ON_ERROR_STOP on

DO $$
DECLARE actual jsonb;
BEGIN
    SELECT jsonb_build_object(
        'facts', COALESCE((SELECT jsonb_agg(f.fact)
            FROM pgreact.derived_facts f
            WHERE f.relation_version_id = i.relation_version_id), '[]'::jsonb),
        'supports', COALESCE((SELECT jsonb_agg(s.source_binding)
            FROM pgreact.support_history s
            WHERE s.relation_version_id = i.relation_version_id), '[]'::jsonb),
        'activations', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'rule_version_id', a.rule_version_id, 'active', a.active))
            FROM pgreact_internal.activation_state a
            JOIN pgreact_internal.derivation_rule_versions d USING (rule_version_id)
            WHERE d.relation_version_id = i.relation_version_id), '[]'::jsonb)
    ) INTO actual FROM conflict_fixture.identity i;
    IF actual IS DISTINCT FROM jsonb_build_object(
        'facts', '[]'::jsonb, 'supports', '[]'::jsonb, 'activations', '[]'::jsonb) THEN
        RAISE EXCEPTION 'conflicting refresh was not atomic: %', actual;
    END IF;
END $$;

SELECT 'M7 conflicting payload rollback check passed' AS result;
