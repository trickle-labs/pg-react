-- Rebind catalog OIDs and block stale consequence identities after restore.
CREATE OR REPLACE FUNCTION pgreact.rebuild_transient_metadata()
RETURNS TABLE(rebuilt_rules bigint, blocked_rules bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE version_row pgreact_internal.rule_versions%ROWTYPE; rebuild_id bigint; source_oid oid; match_oid oid;
    binding pgreact_internal.consequence_bindings%ROWTYPE; resolved_function_oid oid; resolved_dispatcher_oid oid;
    resolved_consequence_oid oid; resolved_version_dispatcher_oid oid;
    rebuilt bigint := 0; blocked bigint := 0; valid boolean;
BEGIN
    IF NOT pgreact_internal.is_operator_admin() THEN RAISE EXCEPTION 'only pgreact_admin may rebuild transient metadata'; END IF;
    IF EXISTS (
        SELECT 1 FROM pgreact_internal.rules r
        WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles p WHERE p.rolname = r.owner_name)
    ) THEN
        RAISE EXCEPTION 'cannot rebuild transient metadata: a stored rule owner is missing';
    END IF;
    UPDATE pgreact_internal.rules r
    SET owner_oid = p.oid
    FROM pg_catalog.pg_roles p
    WHERE p.rolname = r.owner_name;
    UPDATE pgreact_internal.rule_versions v
    SET owner_oid = p.oid
    FROM pgreact_internal.rules r
    JOIN pg_catalog.pg_roles p ON p.rolname = r.owner_name
    WHERE r.rule_id = v.rule_id;
    INSERT INTO pgreact_internal.metadata_rebuild_audits (status) VALUES ('RUNNING') RETURNING metadata_rebuild_id INTO rebuild_id;
    FOR version_row IN SELECT * FROM pgreact_internal.rule_versions WHERE state <> 'REMOVED' FOR UPDATE LOOP
        source_oid := to_regclass(version_row.source_view_name);
        match_oid := to_regclass(version_row.match_name);
        valid := source_oid IS NOT NULL AND match_oid IS NOT NULL
            AND pg_get_viewdef(source_oid, true) = version_row.source_definition
            AND EXISTS (SELECT 1 FROM pg_catalog.pg_class c
                        WHERE c.oid = source_oid AND c.relowner = version_row.owner_oid)
            AND pgreact_internal.source_row_signature(source_oid) = version_row.source_row_signature;
        resolved_consequence_oid := CASE WHEN version_row.consequence_identity IS NULL THEN NULL
            ELSE to_regprocedure(version_row.consequence_identity) END;
        resolved_version_dispatcher_oid := CASE WHEN version_row.dispatcher_identity IS NULL THEN NULL
            ELSE to_regprocedure(version_row.dispatcher_identity) END;
        valid := valid
            AND ((version_row.consequence_identity IS NULL AND version_row.consequence_oid IS NULL)
                 OR (resolved_consequence_oid IS NOT NULL
                     AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                 WHERE p.oid = resolved_consequence_oid AND p.proowner = version_row.owner_oid)
                     AND sha256(convert_to(pg_get_functiondef(resolved_consequence_oid), 'UTF8')) = version_row.consequence_digest))
            AND ((version_row.dispatcher_identity IS NULL AND version_row.dispatcher_oid IS NULL)
                 OR (resolved_version_dispatcher_oid IS NOT NULL
                     AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                 WHERE p.oid = resolved_version_dispatcher_oid AND p.proowner = version_row.owner_oid)
                     AND sha256(convert_to(pg_get_functiondef(resolved_version_dispatcher_oid), 'UTF8')) = version_row.dispatcher_digest));
        FOR binding IN SELECT * FROM pgreact_internal.consequence_bindings WHERE rule_version_id = version_row.rule_version_id LOOP
            resolved_function_oid := to_regprocedure(binding.function_identity);
            resolved_dispatcher_oid := CASE WHEN binding.dispatcher_identity IS NULL THEN NULL ELSE to_regprocedure(binding.dispatcher_identity) END;
            valid := valid AND resolved_function_oid IS NOT NULL
                AND sha256(convert_to(pg_get_functiondef(resolved_function_oid), 'UTF8')) = binding.function_digest
                AND (binding.consequence_kind <> 'DATABASE_TYPED' OR EXISTS (
                    SELECT 1 FROM pg_catalog.pg_proc p
                    WHERE p.oid = resolved_function_oid AND p.proowner = version_row.owner_oid))
                AND ((binding.dispatcher_identity IS NULL AND binding.dispatcher_oid IS NULL)
                     OR (resolved_dispatcher_oid IS NOT NULL
                         AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
                                     WHERE p.oid = resolved_dispatcher_oid AND p.proowner = version_row.owner_oid)
                         AND sha256(convert_to(pg_get_functiondef(resolved_dispatcher_oid), 'UTF8')) = binding.dispatcher_digest));
            IF valid THEN
                UPDATE pgreact_internal.consequence_bindings SET function_oid = resolved_function_oid, dispatcher_oid = resolved_dispatcher_oid
                WHERE rule_version_id = binding.rule_version_id AND event_kind = binding.event_kind;
            END IF;
        END LOOP;
        IF valid THEN
            UPDATE pgreact_internal.rule_versions
            SET source_view_oid = source_oid, match_relid = match_oid,
                consequence_oid = resolved_consequence_oid,
                dispatcher_oid = resolved_version_dispatcher_oid
            WHERE rule_version_id = version_row.rule_version_id;
            rebuilt := rebuilt + 1;
        ELSE
            INSERT INTO pgreact_internal.rule_barriers (rule_version_id, reason)
            VALUES (version_row.rule_version_id, 'RECONCILING')
            ON CONFLICT (rule_version_id) DO UPDATE SET reason = 'RECONCILING', created_at = clock_timestamp();
            PERFORM pgreact_internal.record_runtime_event('ERROR', 'METADATA_REBUILD_BLOCKED', version_row.rule_version_id);
            blocked := blocked + 1;
        END IF;
    END LOOP;
    UPDATE pgreact_internal.metadata_rebuild_audits SET completed_at = clock_timestamp(), rebuilt_rules = rebuilt,
        blocked_rules = blocked, status = 'COMPLETED' WHERE metadata_rebuild_id = rebuild_id;
    RETURN QUERY SELECT rebuilt, blocked;
END $$;
-- Grant managed-worker access only to React-generated stream tables.
