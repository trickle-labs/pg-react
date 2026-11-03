\set ON_ERROR_STOP on
\set VERBOSITY verbose
SET TIME ZONE 'UTC';

CREATE SCHEMA s1_retention;

CREATE FUNCTION s1_retention.state() RETURNS jsonb
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $state$
SELECT jsonb_build_object(
    'entity', (SELECT to_jsonb(e) FROM mdm_internal.entities AS e
               WHERE e.entity_name = 'policy_qualification'),
    'cases', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.case_key), '[]')
              FROM mdm_steward.policy_cases_v1 AS c
              WHERE c.entity_name = 'policy_qualification'),
    'mdm_bindings', (SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.binding_id), '[]')
                     FROM mdm_steward.policy_bindings_v1 AS b
                     WHERE b.entity_id = (SELECT e.entity_id FROM mdm_internal.entities AS e
                                          WHERE e.entity_name = 'policy_qualification')),
    'receipts', (SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.created_at, r.receipt_id), '[]')
                 FROM mdm_steward.policy_receipts_v1 AS r
                 WHERE r.binding_id IN (
                     SELECT b.binding_id FROM mdm_steward.policy_bindings_v1 AS b
                     WHERE b.entity_id = (SELECT e.entity_id FROM mdm_internal.entities AS e
                                          WHERE e.entity_name = 'policy_qualification'))),
    'adapter_bindings', (SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.binding_id), '[]')
                         FROM pgreact_mdm.policy_intent_bindings AS b
                         WHERE b.entity_name = 'policy_qualification'),
    'identities', (SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.case_identity), '[]')
                   FROM pgreact_mdm.intent_case_identities AS i
                   WHERE i.entity_name = 'policy_qualification'),
    'requests', (SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.binding_id, r.request_key), '[]')
                 FROM pgreact_mdm.intent_requests AS r
                 JOIN pgreact_mdm.policy_intent_bindings AS b USING (binding_id)
                 WHERE b.entity_name = 'policy_qualification'),
    'attempts', (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.episode_id, a.attempt_no), '[]')
                 FROM pgreact_mdm.intent_attempts AS a
                 JOIN pgreact_mdm.policy_intent_bindings AS b USING (binding_id)
                 WHERE b.entity_name = 'policy_qualification'))
$state$;

CREATE FUNCTION s1_retention.expect_blocked(
    operation text, expected_sqlstate text, expected_message text
) RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $assertion$
DECLARE
    before_state jsonb;
    after_state jsonb;
    actual_sqlstate text;
    actual_message text;
BEGIN
    before_state := s1_retention.state();
    BEGIN
        EXECUTE operation;
        RAISE EXCEPTION USING
            ERRCODE = 'P0001',
            MESSAGE = 'RETENTION_TEST_EXPECTED_BLOCK: operation succeeded';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            actual_sqlstate = RETURNED_SQLSTATE,
            actual_message = MESSAGE_TEXT;
    END;
    IF ROW(actual_sqlstate, actual_message)
       IS DISTINCT FROM ROW(expected_sqlstate, expected_message) THEN
        RAISE EXCEPTION 'retention block output differs: expected (%, %), got (%, %)',
            expected_sqlstate, expected_message, actual_sqlstate, actual_message;
    END IF;
    after_state := s1_retention.state();
    IF after_state IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'blocked retention operation changed exact state: before %, after %',
            before_state, after_state;
    END IF;
END
$assertion$;

GRANT USAGE ON SCHEMA s1_retention TO mdm_legacy_administrator;
GRANT EXECUTE ON FUNCTION s1_retention.state(),
    s1_retention.expect_blocked(text, text, text) TO mdm_legacy_administrator;

SELECT c.case_key, COALESCE(c.assigned_queue::text, '') AS assigned_queue,
       c.action_revision
FROM mdm_steward.policy_cases_v1 AS c
JOIN pgreact_mdm.policy_intent_bindings AS b
  ON b.entity_name = c.entity_name AND b.enabled
WHERE c.entity_name = 'policy_qualification'
  AND c.status = 'open'
  AND 'ESCALATE' = ANY(c.permitted_actions)
  AND b.max_escalation_level >= 2
ORDER BY c.case_key
LIMIT 1
\gset target_

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_steward.set_case_controls(
    :target_case_key, NULLIF(:'target_assigned_queue', '')::name,
    clock_timestamp() - interval '1 hour', 1, false,
    :target_action_revision, 'Retention fixture delivery')
