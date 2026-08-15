\set ON_ERROR_STOP on
DO $$
DECLARE relation_id uuid; actual jsonb;
BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname='pg_react') <> '0.19.0' THEN
        RAISE EXCEPTION 'M22 upgrade version changed';
    END IF;
    IF to_regclass('pgreact_internal.support_provenance_bindings') IS NULL THEN
        RAISE EXCEPTION 'M22 provenance catalog was not installed';
    END IF;
    SELECT relation_version_id INTO STRICT relation_id
      FROM pgreact_internal.derived_relation_versions
     WHERE public_view_name = 'm22_upgrade.fact' AND state = 'ACTIVE';
    actual := pgreact_api.explain_provenance(relation_id, 7);
    IF actual ->> 'status' <> 'GROUNDED'
       OR (actual ->> 'total_supports')::bigint <> 1
       OR NOT EXISTS (SELECT 1 FROM pgreact_internal.support_provenance_bindings binding
                       JOIN pgreact_internal.derived_supports support USING (support_id)
                      WHERE support.relation_version_id = relation_id AND binding.active) THEN
        RAISE EXCEPTION 'M22 populated upgrade provenance changed: %', actual;
    END IF;
END
$$;
SELECT 'M22 direct 0.18.0 to 0.19.0 upgrade gate passed';
