\set ON_ERROR_STOP on
SET TIME ZONE 'UTC';

CREATE SCHEMA m34_reference;
CREATE TABLE m34_reference.orders_current (
    order_id bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    label text NOT NULL
);
INSERT INTO m34_reference.orders_current VALUES
    (1, 10, 'review'), (2, 20, 'review'), (4, 40, 'review');
CREATE VIEW m34_reference.orders_current_match AS
SELECT order_id, customer_id, label FROM m34_reference.orders_current;
CREATE VIEW m34_reference.orders_proposed AS
SELECT 1::bigint AS order_id, 10::bigint AS customer_id, 'approved'::text AS label
UNION ALL
SELECT 2::bigint, 20::bigint, 'review'::text
UNION ALL
SELECT 3::bigint, 30::bigint, 'review'::text;
CREATE TABLE m34_reference.candidates_current (
    subject_id bigint NOT NULL,
    candidate_id bigint NOT NULL,
    priority bigint NOT NULL,
    result text NOT NULL
);
INSERT INTO m34_reference.candidates_current VALUES
    (10, 100, 1, 'approve'), (20, 200, 1, 'hold');
CREATE VIEW m34_reference.candidates_current_view AS
SELECT subject_id, candidate_id, priority, result
FROM m34_reference.candidates_current;
CREATE VIEW m34_reference.candidates_proposed_view AS
SELECT 10::bigint AS subject_id, 101::bigint AS candidate_id, 0::bigint AS priority,
       'reject'::text AS result
UNION ALL
SELECT 30::bigint, 300::bigint, 1::bigint, 'approve'::text;
CREATE TABLE m34_reference.customers_current (customer_id bigint PRIMARY KEY);
INSERT INTO m34_reference.customers_current VALUES (10), (20);
CREATE VIEW m34_reference.customers_proposed AS
SELECT 10::bigint AS customer_id
UNION ALL
SELECT 30::bigint;
CREATE TABLE m34_reference.rls_orders (order_id bigint PRIMARY KEY);
ALTER TABLE m34_reference.rls_orders ENABLE ROW LEVEL SECURITY;

DO $m34$
DECLARE
    current_declaration pgreact_api.declaration;
    proposed_declaration pgreact_api.declaration;
    current_decision pgreact_api.declaration;
    proposed_decision pgreact_api.declaration;
    current_policy pgreact_api.declaration;
    proposed_policy pgreact_api.declaration;
    rls_declaration pgreact_api.declaration;
    preview jsonb;
    deployed jsonb;
    comparison jsonb;
    before_checksum text;
    after_checksum text;
    result_count bigint;
    lifecycle_count bigint;
    work_count bigint;