\gset control_
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT c.case_key, c.review_version, c.definition_version,
       c.publication_revision, c.stewardship_epoch,
       encode(c.evidence_basis_digest, 'hex') AS evidence_digest,
       c.action_revision, b.binding_id, encode(b.policy_digest, 'hex') AS policy_digest,
       b.policy_revision
FROM mdm_steward.policy_cases_v1 AS c
JOIN pgreact_mdm.policy_intent_bindings AS b
  ON b.entity_name = c.entity_name AND b.enabled
WHERE c.case_key = :target_case_key
\gset current_

SET SESSION AUTHORIZATION mdm_s1_runtime;
SET ROLE pgreact_mdm_worker;
SELECT receipt_id, outcome, reason_code, case_key, action_revision, control
FROM mdm_steward.submit_policy_intent(
    :'current_binding_id'::uuid, decode(repeat('a1', 32), 'hex'),
    :current_case_key, 'ESCALATE', '{"level":2}'::jsonb,
    :current_review_version, :current_definition_version,
    :current_publication_revision, :current_stewardship_epoch,
    decode(:'current_evidence_digest', 'hex'), :current_action_revision,
    decode(:'current_policy_digest', 'hex'), :'current_policy_revision',
    'retention-regression', 'retention-regression-work')
\gset receipt_
RESET ROLE;
RESET SESSION AUTHORIZATION;

SELECT :'receipt_outcome' = 'APPLIED_CONTROL'
   AND :'receipt_reason_code' = 'CONTROL_APPLIED'
   AND :receipt_case_key::bigint = :current_case_key::bigint
   AND :receipt_action_revision::bigint = :current_action_revision::bigint + 1
   AND :'receipt_control'::jsonb ->> 'escalation_level' = '2'
   AND (SELECT count(*) = 1 FROM mdm_steward.policy_receipts_v1 AS r
        WHERE r.receipt_id = :'receipt_receipt_id'::uuid)
AS receipt_exactly_applied
\gset
\if :receipt_exactly_applied
\else
\quit 1
\endif

CREATE TABLE s1_retention.target AS
SELECT :current_case_key::bigint AS case_key,
       :'receipt_receipt_id'::uuid AS receipt_id;
GRANT SELECT ON s1_retention.target TO mdm_legacy_administrator;

-- Controlled timestamps exercise the elapsed-day boundary without a 90-day wait.
UPDATE mdm_steward.policy_cases_v1
SET status = 'resolved', permitted_actions = '{}'::text[],
    resolved_at = clock_timestamp() - interval '89 days'
WHERE entity_name = 'policy_qualification';
UPDATE mdm_steward.policy_receipts_v1
SET created_at = clock_timestamp() - interval '91 days'
WHERE receipt_id = (SELECT receipt_id FROM s1_retention.target);

DO $young_case$
DECLARE expected_message text;
BEGIN
    expected_message := format(
        'PGREACT_MDM_RETENTION: managed policy history for case %s is not eligible for deletion',
        (SELECT case_key FROM s1_retention.target));
    PERFORM s1_retention.expect_blocked(
        'DELETE FROM mdm_steward.policy_receipts_v1 WHERE receipt_id = '
        '(SELECT receipt_id FROM s1_retention.target)', '55000', expected_message);
    PERFORM s1_retention.expect_blocked(
        'DELETE FROM mdm_steward.policy_cases_v1 WHERE case_key = '
        '(SELECT case_key FROM s1_retention.target)', '55000', expected_message);
    PERFORM s1_retention.expect_blocked(
        'TRUNCATE TABLE mdm_steward.policy_receipts_v1', '55000',
        'PGREACT_MDM_RETENTION: managed policy receipts remain within the retention period');
    PERFORM s1_retention.expect_blocked(
        'TRUNCATE TABLE mdm_steward.policy_cases_v1', '55000',
        'PGREACT_MDM_RETENTION: managed cases or receipts remain protected');
END
$young_case$;

CREATE SCHEMA s1_retention_public_create;
GRANT CREATE ON SCHEMA s1_retention_public_create TO PUBLIC;
\ir ../../../../integrations/pg-mdm/sql/retention-guard.sql
SELECT pg_catalog.has_schema_privilege(guard_owner.oid, schema_row.oid, 'CREATE')
   AND NOT EXISTS (
        SELECT 1
        FROM pg_catalog.aclexplode(COALESCE(
            schema_row.nspacl,
            pg_catalog.acldefault('n', schema_row.nspowner)
        )) AS schema_acl
        WHERE schema_acl.grantee = guard_owner.oid
          AND schema_acl.privilege_type = 'CREATE')
       AS public_schema_create_is_ambient
