DO $install_guard$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles
        WHERE rolname = current_user AND rolsuper) THEN
        RAISE EXCEPTION 'PGREACT_MDM_RETENTION_DDL: install the DDL guard as a superuser';
    END IF;
END
$install_guard$;

\ir retention-guard-role.sql

GRANT USAGE ON SCHEMA mdm_steward, pgreact_mdm
    TO mdm_retention_guard_owner;
REVOKE CREATE ON SCHEMA mdm_steward, pgreact_mdm
    FROM mdm_retention_guard_owner;
DO $guard_owner_schema_privileges$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.pg_roles AS guard_owner
        CROSS JOIN pg_catalog.pg_namespace AS schema_row
        WHERE guard_owner.rolname = 'mdm_retention_guard_owner'
          AND (
              schema_row.nspowner = guard_owner.oid
              OR EXISTS (
                  SELECT 1
                  FROM pg_catalog.aclexplode(COALESCE(
                      schema_row.nspacl,
                      pg_catalog.acldefault('n', schema_row.nspowner)
                  )) AS schema_acl
                  WHERE schema_acl.grantee = guard_owner.oid
                    AND schema_acl.privilege_type = 'CREATE'
              )
          )) THEN
        RAISE EXCEPTION
            'PGREACT_MDM_RETENTION_DDL: guard owner role cannot own schemas or receive schema CREATE grants';
    END IF;
END
$guard_owner_schema_privileges$;

DROP EVENT TRIGGER IF EXISTS pgre_mdm_history_guard_ddl;

CREATE OR REPLACE FUNCTION pgreact_mdm.guard_intent_retention_markers()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
    IF TG_LEVEL = 'ROW' AND TG_TABLE_NAME = 'policy_intent_bindings'
       AND TG_OP = 'UPDATE' THEN
        IF NEW.binding_id IS NOT DISTINCT FROM OLD.binding_id
           AND NEW.entity_name IS NOT DISTINCT FROM OLD.entity_name THEN
            RETURN NEW;
        END IF;
    END IF;

    RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'PGREACT_MDM_RETENTION: history markers cannot be deleted or rekeyed';
END
$function$;

ALTER FUNCTION pgreact_mdm.guard_intent_retention_markers()
    OWNER TO mdm_retention_guard_owner;
REVOKE ALL ON FUNCTION pgreact_mdm.guard_intent_retention_markers() FROM PUBLIC;

CREATE OR REPLACE FUNCTION pgreact_mdm.enforce_history_guard_ddl()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
    missing_guards text;