BEGIN
    current_declaration := pgreact.rule(
        'm34-order-rule', 'm34_reference.orders_current_match'::regclass, 'order_id'::name);
    proposed_declaration := pgreact.rule(
        'm34-order-rule', 'm34_reference.orders_proposed'::regclass, 'order_id'::name);
    preview := pgreact.preview(current_declaration);
    deployed := pgreact.deploy(current_declaration, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M34 fixture deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-18 09:00:00+00');

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    comparison := pgreact.compare(
        proposed_declaration,
        pgreact_api.target('rule', 'm34-order-rule'),
        jsonb_build_object('evidence_limit', 10));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF comparison ->> 'state' <> 'ready'
       OR comparison -> 'summary' ->> 'counts_exact' <> 'true'
       OR (comparison -> 'summary' ->> 'current_count')::bigint <> 3
       OR (comparison -> 'summary' ->> 'proposed_count')::bigint <> 3
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'added')::bigint <> 1
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'removed')::bigint <> 1
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'changed')::bigint <> 1
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'unchanged')::bigint <> 1
       OR (comparison -> 'cost' ->> 'rows_considered')::bigint <> 6
       OR comparison -> 'cost' ->> 'elapsed_ms' IS NULL
       OR comparison -> 'evidence' ->> 'authoritative_checksum_before' <> before_checksum
       OR comparison -> 'evidence' ->> 'authoritative_checksum_after' <> after_checksum
       OR before_checksum <> after_checksum
       OR NOT (comparison -> 'findings' @> jsonb_build_array(
           jsonb_build_object('code', 'M34_NO_EFFECT')))
    THEN
        RAISE EXCEPTION 'M34 comparison result mismatch: %', comparison;
    END IF;

    SELECT count(*) INTO result_count
    FROM pgreact.compare_results(
        proposed_declaration,
        pgreact_api.target('rule', 'm34-order-rule'),
        jsonb_build_object('evidence_limit', 10));
    IF result_count <> 16 THEN
        RAISE EXCEPTION 'M34 relational comparison row count mismatch: %', result_count;
    END IF;
    SELECT count(*) FILTER (WHERE result_set = 'lifecycle'),
           count(*) FILTER (WHERE result_set = 'work')
    INTO lifecycle_count, work_count
    FROM pgreact.compare_results(
        proposed_declaration,
        pgreact_api.target('rule', 'm34-order-rule'),
        jsonb_build_object('evidence_limit', 10));
    IF lifecycle_count <> 3 OR work_count <> 3 THEN
        RAISE EXCEPTION 'M34 relational projections mismatch: %, %',
            lifecycle_count, work_count;
    END IF;

    comparison := pgreact.compare(
        proposed_declaration,
        pgreact_api.target('rule', 'm34-order-rule'),
        jsonb_build_object('evidence_limit', 1));
    IF comparison ->> 'state' <> 'partial'
       OR comparison ->> 'truncated' <> 'true'
       OR comparison -> 'summary' ->> 'counts_exact' <> 'false'
       OR NOT (comparison -> 'findings' @> jsonb_build_array(
           jsonb_build_object('code', 'M34_COMPARISON_INCOMPLETE')))
    THEN
        RAISE EXCEPTION 'M34 bounded evidence result mismatch: %', comparison;
    END IF;

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    comparison := pgreact.compare(
        proposed_declaration,
        pgreact_api.target('rule', 'm34-order-rule'),
        jsonb_build_object('evidence_limit', 3));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF comparison ->> 'state' <> 'partial'
       OR comparison -> 'summary' ->> 'counts_exact' <> 'false'
       OR comparison -> 'evidence' ->> 'authoritative_checksum_before' <> before_checksum
       OR comparison -> 'evidence' ->> 'authoritative_checksum_after' <> after_checksum
       OR before_checksum <> after_checksum
    THEN
        RAISE EXCEPTION 'M34 delta truncation result mismatch: %', comparison;
    END IF;

    before_checksum := pgreact_internal.m34_authoritative_checksum();
    BEGIN
        PERFORM pgreact.compare(
            proposed_declaration,
            pgreact_api.target('rule', 'm34-order-rule'),
            jsonb_build_object('evidence_limit', 0));
        RAISE EXCEPTION 'M34 invalid limit unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF position('M34_RESOURCE_LIMIT' IN SQLERRM) = 0 THEN
            RAISE;
        END IF;
    END;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF before_checksum <> after_checksum THEN
        RAISE EXCEPTION 'M34 invalid limit changed authoritative state';
    END IF;

    rls_declaration := pgreact.rule(
        'm34-order-rule', 'm34_reference.rls_orders'::regclass, 'order_id'::name);
    before_checksum := pgreact_internal.m34_authoritative_checksum();
    BEGIN
        PERFORM pgreact.compare(
            rls_declaration,
            pgreact_api.target('rule', 'm34-order-rule'),
            jsonb_build_object('evidence_limit', 10));
        RAISE EXCEPTION 'M34 RLS source unexpectedly succeeded';
    EXCEPTION WHEN OTHERS THEN
        IF position('M34_RLS_UNSUPPORTED' IN SQLERRM) = 0 THEN
            RAISE;
        END IF;
    END;
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF before_checksum <> after_checksum THEN
        RAISE EXCEPTION 'M34 RLS rejection changed authoritative state';
    END IF;

    current_decision := pgreact.decision(
        'm34-decision', 'm34_reference.candidates_current_view'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-01-01 00:00:00+00');
    proposed_decision := pgreact.decision(
        'm34-decision', 'm34_reference.candidates_proposed_view'::regclass,
        'subject_id'::name, 'candidate_id'::name, 'priority'::name,
        ARRAY['result']::name[], '2026-01-01 00:00:00+00');
    preview := pgreact.preview(current_decision);
    deployed := pgreact.deploy(current_decision, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M34 decision deployment failed: %', deployed;
    END IF;
    PERFORM pgreact.run('2026-08-18 09:00:00+00');
    before_checksum := pgreact_internal.m34_authoritative_checksum();
    comparison := pgreact.compare(
        proposed_decision,
        pgreact_api.target('decision_program', 'm34-decision'),
        jsonb_build_object('evidence_limit', 10));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF comparison ->> 'state' <> 'ready'
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'added')::bigint <> 1
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'removed')::bigint <> 0
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'changed')::bigint <> 2
       OR NOT (comparison -> 'proposed' @> jsonb_build_array(
           jsonb_build_object('subject_key', '20', 'state', 'NO_CANDIDATE')))
       OR before_checksum <> after_checksum
    THEN
        RAISE EXCEPTION 'M34 decision comparison mismatch: %', comparison;
    END IF;

    current_policy := pgreact.policy_set(
        'm34-customers', '1', ARRAY[current_declaration],
        'm34_reference.customers_current'::regclass,
        ARRAY['customer_id']::name[], '2026-01-01 00:00:00+00');
    proposed_policy := pgreact.policy_set(
        'm34-customers', '2', ARRAY[current_declaration],
        'm34_reference.customers_proposed'::regclass,
        ARRAY['customer_id']::name[], '2026-01-01 00:00:00+00');
    preview := pgreact.preview(current_policy);
    deployed := pgreact.deploy(current_policy, jsonb_build_object(
        'preview_digest', preview -> 'summary' ->> 'preview_digest'));
    IF deployed ->> 'state' <> 'deployed' THEN
        RAISE EXCEPTION 'M34 policy-set deployment failed: %', deployed;
    END IF;
    before_checksum := pgreact_internal.m34_authoritative_checksum();
    comparison := pgreact.compare(
        proposed_policy,
        pgreact_api.target('policy_set', 'm34-customers', '1'),
        jsonb_build_object('evidence_limit', 10));
    after_checksum := pgreact_internal.m34_authoritative_checksum();
    IF comparison ->> 'state' <> 'ready'
       OR comparison -> 'evidence' ->> 'complete' <> 'true'
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'added')::bigint <> 1
       OR (comparison -> 'summary' -> 'delta_counts' ->> 'removed')::bigint <> 1
       OR before_checksum <> after_checksum
    THEN
        RAISE EXCEPTION 'M34 policy-set comparison mismatch: %', comparison;
    END IF;

    IF jsonb_array_length(pgreact_internal.m34_finding_registry() -> 'codes') <> 18 THEN
        RAISE EXCEPTION 'M34 finding registry is incomplete';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('pgreact', 'pgreact_api')
          AND p.prosecdef
          AND NOT (COALESCE(p.proconfig, ARRAY[]::text[]) @>
                   ARRAY['search_path=pg_catalog, pg_temp'])
    ) THEN
        RAISE EXCEPTION 'M34 public SECURITY DEFINER routine has unsafe search_path';
    END IF;
END
$m34$;
