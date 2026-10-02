-- Grant managed-worker access only to React-generated stream tables.
CREATE OR REPLACE FUNCTION pgreact_internal.m54_sync_grants(old_roles oid[] DEFAULT ARRAY[]::oid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    author_oid oid;
    operator_oid oid;
    reader_oid oid;
    worker_oid oid;
    role_oid oid;
    stream_row record;
BEGIN
    SELECT application_role.role_oid INTO author_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'author';
    SELECT application_role.role_oid INTO operator_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'operator';
    SELECT application_role.role_oid INTO reader_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'reader';
    SELECT application_role.role_oid INTO worker_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'worker';
    FOREACH role_oid IN ARRAY COALESCE(old_roles, ARRAY[]::oid[]) LOOP
        CONTINUE WHEN role_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE oid = role_oid);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION pgreact_api.managed_cycle() FROM %I', role_oid::regrole::text);
        EXECUTE format('REVOKE ALL ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) FROM %I', role_oid::regrole::text);
        FOR stream_row IN
            SELECT DISTINCT pg_catalog.to_regclass(version.match_name) AS relation
            FROM pgreact_internal.rule_versions AS version
            WHERE pg_catalog.to_regclass(version.match_name) IS NOT NULL
        LOOP
            EXECUTE format('REVOKE MAINTAIN ON TABLE %s FROM %I',
                           stream_row.relation, role_oid::regrole::text);
        END LOOP;
    END LOOP;
    IF worker_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_api.managed_cycle() TO %I', worker_oid::regrole::text);
        FOR stream_row IN
            SELECT DISTINCT pg_catalog.to_regclass(version.match_name) AS relation
            FROM pgreact_internal.rule_versions AS version
            WHERE pg_catalog.to_regclass(version.match_name) IS NOT NULL
        LOOP
            EXECUTE format('GRANT MAINTAIN ON TABLE %s TO %I',
                           stream_row.relation, worker_oid::regrole::text);
        END LOOP;
    END IF;
    IF author_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.validate(pgreact_api.declaration), pgreact.preview(pgreact_api.declaration,jsonb), pgreact.deploy(pgreact_api.declaration,jsonb), pgreact.export(text,text,text) TO %I', author_oid::regrole::text);
    END IF;
    IF reader_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.review_token(jsonb), pgreact.validate(pgreact_api.declaration), pgreact.export(text,text,text) TO %I', reader_oid::regrole::text);
    END IF;
    IF operator_oid IS NOT NULL THEN
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) TO %I', operator_oid::regrole::text);
    END IF;
    FOREACH role_oid IN ARRAY ARRAY[author_oid, operator_oid, reader_oid] LOOP
        CONTINUE WHEN role_oid IS NULL;
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact.compare(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact.compare_results(pgreact_api.declaration,pgreact_api.target,jsonb), pgreact_internal.m54_read_rule_model(name,name,name,text,boolean,integer), pgreact_internal.m54_read_decision_model(name,name,name,name,name,name[],integer,text,integer), pgreact_internal.m54_decision_result(jsonb,name[]) TO %I', role_oid::regrole::text);
        EXECUTE format('GRANT EXECUTE ON FUNCTION pgreact_internal.m34_authoritative_checksum(), pgreact_internal.m34_delta(jsonb,jsonb), pgreact_internal.m34_raw_rows(jsonb,bigint,integer), pgreact_internal.m34_finding(text,text,text,text,text,text,jsonb) TO %I', role_oid::regrole::text);
    END LOOP;
END
$m54$;

-- Repair an already configured predecessor without changing its role mapping.
DO $maintenance$
BEGIN
    PERFORM pgreact_internal.m54_sync_grants();
END
$maintenance$;

-- Keep each generated stream owned by its author while delegating refresh
-- only to the currently configured managed worker.
CREATE OR REPLACE FUNCTION pgreact_internal.create_m0_stream(name text, query text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m0$
DECLARE
    worker_oid oid;
    stream_relation regclass;
BEGIN
    PERFORM pgreact_internal.assert_m0_compatibility();
    PERFORM pgtrickle.create_stream_table(
        name => create_m0_stream.name,
        query => create_m0_stream.query,
        schedule => '1h',
        refresh_mode => 'DIFFERENTIAL',
        initialize => true
    );

    SELECT application_role.role_oid INTO worker_oid
    FROM pgreact_internal.application_roles AS application_role
    WHERE application_role.role_kind = 'worker';
    IF worker_oid IS NOT NULL THEN
        stream_relation := pg_catalog.to_regclass(name);
        EXECUTE format('GRANT MAINTAIN ON TABLE %s TO %I',
                       stream_relation, worker_oid::regrole::text);
    END IF;
END
$m0$;