BEGIN
    WITH expected(relation_name, trigger_name, function_name, trigger_type) AS (
        VALUES
            ('mdm_steward.policy_receipts_v1', 'pgreact_mdm_receipts_retention',
             'pgreact_mdm.guard_policy_history_retention()', 11),
            ('mdm_steward.policy_receipts_v1', 'pgreact_mdm_receipts_no_truncate',
             'pgreact_mdm.guard_policy_history_retention()', 34),
            ('mdm_steward.policy_cases_v1', 'pgreact_mdm_cases_retention',
             'pgreact_mdm.guard_policy_history_retention()', 11),
            ('mdm_steward.policy_cases_v1', 'pgreact_mdm_cases_no_truncate',
             'pgreact_mdm.guard_policy_history_retention()', 34),
            ('pgreact_mdm.policy_intent_bindings', 'intent_bindings_retained',
             'pgreact_mdm.guard_intent_retention_markers()', 27),
            ('pgreact_mdm.policy_intent_bindings', 'intent_bindings_no_truncate',
             'pgreact_mdm.guard_intent_retention_markers()', 34),
            ('pgreact_mdm.intent_case_identities', 'intent_case_identities_retained',
             'pgreact_mdm.guard_intent_retention_markers()', 27),
            ('pgreact_mdm.intent_case_identities', 'intent_case_identities_no_truncate',
             'pgreact_mdm.guard_intent_retention_markers()', 34),
            ('pgreact_mdm.intent_requests', 'intent_requests_retained',
             'pgreact_mdm.reject_intent_record_mutation()', 27),
            ('pgreact_mdm.intent_requests', 'intent_requests_no_truncate',
             'pgreact_mdm.reject_intent_record_mutation()', 34),
            ('pgreact_mdm.intent_attempts', 'intent_attempts_retained',
             'pgreact_mdm.reject_intent_record_mutation()', 27),
            ('pgreact_mdm.intent_attempts', 'intent_attempts_no_truncate',
             'pgreact_mdm.reject_intent_record_mutation()', 34)
    )
    SELECT string_agg(expected.trigger_name, ', ' ORDER BY expected.trigger_name)
      INTO missing_guards
      FROM expected
      LEFT JOIN LATERAL (
          SELECT trigger_row.oid
          FROM pg_catalog.pg_trigger AS trigger_row
          WHERE trigger_row.tgrelid = pg_catalog.to_regclass(expected.relation_name)
            AND trigger_row.tgname = expected.trigger_name
            AND trigger_row.tgfoid = pg_catalog.to_regprocedure(expected.function_name)
            AND trigger_row.tgtype = expected.trigger_type
            AND trigger_row.tgenabled = 'O'
            AND NOT trigger_row.tgisinternal
            AND trigger_row.tgqual IS NULL
      ) AS installed ON true
     WHERE installed.oid IS NULL;

    IF missing_guards IS NOT NULL THEN
        RAISE EXCEPTION USING
            ERRCODE = '55000',
            MESSAGE = 'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled',
            DETAIL = 'Missing or altered guards: ' || missing_guards;
    END IF;
END
$function$;

ALTER FUNCTION pgreact_mdm.enforce_history_guard_ddl() OWNER TO mdm_retention_guard_owner;
REVOKE ALL ON FUNCTION pgreact_mdm.enforce_history_guard_ddl() FROM PUBLIC;

DROP TRIGGER IF EXISTS intent_bindings_retained
    ON pgreact_mdm.policy_intent_bindings;
CREATE TRIGGER intent_bindings_retained
    BEFORE UPDATE OR DELETE ON pgreact_mdm.policy_intent_bindings
    FOR EACH ROW EXECUTE FUNCTION pgreact_mdm.guard_intent_retention_markers();
DROP TRIGGER IF EXISTS intent_bindings_no_truncate
    ON pgreact_mdm.policy_intent_bindings;
CREATE TRIGGER intent_bindings_no_truncate
    BEFORE TRUNCATE ON pgreact_mdm.policy_intent_bindings
    FOR EACH STATEMENT EXECUTE FUNCTION pgreact_mdm.guard_intent_retention_markers();
DROP TRIGGER IF EXISTS intent_case_identities_retained
    ON pgreact_mdm.intent_case_identities;
CREATE TRIGGER intent_case_identities_retained
    BEFORE UPDATE OR DELETE ON pgreact_mdm.intent_case_identities
    FOR EACH ROW EXECUTE FUNCTION pgreact_mdm.guard_intent_retention_markers();
DROP TRIGGER IF EXISTS intent_case_identities_no_truncate
    ON pgreact_mdm.intent_case_identities;
CREATE TRIGGER intent_case_identities_no_truncate
    BEFORE TRUNCATE ON pgreact_mdm.intent_case_identities
    FOR EACH STATEMENT EXECUTE FUNCTION pgreact_mdm.guard_intent_retention_markers();

CREATE EVENT TRIGGER pgre_mdm_history_guard_ddl
    ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE', 'CREATE TRIGGER', 'DROP TRIGGER', 'DROP TABLE',
                 'DROP OWNED', 'CREATE FUNCTION', 'ALTER FUNCTION', 'DROP FUNCTION',
                 'ALTER SCHEMA', 'DROP SCHEMA', 'ALTER EXTENSION', 'DROP EXTENSION')
    EXECUTE FUNCTION pgreact_mdm.enforce_history_guard_ddl();
