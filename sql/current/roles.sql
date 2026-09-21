-- Qualify application_roles columns for PostgreSQL 18's PL/pgSQL name resolution.
CREATE OR REPLACE FUNCTION pgreact_internal.m54_sync_grants(old_roles oid[] DEFAULT ARRAY[]::oid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $m54$
DECLARE
    author_oid oid;
    operator_oid oid;
    reader_oid oid;
    role_oid oid;
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
    FOREACH role_oid IN ARRAY COALESCE(old_roles, ARRAY[]::oid[]) LOOP
        CONTINUE WHEN role_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE oid = role_oid);
        EXECUTE format('REVOKE ALL ON FUNCTION pgreact.review_token(jsonb), pgreact.deploy(pgreact_api.declaration,text,jsonb), pgreact_api.deploy(pgreact_api.declaration,text,jsonb), pgreact.reconcile_rule(text,text), pgreact.sweep_expired_leases(text), pgreact.requeue_episode(text,text) FROM %I', role_oid::regrole::text);
    END LOOP;
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