FROM pg_catalog.pg_roles AS guard_owner
CROSS JOIN pg_catalog.pg_namespace AS schema_row
WHERE guard_owner.rolname = 'mdm_retention_guard_owner'
  AND schema_row.nspname = 's1_retention_public_create'
\gset
\if :public_schema_create_is_ambient
\else
\quit 1
\endif
DROP SCHEMA s1_retention_public_create;
GRANT USAGE ON SCHEMA s1_retention TO mdm_helper_owner;
GRANT EXECUTE ON FUNCTION s1_retention.state(),
    s1_retention.expect_blocked(text, text, text) TO mdm_helper_owner;
SELECT pg_catalog.pg_get_userbyid(function_row.proowner) = 'mdm_retention_guard_owner'
   AND NOT owner_row.rolcanlogin
   AND NOT owner_row.rolsuper
   AND NOT owner_row.rolcreatedb
   AND NOT owner_row.rolcreaterole
   AND NOT owner_row.rolinherit
   AND NOT owner_row.rolreplication
   AND NOT owner_row.rolbypassrls
   AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_namespace AS schema_row
        WHERE schema_row.nspowner = owner_row.oid
           OR EXISTS (
                SELECT 1
                FROM pg_catalog.aclexplode(COALESCE(
                    schema_row.nspacl,
                    pg_catalog.acldefault('n', schema_row.nspowner)
                )) AS schema_acl
                WHERE schema_acl.grantee = owner_row.oid
                  AND schema_acl.privilege_type = 'CREATE'))
   AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_auth_members
        WHERE roleid = owner_row.oid OR member = owner_row.oid)
       AS guard_owner_isolated
FROM pg_catalog.pg_proc AS function_row
JOIN pg_catalog.pg_roles AS owner_row
  ON owner_row.oid = function_row.proowner
WHERE function_row.oid =
    'pgreact_mdm.enforce_history_guard_ddl()'::regprocedure
\gset
\if :guard_owner_isolated
\else
\quit 1
\endif
GRANT USAGE ON SCHEMA s1_retention TO mdm_retention_guard_owner;
GRANT EXECUTE ON FUNCTION s1_retention.state(),
    s1_retention.expect_blocked(text, text, text) TO mdm_retention_guard_owner;
SET SESSION AUTHORIZATION mdm_retention_guard_owner;
SELECT s1_retention.expect_blocked(
    $ddl$CREATE OR REPLACE FUNCTION pgreact_mdm.enforce_history_guard_ddl()
        RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
        AS $replacement$BEGIN END;$replacement$$ddl$,
    '42501',
    'permission denied for schema pgreact_mdm')
\gset
RESET SESSION AUTHORIZATION;
REVOKE USAGE ON SCHEMA s1_retention FROM mdm_retention_guard_owner;
REVOKE EXECUTE ON FUNCTION s1_retention.state(),
    s1_retention.expect_blocked(text, text, text) FROM mdm_retention_guard_owner;
SET SESSION AUTHORIZATION mdm_helper_owner;
SELECT s1_retention.expect_blocked(
    $ddl$CREATE OR REPLACE FUNCTION pgreact_mdm.enforce_history_guard_ddl()
        RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
        AS $replacement$BEGIN END;$replacement$$ddl$,
    '42501',
    'permission denied for schema pgreact_mdm')
\gset
SELECT s1_retention.expect_blocked(
    $ddl$CREATE OR REPLACE FUNCTION pgreact_mdm.guard_policy_history_retention()
        RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
        AS $replacement$BEGIN RETURN OLD;$replacement$$ddl$,
    '42501',
    'permission denied for schema pgreact_mdm')
\gset
SELECT s1_retention.expect_blocked(
    $ddl$CREATE OR REPLACE FUNCTION pgreact_mdm.reject_intent_record_mutation()
        RETURNS trigger LANGUAGE plpgsql
        SET search_path = pg_catalog, pg_temp
        AS $replacement$BEGIN RETURN OLD;$replacement$$ddl$,
    '42501',
    'permission denied for schema pgreact_mdm')
