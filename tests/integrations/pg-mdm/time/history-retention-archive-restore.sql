\set ON_ERROR_STOP on
\set VERBOSITY verbose
SET TIME ZONE 'UTC';

CREATE SCHEMA s1_retention_archive_check;

CREATE FUNCTION s1_retention_archive_check.state() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $state$
WITH target AS (
    SELECT * FROM s1_retention.archive_target
)
SELECT jsonb_build_object(
    'entity', (SELECT to_jsonb(e) FROM mdm_internal.entities e
               WHERE e.entity_name = 'policy_qualification'),
    'mdm_bindings', (SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.binding_id), '[]')
                     FROM mdm_steward.policy_bindings_v1 b
                     WHERE b.entity_id = (SELECT entity_id FROM mdm_internal.entities
                                          WHERE entity_name = 'policy_qualification')),
    'target_case', (SELECT to_jsonb(c) FROM mdm_steward.policy_cases_v1 c
                    JOIN target t ON t.case_key = c.case_key),
    'other_cases', (SELECT COALESCE(jsonb_agg(to_jsonb(c) ORDER BY c.case_key), '[]')
                    FROM mdm_steward.policy_cases_v1 c
                    JOIN target t ON c.entity_name = 'policy_qualification'
                                 AND c.case_key <> t.case_key),
    'target_receipt', (SELECT to_jsonb(r) FROM mdm_steward.policy_receipts_v1 r
                       JOIN target t ON t.receipt_id = r.receipt_id),
    'other_receipts', (SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.receipt_id), '[]')
                       FROM mdm_steward.policy_receipts_v1 r
                       JOIN target t ON r.binding_id = t.binding_id
                                    AND r.receipt_id <> t.receipt_id),
    'adapter_bindings', (SELECT COALESCE(jsonb_agg(to_jsonb(b) ORDER BY b.binding_id), '[]')
                         FROM pgreact_mdm.policy_intent_bindings b
                         WHERE b.entity_name = 'policy_qualification'),
    'identities', (SELECT COALESCE(jsonb_agg(to_jsonb(i) ORDER BY i.case_identity), '[]')
                   FROM pgreact_mdm.intent_case_identities i
                   WHERE i.entity_name = 'policy_qualification'),
    'identity_sequence', (SELECT jsonb_build_object('last_value', last_value, 'is_called', is_called)
                          FROM pgreact_mdm.intent_case_identities_case_identity_seq),
    'requests', (SELECT COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.request_key), '[]')
                 FROM pgreact_mdm.intent_requests r
                 JOIN target t USING (binding_id)),
    'attempts', (SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.episode_id, a.attempt_no), '[]')
                 FROM pgreact_mdm.intent_attempts a
                 JOIN target t USING (binding_id)),
    'holds', (SELECT COALESCE(jsonb_agg(to_jsonb(h) ORDER BY h.case_key, h.policy_revision), '[]')
              FROM pgreact_mdm.intent_holds h
              JOIN target t USING (binding_id)))
$state$;

CREATE FUNCTION s1_retention_archive_check.expect_blocked(
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
    before_state := s1_retention_archive_check.state();
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
    after_state := s1_retention_archive_check.state();
    IF after_state IS DISTINCT FROM before_state THEN
        RAISE EXCEPTION 'blocked retention operation changed exact archive state: before %, after %',
            before_state, after_state;
    END IF;
END
$assertion$;

GRANT USAGE ON SCHEMA s1_retention, s1_retention_archive_check TO mdm_legacy_administrator;
GRANT SELECT ON s1_retention.archive_target TO mdm_legacy_administrator;
GRANT EXECUTE ON FUNCTION s1_retention_archive_check.state(),
    s1_retention_archive_check.expect_blocked(text, text, text) TO mdm_legacy_administrator;

DO $archive_boundary$
BEGIN
    IF (SELECT count(*) FROM s1_retention.archive_target) <> 1 THEN
        RAISE EXCEPTION 'logical retention archive target must contain exactly one applied receipt';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM s1_retention.archive_target t
        JOIN mdm_steward.policy_cases_v1 c ON c.case_key = t.case_key
        JOIN mdm_steward.policy_receipts_v1 r ON r.receipt_id = t.receipt_id
        WHERE c.status = 'resolved'
          AND c.resolved_at <= clock_timestamp() - interval '90 days'
          AND r.created_at > clock_timestamp() - interval '90 days'
          AND r.request_key = t.request_key
          AND r.binding_id = t.binding_id)
    THEN
        RAISE EXCEPTION 'logical retention archive did not contain its exact 89/91-day boundary';
    END IF;
END
$archive_boundary$;