\gset
SELECT s1_retention.expect_blocked(
    $ddl$CREATE OR REPLACE FUNCTION pgreact_mdm.guard_intent_retention_markers()
        RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
        SET search_path = pg_catalog, pg_temp
        AS $replacement$BEGIN RETURN OLD;$replacement$$ddl$,
    '42501',
    'permission denied for schema pgreact_mdm')
\gset
SELECT s1_retention.expect_blocked(
    'DROP FUNCTION pgreact_mdm.guard_intent_retention_markers() CASCADE',
    '42501',
    'must be owner of function pgreact_mdm.guard_intent_retention_markers')
\gset
SELECT s1_retention.expect_blocked(
    'DELETE FROM pgreact_mdm.policy_intent_bindings '
    'WHERE entity_name = ''policy_qualification''',
    '55000',
    'PGREACT_MDM_RETENTION: history markers cannot be deleted or rekeyed')
\gset
SELECT s1_retention.expect_blocked(
    'UPDATE pgreact_mdm.policy_intent_bindings '
    'SET entity_name = ''retention_test_unmanaged'' '
    'WHERE entity_name = ''policy_qualification''',
    '55000',
    'PGREACT_MDM_RETENTION: history markers cannot be deleted or rekeyed')
\gset
SELECT s1_retention.expect_blocked(
    'TRUNCATE TABLE pgreact_mdm.policy_intent_bindings',
    '55000',
    'PGREACT_MDM_RETENTION: history markers cannot be deleted or rekeyed')
\gset
SELECT s1_retention.expect_blocked(
    'DELETE FROM pgreact_mdm.intent_case_identities '
    'WHERE entity_name = ''policy_qualification''',
    '55000',
    'PGREACT_MDM_RETENTION: history markers cannot be deleted or rekeyed')
\gset
SELECT s1_retention.expect_blocked(
    'UPDATE pgreact_mdm.intent_case_identities '
    'SET entity_name = ''retention_test_unmanaged'' '
    'WHERE entity_name = ''policy_qualification''',
    '55000',
    'PGREACT_MDM_RETENTION: history markers cannot be deleted or rekeyed')
\gset
SELECT s1_retention.expect_blocked(
    'TRUNCATE TABLE pgreact_mdm.intent_case_identities',
    '55000',
    'PGREACT_MDM_RETENTION: history markers cannot be deleted or rekeyed')
\gset
SELECT s1_retention.state() AS binding_state_before_update
\gset
BEGIN;
UPDATE pgreact_mdm.policy_intent_bindings
SET enabled = NOT enabled
WHERE entity_name = 'policy_qualification';
ROLLBACK;
SELECT s1_retention.state() = :'binding_state_before_update'::jsonb
    AS binding_config_update_rolled_back
\gset
\if :binding_config_update_rolled_back
\else
\quit 1
\endif
SELECT s1_retention.expect_blocked(
    'ALTER TABLE pgreact_mdm.policy_intent_bindings '
    'DISABLE TRIGGER intent_bindings_retained',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
SELECT s1_retention.expect_blocked(
    'DROP TRIGGER intent_bindings_no_truncate '
    'ON pgreact_mdm.policy_intent_bindings',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
SELECT s1_retention.expect_blocked(
    'ALTER TABLE pgreact_mdm.intent_case_identities '
    'DISABLE TRIGGER intent_case_identities_retained',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
SELECT s1_retention.expect_blocked(
    'DROP TRIGGER intent_case_identities_no_truncate '
    'ON pgreact_mdm.intent_case_identities',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
SELECT s1_retention.expect_blocked(
    'DROP OWNED BY mdm_helper_owner CASCADE',
    '2BP01',
    'cannot drop function mdm_admin.verify_installation() because extension pg_mdm requires it')
\gset
SELECT s1_retention.expect_blocked(
    'DROP FUNCTION pgreact_mdm.enforce_history_guard_ddl() CASCADE',
    '42501',
    'must be owner of function pgreact_mdm.enforce_history_guard_ddl')
\gset
RESET SESSION AUTHORIZATION;
REVOKE USAGE ON SCHEMA s1_retention FROM mdm_helper_owner;
REVOKE EXECUTE ON FUNCTION s1_retention.state(),
    s1_retention.expect_blocked(text, text, text) FROM mdm_helper_owner;

CREATE ROLE mdm_retention_ddl_owner NOLOGIN NOSUPERUSER NOBYPASSRLS;
GRANT USAGE, CREATE ON SCHEMA mdm_steward, pgreact_mdm TO mdm_retention_ddl_owner;
GRANT USAGE ON SCHEMA s1_retention TO mdm_retention_ddl_owner;
GRANT EXECUTE ON FUNCTION s1_retention.state(),
    s1_retention.expect_blocked(text, text, text) TO mdm_retention_ddl_owner;
SELECT pg_catalog.pg_get_userbyid(c.relowner) AS receipts_owner
FROM pg_catalog.pg_class AS c
WHERE c.oid = 'mdm_steward.policy_receipts_v1'::regclass
\gset
SELECT pg_catalog.pg_get_userbyid(c.relowner) AS requests_owner
FROM pg_catalog.pg_class AS c
WHERE c.oid = 'pgreact_mdm.intent_requests'::regclass
\gset
SELECT pg_catalog.pg_get_userbyid(c.relowner) AS attempts_owner
FROM pg_catalog.pg_class AS c
WHERE c.oid = 'pgreact_mdm.intent_attempts'::regclass
\gset
ALTER TABLE mdm_steward.policy_receipts_v1 OWNER TO mdm_retention_ddl_owner;
ALTER TABLE pgreact_mdm.intent_requests OWNER TO mdm_retention_ddl_owner;
ALTER TABLE pgreact_mdm.intent_attempts OWNER TO mdm_retention_ddl_owner;
SET SESSION AUTHORIZATION mdm_retention_ddl_owner;
SELECT s1_retention.expect_blocked(
    'ALTER TABLE mdm_steward.policy_receipts_v1 DISABLE TRIGGER pgreact_mdm_receipts_retention',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
SELECT s1_retention.expect_blocked(
    'DROP TRIGGER pgreact_mdm_receipts_retention ON mdm_steward.policy_receipts_v1',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
SELECT s1_retention.expect_blocked(
    'ALTER TABLE pgreact_mdm.intent_requests DISABLE TRIGGER intent_requests_retained',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
SELECT s1_retention.expect_blocked(
    'DROP TRIGGER intent_requests_retained ON pgreact_mdm.intent_requests',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
RESET SESSION AUTHORIZATION;
ALTER TABLE mdm_steward.policy_receipts_v1 OWNER TO :"receipts_owner";
ALTER TABLE pgreact_mdm.intent_requests OWNER TO :"requests_owner";
SET SESSION AUTHORIZATION mdm_retention_ddl_owner;
SELECT s1_retention.expect_blocked(
    'DROP OWNED BY mdm_retention_ddl_owner CASCADE',
    '55000',
    'PGREACT_MDM_RETENTION_DDL: protected history guards cannot be removed or disabled')
\gset
RESET SESSION AUTHORIZATION;
ALTER TABLE pgreact_mdm.intent_attempts OWNER TO :"attempts_owner";
REVOKE USAGE, CREATE ON SCHEMA mdm_steward, pgreact_mdm, s1_retention
    FROM mdm_retention_ddl_owner;
REVOKE EXECUTE ON FUNCTION s1_retention.state(),
    s1_retention.expect_blocked(text, text, text) FROM mdm_retention_ddl_owner;
DROP ROLE mdm_retention_ddl_owner;

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
DO $drop_blocked$
DECLARE expected_message text;
BEGIN
    expected_message := format(
        'PGREACT_MDM_RETENTION: '
        'managed policy history for case %s is not eligible for deletion',
        (SELECT case_key FROM s1_retention.target));
    PERFORM s1_retention.expect_blocked(
        'SELECT mdm_admin.drop_entity(''policy_qualification'', ''policy_qualification'')',
        '55000', expected_message);
END
$drop_blocked$;
RESET ROLE;
RESET SESSION AUTHORIZATION;

UPDATE mdm_steward.policy_cases_v1
SET resolved_at = clock_timestamp() - interval '91 days'
WHERE entity_name = 'policy_qualification';
UPDATE mdm_steward.policy_receipts_v1
SET created_at = clock_timestamp() - interval '89 days'
WHERE receipt_id = (SELECT receipt_id FROM s1_retention.target);

DO $young_receipt$
DECLARE expected_message text;
BEGIN
    expected_message := format(
        'PGREACT_MDM_RETENTION: receipt for managed case %s is younger than 90 days',
        (SELECT case_key FROM s1_retention.target));
    PERFORM s1_retention.expect_blocked(
        'DELETE FROM mdm_steward.policy_receipts_v1 WHERE receipt_id = '
        '(SELECT receipt_id FROM s1_retention.target)', '55000', expected_message);
    PERFORM s1_retention.expect_blocked(
        'TRUNCATE TABLE mdm_steward.policy_receipts_v1', '55000',
        'PGREACT_MDM_RETENTION: managed policy receipts remain within the retention period');
END
$young_receipt$;

UPDATE mdm_steward.policy_receipts_v1
SET created_at = clock_timestamp() - interval '91 days'
WHERE receipt_id = (SELECT receipt_id FROM s1_retention.target);

CREATE TABLE s1_retention.before_aged_receipt_truncate AS
SELECT s1_retention.state() AS vector;
BEGIN;
TRUNCATE TABLE mdm_steward.policy_receipts_v1;
ROLLBACK;
DO $aged_receipt_truncate$
BEGIN
    IF s1_retention.state() IS DISTINCT FROM
       (SELECT vector FROM s1_retention.before_aged_receipt_truncate) THEN
        RAISE EXCEPTION 'eligible receipt TRUNCATE rollback changed exact state';
    END IF;
END
$aged_receipt_truncate$;

DO $aged_prune$
DECLARE changed bigint;
BEGIN
    DELETE FROM mdm_steward.policy_receipts_v1
    WHERE receipt_id = (SELECT receipt_id FROM s1_retention.target);
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed <> 1 THEN
        RAISE EXCEPTION 'eligible receipt DELETE removed %, expected exactly one', changed;
    END IF;
END
$aged_prune$;

CREATE TABLE s1_retention.before_aged_case_truncate AS
SELECT s1_retention.state() AS vector;
BEGIN;
TRUNCATE TABLE mdm_steward.policy_cases_v1;
ROLLBACK;
DO $aged_case_truncate$
BEGIN
    IF s1_retention.state() IS DISTINCT FROM
       (SELECT vector FROM s1_retention.before_aged_case_truncate) THEN
        RAISE EXCEPTION 'eligible case TRUNCATE rollback changed exact state';
    END IF;
END
$aged_case_truncate$;

DO $aged_case_delete$
DECLARE changed bigint;
BEGIN
    DELETE FROM mdm_steward.policy_cases_v1
    WHERE case_key = (SELECT case_key FROM s1_retention.target);
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed <> 1 THEN
        RAISE EXCEPTION 'eligible case DELETE removed %, expected exactly one', changed;
    END IF;
END
$aged_case_delete$;

SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT mdm_admin.drop_entity('policy_qualification', 'policy_qualification')->>'entity_name'
    = 'policy_qualification' AS entity_drop_succeeded
\gset
RESET ROLE;
RESET SESSION AUTHORIZATION;
\if :entity_drop_succeeded
\else
\quit 1
\endif

DO $drop_complete$
BEGIN
    IF EXISTS (SELECT 1 FROM mdm_internal.entities WHERE entity_name = 'policy_qualification')
       OR EXISTS (SELECT 1 FROM mdm_steward.policy_cases_v1 WHERE entity_name = 'policy_qualification')
       OR EXISTS (SELECT 1 FROM mdm_steward.policy_receipts_v1) THEN
        RAISE EXCEPTION 'aged MDM entity drop left managed cases or receipts';
    END IF;
END
$drop_complete$;

BEGIN;
ALTER EVENT TRIGGER pgre_mdm_history_guard_ddl DISABLE;
\ir ../../../../integrations/pg-mdm/sql/retention-guard-health.sql
ROLLBACK;

BEGIN;
DROP EVENT TRIGGER pgre_mdm_history_guard_ddl;
\ir ../../../../integrations/pg-mdm/sql/retention-guard-health.sql
ROLLBACK;

\ir ../../../../integrations/pg-mdm/sql/retention-guard-health.sql

BEGIN;
CREATE OR REPLACE FUNCTION pgreact_mdm.guard_policy_history_retention()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
    RETURN OLD;
END
$function$;
\ir ../../../../integrations/pg-mdm/sql/retention-guard-health.sql
ROLLBACK;

SELECT 'PASS: managed history blocks marker tampering and early DDL, and health detects a replaced policy retention function; both DROP OWNED attempts preserve state; aged pruning succeeds';