SELECT s1_retention_archive_check.expect_blocked(
    format('DELETE FROM mdm_steward.policy_receipts_v1 WHERE receipt_id=%L', target.receipt_id),
    '55000', format('PGREACT_MDM_RETENTION: receipt for managed case %s is younger than 90 days',
                    target.case_key))
FROM s1_retention.archive_target AS target;
SELECT s1_retention_archive_check.expect_blocked(
    format('DELETE FROM mdm_steward.policy_cases_v1 WHERE case_key=%L', target.case_key),
    '55000', format('PGREACT_MDM_RETENTION: receipts for managed case %s must be pruned first',
                    target.case_key))
FROM s1_retention.archive_target AS target;
SELECT s1_retention_archive_check.expect_blocked(
    'TRUNCATE TABLE mdm_steward.policy_receipts_v1', '55000',
    'PGREACT_MDM_RETENTION: managed policy receipts remain within the retention period');
SELECT s1_retention_archive_check.expect_blocked(
    'TRUNCATE TABLE mdm_steward.policy_cases_v1', '55000',
    'PGREACT_MDM_RETENTION: managed cases or receipts remain protected');
SET SESSION AUTHORIZATION mdm_legacy_login;
SET ROLE mdm_legacy_administrator;
SELECT s1_retention_archive_check.expect_blocked(
    'SELECT mdm_admin.drop_entity(''policy_qualification'', ''policy_qualification'')',
    '55000', format('PGREACT_MDM_RETENTION: receipt for managed case %s is younger than 90 days',
                    (SELECT case_key FROM s1_retention.archive_target)));
RESET ROLE;
RESET SESSION AUTHORIZATION;

CREATE TABLE s1_retention_archive_check.before_aged_prune AS
SELECT s1_retention_archive_check.state() AS vector;
UPDATE mdm_steward.policy_receipts_v1
SET created_at = clock_timestamp() - interval '91 days'
WHERE receipt_id = (SELECT receipt_id FROM s1_retention.archive_target);

DO $aged_prune$
DECLARE
    target s1_retention.archive_target%ROWTYPE;
    changed bigint;
BEGIN
    SELECT * INTO STRICT target FROM s1_retention.archive_target;
    DELETE FROM mdm_steward.policy_receipts_v1 WHERE receipt_id = target.receipt_id;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed <> 1 THEN
        RAISE EXCEPTION 'eligible restored receipt DELETE removed %, expected exactly one', changed;
    END IF;
    DELETE FROM mdm_steward.policy_cases_v1 WHERE case_key = target.case_key;
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed <> 1 THEN
        RAISE EXCEPTION 'eligible restored case DELETE removed %, expected exactly one', changed;
    END IF;
END
$aged_prune$;

DO $pruned_vector$
DECLARE
    before_state jsonb;
    after_state jsonb;
    target s1_retention.archive_target%ROWTYPE;
BEGIN
    SELECT * INTO STRICT target FROM s1_retention.archive_target;
    SELECT vector INTO STRICT before_state
    FROM s1_retention_archive_check.before_aged_prune;
    after_state := s1_retention_archive_check.state();
    IF after_state - 'target_case' - 'target_receipt'
       IS DISTINCT FROM before_state - 'target_case' - 'target_receipt' THEN
        RAISE EXCEPTION 'aged pruning changed retained keys, attempts, bindings, entity, or unrelated history: before %, after %',
            before_state, after_state;
    END IF;
    IF after_state->'target_case' IS DISTINCT FROM 'null'::jsonb
       OR after_state->'target_receipt' IS DISTINCT FROM 'null'::jsonb THEN
        RAISE EXCEPTION 'aged pruning did not remove the selected case and receipt: %', after_state;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pgreact_mdm.intent_requests r
        JOIN s1_retention.archive_target t USING (binding_id, request_key))
       OR NOT EXISTS (
        SELECT 1 FROM pgreact_mdm.intent_attempts a
        JOIN s1_retention.archive_target t USING (binding_id, request_key)) THEN
        RAISE EXCEPTION 'aged pruning removed the matching request key or attempt';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM mdm_internal.entities WHERE entity_name = 'policy_qualification')
       OR NOT EXISTS (SELECT 1 FROM mdm_steward.policy_bindings_v1
                      WHERE binding_id = target.binding_id) THEN
        RAISE EXCEPTION 'aged pruning removed the retained entity or matching policy binding';
    END IF;
END
$pruned_vector$;

\ir ../../../../integrations/pg-mdm/sql/retention-guard-health.sql

SELECT 'PASS: restored 89-day history stays protected; aged pruning preserves request keys and bindings';
